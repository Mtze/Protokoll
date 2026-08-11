import Foundation
import Testing
@testable import ProcessSession
@testable import SharedKit

/// A scripted fake for the subprocess boundary so pipeline tests never really
/// shell out to whisper or `claude`.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Stub {
        var match: @Sendable (String, [String]) -> Bool
        var result: CommandResult
        /// Optional side effect (e.g. write fake engine output files).
        var sideEffect: (@Sendable ([String]) -> Void)?
    }

    private let lock = NSLock()
    private var stubs: [Stub] = []
    private(set) var calls: [(executable: String, arguments: [String], stdin: String?)] = []

    func stub(
        when match: @escaping @Sendable (String, [String]) -> Bool,
        return result: CommandResult,
        sideEffect: (@Sendable ([String]) -> Void)? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(Stub(match: match, result: result, sideEffect: sideEffect))
    }

    func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        workingDirectory: URL?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        lock.lock()
        calls.append((executable, arguments, stdin))
        let stub = stubs.first { $0.match(executable, arguments) }
        lock.unlock()
        guard let stub else {
            return CommandResult(exitCode: 127, stdout: "", stderr: "no stub for \(executable)")
        }
        stub.sideEffect?(arguments)
        return stub.result
    }
}

private func makeSession() throws -> (Container, Session) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mn-ps-\(UUID().uuidString)", isDirectory: true)
    let container = Container(locator: LocalFolderContainer(root: root))
    let session = try container.createSession(device: .mac)
    // Provide a fake mic.m4a so the audio-exists check passes.
    try Data("fake audio".utf8).write(to: session.micAudioURL)
    return (container, session)
}

private func vendoredScriptEnv() -> ToolLocator {
    // Point at the repo's vendored transcribe.sh so ToolLocator resolves it.
    let cwd = FileManager.default.currentDirectoryPath
    return ToolLocator(environment: [
        "TRANSCRIBE_SH": "\(cwd)/scripts/transcribe.sh",
        "CLAUDE_BIN": "claude",
    ])
}

@Suite struct TranscriberTests {
    @Test func assemblesTranscriptFromJSON() throws {
        let runner = FakeCommandRunner()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let json = """
        {"language":"de","segments":[{"start":0.0,"end":2.0,"text":"Hallo Welt"},
        {"start":2.0,"end":4.0,"text":"Zweiter Satz"}]}
        """
        let jsonURL = tmp.appendingPathComponent("mic.json")
        try Data(json.utf8).write(to: jsonURL)
        let transcriber = Transcriber(runner: runner)
        let assembled = try transcriber.assembleTranscript(
            jsonURL: jsonURL,
            txtURL: tmp.appendingPathComponent("mic.txt")
        )
        #expect(assembled.language == "de")
        #expect(assembled.markdown.contains("Hallo Welt"))
        #expect(assembled.markdown.contains("[00:00:00]"))
        #expect(assembled.markdown.contains("language: de"))
    }

    @Test func transcribeWritesTranscriptAndSetsLanguage() throws {
        let (_, session) = try makeSession()
        let runner = FakeCommandRunner()
        runner.stub(when: { exe, _ in exe.contains("transcribe.sh") }, return: CommandResult(exitCode: 0, stdout: "", stderr: "")) { args in
            // Emulate the engine writing mic.json into the --output-dir.
            guard let outIndex = args.firstIndex(of: "--output-dir"), outIndex + 1 < args.count else { return }
            let outDir = URL(fileURLWithPath: args[outIndex + 1])
            let json = #"{"language":"en","segments":[{"start":0.0,"end":1.0,"text":"Hello"}]}"#
            try? Data(json.utf8).write(to: outDir.appendingPathComponent("mic.json"))
        }
        let transcriber = Transcriber(runner: runner, tools: vendoredScriptEnv())
        let updated = try transcriber.transcribe(session: session)
        #expect(FileManager.default.fileExists(atPath: session.transcriptURL.path))
        #expect(updated.metadata.language == "en")
    }
}

