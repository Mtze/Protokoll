import Foundation

/// A `--step` value of the `process-session` CLI. Distinct from the claim-side
/// ``PipelineStep`` on purpose: custom actions (ADR-13) claim under
/// `.summarize`, so this enum can grow without touching the on-disk lease
/// format that older builds decode.
public enum PipelineRunStep: Sendable, Equatable, Hashable {
    case transcribe
    case summarize
    /// All enabled custom actions of the session's resolved pipeline.
    case actions
    /// One custom action, for a single-step re-run (N6).
    case action(String)

    /// The `--step` argument string (`action:<id>` for a single action).
    public var argument: String {
        switch self {
        case .transcribe: return "transcribe"
        case .summarize: return "summarize"
        case .actions: return "actions"
        case .action(let id): return "action:\(id)"
        }
    }

    public init?(argument: String) {
        switch argument {
        case "transcribe": self = .transcribe
        case "summarize": self = .summarize
        case "actions": self = .actions
        default:
            guard argument.hasPrefix("action:") else { return nil }
            let id = String(argument.dropFirst("action:".count))
            guard !id.isEmpty else { return nil }
            self = .action(id)
        }
    }
}

/// Drives the `process-session` binary as a subprocess (ADR-1: the app never
/// processes in-process). One call runs one step and streams the engine's
/// progress lines back to the caller. Lives in SharedKit (behind the
/// ``CommandRunning`` seam) so the whole invocation is unit-testable with a
/// fake instead of really shelling out to whisper or `claude`.
public struct PipelineRunner: Sendable {
    public var binary: String
    public var deviceId: String
    public var runner: any CommandRunning
    public var environment: [String: String]

    public init(
        binary: String,
        deviceId: String,
        runner: any CommandRunning,
        environment: [String: String] = [:]
    ) {
        self.binary = binary
        self.deviceId = deviceId
        self.runner = runner
        self.environment = environment
    }

    public struct Failure: Error, LocalizedError {
        public var message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Runs a single `--step` selection against a session folder, including
    /// action steps (ADR-13). Throws ``Failure`` with the engine's stderr (or
    /// stdout) when the subprocess exits non-zero.
    public func run(
        folder: URL,
        step: PipelineRunStep,
        force: Bool = false,
        onProgress: @escaping @Sendable (String) -> Void
    ) throws {
        var env = environment
        env["DEVICE_ID"] = deviceId
        var arguments = [folder.path, "--step", step.argument]
        if force { arguments.append("--force") }
        let result = try runner.run(
            executable: binary,
            arguments: arguments,
            stdin: nil,
            environment: env,
            workingDirectory: folder,
            onStderrLine: onProgress
        )
        guard result.succeeded else {
            throw Failure(message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
