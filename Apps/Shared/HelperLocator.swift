import Foundation
import SharedKit

/// Resolves the bundled helpers the app drives: the `process-session` binary
/// and `transcribe.sh`. In a packaged app these live in `Contents/Helpers/` and
/// `Contents/Resources/`; the dev loop overrides them via env and falls back to
/// the SwiftPM build output and repo `scripts/` (decision #9).
enum HelperLocator {
    /// Path to the `process-session` executable.
    static func processSessionBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["PROCESS_SESSION_BIN"], !override.isEmpty {
            return override
        }
        let fileManager = FileManager.default
        var candidates: [String] = []
        // Packaged location: Protokoll.app/Contents/Helpers/process-session.
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/process-session").path)
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: "process-session") {
            candidates.append(auxiliary.path)
        }
        // Dev fallbacks: SwiftPM build products next to the repo root.
        for config in ["debug", "release"] {
            candidates.append(repoRoot().appendingPathComponent(".build/\(config)/process-session").path)
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Path to the vendored `transcribe.sh`.
    static func transcribeScript() -> String? {
        if let override = ProcessInfo.processInfo.environment["TRANSCRIBE_SH"], !override.isEmpty {
            return override
        }
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forResource: "transcribe", withExtension: "sh") {
            candidates.append(bundled.path)
        }
        candidates.append(repoRoot().appendingPathComponent("scripts/transcribe.sh").path)
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Best-effort repo root for dev fallbacks (…/Protokoll.app is deep in
    /// DerivedData, so we also honor a `MN_REPO_ROOT` override).
    static func repoRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["MN_REPO_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Environment passed to the pipeline subprocess so it can find its helpers.
    /// When `config` selects an API summary provider (ADR-9), the stored API key
    /// is materialized to a 0600 file and its path injected as
    /// `SUMMARY_API_KEY_FILE` - the raw secret never enters the child env.
    static func pipelineEnvironment(config: PipelineConfig? = nil,
                                    connections: [PlatformConnection] = []) -> [String: String] {
        var env: [String: String] = [:]
        let defaults = UserDefaults.standard
        // transcribe.sh: user override wins over the bundled/dev copy.
        if let override = defaults.string(forKey: SettingsKeys.transcribeShOverride),
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            env["TRANSCRIBE_SH"] = override
        } else if let script = transcribeScript() {
            env["TRANSCRIBE_SH"] = script
        }
        // Optional `claude` binary override (Advanced settings).
        if let claude = defaults.string(forKey: SettingsKeys.claudeBinOverride),
           !claude.trimmingCharacters(in: .whitespaces).isEmpty {
            env["CLAUDE_BIN"] = claude
        }
        // API summary provider: hand the pipeline a path to the key, not the key.
        let provider = config?.summaryProvider ?? "cli"
        if provider == "anthropic" || provider == "openai",
           let path = SummaryKeychain.materializeKeyFile(for: provider) {
            env["SUMMARY_API_KEY_FILE"] = path
        }
        // Automations (ADR-13): connection secrets + custom launch specs + the
        // machine CLI allowlist, as one 0600 manifest path.
        if !connections.isEmpty,
           let path = ConnectionKeychain.materializeManifest(for: connections) {
            env["CONNECTION_KEYS_FILE"] = path
        }
        return env
    }
}