@Suite struct SummarizerTests {
    @Test func liftsTitleAndWritesProtocol() throws {
        let (container, session) = try makeSession()
        // Provide a transcript.
        try Data("---\nlanguage: de\n---\n\n# Transcript\n\nHallo".utf8).write(to: session.transcriptURL)

        let runner = FakeCommandRunner()
        let claudeOutput = "---\ntitle: Sprint Planning\nlanguage: de\n---\n\n# Sprint Planning\n\n## Beschlüsse\n- Nichts."
        runner.stub(when: { exe, _ in exe == "claude" }, return: CommandResult(exitCode: 0, stdout: claudeOutput, stderr: ""))

        let summarizer = Summarizer(runner: runner, tools: vendoredScriptEnv(), store: container.store)
        let updated = try summarizer.summarize(session: session)
        #expect(updated.metadata.title == "Sprint Planning")
        #expect(FileManager.default.fileExists(atPath: session.protocolURL.path))
        let written = try String(contentsOf: session.protocolURL, encoding: .utf8)
        #expect(written.contains("Sprint Planning"))
    }

    @Test func keepsExplicitTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID().uuidString)")
        let container = Container(locator: LocalFolderContainer(root: root))
        let session = try container.createSession(device: .mac, title: "My Title")
        try Data("body".utf8).write(to: session.transcriptURL)
        let runner = FakeCommandRunner()
        runner.stub(when: { exe, _ in exe == "claude" }, return: CommandResult(exitCode: 0, stdout: "---\ntitle: Generated\n---\n\nbody", stderr: ""))
        let summarizer = Summarizer(runner: runner, tools: vendoredScriptEnv(), store: container.store)
        let updated = try summarizer.summarize(session: session)
        #expect(updated.metadata.title == "My Title")
    }

    @Test func regenerateRotatesOldProtocol() throws {
        let (container, session) = try makeSession()
        try Data("body".utf8).write(to: session.transcriptURL)
        let runner = FakeCommandRunner()
        runner.stub(when: { exe, _ in exe == "claude" }, return: CommandResult(exitCode: 0, stdout: "---\ntitle: V1\n---\n\nfirst", stderr: ""))
        let summarizer = Summarizer(runner: runner, tools: vendoredScriptEnv(), store: container.store)
        _ = try summarizer.summarize(session: session)
        // A second summarize rotates protocol.md → protocol.v1.md (N10).
        let runner2 = FakeCommandRunner()
        runner2.stub(when: { exe, _ in exe == "claude" }, return: CommandResult(exitCode: 0, stdout: "---\ntitle: V2\n---\n\nsecond", stderr: ""))
        _ = try Summarizer(runner: runner2, tools: vendoredScriptEnv(), store: container.store).summarize(session: session)
        #expect(FileManager.default.fileExists(atPath: session.rotatedProtocolURL(version: 1).path))
        #expect(try String(contentsOf: session.protocolURL, encoding: .utf8).contains("second"))
    }

    @Test func missingTranscriptThrows() throws {
        let (container, session) = try makeSession()
        let summarizer = Summarizer(runner: FakeCommandRunner(), tools: vendoredScriptEnv(), store: container.store)
        #expect(throws: SummarizationError.self) {
            _ = try summarizer.summarize(session: session)
        }
    }
}

@Suite struct PipelineTests {
    @Test func fullRunWalksStatusAndClearsClaim() throws {
        let (container, session) = try makeSession()
        let runner = FakeCommandRunner()
        runner.stub(when: { exe, _ in exe.contains("transcribe.sh") }, return: CommandResult(exitCode: 0, stdout: "", stderr: "")) { args in
            guard let outIndex = args.firstIndex(of: "--output-dir"), outIndex + 1 < args.count else { return }
            let outDir = URL(fileURLWithPath: args[outIndex + 1])
            let json = #"{"language":"en","segments":[{"start":0.0,"end":1.0,"text":"Hello world"}]}"#
            try? Data(json.utf8).write(to: outDir.appendingPathComponent("mic.json"))
        }
        runner.stub(when: { exe, _ in exe == "claude" }, return: CommandResult(exitCode: 0, stdout: "---\ntitle: Standup\n---\n\n# Standup\n\nDone.", stderr: ""))

        let pipeline = Pipeline(container: container, runner: runner, tools: vendoredScriptEnv(), deviceId: "mac-test")
        let final = try pipeline.run(folder: session.folder, step: .all)
        #expect(final.metadata.pipeline.status == .done)
        #expect(final.metadata.pipeline.claim == nil)
        #expect(final.metadata.title == "Standup")
        #expect(FileManager.default.fileExists(atPath: session.transcriptURL.path))
        #expect(FileManager.default.fileExists(atPath: session.protocolURL.path))
    }

