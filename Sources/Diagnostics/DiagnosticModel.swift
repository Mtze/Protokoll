import Foundation
import SharedKit

/// Stable identifiers for the preflight checks. The UI maps these to SF Symbols
/// and localized strings.
public enum CheckID: String, Sendable, CaseIterable {
    case claude
    case whisperEngine
    case whisperModel
    case ffmpeg
    case path
    case containerWritable
    case microphone
    case screenRecording
}

/// The outcome of a single check.
public enum CheckOutcome: String, Sendable, Equatable {
    /// Everything is fine.
    case passed
    /// Usable, but with a caveat (e.g. model downloads on first use).
    case warning
    /// Blocks the pipeline until fixed.
    case failed
    /// Could not be determined (e.g. a permission the app must evaluate).
    case unknown
}

/// The result of running one check, including a raw detail string for the
/// "Details" disclosure.
public struct CheckResult: Sendable, Equatable, Identifiable {
    public var id: CheckID
    public var outcome: CheckOutcome
    /// Raw, developer-facing detail (command output / error) for the disclosure.
    public var detail: String?

    public init(id: CheckID, outcome: CheckOutcome, detail: String? = nil) {
        self.id = id
        self.outcome = outcome
        self.detail = detail
    }
}

/// Aggregate health shown as the menubar dot.
public enum HealthLevel: String, Sendable, Equatable {
    case green   // all passed
    case yellow  // warnings only
    case red     // at least one failure

    /// The SF Symbol the UI renders for this level (icons are SF Symbols only).
    public var symbolName: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .yellow: return "exclamationmark.triangle.fill"
        case .red: return "xmark.octagon.fill"
        }
    }

    public static func aggregate(_ results: [CheckResult]) -> HealthLevel {
        if results.contains(where: { $0.outcome == .failed }) { return .red }
        if results.contains(where: { $0.outcome == .warning || $0.outcome == .unknown }) { return .yellow }
        return .green
    }
}

// MARK: - Remediation (tiered)

/// A shell command a remediation can run.
public struct ShellCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    /// A copy-pasteable representation for the manual-instructions fallback.
    public var displayString: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// A prerequisite tool (a package manager or runtime) that must exist before an
/// auto-fix can run. Installing it is a bigger, explicitly-labeled step and is
/// never done silently (per the Diagnostics spec).
public struct Bootstrap: Sendable, Equatable {
    public var toolName: String
    /// Localization key for a plain-language explanation of the bigger step.
    public var explanationKey: String
    /// Command to install the prerequisite, if we can offer it.
    public var installCommand: ShellCommand?

    public init(toolName: String, explanationKey: String, installCommand: ShellCommand? = nil) {
        self.toolName = toolName
        self.explanationKey = explanationKey
        self.installCommand = installCommand
    }
}

/// A one-click auto-fix with a live progress log.
public struct AutoFix: Sendable, Equatable {
    public var titleKey: String
    public var command: ShellCommand
    /// Prerequisite that must exist first (bootstrap-gated), if any.
    public var bootstrap: Bootstrap?
    /// Localization key for copy-paste instructions if the user declines.
    public var manualInstructionsKey: String

    public init(titleKey: String, command: ShellCommand, bootstrap: Bootstrap? = nil, manualInstructionsKey: String) {
        self.titleKey = titleKey
        self.command = command
        self.bootstrap = bootstrap
        self.manualInstructionsKey = manualInstructionsKey
    }
}

/// A guided (deep-link) remediation the user completes themselves.
public enum Guidance: Sendable, Equatable {
    /// Open Terminal at a command the user should run (e.g. `claude login`).
    case terminalCommand(String)
    /// Deep-link a System Settings pane (e.g. the Microphone privacy pane).
    case systemSettings(url: String)
}

/// The tiered remediation for a check (auto-fix > guided > none).
public enum Remediation: Sendable, Equatable {
    case autoFix(AutoFix)
    case guided(titleKey: String, Guidance)
    case none
}
