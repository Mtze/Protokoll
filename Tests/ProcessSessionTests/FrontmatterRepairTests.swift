import Foundation
import Testing
@testable import ProcessSession
@testable import SharedKit

/// The frontmatter contract is a *file* invariant, so it is guaranteed in Swift
/// rather than merely requested in the prompt.
///
/// The bug these guard: `Frontmatter.split` returns an empty frontmatter whenever
/// line 1 is not `---`, so one word of preamble or a ```markdown fence meant
/// `protocol.md` was written verbatim *including the chatter*, the F9 auto-title
/// silently did not happen, the language was silently not recorded, and nothing
/// was thrown or logged.
struct FrontmatterRepairTests {

    @Test func compliantOutputNeedsNoRepair() throws {
        let (session, context) = try makeSession()
        let output = "---\ntitle: Weekly Sync\nlanguage: de\n---\n\n# Weekly Sync\n\nBody."
        let repaired = Summarizer.repairFrontmatter(output, session: session, context: context)
        #expect(repaired.repairs.isEmpty)
        #expect(repaired.title == "Weekly Sync")
        #expect(repaired.language == "de")
        #expect(repaired.document.hasPrefix("---"))
    }

    @Test func stripsAWrappingCodeFence() throws {
        let (session, context) = try makeSession()
        let output = "```markdown\n---\ntitle: Fenced\nlanguage: en\n---\n\n# Fenced\n\nBody.\n```"
        let repaired = Summarizer.repairFrontmatter(output, session: session, context: context)
        #expect(repaired.title == "Fenced")
        #expect(!repaired.document.contains("```"))
        #expect(repaired.repairs.contains { $0.contains("code fence") })
    }

    @Test func dropsShortLeadingChatter() throws {
        let (session, context) = try makeSession()
        let output = "Here is the protocol:\n\n---\ntitle: Chatty\nlanguage: en\n---\n\n# Chatty\n\nBody."
        let repaired = Summarizer.repairFrontmatter(output, session: session, context: context)
        #expect(repaired.title == "Chatty")
        #expect(!repaired.document.contains("Here is the protocol"))
    }

    /// The important half of that rule: never delete what might be real content.
    @Test func keepsLongLeadingTextRatherThanRiskDeletingContent() throws {
        let (session, context) = try makeSession()
        let essay = String(repeating: "This is substantive prose that must not be discarded. ", count: 10)
        let output = "\(essay)\n\n# Heading\n\nBody."
        let repaired = Summarizer.repairFrontmatter(output, session: session, context: context)
        #expect(repaired.document.contains("substantive prose"))
        #expect(repaired.repairs.contains { $0.contains("too long to assume chatter") })
    }

    /// The regression that mattered most: no frontmatter at all used to be written
    /// verbatim with the title silently skipped.
    @Test func synthesizesFrontmatterWhenTheModelEmitsNone() throws {
        let (session, context) = try makeSession()
        let repaired = Summarizer.repairFrontmatter(
            "# Sprint Review\n\nWe discussed the roadmap.", session: session, context: context
        )
        #expect(repaired.document.hasPrefix("---"))
        // Title lifted from the first heading.
        #expect(repaired.title == "Sprint Review")
        let (frontmatter, body) = Frontmatter.split(repaired.document)
        #expect(frontmatter["title"] == "Sprint Review")
        #expect(body.contains("We discussed the roadmap."))
    }

    @Test func repairsAnUnterminatedFrontmatterBlock() throws {
        let (session, context) = try makeSession()
        // Opening `---` with no closing one: split() gives up and returns it all.
        let output = "---\ntitle: Broken\nlanguage: en\n\n# Broken\n\nBody."
        let repaired = Summarizer.repairFrontmatter(output, session: session, context: context)
        let (frontmatter, _) = Frontmatter.split(repaired.document)
        #expect(frontmatter["title"] != nil)
        #expect(!repaired.repairs.isEmpty)
    }

    /// Language falls back to what the transcriber detected from the audio, which
    /// is more reliable than asking the model to guess a second time.
    @Test func fallsBackToTheTranscriptLanguage() throws {
        var (session, context) = try makeSession()
        session.metadata.language = "de"
        let repaired = Summarizer.repairFrontmatter(
            "# Ohne Sprache\n\nInhalt.", session: session, context: context
        )
        #expect(repaired.language == "de")
    }

    /// Facts the app already knows are stamped by the pipeline, never generated -
    /// hallucination-proof by construction.
    @Test func stampsPipelineOwnedMetadata() throws {
        let (session, _) = try makeSession()
        let context = MeetingContext(date: "2026-08-13", durationMinutes: 47)
        let repaired = Summarizer.repairFrontmatter(
            "---\ntitle: T\nlanguage: en\n---\n\n# T\n", session: session, context: context
        )
        let (frontmatter, _) = Frontmatter.split(repaired.document)
        #expect(frontmatter["date"] == "2026-08-13")
        #expect(frontmatter["duration_minutes"] == "47")
        #expect(frontmatter["session"] == session.id)
    }

    /// An explicit user title always wins over anything the model returns (F9).
    @Test func preservesAnExplicitUserTitle() throws {
        var (session, context) = try makeSession()
        session.metadata.title = "My Own Title"
        let repaired = Summarizer.repairFrontmatter(
            "no frontmatter and no heading at all", session: session, context: context
        )
        #expect(repaired.title == "My Own Title")
    }

    // MARK: Helpers

    private func makeSession() throws -> (Session, MeetingContext) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-fr-\(UUID().uuidString)", isDirectory: true)
        let container = Container(locator: LocalFolderContainer(root: root))
        let session = try container.createSession(device: .mac)
        return (session, MeetingContext(date: "2026-08-13", durationMinutes: 30))
    }
}
