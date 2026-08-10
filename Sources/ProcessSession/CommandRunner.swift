import Foundation

/// The result of running an external command.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The subprocess boundary, behind a protocol so the pipeline can be unit-tested
/// with fakes instead of really shelling out to whisper or `claude`.
public protocol CommandRunning: Sendable {
    /// Runs `executable` with `arguments`, optionally feeding `stdin`, and
    /// optionally streaming stderr lines to `onStderrLine` as they arrive.
    func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult
}

extension CommandRunning {
    public func run(executable: String, arguments: [String]) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: nil, environment: nil, onStderrLine: nil)
    }

    public func run(executable: String, arguments: [String], stdin: String?) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: stdin, environment: nil, onStderrLine: nil)
    }
}

/// Runs commands for real via `Process`.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        let process = Process()
        // Resolve via /usr/bin/env so PATH lookups work for user-installed CLIs.
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment { env[key] = value }
        }
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe = Pipe()
        if stdin != nil {
            process.standardInput = inputPipe
        }

        // Collect stdout/stderr on background readers to avoid pipe-buffer deadlock.
        let outputCollector = OutputCollector()
        let errorCollector = OutputCollector()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outputCollector.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            errorCollector.append(data)
            if let onStderrLine, let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    onStderrLine(String(line))
                }
            }
        }

        try process.run()

        if let stdin {
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        // Drain any final buffered output.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: outputCollector.string(),
            stderr: errorCollector.string()
        )
    }
}

/// Thread-safe accumulator for pipe data read off background handlers.
private final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
