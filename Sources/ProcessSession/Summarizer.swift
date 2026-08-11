import Foundation
import SharedKit

public enum SummarizationError: Error, LocalizedError, Equatable {
    case transcriptMissing
    case claudeFailed(String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .transcriptMissing:
            return "No transcript.md to summarize. Run the transcribe step first."
        case let .claudeFailed(message):
            return "claude failed: \(message)"
        case .emptyOutput:
            return "claude produced no protocol output."
        }
    }
}

/// Summarizes a transcript into a protocol via `claude -p` in print mode with no
/// tools (decision #5). The transcript is piped on stdin; `claude` prints the
/// protocol; the Swift pipeline owns the file write and rotation (N10) and lifts
/// the auto-title (F9) out of the returned frontmatter.
public struct Summarizer: Sendable {
    let runner: CommandRunning
    let tools: ToolLocator
    let store: SessionStore
    let chunker: TranscriptChunker
    /// User's extra summary instructions, appended to the built-in prompt.
    let customInstructions: String
    /// `"auto"` (match the meeting, N8) or an ISO code to force the summary into.
    let summaryLanguage: String
    /// Overrides ``ToolLocator/claudeModel`` when non-empty.
    let summaryModel: String

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        store: SessionStore = SessionStore(),
        chunker: TranscriptChunker = TranscriptChunker(),
        customInstructions: String = "",
        summaryLanguage: String = "auto",
        summaryModel: String = ""
    ) {
        self.runner = runner
        self.tools = tools
        self.store = store
        self.chunker = chunker
        self.customInstructions = customInstructions
        self.summaryLanguage = summaryLanguage
        self.summaryModel = summaryModel
    }

    /// The custom instructions, prefixed with a language directive when the user
    /// forced a summary language (overrides N8). Fed to the prompt's `extra`.
    var effectiveInstructions: String {
        guard summaryLanguage != "auto", !summaryLanguage.trimmingCharacters(in: .whitespaces).isEmpty else {
            return customInstructions
        }
        let name = Locale(identifier: "en").localizedString(forLanguageCode: summaryLanguage) ?? summaryLanguage
        let directive = "Write the ENTIRE protocol in \(name), regardless of the meeting's language."
        return customInstructions.isEmpty ? directive : "\(directive)\n\n\(customInstructions)"
    }

    private var effectiveModel: String { summaryModel.isEmpty ? tools.claudeModel : summaryModel }

    public func summarize(
        session: Session,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> Session {
        guard let transcriptData = try? Data(contentsOf: session.transcriptURL),
              let transcriptDoc = String(data: transcriptData, encoding: .utf8),
              !transcriptDoc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.transcriptMissing
        }

        // Feed the model just the transcript body, not our frontmatter.
        let (_, body) = Frontmatter.split(transcriptDoc)
        let currentTitle = session.hasExplicitTitle ? session.metadata.title : nil

        // Long transcripts (N9) go through map-reduce; short ones stay single-shot.
        let chunks = chunker.chunk(body)
        let output: String
        if chunks.count <= 1 {
            output = try runClaude(
                prompt: SummarizePrompt.build(currentTitle: currentTitle, extra: effectiveInstructions),
                stdin: body, onProgress: onProgress
            )
        } else {
            output = try mapReduce(chunks: chunks, currentTitle: currentTitle, onProgress: onProgress)
        }

        let (frontmatter, protocolBody) = Frontmatter.split(output)

        // The pipeline owns the write + rotation.
        try store.writeProtocol(output, for: session)

        var updated = session
        // Adopt the generated title only when the user hasn't set one (F9).
        if !session.hasExplicitTitle, let title = frontmatter["title"], !title.isEmpty {
            updated.metadata.title = title
        }
        if let language = frontmatter["language"], !language.isEmpty {
            updated.metadata.language = language
        }
        updated.metadata.pipeline.summarizedAt = Date()
        _ = protocolBody // body already persisted via writeProtocol(output)
        return updated
    }

    /// One `claude -p` call (print mode, no tools).
    private func runClaude(
        prompt: String,
        stdin: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        AppLog.pipeline.debug("running claude model=\(effectiveModel, privacy: .public)")
        let result = try runner.run(
            executable: tools.claudeBinary,
            arguments: ["-p", prompt, "--model", effectiveModel],
            stdin: stdin,
            environment: nil,
            onStderrLine: onProgress
        )
        guard result.succeeded else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            AppLog.pipeline.error("claude exited \(result.exitCode, privacy: .public): \(stderr, privacy: .public)")
            throw SummarizationError.claudeFailed(stderr)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw SummarizationError.emptyOutput }
        return output
    }

    /// Map-reduce for long transcripts (N9): summarize each chunk, then a final
    /// synthesis pass. Chunk boundaries are also the NH3 checkpoints.
    private func mapReduce(
        chunks: [TranscriptChunk],
        currentTitle: String?,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        var partials: [String] = []
        for chunk in chunks {
            onProgress?("summarizing part \(chunk.index + 1)/\(chunks.count)")
            let partial = try runClaude(
                prompt: SummarizePrompt.map(chunkIndex: chunk.index, chunkCount: chunks.count),
                stdin: chunk.text,
                onProgress: onProgress
            )
            partials.append("## Part \(chunk.index + 1)\n\n\(partial)")
        }
        onProgress?("synthesizing final protocol")
        return try runClaude(
            prompt: SummarizePrompt.reduce(currentTitle: currentTitle, extra: effectiveInstructions),
            stdin: partials.joined(separator: "\n\n"),
            onProgress: onProgress
        )
    }
}
