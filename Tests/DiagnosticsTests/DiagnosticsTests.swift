import Foundation
import Testing
@testable import Diagnostics
@testable import SharedKit

/// A programmable runner that answers `command -v` probes and records calls.
final class ProbeRunner: CommandRunning, @unchecked Sendable {
    var available: Set<String>
    var pythonImports: Set<String>
    var homeHasClaude = true
    private(set) var lastCalls: [[String]] = []
    private let lock = NSLock()

    init(available: Set<String> = [], pythonImports: Set<String> = []) {
        self.available = available
        self.pythonImports = pythonImports
    }

    func run(executable: String, arguments: [String], stdin: String?, environment: [String: String]?, onStderrLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
        lock.lock(); lastCalls.append(arguments); lock.unlock()
        let script = arguments.last ?? ""
        if script.hasPrefix("command -v ") {
            let tool = String(script.dropFirst("command -v ".count))
            return available.contains(tool)
                ? CommandResult(exitCode: 0, stdout: "/usr/bin/\(tool)", stderr: "")
                : CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        if script.contains("import faster_whisper") {
            return pythonImports.contains("faster_whisper")
                ? CommandResult(exitCode: 0, stdout: "", stderr: "")
                : CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        if script.contains(".credentials.json") || script.contains(".claude") {
            return homeHasClaude ? CommandResult(exitCode: 0, stdout: "", stderr: "") : CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        if script.contains("ggml-") {
            return CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

@Suite struct CheckTests {
    @Test func ffmpegPassesWhenPresent() {
        let runner = ProbeRunner(available: ["ffmpeg"])
        #expect(FFmpegCheck().run(runner: runner).outcome == .passed)
    }

    @Test func ffmpegFailsWhenAbsent() {
        let runner = ProbeRunner(available: [])
        let result = FFmpegCheck().run(runner: runner)
        #expect(result.outcome == .failed)
        if case let .autoFix(fix) = FFmpegCheck().remediation {
            #expect(fix.command.displayString == "brew install ffmpeg")
            #expect(fix.bootstrap?.toolName == "brew")
        } else {
            Issue.record("expected autoFix remediation")
        }
    }

    @Test func whisperEnginePassesForMLX() {
        let runner = ProbeRunner(available: ["mlx_whisper"])
        #expect(WhisperEngineCheck().run(runner: runner).outcome == .passed)
    }

    @Test func whisperEnginePassesForFasterWhisper() {
        let runner = ProbeRunner(available: [], pythonImports: ["faster_whisper"])
        #expect(WhisperEngineCheck().run(runner: runner).outcome == .passed)
    }

    @Test func whisperEngineFailsWhenNone() {
        #expect(WhisperEngineCheck().run(runner: ProbeRunner()).outcome == .failed)
    }

    @Test func modelWarnsWhenMLXPresentButNoGGML() {
        // mlx present → model fetched on first use → pass, not fail.
        let runner = ProbeRunner(available: ["mlx_whisper"])
        #expect(WhisperModelCheck().run(runner: runner).outcome == .passed)
    }

    @Test func modelWarnsWhenNothingPresent() {
        #expect(WhisperModelCheck().run(runner: ProbeRunner()).outcome == .warning)
    }

    @Test func claudePassesWhenPresentAndLoggedIn() {
        let runner = ProbeRunner(available: ["claude"])
        #expect(ClaudeCheck().run(runner: runner).outcome == .passed)
    }

    @Test func claudeFailsWhenAbsent() {
        #expect(ClaudeCheck().run(runner: ProbeRunner()).outcome == .failed)
    }

    @Test func containerWritableForRealTempDir() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = ContainerWritableCheck(containerRoot: root).run(runner: ProbeRunner())
        #expect(result.outcome == .passed)
    }
}

@Suite struct AggregateHealthTests {
    @Test func redWhenAnyFailure() {
        let results = [
            CheckResult(id: .claude, outcome: .passed),
            CheckResult(id: .ffmpeg, outcome: .failed),
        ]
        #expect(HealthLevel.aggregate(results) == .red)
    }

    @Test func yellowWhenOnlyWarnings() {
        let results = [
            CheckResult(id: .claude, outcome: .passed),
            CheckResult(id: .whisperModel, outcome: .warning),
        ]
        #expect(HealthLevel.aggregate(results) == .yellow)
    }

    @Test func greenWhenAllPass() {
        let results = [CheckResult(id: .claude, outcome: .passed)]
        #expect(HealthLevel.aggregate(results) == .green)
    }

    @Test func runnerRunsAllChecks() {
        let runner = ProbeRunner(available: ["claude", "mlx_whisper", "ffmpeg"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let diag = DiagnosticsRunner(checks: DiagnosticsRunner.standardChecks(containerRoot: root), runner: runner)
        let results = diag.runAll()
        #expect(results.count == 6)
        #expect(HealthLevel.aggregate(results) == .green)
    }
}

@Suite struct RemediationExecutorTests {
    @Test func bootstrapRequiredWhenPrerequisiteMissing() {
        let runner = ProbeRunner(available: [])  // no brew
        let fix = AutoFix(
            titleKey: "t",
            command: ShellCommand("brew", ["install", "ffmpeg"]),
            bootstrap: Bootstrap(toolName: "brew", explanationKey: "e"),
            manualInstructionsKey: "m"
        )
        let outcome = RemediationExecutor(runner: runner).run(fix)
        #expect(outcome == .bootstrapRequired(Bootstrap(toolName: "brew", explanationKey: "e")))
    }

    @Test func runsWhenPrerequisitePresent() {
        let runner = ProbeRunner(available: ["brew"])
        let fix = AutoFix(
            titleKey: "t",
            command: ShellCommand("brew", ["install", "ffmpeg"]),
            bootstrap: Bootstrap(toolName: "brew", explanationKey: "e"),
            manualInstructionsKey: "m"
        )
        #expect(RemediationExecutor(runner: runner).run(fix) == .succeeded)
    }
}

@Suite struct SystemTestTests {
    @Test func passesWhenPipelineProducesOutputs() throws {
        // Fake process-session: writes transcript + protocol and sets done.
        final class FakePipelineRunner: CommandRunning, @unchecked Sendable {
            func run(executable: String, arguments: [String], stdin: String?, environment: [String: String]?, onStderrLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
                let folder = URL(fileURLWithPath: arguments[0])
                let store = SessionStore()
                var session = try store.load(folder: folder)
                try Data("transcript".utf8).write(to: session.transcriptURL)
                try Data("protocol".utf8).write(to: session.protocolURL)
                session.metadata.pipeline.status = .done
                session.metadata.title = "Dry Run Title"
                try store.save(session)
                onStderrLine?("transcribing…")
                return CommandResult(exitCode: 0, stdout: "done", stderr: "")
            }
        }
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }

        let test = SystemTest(runner: FakePipelineRunner(), processSessionBinary: "/bin/true", sampleClip: clip)
        let outcome = test.run()
        #expect(outcome == .passed(title: "Dry Run Title"))
    }

    @Test func failsWhenPipelineErrors() throws {
        final class FailingRunner: CommandRunning, @unchecked Sendable {
            func run(executable: String, arguments: [String], stdin: String?, environment: [String: String]?, onStderrLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
                CommandResult(exitCode: 1, stdout: "", stderr: "engine missing")
            }
        }
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        let test = SystemTest(runner: FailingRunner(), processSessionBinary: "/bin/false", sampleClip: clip)
        #expect(test.run() == .failed(reason: "engine missing"))
    }
}
