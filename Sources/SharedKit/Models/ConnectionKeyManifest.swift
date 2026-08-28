import Foundation

/// The local key manifest handed to `process-session` as a 0600 file path
/// (`CONNECTION_KEYS_FILE`, ADR-13): per-connection secrets, the machine-local
/// launch specs for `custom` MCP connections, and the machine-local CLI command
/// allowlist. Written by the Mac app from the Keychain + local defaults - this
/// data is exactly what must **never** land in the synced container.
public struct ConnectionKeyManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// The connection's secret (API token). Empty when only a launch spec
        /// is provided.
        public var key: String
        /// Launch spec for `custom` connections; empty for known kinds.
        public var command: String
        public var arguments: [String]
        /// Env var name the custom server expects its key in.
        public var keyEnvVar: String

        public init(key: String = "", command: String = "", arguments: [String] = [], keyEnvVar: String = "") {
            self.key = key
            self.command = command
            self.arguments = arguments
            self.keyEnvVar = keyEnvVar
        }
    }

    /// Keyed by ``PlatformConnection/id``.
    public var connections: [String: Entry]
    /// Commands (executable names) approved on this machine for step
    /// `allowedCommands` - the second key of the Bash escape hatch (ADR-13).
    public var allowedCommands: [String]

    public init(connections: [String: Entry] = [:], allowedCommands: [String] = []) {
        self.connections = connections
        self.allowedCommands = allowedCommands
    }

    public var isEmpty: Bool { connections.isEmpty && allowedCommands.isEmpty }
}
