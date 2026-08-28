import Foundation
import SharedKit

/// Maps a ``PlatformConnection`` plus its secret to a `claude --mcp-config`
/// server entry and a read-only tool allowlist (ADR-13).
///
/// Package and tool names are config data verified manually against the
/// upstream MCP servers (`outline-mcp-server`, `@doist/todoist-ai` on npm);
/// wrong names fail closed (the tool is simply denied). Pin the npx versions
/// here once a release has been verified against them.
enum MCPServerTemplate {
    struct ServerSpec: Encodable, Equatable {
        var command: String
        var args: [String]
        var env: [String: String]
    }

    struct Server: Equatable {
        /// The mcp-config server name; tool references use `mcp__<name>__…`.
        var name: String
        var spec: ServerSpec
        /// Read-only tools for `access == "read"` steps and material fetches.
        /// Unknown names in the allowlist are harmless; a `nil` list means the
        /// kind has no known read-only subset (custom servers).
        var readOnlyTools: [String]?

        /// `--allowedTools` entries granting the whole server.
        var allTools: [String] { ["mcp__\(name)"] }

        /// `--allowedTools` entries for read-only access. Fails **closed**: a
        /// server without a known read-only subset (custom) yields no tools at
        /// all - read access must never silently widen to the whole server.
        var readTools: [String] {
            readOnlyTools?.map { "mcp__\(name)__\($0)" } ?? []
        }
    }

    /// Builds the server for a connection, or nil when the connection cannot be
    /// launched (custom kind without a machine-local launch spec).
    static func server(for connection: PlatformConnection, entry: ConnectionKeyManifest.Entry?) -> Server? {
        let key = entry?.key ?? ""
        switch connection.kind {
        case PlatformConnection.kindOutline:
            // The Outline API lives under <instance>/api.
            let api = connection.baseURL.hasSuffix("/api")
                ? connection.baseURL
                : connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api"
            return Server(
                name: "outline",
                spec: ServerSpec(command: "npx", args: ["-y", "outline-mcp-server"],
                                 env: ["OUTLINE_API_KEY": key, "OUTLINE_API_URL": api]),
                readOnlyTools: ["search_documents", "get_document", "list_documents", "read_document"]
            )
        case PlatformConnection.kindTodoist:
            return Server(
                name: "todoist",
                spec: ServerSpec(command: "npx", args: ["-y", "@doist/todoist-ai"],
                                 env: ["TODOIST_API_KEY": key]),
                readOnlyTools: ["find-tasks", "find-projects", "find-sections", "get-overview"]
            )
        default:
            guard let entry, !entry.command.isEmpty else { return nil }
            var env: [String: String] = [:]
            if !entry.keyEnvVar.isEmpty { env[entry.keyEnvVar] = key }
            return Server(
                name: "custom",
                spec: ServerSpec(command: entry.command, args: entry.arguments, env: env),
                readOnlyTools: nil
            )
        }
    }

    /// Writes `{"mcpServers": {…}}` for one server to a fresh 0600 file inside
    /// a private 0700 temp directory and returns its URL. Callers must delete
    /// the file after the run (`defer`); stale leftovers from crashed runs are
    /// pruned here on every call.
    static func writeConfig(for server: Server) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.protokoll.mcp-configs", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        pruneStale(in: directory)

        struct Config: Encodable {
            var mcpServers: [String: ServerSpec]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(Config(mcpServers: [server.name: server.spec]))
        let file = directory.appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString + ".json")
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// Deletes config files older than 10 minutes (crash/SIGKILL leftovers -
    /// they carry secrets in the server env, so they must not linger).
    private static func pruneStale(in directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: entry) }
        }
    }

    /// Tools that are always denied to automation runs, whatever the step says.
    static let deniedTools = ["Bash", "Edit", "Write", "WebFetch", "WebSearch", "NotebookEdit"]
}
