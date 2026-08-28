import Foundation
import Security
import SharedKit

/// Stores platform-connection secrets in the macOS Keychain, keyed by
/// connection id (ADR-13, mirroring ``SummaryKeychain``). Secrets never touch
/// the container; the pipeline gets a path to a short-lived 0600 manifest file.
enum ConnectionKeychain {
    static let service = "com.protokoll.connection-key"

    static func key(for connectionID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Stores (or, if empty, clears) the secret for a connection.
    static func setKey(_ value: String, for connectionID: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { deleteKey(for: connectionID); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
        ]
        let data = Data(trimmed.utf8)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deleteKey(for connectionID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Builds the ``ConnectionKeyManifest`` for the given connections (Keychain
    /// secrets + machine-local custom launch specs + the CLI allowlist), writes
    /// it to a fresh **0600** file in a 0700 temp directory, and returns its
    /// path for injection as `CONNECTION_KEYS_FILE`. Returns nil when there is
    /// nothing to hand over. Best-effort prunes stale files (crash leftovers).
    static func materializeManifest(for connections: [PlatformConnection]) -> String? {
        var manifest = ConnectionKeyManifest(allowedCommands: MachineAllowlist.commands())
        for connection in connections {
            var entry = ConnectionKeyManifest.Entry(key: key(for: connection.id) ?? "")
            if connection.kind == PlatformConnection.kindCustom {
                let spec = CustomMCPSpec.load(for: connection.id)
                entry.command = spec.command
                entry.arguments = spec.arguments
                entry.keyEnvVar = spec.keyEnvVar
            }
            if !entry.key.isEmpty || !entry.command.isEmpty {
                manifest.connections[connection.id] = entry
            }
        }
        guard !manifest.isEmpty else { return nil }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.protokoll.connection-keys", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        pruneStale(in: directory)
        let file = directory.appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            AppLog.pipeline.error("connection manifest write failed: \(AppLog.describe(error), privacy: .public)")
            return nil
        }
    }

    /// Deletes manifest files older than 10 minutes (a spawned pipeline reads
    /// its file immediately, so anything older is a leftover).
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
}

/// Machine-local launch specs for `custom` MCP connections. Deliberately in
/// UserDefaults, not the container: the container syncs via iCloud, and a
/// synced command line would be remote code execution on every device (ADR-13).
enum CustomMCPSpec {
    struct Spec: Codable, Equatable {
        var command = ""
        var arguments: [String] = []
        var keyEnvVar = ""
    }

    private static func defaultsKey(_ connectionID: String) -> String { "customMCPSpec.\(connectionID)" }

    static func load(for connectionID: String) -> Spec {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(connectionID)),
              let spec = try? JSONDecoder().decode(Spec.self, from: data) else { return Spec() }
        return spec
    }

    static func save(_ spec: Spec, for connectionID: String) {
        if spec == Spec() {
            UserDefaults.standard.removeObject(forKey: defaultsKey(connectionID))
        } else if let data = try? JSONEncoder().encode(spec) {
            UserDefaults.standard.set(data, forKey: defaultsKey(connectionID))
        }
    }

    static func delete(for connectionID: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(connectionID))
    }
}

/// The machine-local CLI command allowlist for action steps (ADR-13): a step's
/// `allowedCommands` only takes effect for commands that also appear here.
enum MachineAllowlist {
    /// Parses the stored free-text list (comma/whitespace separated).
    static func commands() -> [String] {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.stepCommandAllowlist) ?? ""
        return raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }
}
