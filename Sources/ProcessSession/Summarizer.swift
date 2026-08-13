import Foundation
import SharedKit

public enum SummarizationError: Error, LocalizedError, Equatable {
    case transcriptMissing
    case providerFailed(String)
    case emptyOutput
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptMissing:
            return "No transcript.md to summarize. Run the transcribe step first."
        case let .providerFailed(message):
            return "Summary provider failed: \(message)"
        case .emptyOutput:
            return "The summary provider produced no protocol output."
        case let .notConfigured(message):
            return "Summary provider not configured: \(message)"
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
    /// Overrides ``ToolLocator/claudeModel`` when non-empty. Used by the CLI
    /// provider only.
    let summaryModel: String
    /// Which engine summarizes (ADR-9): `cli`, `anthropic`, or `openai`.
    let providerKind: SummaryProviderKind
    /// Full model id for API providers (freeform).
    let summaryApiModel: String
    /// The resolved engine for the configured provider.
    private let engine: SummaryEngine
    /// Non-nil when the provider is misconfigured (missing key / base URL); the
    /// summarize step fails cleanly with this instead of making a doomed request.
    private let configError: String?

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        store: SessionStore = SessionStore(),
        chunker: TranscriptChunker = TranscriptChunker(),
        customInstructions: String = "",
        summaryLanguage: String = "auto",
        summaryModel: String = "",
        summaryProvider: String = "cli",
        summaryApiModel: String = "",
        summaryApiBaseURL: String = "",
        summaryMaxTokens: Int = 8192,
        http: HTTPPosting = URLSessionHTTPPoster()
    ) {
        self.runner = runner
        self.tools = tools
        self.store = store
        self.chunker = chunker
        self.customInstructions = customInstructions
        self.summaryLanguage = summaryLanguage
        self.summaryModel = summaryModel
        self.summaryApiModel = summaryApiModel

        let kind = SummaryProviderKind(summaryProvider)
        self.providerKind = kind
        switch kind {
        case .cli:
            self.engine = ClaudeCLIEngine(runner: runner, claudeBinary: tools.claudeBinary)
            self.configError = nil
        case .anthropic, .openai:
            let key = SummaryAPI.resolveKey(environment: tools.environment, provider: kind) ?? ""
            let baseEmpty = summaryApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if key.isEmpty {
                self.configError = "no API key (set it in Settings or SUMMARY_API_KEY)"
            } else if kind == .openai, baseEmpty {
                self.configError = "no base URL for the OpenAI-compatible provider"
            } else {
                self.configError = nil
            }
            if kind == .anthropic {
                self.engine = AnthropicEngine(http: http, apiKey: key,
                                              baseURL: summaryApiBaseURL, maxTokens: summaryMaxTokens)
            } else {
                self.engine = OpenAIEngine(http: http, apiKey: key,
                                           baseURL: summaryApiBaseURL, maxTokens: summaryMaxTokens)
            }
        }
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

    private var effectiveModel: String {
        switch providerKind {
        case .cli: return summaryModel.isEmpty ? tools.claudeModel : summaryModel
        case .anthropic, .openai: return summaryApiModel
        }
    }

    public func summarize(
        session: Session,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> Session {
        if let configError { throw SummarizationError.notConfigured(configError) }
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
            output = try runEngine(
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

    /// One call to the configured engine (CLI or API).
    private func runEngine(
        prompt: String,
        stdin: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        try engine.complete(prompt: prompt, input: stdin, model: effectiveModel, onProgress: onProgress)
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
            let partial = try runEngine(
                prompt: SummarizePrompt.map(chunkIndex: chunk.index, chunkCount: chunks.count),
                stdin: chunk.text,
                onProgress: onProgress
            )
            partials.append("## Part \(chunk.index + 1)\n\n\(partial)")
        }
        onProgress?("synthesizing final protocol")
        return try runEngine(
            prompt: SummarizePrompt.reduce(currentTitle: currentTitle, extra: effectiveInstructions),
            stdin: partials.joined(separator: "\n\n"),
            onProgress: onProgress
        )
    }
}
