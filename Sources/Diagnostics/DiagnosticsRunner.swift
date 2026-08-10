import Foundation
import SharedKit

/// Runs the ordered list of preflight checks and computes aggregate health.
///
/// UI-free and `Sendable`: the app calls ``runAll()`` off the main actor and
/// renders the results. Extra checks the app must evaluate itself (microphone /
/// screen-recording permission) are appended to ``checks`` at construction.
public struct DiagnosticsRunner: Sendable {
    public var checks: [any DiagnosticCheck]
    public var runner: CommandRunning

    public init(checks: [any DiagnosticCheck], runner: CommandRunning = ProcessCommandRunner()) {
        self.checks = checks
        self.runner = runner
    }

    /// The standard shell-resolvable checks, in display order.
    public static func standardChecks(containerRoot: URL?, model: String = "large-v3") -> [any DiagnosticCheck] {
        [
            ClaudeCheck(),
            WhisperEngineCheck(),
            WhisperModelCheck(model: model),
            FFmpegCheck(),
            PathCheck(),
            ContainerWritableCheck(containerRoot: containerRoot),
        ]
    }

    /// Runs every check and returns results in check order.
    public func runAll() -> [CheckResult] {
        checks.map { $0.run(runner: runner) }
    }

    /// Looks up the remediation for a given check id.
    public func remediation(for id: CheckID) -> Remediation {
        checks.first { $0.id == id }?.remediation ?? .none
    }
}
