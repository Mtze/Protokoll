import Foundation

/// Resolves the external tools the pipeline depends on, honoring env overrides
/// for the dev loop and falling back to bundled/`PATH` locations.
public struct ToolLocator: Sendable {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// The `claude` CLI (N1: uses the existing login, no API key). Model pinned
    /// to the strongest available via ``claudeModel``.
    public var claudeBinary: String { environment["CLAUDE_BIN"] ?? "claude" }

    /// The summarization model. Pinned to Opus per the design decision; a config
    /// point rather than a hardcoded literal scattered around.
    public var claudeModel: String { environment["CLAUDE_MODEL"] ?? "opus" }

    /// The default transcription model (F3: quality over speed).
    public var transcriptionModel: String { environment["TRANSCRIBE_MODEL"] ?? "large-v3" }

    /// Locates the vendored `transcribe.sh`. Resolution order:
    /// 1. `TRANSCRIBE_SH` env override (dev loop).
    /// 2. Bundled next to the executable at `../Resources/transcribe.sh`
    ///    (app packaging) or a sibling `scripts/` dir.
    /// 3. `scripts/transcribe.sh` under the current working directory.
    public func transcribeScript() -> String? {
        if let override = environment["TRANSCRIBE_SH"], !override.isEmpty {
            return override
        }
        let fileManager = FileManager.default
        let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        let candidates = [
            executableDir.appendingPathComponent("../Resources/transcribe.sh").standardizedFileURL,
            executableDir.appendingPathComponent("scripts/transcribe.sh").standardizedFileURL,
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("scripts/transcribe.sh"),
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }
}
