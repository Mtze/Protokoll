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

/// Raised when a subprocess exceeds its wall-clock budget.
public struct CommandTimedOut: Error, LocalizedError, Equatable {
    /// The executable that was killed.
    public var executable: String
    /// The budget it blew through, in seconds.
    public var timeout: TimeInterval
    /// Whatever it had written to stderr before being killed, for diagnosis.
    public var stderrTail: String

    public init(executable: String, timeout: TimeInterval, stderrTail: String = "") {
        self.executable = executable
        self.timeout = timeout
        self.stderrTail = stderrTail
    }

    public var errorDescription: String? {
        let minutes = Int((timeout / 60).rounded())
        return "\(executable) did not finish within \(minutes) minutes and was stopped."
    }
}

/// The subprocess boundary, behind a protocol so the pipeline can be unit-tested
/// with fakes instead of really shelling out to whisper or `claude`.
public protocol CommandRunning: Sendable {
    /// Runs `executable` with `arguments`, optionally feeding `stdin`, running in
    /// `workingDirectory` (so subprocesses don't roam from `/` and trigger broad
    /// macOS file-access prompts), and optionally streaming stderr lines.
    func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        workingDirectory: URL?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult

    /// As above, but killed after `timeout` seconds. Throws ``CommandTimedOut``.
    ///
    /// A separate requirement (rather than a parameter on the method above) so
    /// existing fakes need no changes: the default implementation ignores the
    /// budget, which is correct for fakes that return immediately.
    func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: TimeInterval?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult
}

extension CommandRunning {
    /// Default: run without enforcing the budget. Overridden by
    /// ``ProcessCommandRunner``, which is the only conformer that really spawns.
    public func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: TimeInterval?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: stdin,
                environment: environment, workingDirectory: workingDirectory,
                onStderrLine: onStderrLine)
    }
}

extension CommandRunning {
    public func run(executable: String, arguments: [String]) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: nil, environment: nil, workingDirectory: nil, onStderrLine: nil)
    }

    public func run(executable: String, arguments: [String], stdin: String?) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: stdin, environment: nil, workingDirectory: nil, onStderrLine: nil)
    }

    /// Back-compat overload for callers that don't set a working directory.
    public func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: stdin,
                environment: environment, workingDirectory: nil, onStderrLine: onStderrLine)
    }
}

#if os(macOS)
/// Runs commands for real via `Process` (macOS only; iOS/watch never spawn
/// subprocesses - all processing happens on the Mac, F11).
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        workingDirectory: URL?,
        onStderrLine: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        try run(executable: executable, arguments: arguments, stdin: stdin,
                environment: environment, workingDirectory: workingDirectory,
                timeout: nil, onStderrLine: onStderrLine)
    }

    public func run(
        executable: String,
        arguments: [String],
        stdin: String?,
        environment: [String: String]?,
        workingDirectory: URL?,
        timeout: TimeInterval?,
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
        // Contain the subprocess (and its children) to a known directory instead
        // of inheriting the app's `/` cwd.
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment { env[key] = value }
        }
        // A GUI-launched app has a minimal PATH; make sure Homebrew/pip CLIs
        // (ffmpeg, claude, whisper) are findable by every subprocess.
        env["PATH"] = ShellPath.augmented(base: env["PATH"], home: env["HOME"])
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
            // Use the throwing write and ignore failures: if the child already
            // exited (e.g. `claude` missing → exit 127), writing its stdin would
            // otherwise raise an uncatchable broken-pipe exception. The caller
            // sees the non-zero exit code instead of a crash (verification #8).
            try? inputPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }

        // Enforce the wall-clock budget, if one was given. A wedged engine (whisper
        // re-decoding a looping window at escalating temperatures) otherwise runs
        // forever while its heartbeat keeps renewing the claim, which is
        // indistinguishable from healthy progress.
        var timedOut = false
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: deadline)
            watchdog.setEventHandler {
                guard process.isRunning else { return }
                // SIGTERM first so the child can clean up its temp files; the
                // SIGKILL below is the backstop if it ignores that.
                process.terminate()
            }
            watchdog.resume()
            defer { watchdog.cancel() }

            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            if finished.wait(timeout: deadline + 5) == .timedOut {
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            } else if process.terminationReason == .uncaughtSignal {
                // terminate() fired: distinguish "we killed it" from a crash by
                // whether the deadline had passed.
                timedOut = DispatchTime.now() >= deadline
            }
        }
        process.waitUntilExit()
        // Drain any final buffered output.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        if timedOut, let timeout {
            let stderr = errorCollector.string()
            AppLog.pipeline.error("\(executable, privacy: .public) timed out after \(timeout, format: .fixed(precision: 0), privacy: .public)s and was killed")
            throw CommandTimedOut(
                executable: executable,
                timeout: timeout,
                stderrTail: String(stderr.suffix(2_000))
            )
        }

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
#endif
