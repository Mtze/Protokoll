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
            WhisperEnginePerformanceCheck(),
            WhisperModelCheck(model: model),
            FFmpegCheck(),
            PathCheck(),
            ContainerWritableCheck(containerRoot: containerRoot),
        ]
    }

    /// Runs every check and returns results in check order.
    public func runAll() -> [CheckResult] {
        checks.map { check in
            let result = check.run(runner: runner)
            switch result.outcome {
            case .passed:
                AppLog.diagnostics.info("check \(check.id.rawValue, privacy: .public): passed")
            case .warning, .unknown:
                AppLog.diagnostics.info("check \(check.id.rawValue, privacy: .public): \(result.outcome.rawValue, privacy: .public)")
            case .failed:
                AppLog.diagnostics.error("check \(check.id.rawValue, privacy: .public): failed - \(result.detail ?? "", privacy: .public)")
            }
            return result
        }
    }

    /// Looks up the remediation for a given check id.
    public func remediation(for id: CheckID) -> Remediation {
        checks.first { $0.id == id }?.remediation ?? .none
    }
}
