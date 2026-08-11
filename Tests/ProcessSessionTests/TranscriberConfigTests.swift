import Foundation
import Testing
@testable import ProcessSession
@testable import SharedKit

/// Tests that the configurable transcription settings reach `transcribe.sh`.
struct TranscriberConfigTests {
    private func makeSession() throws -> (Container, Session) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-tr-\(UUID().uuidString)", isDirectory: true)
        let container = Container(locator: LocalFolderContainer(root: root))
        let session = try container.createSession(device: .mac)
        try Data("audio".utf8).write(to: session.micAudioURL)
        return (container, session)
    }

    /// A fake that "runs" transcribe.sh by writing a mic.json into --output-dir.
    private func stubbedRunner() -> FakeCommandRunner {
        let fake = FakeCommandRunner()
        fake.stub(when: { exe, _ in exe.hasSuffix("transcribe.sh") },
                  return: CommandResult(exitCode: 0, stdout: "", stderr: ""),
                  sideEffect: { args in
                      guard let i = args.firstIndex(of: "--output-dir"), i + 1 < args.count else { return }
                      let out = URL(fileURLWithPath: args[i + 1])
                      let json = #"{"language":"de","segments":[{"start":0,"end":1,"text":"Hallo"}]}"#
                      try? Data(json.utf8).write(to: out.appendingPathComponent("mic.json"))
                  })
        return fake
    }

    private func tools() -> ToolLocator { ToolLocator(environment: ["TRANSCRIBE_SH": "/fake/transcribe.sh"]) }

    @Test func passesLanguageVocabularyAndModel() throws {
        let (_, session) = try makeSession()
        let fake = stubbedRunner()
        let transcriber = Transcriber(runner: fake, tools: tools(),
                                      language: "de", vocabulary: "Ceph, Proxmox", model: "large-v3-turbo")
        _ = try transcriber.transcribe(session: session)
        let call = try #require(fake.calls.first { $0.executable.hasSuffix("transcribe.sh") })
        #expect(call.arguments.contains("--language"))
        #expect(call.arguments.contains("de"))
        #expect(call.arguments.contains("--prompt"))
        #expect(call.arguments.contains("Ceph, Proxmox"))
        #expect(call.arguments.contains("large-v3-turbo"))
    }

    @Test func omitsLanguageAndVocabularyWhenUnset() throws {
        let (_, session) = try makeSession()
        let fake = stubbedRunner()
        let transcriber = Transcriber(runner: fake, tools: tools(), language: "auto", vocabulary: "")
        _ = try transcriber.transcribe(session: session)
        let call = try #require(fake.calls.first { $0.executable.hasSuffix("transcribe.sh") })
        #expect(!call.arguments.contains("--language"))
        #expect(!call.arguments.contains("--prompt"))
    }
}
