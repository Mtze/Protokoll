import Foundation
import SharedKit

extension Summarizer {
    /// A protocol document with a guaranteed-valid frontmatter block.
    struct RepairedProtocol: Equatable {
        /// The full document, ready to write.
        var document: String
        /// The title to adopt (F9), if one could be determined.
        var title: String?
        /// The language to record (N8), if one could be determined.
        var language: String?
        /// What had to be fixed, for logging. Empty when the model complied.
        var repairs: [String]
    }

    /// Makes the model's output conform to the frontmatter contract, deterministically.
    ///
    /// The contract is a *file* invariant, not a prompt preference, so this always
    /// runs - the prompt asks, this guarantees. It repairs the wrapper only; it
    /// cannot rescue a bad body, and deliberately never discards content it is not
    /// confident is chatter.
    static func repairFrontmatter(
        _ output: String,
        session: Session,
        context: MeetingContext
    ) -> RepairedProtocol {
        var repairs: [String] = []
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. A wrapping code fence. Models like to fence Markdown.
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            repairs.append("stripped code fence")
        }

        // 2. Leading chatter before the frontmatter or the first heading.
        //    Only drop it when it is short enough to be unambiguously a preamble
        //    ("Here is the protocol:"). Anything longer is kept - losing real
        //    protocol content would be far worse than a cosmetic wart.
        if !text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let markerIndex = lines.firstIndex(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed == "---" || trimmed.hasPrefix("# ")
            }) {
                let preamble = lines[..<markerIndex].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preamble.isEmpty, preamble.count <= maxDroppablePreamble {
                    text = lines[markerIndex...].joined(separator: "\n")
                    repairs.append("dropped \(preamble.count)-character preamble")
                } else if !preamble.isEmpty {
                    repairs.append("kept \(preamble.count)-character preamble (too long to assume chatter)")
                }
            }
        }

        // 3. Parse whatever frontmatter survived.
        let (parsed, body) = Frontmatter.split(text)
        var title = parsed["title"]?.trimmingCharacters(in: .whitespaces)
        var language = parsed["language"]?.trimmingCharacters(in: .whitespaces)

        if title?.isEmpty ?? true {
            title = fallbackTitle(session: session, body: body.isEmpty ? text : body)
            repairs.append("synthesized missing title")
        }
        if language?.isEmpty ?? true {
            // The transcriber already detected this from the audio, which is more
            // reliable than asking the model to guess a second time.
            language = session.metadata.language
            if language != nil { repairs.append("used transcript language") }
        }

        // 4. Re-render with the pipeline-owned keys stamped in. The app already
        //    knows these, so generating them would only invite hallucination.
        var frontmatter = Frontmatter()
        if let title { frontmatter["title"] = title }
        if let language { frontmatter["language"] = language }
        if let date = context.date { frontmatter["date"] = date }
        if let minutes = context.durationMinutes { frontmatter["duration_minutes"] = String(minutes) }
        frontmatter["session"] = session.id

        let finalBody = body.isEmpty ? text : body
        let document = frontmatter.render(body: finalBody)

        if !repairs.isEmpty {
            AppLog.pipeline.warning("protocol frontmatter repaired session=\(session.id, privacy: .public): \(repairs.joined(separator: "; "), privacy: .public)")
        }
        return RepairedProtocol(document: document, title: title, language: language, repairs: repairs)
    }

    /// Preamble longer than this is assumed to be real content, not chatter.
    static let maxDroppablePreamble = 200

    /// Title when the model did not supply one: the user's explicit title, else
    /// the body's first `# ` heading, else the session's derived title.
    private static func fallbackTitle(session: Session, body: String) -> String? {
        if session.hasExplicitTitle, let existing = session.metadata.title, !existing.isEmpty {
            return existing
        }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return heading }
            }
        }
        return session.displayTitle
    }
}
