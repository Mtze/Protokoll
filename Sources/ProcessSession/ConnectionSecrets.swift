import Foundation
import SharedKit

/// Resolves connection credentials and machine-local launch specs for the
/// pipeline (ADR-13). Source order: the 0600 manifest file the app materializes
/// (`CONNECTION_KEYS_FILE`), then per-connection env vars for standalone runs
/// (`CONNECTION_KEY_<ID>` with non-alphanumerics mapped to `_`).
public struct ConnectionSecrets: Sendable {
    private let manifest: ConnectionKeyManifest
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        if let path = environment["CONNECTION_KEYS_FILE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(ConnectionKeyManifest.self, from: data) {
            self.manifest = decoded
        } else {
            self.manifest = ConnectionKeyManifest()
        }
    }

    /// The env var name carrying a connection's key in standalone runs.
    static func envName(for connectionID: String) -> String {
        let mapped = connectionID.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "CONNECTION_KEY_\(String(mapped))"
    }

    /// The manifest entry (key + custom launch spec) for a connection, with the
    /// per-id env var as key fallback. Nil when nothing is available.
    public func entry(for connection: PlatformConnection) -> ConnectionKeyManifest.Entry? {
        if let entry = manifest.connections[connection.id] { return entry }
        if let key = environment[Self.envName(for: connection.id)], !key.isEmpty {
            return ConnectionKeyManifest.Entry(key: key)
        }
        return nil
    }

    /// Machine-approved CLI commands for step escape hatches (ADR-13).
    public var allowedCommands: [String] { manifest.allowedCommands }
}
