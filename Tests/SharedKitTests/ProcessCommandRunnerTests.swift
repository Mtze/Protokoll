#if os(macOS)
import Foundation
import Testing
@testable import SharedKit

/// Regression test: the subprocess runs in the given working directory instead
/// of the app's `/` cwd, so `claude`/`whisper`/`ffmpeg` don't roam and trigger
/// broad macOS file-access prompts.
struct ProcessCommandRunnerTests {
    @Test func runsInTheGivenWorkingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try ProcessCommandRunner().run(
            executable: "/bin/pwd", arguments: [], stdin: nil, environment: nil,
            workingDirectory: dir, onStderrLine: nil)

        #expect(result.succeeded)
        let printed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path
                == dir.resolvingSymlinksInPath().path)
    }

    /// A wedged engine must be killed rather than run forever. Before this, a
    /// stuck `whisper` kept its claim heartbeat alive for 19+ hours and looked
    /// exactly like healthy progress.
    @Test func killsASubprocessThatOverrunsItsBudget() throws {
        let start = Date()
        #expect(throws: CommandTimedOut.self) {
            try ProcessCommandRunner().run(
                executable: "/bin/sleep", arguments: ["30"], stdin: nil, environment: nil,
                workingDirectory: nil, timeout: 1, onStderrLine: nil)
        }
        // Killed promptly, not after the full 30 s.
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// A command that finishes inside its budget is unaffected.
    @Test func doesNotDisturbACommandThatFinishesInTime() throws {
        let result = try ProcessCommandRunner().run(
            executable: "/bin/echo", arguments: ["ok"], stdin: nil, environment: nil,
            workingDirectory: nil, timeout: 30, onStderrLine: nil)
        #expect(result.succeeded)
        #expect(result.stdout.contains("ok"))
    }

    /// No budget means the previous behaviour, unchanged.
    @Test func noTimeoutMeansNoEnforcement() throws {
        let result = try ProcessCommandRunner().run(
            executable: "/bin/echo", arguments: ["ok"], stdin: nil, environment: nil,
            workingDirectory: nil, timeout: nil, onStderrLine: nil)
        #expect(result.succeeded)
    }
}
#endif