    @Test func transcribeFailureRecordsFailedStatus() throws {
        let (container, session) = try makeSession()
        let runner = FakeCommandRunner()
        runner.stub(when: { exe, _ in exe.contains("transcribe.sh") }, return: CommandResult(exitCode: 1, stdout: "", stderr: "engine boom"))
        let pipeline = Pipeline(container: container, runner: runner, tools: vendoredScriptEnv(), deviceId: "mac-test")
        #expect(throws: (any Error).self) {
            _ = try pipeline.run(folder: session.folder, step: .transcribe)
        }
        let reloaded = try container.store.load(folder: session.folder)
        if case .failed = reloaded.metadata.pipeline.status {} else {
            Issue.record("expected failed status, got \(reloaded.metadata.pipeline.status)")
        }
        #expect(reloaded.metadata.pipeline.claim == nil)
    }

    @Test func chunkerSingleChunkForShortTranscript() throws {
        let chunks = TranscriptChunker().chunk("short text")
        #expect(chunks.count == 1)
        #expect(chunks[0].index == 0)
    }

    @Test func chunkerSplitsLongTranscriptAtPauses() throws {
        // 10 paragraphs of ~30 chars; a 100-char budget forces multiple chunks.
        let paragraphs = (0..<10).map { "**[00:00:0\($0)]** sentence number \($0) here" }
        let transcript = paragraphs.joined(separator: "\n\n")
        let chunks = TranscriptChunker(characterBudget: 100).chunk(transcript)
        #expect(chunks.count > 1)
        // No chunk splits a paragraph (each chunk starts at a segment marker).
        for chunk in chunks { #expect(chunk.text.hasPrefix("**[")) }
        // Reassembling yields the original content.
        let reassembled = chunks.map(\.text).joined(separator: "\n\n")
        #expect(reassembled == transcript)
    }

    @Test func mapReduceRunsPerChunkThenSynthesis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mn-mr-\(UUID().uuidString)")
        let container = Container(locator: LocalFolderContainer(root: root))
        let session = try container.createSession(device: .mac)
        let longBody = (0..<20).map { "**[00:0\($0):00]** paragraph \($0) with enough words to matter here" }
            .joined(separator: "\n\n")
        try Data(longBody.utf8).write(to: session.transcriptURL)

        let runner = FakeCommandRunner()
        // Map calls: prompt contains "PART". Reduce: prompt contains "final protocol".
        runner.stub(when: { exe, _ in exe == "claude" }, return: CommandResult(exitCode: 0, stdout: "partial notes", stderr: "")) { _ in }

        // Distinguish reduce output so we can assert synthesis ran.
        final class Tracking: CommandRunning, @unchecked Sendable {
            var mapCalls = 0; var reduceCalls = 0
            let lock = NSLock()
            func run(executable: String, arguments: [String], stdin: String?, environment: [String: String]?, workingDirectory: URL?, onStderrLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
                lock.lock(); defer { lock.unlock() }
                let prompt = arguments.count > 1 ? arguments[1] : ""
                if prompt.contains("PART") { mapCalls += 1; return CommandResult(exitCode: 0, stdout: "notes", stderr: "") }
                reduceCalls += 1
                return CommandResult(exitCode: 0, stdout: "---\ntitle: Long Meeting\n---\n\n# Long Meeting\n\nDone.", stderr: "")
            }
        }
        let tracking = Tracking()
        let summarizer = Summarizer(runner: tracking, tools: vendoredScriptEnv(), store: container.store, chunker: TranscriptChunker(characterBudget: 200))
        let updated = try summarizer.summarize(session: session)
        #expect(tracking.mapCalls > 1)
        #expect(tracking.reduceCalls == 1)
        #expect(updated.metadata.title == "Long Meeting")
    }
}
