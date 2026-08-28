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

extension ProcessInfo {
    /// Whether this is Apple silicon, where a Metal-accelerated engine exists and
    /// the CPU-only fallback is therefore a real, avoidable penalty. Reads the
    /// machine hardware name rather than `#if arch`, so a Rosetta-translated
    /// build still answers about the *host*.
    public var isAppleSilicon: Bool {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return false }
        let machine = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return machine.hasPrefix("arm64")
    }
}

extension DiagnosticCheck {
    /// Whether an executable is resolvable on PATH (via `command -v`).
    func resolves(_ tool: String, runner: CommandRunning) -> CommandResult {
        // `-c` (not `-lc`): use the inherited, PATH-augmented environment rather
        // than a login shell, whose profile never sees a fish user's PATH.
        (try? runner.run(executable: "/bin/sh", arguments: ["-c", "command -v \(tool)"]))
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

/// Installing mlx-whisper. **Not `pip`**: Homebrew's Python enforces PEP 668, so
/// `pip install` fails with `error: externally-managed-environment` and the
/// one-click fix silently never works. `uv tool install` needs no venv and drops
/// the binary in `~/.local/bin`, which ``ShellPath/augmented`` already adds to
/// the subprocess PATH.
private let installMLXWhisper = AutoFix(
    titleKey: "diag.whisper.fix",
    command: ShellCommand("uv", ["tool", "install", "mlx-whisper"]),
    bootstrap: Bootstrap(
        toolName: "uv",
        explanationKey: "diag.bootstrap.uv",
        installCommand: ShellCommand("brew", ["install", "uv"])
    ),
    manualInstructionsKey: "diag.whisper.manual"
)

/// The engines `transcribe.sh`'s `detect_engine()` picks from, in the same
/// preference order. Kept here so the checks predict what will actually run;
/// if the script's order changes, change it here too.
let whisperEnginePreference = ["mlx_whisper", "whisper-cli", "whisper-cpp", "whisper"]

/// A local whisper engine present (mlx-whisper preferred, others accepted).
public struct WhisperEngineCheck: DiagnosticCheck {
    public init() {}
    public let id = CheckID.whisperEngine
    public let titleKey = "diag.whisper.title"
    public let explanationKey = "diag.whisper.explanation"
    public var remediation: Remediation { .autoFix(installMLXWhisper) }
    public func run(runner: CommandRunning) -> CheckResult {
        for engine in whisperEnginePreference where resolves(engine, runner: runner).succeeded {
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

/// Whether the engine that will actually run is GPU-accelerated.
///
/// ``WhisperEngineCheck`` passes as soon as *any* engine resolves, which made a
/// silent ~19x slowdown invisible: with only `openai-whisper` installed,
/// `detect_engine()` picks it and it runs `large-v3` entirely on the CPU
/// (its CLI selects `cuda if available else cpu`, and there is no CUDA on a
/// Mac). A one-hour meeting then takes three hours instead of ~8 minutes.
///
/// This is a **warning**, not a failure: on an Intel Mac `openai-whisper` is the
/// correct choice. The detail is phrased in wall-clock terms because that is
/// what the user actually cares about.
public struct WhisperEnginePerformanceCheck: DiagnosticCheck {
    /// Whether this machine has a GPU that mlx/Metal can use. Injected so the
    /// check is testable on any host.
    public var isAppleSilicon: Bool

    public init(isAppleSilicon: Bool = ProcessInfo.processInfo.isAppleSilicon) {
        self.isAppleSilicon = isAppleSilicon
    }

    public let id = CheckID.whisperEnginePerformance
    public let titleKey = "diag.enginePerf.title"
    public let explanationKey = "diag.enginePerf.explanation"
    public var remediation: Remediation { .autoFix(installMLXWhisper) }

    public func run(runner: CommandRunning) -> CheckResult {
        if resolves("mlx_whisper", runner: runner).succeeded {
            return CheckResult(id: id, outcome: .passed, detail: "mlx-whisper (Metal GPU)")
        }
        if resolves("whisper-cli", runner: runner).succeeded || resolves("whisper-cpp", runner: runner).succeeded {
            return CheckResult(id: id, outcome: .passed, detail: "whisper.cpp (Metal)")
        }
        if resolves("whisper", runner: runner).succeeded {
            guard isAppleSilicon else {
                // No GPU path exists here; openai-whisper is the right engine.
                return CheckResult(id: id, outcome: .passed, detail: "openai-whisper (CPU; no GPU engine on this Mac)")
            }
            return CheckResult(
                id: id,
                outcome: .warning,
                detail: "only openai-whisper found: it runs on the CPU, so a 1-hour meeting takes about 3 hours instead of about 8 minutes"
            )
        }
        return CheckResult(id: id, outcome: .unknown, detail: "no engine to assess")
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
        // mlx present → model is fetched on first use; not a hard failure. Warn
        // rather than pass, because the first large-v3 fetch is ~2.9 GB and
        // silently stalls the first real run if it happens then.
        if resolves("mlx_whisper", runner: runner).succeeded {
            let cached = try? runner.run(
                executable: "/bin/sh",
                arguments: ["-lc", "ls -d \"$HOME/.cache/huggingface/hub\"/*whisper*\(model)* >/dev/null 2>&1"]
            )
            if cached?.succeeded == true {
                return CheckResult(id: id, outcome: .passed, detail: "mlx model cached")
            }
            return CheckResult(
                id: id,
                outcome: .warning,
                detail: "mlx downloads \(model) on first use (about 2.9 GB); the first run will be slow"
            )
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
        // Report the *effective* PATH used for subprocesses (CommandRunner adds
        // the Homebrew/pip dirs), not the app's minimal launch PATH.
        let env = ProcessInfo.processInfo.environment
        let effective = ShellPath.augmented(base: env["PATH"], home: env["HOME"])
        let hasHomebrew = effective.contains("/opt/homebrew/bin") || effective.contains("/usr/local/bin")
        return CheckResult(id: id, outcome: hasHomebrew ? .passed : .warning, detail: effective)
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

/// `npx` launches the MCP servers automations use (ADR-13). Only listed when
/// automations are configured; ships with Node.
public struct NpxCheck: DiagnosticCheck {
    public init() {}
    public let id = CheckID.npx
    public let titleKey = "diag.npx.title"
    public let explanationKey = "diag.npx.explanation"
    public var remediation: Remediation {
        .autoFix(AutoFix(
            titleKey: "diag.npx.fix",
            command: ShellCommand("brew", ["install", "node"]),
            bootstrap: Bootstrap(toolName: "brew", explanationKey: "diag.bootstrap.brew"),
            manualInstructionsKey: "diag.npx.manual"
        ))
    }
    public func run(runner: CommandRunning) -> CheckResult {
        let result = resolves("npx", runner: runner)
        return CheckResult(id: id, outcome: result.succeeded ? .passed : .failed, detail: result.succeeded ? result.stdout : result.stderr)
    }
}
