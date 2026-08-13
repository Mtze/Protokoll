import Foundation
import SharedKit

/// Errors surfaced by the transcription step.
public enum TranscriptionError: Error, LocalizedError, Equatable {
    case scriptNotFound
    case audioMissing(String)
    case engineFailed(String)
    case noOutput
    case timedOut(minutes: Int)

    public var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "transcribe.sh could not be located. Set TRANSCRIBE_SH or bundle it in Resources."
        case let .audioMissing(path):
            return "Audio file not found: \(path)"
        case let .engineFailed(message):
            return "Transcription failed: \(message)"
        case .noOutput:
            return "The transcription engine produced no output."
        case let .timedOut(minutes):
            return """
            Transcription did not finish within \(minutes) minutes and was stopped. \
            This usually means the engine is stuck re-decoding a passage. Check \
            Settings > Diagnostics: a GPU engine (mlx-whisper) is far faster and \
            far less prone to this than the CPU fallback.
            """
        }
    }
}

/// Runs local transcription by shelling out to the vendored `transcribe.sh`
/// (decision #4: reuse the hardened script rather than reimplement whisper),
/// then assembles a timestamped `transcript.md` with YAML frontmatter.
///
/// `transcript.md` is written once and treated as immutable afterwards (N10).
public struct Transcriber: Sendable {
    let runner: CommandRunning
    let tools: ToolLocator
    /// `"auto"` (detect) or an ISO code passed to `transcribe.sh --language`.
    let language: String
    /// Domain vocabulary seeded via `transcribe.sh --prompt` (may be empty).
    let vocabulary: String
    /// Overrides ``ToolLocator/transcriptionModel`` when non-empty.
    let model: String
    /// `"off"` disables the safe ffmpeg prep chain (high-pass + static gain).
    let preprocess: String

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        language: String = "auto",
        vocabulary: String = "",
        model: String = "",
        preprocess: String = "safe"
    ) {
        self.runner = runner
        self.tools = tools
        self.language = language
        self.vocabulary = vocabulary
        self.model = model
        self.preprocess = preprocess
    }

    private var effectiveModel: String { model.isEmpty ? tools.transcriptionModel : model }

    /// Wall-clock budget for one transcription, from the recording's length.
    ///
    /// A GPU engine runs at roughly 0.13x realtime and even the CPU fallback
    /// manages ~3.3x, so 10x realtime is generous for every healthy
    /// configuration while still catching a wedged engine. The 15-minute floor
    /// keeps short clips from tripping on model-download or warm-up time.
    static func timeout(forAudioSeconds seconds: TimeInterval) -> TimeInterval {
        max(15 * 60, seconds * 10)
    }

    /// The recording's duration, or `nil` when it cannot be read.
    private func audioDuration(of session: Session) -> TimeInterval? {
        if let recorded = session.metadata.duration, recorded > 0 { return recorded }
        return nil
    }

    /// Transcribes the session's `mic.m4a`, writing `transcript.md`. Progress
    /// lines from the engine are forwarded to `onProgress`.
    public func transcribe(
        session: Session,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> Session {
        guard let script = tools.transcribeScript() else { throw TranscriptionError.scriptNotFound }
        let audioURL = session.micAudioURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.audioMissing(audioURL.path)
        }

        let workDir = session.folder.appendingPathComponent(".transcribe-tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var arguments = [
            audioURL.path,
            "--model", effectiveModel,
            "--output-dir", workDir.path,
        ]
        if language != "auto", !language.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["--language", language]
        }
        if !vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--prompt", vocabulary]
        }
        if preprocess != "safe" {
            arguments += ["--preprocess", preprocess]
        }

        let budget = Self.timeout(forAudioSeconds: audioDuration(of: session) ?? 0)
        AppLog.pipeline.debug("running transcribe.sh model=\(effectiveModel, privacy: .public) lang=\(language, privacy: .public) audio=\(audioURL.lastPathComponent, privacy: .public) budget=\(budget, format: .fixed(precision: 0), privacy: .public)s")
        let result: CommandResult
        do {
            result = try runner.run(
                executable: script,
                arguments: arguments,
                stdin: nil,
                environment: nil,
                workingDirectory: session.folder,
                timeout: budget,
                onStderrLine: onProgress
            )
        } catch let timeout as CommandTimedOut {
            AppLog.pipeline.error("transcribe timed out session=\(session.id, privacy: .public) after \(timeout.timeout, format: .fixed(precision: 0), privacy: .public)s")
            throw TranscriptionError.timedOut(minutes: Int((timeout.timeout / 60).rounded()))
        }
        guard result.succeeded else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            AppLog.pipeline.error("transcribe.sh exited \(result.exitCode, privacy: .public): \(stderr, privacy: .public)")
            throw TranscriptionError.engineFailed(stderr)
        }

        // transcribe.sh names outputs after the input basename ("mic").
        let jsonURL = workDir.appendingPathComponent("mic.json")
        let txtURL = workDir.appendingPathComponent("mic.txt")
        let transcript = try assembleTranscript(jsonURL: jsonURL, txtURL: txtURL)

        try Data(transcript.markdown.utf8).write(to: session.transcriptURL, options: .atomic)

        var updated = session
        updated.metadata.language = transcript.language ?? updated.metadata.language
        updated.metadata.pipeline.transcribedAt = Date()
        return updated
    }

    struct AssembledTranscript {
        var markdown: String
        var language: String?
    }

    /// Builds `transcript.md` from the engine's JSON (preferred, has timestamps)
    /// or plain-text fallback, with mirrored frontmatter.
    func assembleTranscript(jsonURL: URL, txtURL: URL) throws -> AssembledTranscript {
        var language: String?
        var body: String

        if let data = try? Data(contentsOf: jsonURL),
           let parsed = try? JSONDecoder().decode(WhisperJSON.self, from: data),
           !parsed.segments.isEmpty {
            language = parsed.language
            body = parsed.segments.map { segment in
                "**[\(Self.timestamp(segment.start))]** \(segment.text.trimmingCharacters(in: .whitespaces))"
            }.joined(separator: "\n\n")
        } else if let text = try? String(contentsOf: txtURL, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = text
        } else {
            throw TranscriptionError.noOutput
        }

        var frontmatter = Frontmatter()
        frontmatter["kind"] = "transcript"
        if let language { frontmatter["language"] = language }
        frontmatter["generated"] = ISO8601DateFormatter().string(from: Date())
        let markdown = frontmatter.render(body: "# Transcript\n\n" + body + "\n")
        return AssembledTranscript(markdown: markdown, language: language)
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Subset of the JSON produced by `transcribe.sh` (any of its engines).
struct WhisperJSON: Decodable {
    struct Segment: Decodable {
        var start: Double
        var end: Double
        var text: String
    }
    var language: String?
    var segments: [Segment]
}
