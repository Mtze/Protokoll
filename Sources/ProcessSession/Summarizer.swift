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
    /// The user's body-spec template from `config/summary-prompt.md`. Empty means
    /// use ``SummarizePrompt/defaultBodyTemplate``.
    let template: String

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        store: SessionStore = SessionStore(),
        chunker: TranscriptChunker = TranscriptChunker(),
        customInstructions: String = "",
        summaryLanguage: String = "auto",
        summaryModel: String = "",
        template: String = ""
    ) {
        self.runner = runner
        self.tools = tools
        self.store = store
        self.chunker = chunker
        self.customInstructions = customInstructions
        self.summaryLanguage = summaryLanguage
        self.summaryModel = summaryModel
        self.template = template
    }

    private var effectiveModel: String { summaryModel.isEmpty ? tools.claudeModel : summaryModel }

    /// The body spec: the user's `config/summary-prompt.md` if present and
    /// non-empty, otherwise the built-in default.
    var bodyTemplate: String {
        let custom = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? SummarizePrompt.defaultBodyTemplate : custom
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
        let context = Self.meetingContext(for: session, transcriptBody: body)

        // Long transcripts (N9) go through map-reduce; short ones stay single-shot.
        let chunks = chunker.chunk(body)
        let output: String
        if chunks.count <= 1 {
            output = try runClaude(
                system: SummarizePrompt.systemPrompt(currentTitle: currentTitle, summaryLanguage: summaryLanguage),
                stdin: SummarizePrompt.userMessage(
                    transcript: body, context: context,
                    bodyTemplate: bodyTemplate, extra: customInstructions
                ),
                onProgress: onProgress
            )
        } else {
            output = try mapReduce(
                chunks: chunks, currentTitle: currentTitle, context: context, onProgress: onProgress
            )
        }

        // Repair before writing. `Frontmatter.split` yields an empty frontmatter
        // whenever line 1 is not `---`, so a single word of preamble or a
        // ```markdown fence used to be written verbatim into protocol.md while the
        // F9 auto-title and the language silently did not happen, with nothing
        // thrown and nothing logged.
        let repaired = Self.repairFrontmatter(output, session: session, context: context)
        try store.writeProtocol(repaired.document, for: session)

        var updated = session
        // Adopt the generated title only when the user hasn't set one (F9).
        if !session.hasExplicitTitle, let title = repaired.title, !title.isEmpty {
            updated.metadata.title = title
        }
        if let language = repaired.language, !language.isEmpty {
            updated.metadata.language = language
        }
        updated.metadata.pipeline.summarizedAt = Date()
        return updated
    }

    /// Facts the pipeline knows, so the model never infers them.
    static func meetingContext(for session: Session, transcriptBody: String) -> MeetingContext {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let started = session.metadata.startedAt
        return MeetingContext(
            date: dateFormatter.string(from: started),
            startTime: timeFormatter.string(from: started),
            durationMinutes: session.metadata.duration.map { Int(($0 / 60).rounded()) },
            projects: [],
            lastTimestamp: lastTimestamp(in: transcriptBody)
        )
    }

    /// The last `[HH:MM:SS]` marker in a transcript body, if any.
    static func lastTimestamp(in body: String) -> String? {
        for line in body.components(separatedBy: "\n").reversed() {
            if let (start, _) = TranscriptParser.leadingTimestamp(in: line) {
                let total = Int(start.rounded())
                return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            }
        }
        return nil
    }

    /// One `claude -p` call: print mode, no tools, contract in the system prompt.
    private func runClaude(
        system: String,
        stdin: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        AppLog.pipeline.debug("running claude model=\(effectiveModel, privacy: .public)")
        let result = try runner.run(
            executable: tools.claudeBinary,
            arguments: [
                "-p", SummarizePrompt.pointerPrompt,
                "--model", effectiveModel,
                "--append-system-prompt", system,
                // "no tools (decision #5)" was only ever a comment; make it true.
                "--permission-mode", "plan",
                "--disallowed-tools", "Bash,Edit,Write,Read,WebFetch,WebSearch",
            ],
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

    /// Map-reduce for long transcripts (N9): compress each chunk neutrally, then
    /// one synthesis pass driven by the same body spec as the single-shot path.
    /// Chunk boundaries are also the NH3 checkpoints.
    private func mapReduce(
        chunks: [TranscriptChunk],
        currentTitle: String?,
        context: MeetingContext,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        var partials: [String] = []
        for chunk in chunks {
            onProgress?("summarizing part \(chunk.index + 1)/\(chunks.count)")
            let partial = try runClaude(
                // The map step is intentionally *not* driven by the user template:
                // a shape-neutral intermediate keeps every output spec reachable.
                system: SummarizePrompt.map(
                    chunkIndex: chunk.index, chunkCount: chunks.count, timeRange: chunk.timeRange
                ),
                stdin: "<transcript_part>\n\(chunk.text)\n</transcript_part>",
                onProgress: onProgress
            )
            // Label with the real time range so the reducer has absolute time.
            let label = chunk.timeRange.map { "## Part \(chunk.index + 1) (\($0))" }
                ?? "## Part \(chunk.index + 1)"
            partials.append("\(label)\n\n\(partial)")
        }
        onProgress?("synthesizing final protocol")
        return try runClaude(
            system: SummarizePrompt.reduceSystemPrompt(
                currentTitle: currentTitle, summaryLanguage: summaryLanguage
            ),
            stdin: SummarizePrompt.userMessage(
                transcript: partials.joined(separator: "\n\n"),
                context: context,
                bodyTemplate: bodyTemplate,
                extra: customInstructions,
                transcriptTag: "notes"
            ),
            onProgress: onProgress
        )
    }
}
