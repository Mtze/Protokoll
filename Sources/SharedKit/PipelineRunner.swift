import Foundation

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

    /// Runs a single pipeline step against a session folder. Throws ``Failure``
    /// with the engine's stderr (or stdout) when the subprocess exits non-zero.
    public func run(
        folder: URL,
        step: PipelineStep,
        force: Bool = false,
        onProgress: @escaping @Sendable (String) -> Void
    ) throws {
        var env = environment
        env["DEVICE_ID"] = deviceId
        var arguments = [folder.path, "--step", step.rawValue]
        if force { arguments.append("--force") }
        let result = try runner.run(
            executable: binary,
            arguments: arguments,
            stdin: nil,
            environment: env,
            onStderrLine: onProgress
        )
        guard result.succeeded else {
            throw Failure(message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}
