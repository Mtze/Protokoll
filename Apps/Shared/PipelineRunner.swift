import Foundation
import SharedKit

/// Drives the bundled `process-session` binary as a subprocess (ADR-1: the app
/// never processes in-process). One call runs one step and streams the engine's
/// progress lines back to the caller.
struct PipelineRunner: Sendable {
    var binary: String
    var deviceId: String
    var runner: CommandRunning
    var environment: [String: String]

    init(
        binary: String,
        deviceId: String,
        runner: CommandRunning = ProcessCommandRunner(),
        environment: [String: String] = HelperLocator.pipelineEnvironment()
    ) {
        self.binary = binary
        self.deviceId = deviceId
        self.runner = runner
        self.environment = environment
    }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Runs a single pipeline step against a session folder.
    func run(
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
