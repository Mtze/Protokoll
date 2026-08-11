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
}
#endif
