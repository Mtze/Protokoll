import Foundation
import SharedKit

/// Errors surfaced by the transcription step.
public enum TranscriptionError: Error, LocalizedError, Equatable {
    case scriptNotFound
    case audioMissing(String)
    case engineFailed(String)
    case noOutput

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

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        language: String = "auto",
        vocabulary: String = "",
        model: String = ""
    ) {
        self.runner = runner
        self.tools = tools
        self.language = language
        self.vocabulary = vocabulary
        self.model = model
    }

    private var effectiveModel: String { model.isEmpty ? tools.transcriptionModel : model }

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
        AppLog.pipeline.debug("running transcribe.sh model=\(effectiveModel, privacy: .public) lang=\(language, privacy: .public) audio=\(audioURL.lastPathComponent, privacy: .public)")
        let result = try runner.run(
            executable: script,
            arguments: arguments,
            stdin: nil,
            environment: nil,
            onStderrLine: onProgress
        )
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
