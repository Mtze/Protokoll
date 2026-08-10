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

    public init(runner: CommandRunning, tools: ToolLocator = ToolLocator(), store: SessionStore = SessionStore()) {
        self.runner = runner
        self.tools = tools
        self.store = store
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
        let prompt = SummarizePrompt.build(currentTitle: session.hasExplicitTitle ? session.metadata.title : nil)

        let result = try runner.run(
            executable: tools.claudeBinary,
            arguments: ["-p", prompt, "--model", tools.claudeModel],
            stdin: body,
            environment: nil,
            onStderrLine: onProgress
        )
        guard result.succeeded else {
            throw SummarizationError.claudeFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw SummarizationError.emptyOutput }

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
}
