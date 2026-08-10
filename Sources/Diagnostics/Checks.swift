import Foundation
import SharedKit

/// A single preflight check. Value types, `Sendable`, no UI - the app renders
/// results via the String Catalog keyed on ``CheckID``.
public protocol DiagnosticCheck: Sendable {
    var id: CheckID { get }
    /// Localization key for the plain-language title.
    var titleKey: String { get }
    /// Localization key for the one-line explanation.
    var explanationKey: String { get }
    /// The tiered remediation offered when the check does not pass.
    var remediation: Remediation { get }
    /// Runs the check using the injected subprocess boundary.
    func run(runner: CommandRunning) -> CheckResult
}

extension DiagnosticCheck {
    /// Whether an executable is resolvable on PATH (via `command -v`).
    func resolves(_ tool: String, runner: CommandRunning) -> CommandResult {
        (try? runner.run(executable: "/bin/sh", arguments: ["-lc", "command -v \(tool)"]))
            ?? CommandResult(exitCode: 127, stdout: "", stderr: "could not launch shell")
    }
}

/// `ffmpeg` present (required for audio prep in transcribe.sh).
public struct FFmpegCheck: DiagnosticCheck {
    public init() {}
    public let id = CheckID.ffmpeg
    public let titleKey = "diag.ffmpeg.title"
    public let explanationKey = "diag.ffmpeg.explanation"
    public var remediation: Remediation {
        .autoFix(AutoFix(
            titleKey: "diag.ffmpeg.fix",
            command: ShellCommand("brew", ["install", "ffmpeg"]),
            bootstrap: Bootstrap(toolName: "brew", explanationKey: "diag.bootstrap.brew"),
            manualInstructionsKey: "diag.ffmpeg.manual"
        ))
    }
    public func run(runner: CommandRunning) -> CheckResult {
        let result = resolves("ffmpeg", runner: runner)
        return CheckResult(id: id, outcome: result.succeeded ? .passed : .failed, detail: result.succeeded ? result.stdout : result.stderr)
    }
}

/// A local whisper engine present (mlx-whisper preferred, others accepted).
public struct WhisperEngineCheck: DiagnosticCheck {
    public init() {}
    public let id = CheckID.whisperEngine
    public let titleKey = "diag.whisper.title"
    public let explanationKey = "diag.whisper.explanation"
    public var remediation: Remediation {
        .autoFix(AutoFix(
            titleKey: "diag.whisper.fix",
            command: ShellCommand("pip", ["install", "--upgrade", "mlx-whisper"]),
            bootstrap: Bootstrap(toolName: "python3", explanationKey: "diag.bootstrap.python"),
            manualInstructionsKey: "diag.whisper.manual"
        ))
    }
    public func run(runner: CommandRunning) -> CheckResult {
        let engines = ["mlx_whisper", "whisper-cli", "whisper-cpp", "whisper"]
        for engine in engines where resolves(engine, runner: runner).succeeded {
            return CheckResult(id: id, outcome: .passed, detail: "found \(engine)")
        }
        // faster-whisper is a Python import, not a binary.
        let fw = try? runner.run(executable: "/bin/sh", arguments: ["-lc", "python3 -c 'import faster_whisper'"])
        if fw?.succeeded == true {
            return CheckResult(id: id, outcome: .passed, detail: "found faster-whisper")
        }
        return CheckResult(id: id, outcome: .failed, detail: "no local whisper engine on PATH")
    }
}

/// The `large-v3` model present. mlx downloads on first use, so a missing model
/// with an mlx engine is only a warning; whisper.cpp needs the ggml file.
public struct WhisperModelCheck: DiagnosticCheck {
    public var model: String
    public init(model: String = "large-v3") { self.model = model }
    public let id = CheckID.whisperModel
    public let titleKey = "diag.model.title"
    public let explanationKey = "diag.model.explanation"
    public var remediation: Remediation {
        .autoFix(AutoFix(
            titleKey: "diag.model.fix",
            command: ShellCommand("scripts/setup.sh", ["--model", model]),
            bootstrap: nil,
            manualInstructionsKey: "diag.model.manual"
        ))
    }
    public func run(runner: CommandRunning) -> CheckResult {
        // mlx present → model is fetched on first use; not a hard failure.
        if resolves("mlx_whisper", runner: runner).succeeded {
            return CheckResult(id: id, outcome: .passed, detail: "mlx downloads the model on first use")
        }
        let candidates = [
            "$HOME/.cache/whisper.cpp/ggml-\(model).bin",
            "$HOME/Library/Application Support/whisper.cpp/ggml-\(model).bin",
        ]
        let script = candidates.map { "[ -f \"\($0)\" ]" }.joined(separator: " || ")
        let result = try? runner.run(executable: "/bin/sh", arguments: ["-lc", script])
        if result?.succeeded == true {
            return CheckResult(id: id, outcome: .passed, detail: "ggml model present")
        }
        return CheckResult(id: id, outcome: .warning, detail: "ggml-\(model).bin not found; will download on setup")
    }
}

/// The `claude` CLI present and (best-effort) logged in.
public struct ClaudeCheck: DiagnosticCheck {
    public init() {}
    public let id = CheckID.claude
    public let titleKey = "diag.claude.title"
    public let explanationKey = "diag.claude.explanation"
    public var remediation: Remediation {
        .guided(titleKey: "diag.claude.fix", .terminalCommand("claude login"))
    }
    public func run(runner: CommandRunning) -> CheckResult {
        let resolved = resolves("claude", runner: runner)
        guard resolved.succeeded else {
            return CheckResult(id: id, outcome: .failed, detail: "claude not on PATH")
        }
        // Best-effort login heuristic: credentials/config present. A real ping
        // would cost a network round-trip, so we keep this cheap and only warn.
        let loggedIn = try? runner.run(
            executable: "/bin/sh",
            arguments: ["-lc", "[ -e \"$HOME/.claude/.credentials.json\" ] || [ -d \"$HOME/.claude\" ]"]
        )
        if loggedIn?.succeeded == true {
            return CheckResult(id: id, outcome: .passed, detail: "claude present")
        }
        return CheckResult(id: id, outcome: .warning, detail: "claude present but login not confirmed")
    }
}

/// The Homebrew bin dirs are on PATH, so a GUI-launched app can find CLIs.
public struct PathCheck: DiagnosticCheck {
    public init() {}
    public let id = CheckID.path
    public let titleKey = "diag.path.title"
    public let explanationKey = "diag.path.explanation"
    public let remediation = Remediation.none
    public func run(runner: CommandRunning) -> CheckResult {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let hasHomebrew = path.contains("/opt/homebrew/bin") || path.contains("/usr/local/bin")
        return CheckResult(id: id, outcome: hasHomebrew ? .passed : .warning, detail: path)
    }
}

/// The container root is writable.
public struct ContainerWritableCheck: DiagnosticCheck {
    public var containerRoot: URL?
    public init(containerRoot: URL?) { self.containerRoot = containerRoot }
    public let id = CheckID.containerWritable
    public let titleKey = "diag.container.title"
    public let explanationKey = "diag.container.explanation"
    public let remediation = Remediation.none
    public func run(runner: CommandRunning) -> CheckResult {
        guard let root = containerRoot else {
            return CheckResult(id: id, outcome: .unknown, detail: "container not configured")
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(".mn-write-probe")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return CheckResult(id: id, outcome: .passed, detail: root.path)
        } catch {
            return CheckResult(id: id, outcome: .failed, detail: error.localizedDescription)
        }
    }
}
