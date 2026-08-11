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

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        store: SessionStore = SessionStore(),
        chunker: TranscriptChunker = TranscriptChunker()
    ) {
        self.runner = runner
        self.tools = tools
        self.store = store
        self.chunker = chunker
    }

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
                prompt: SummarizePrompt.build(currentTitle: currentTitle),
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
        AppLog.pipeline.debug("running claude model=\(tools.claudeModel, privacy: .public)")
        let result = try runner.run(
            executable: tools.claudeBinary,
            arguments: ["-p", prompt, "--model", tools.claudeModel],
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
            prompt: SummarizePrompt.reduce(currentTitle: currentTitle),
            stdin: partials.joined(separator: "\n\n"),
            onProgress: onProgress
        )
    }
}
