import Foundation
import Testing
@testable import ProcessSession
@testable import SharedKit

/// Tests for the configurable summary prompt: custom instructions are appended
/// to the built-in prompt, and the required output-format contract is preserved.
struct SummarizePromptTests {
    @Test func buildAppendsUserInstructionsButKeepsTheContract() {
        let out = SummarizePrompt.build(currentTitle: nil, extra: "Add a 2-line TL;DR at the top.")
        #expect(out.contains("Add a 2-line TL;DR at the top."))
        #expect(out.contains("Additional instructions from the user"))
        // The fixed output-format contract must still be present.
        #expect(out.contains("YAML frontmatter"))
        #expect(out.contains("## Beschlüsse / Decisions"))
    }

    @Test func buildWithoutExtraIsUnchanged() {
        let plain = SummarizePrompt.build(currentTitle: nil)
        let blank = SummarizePrompt.build(currentTitle: nil, extra: "   \n ")
        #expect(plain == blank)
        #expect(!plain.contains("Additional instructions from the user"))
    }

    @Test func reduceAppendsUserInstructions() {
        let out = SummarizePrompt.reduce(currentTitle: "T", extra: "Keep it under one page.")
        #expect(out.contains("Keep it under one page."))
        #expect(out.contains("Additional instructions from the user"))
    }

    @Test func summarizerPassesInstructionsIntoTheClaudePrompt() throws {
        let (container, session) = try makeSessionWithTranscript(body: "Alice: we decided to ship on Friday.")
        let fake = FakeCommandRunner()
        fake.stub(when: { exe, args in exe == "claude" && args.contains("-p") },
                  return: CommandResult(exitCode: 0,
                                        stdout: "---\ntitle: Ship\nlanguage: en\n---\n\n# Ship\n", stderr: ""))
        let summarizer = Summarizer(runner: fake, store: container.store,
                                    customInstructions: "REPLY-IN-KLINGON-XYZ")
        _ = try summarizer.summarize(session: session)
        #expect(claudePrompt(in: fake)?.contains("REPLY-IN-KLINGON-XYZ") == true)
    }

    @Test func summarizerWithoutInstructionsHasNoExtraBlock() throws {
        let (container, session) = try makeSessionWithTranscript(body: "short transcript")
        let fake = FakeCommandRunner()
        fake.stub(when: { exe, args in exe == "claude" && args.contains("-p") },
                  return: CommandResult(exitCode: 0,
                                        stdout: "---\ntitle: T\nlanguage: en\n---\n\n# T\n", stderr: ""))
        let summarizer = Summarizer(runner: fake, store: container.store)
        _ = try summarizer.summarize(session: session)
        #expect(claudePrompt(in: fake)?.contains("Additional instructions from the user") == false)
    }

    // MARK: Helpers

    private func makeSessionWithTranscript(body: String) throws -> (Container, Session) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-sp-\(UUID().uuidString)", isDirectory: true)
        let container = Container(locator: LocalFolderContainer(root: root))
        let session = try container.createSession(device: .mac)
        try Data(body.utf8).write(to: session.transcriptURL)
        return (container, session)
    }

    private func claudePrompt(in fake: FakeCommandRunner) -> String? {
        guard let call = fake.calls.first(where: { $0.executable == "claude" && $0.arguments.contains("-p") }),
              let i = call.arguments.firstIndex(of: "-p"), i + 1 < call.arguments.count else { return nil }
        return call.arguments[i + 1]
    }
}
