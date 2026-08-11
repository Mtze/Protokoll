import Foundation
import Testing
@testable import SharedKit

/// Regression tests for the processing chain's subprocess glue: correct
/// arguments/env reach the binary, progress is streamed, and a non-zero exit
/// surfaces a clear error (rather than silently doing nothing).
struct PipelineRunnerTests {
    /// Records the last invocation and returns a canned result.
    private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
        var result: CommandResult
        var stderrLines: [String]
        private(set) var executable = ""
        private(set) var arguments: [String] = []
        private(set) var environment: [String: String] = [:]

        init(result: CommandResult, stderrLines: [String] = []) {
            self.result = result
            self.stderrLines = stderrLines
        }

        func run(
            executable: String,
            arguments: [String],
            stdin: String?,
            environment: [String: String]?,
            onStderrLine: (@Sendable (String) -> Void)?
        ) throws -> CommandResult {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment ?? [:]
            stderrLines.forEach { onStderrLine?($0) }
            return result
        }
    }

    private func runner(_ fake: FakeCommandRunner) -> PipelineRunner {
        PipelineRunner(binary: "/bin/process-session", deviceId: "dev-123", runner: fake)
    }

    @Test func passesFolderStepAndDeviceId() throws {
        let fake = FakeCommandRunner(result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        try runner(fake).run(folder: URL(fileURLWithPath: "/x/sess"), step: .transcribe) { _ in }
        #expect(fake.executable == "/bin/process-session")
        #expect(fake.arguments == ["/x/sess", "--step", "transcribe"])
        #expect(fake.environment["DEVICE_ID"] == "dev-123")
    }

    @Test func appendsForceFlagOnlyWhenForcing() throws {
        let fake = FakeCommandRunner(result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        try runner(fake).run(folder: URL(fileURLWithPath: "/x/sess"), step: .summarize, force: true) { _ in }
        #expect(fake.arguments == ["/x/sess", "--step", "summarize", "--force"])
    }

    @Test func streamsProgressLines() throws {
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let fake = FakeCommandRunner(result: CommandResult(exitCode: 0, stdout: "", stderr: ""),
                                     stderrLines: ["10%", "50%", "done"])
        let box = Box()
        try runner(fake).run(folder: URL(fileURLWithPath: "/x/sess"), step: .transcribe) { box.lines.append($0) }
        #expect(box.lines == ["10%", "50%", "done"])
    }

    @Test func throwsWithStderrOnNonZeroExit() {
        let fake = FakeCommandRunner(result: CommandResult(exitCode: 2, stdout: "out", stderr: "whisper not found"))
        #expect(throws: PipelineRunner.Failure.self) {
            try runner(fake).run(folder: URL(fileURLWithPath: "/x/sess"), step: .transcribe) { _ in }
        }
        do {
            try runner(fake).run(folder: URL(fileURLWithPath: "/x/sess"), step: .transcribe) { _ in }
        } catch let error as PipelineRunner.Failure {
            #expect(error.message == "whisper not found")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func fallsBackToStdoutWhenStderrEmpty() {
        let fake = FakeCommandRunner(result: CommandResult(exitCode: 1, stdout: "boom on stdout", stderr: ""))
        do {
            try runner(fake).run(folder: URL(fileURLWithPath: "/x/sess"), step: .summarize) { _ in }
            Issue.record("expected a failure")
        } catch let error as PipelineRunner.Failure {
            #expect(error.message == "boom on stdout")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
