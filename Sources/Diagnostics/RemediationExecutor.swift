import Foundation
import SharedKit

/// Runs an ``AutoFix`` with a live progress log, honoring the bootstrap gate:
/// if the prerequisite tool (brew / python3) is missing, it refuses to run and
/// reports that the bigger bootstrap step is required first (never installs a
/// package manager silently).
public struct RemediationExecutor: Sendable {
    let runner: CommandRunning
    /// Working directory for relative commands (e.g. `scripts/setup.sh`).
    let workingDirectory: URL?

    public init(runner: CommandRunning = ProcessCommandRunner(), workingDirectory: URL? = nil) {
        self.runner = runner
        self.workingDirectory = workingDirectory
    }

    public enum FixOutcome: Sendable, Equatable {
        case succeeded
        case failed(String)
        /// The prerequisite is missing; surface the bootstrap step to the user.
        case bootstrapRequired(Bootstrap)
    }

    /// Runs the auto-fix, streaming stdout+stderr lines to `onLine`.
    public func run(_ fix: AutoFix, onLine: (@Sendable (String) -> Void)? = nil) -> FixOutcome {
        if let bootstrap = fix.bootstrap {
            let resolved = (try? runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "command -v \(bootstrap.toolName)"]
            )) ?? CommandResult(exitCode: 127, stdout: "", stderr: "")
            if !resolved.succeeded {
                return .bootstrapRequired(bootstrap)
            }
        }

        var env: [String: String] = [:]
        if let workingDirectory {
            // Let relative commands (scripts/…) resolve; pass CWD explicitly.
            env["PWD"] = workingDirectory.path
        }
        let executable = resolveExecutable(fix.command.executable)
        do {
            let result = try runner.run(
                executable: executable,
                arguments: fix.command.arguments,
                stdin: nil,
                environment: env.isEmpty ? nil : env,
                onStderrLine: onLine
            )
            if let onLine, !result.stdout.isEmpty {
                for line in result.stdout.split(separator: "\n") { onLine(String(line)) }
            }
            return result.succeeded ? .succeeded : .failed(result.stderr.isEmpty ? result.stdout : result.stderr)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func resolveExecutable(_ executable: String) -> String {
        guard !executable.hasPrefix("/"), executable.contains("/"),
              let workingDirectory else { return executable }
        // Relative path like `scripts/setup.sh` → absolute under the working dir.
        return workingDirectory.appendingPathComponent(executable).path
    }
}
