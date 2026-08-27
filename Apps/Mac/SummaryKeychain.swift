import Foundation
import Security
import SharedKit

/// Stores the summary-provider API key in the macOS Keychain, keyed by provider
/// so switching between Anthropic and OpenAI keeps each key. The secret never
/// touches the container (ADR-9): Settings writes it here, and the pipeline gets
/// only a path to a short-lived 0600 file (never the raw value in its env, which
/// `ps e` would expose and child processes would inherit).
enum SummaryKeychain {
    static let service = "com.protokoll.summary-api-key"

    /// Reads the stored key for `provider` (`"anthropic"` / `"openai"`).
    static func key(for provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Stores (or, if empty, clears) the key for `provider`.
    static func setKey(_ value: String, for provider: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { deleteKey(for: provider); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
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

    static func deleteKey(for provider: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Writes the stored key for `provider` to a fresh **0600** temp file and
    /// returns its path, for injection as `SUMMARY_API_KEY_FILE`. Returns nil if
    /// no key is stored. Best-effort prunes stale key files so plaintext copies
    /// don't accumulate.
    static func materializeKeyFile(for provider: String) -> String? {
        guard let key = key(for: provider) else { return nil }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.protokoll.summary-keys", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        pruneStale(in: directory)
        let file = directory.appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
        do {
            try Data(key.utf8).write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            AppLog.pipeline.error("summary key-file write failed: \(AppLog.describe(error), privacy: .public)")
            return nil
        }
    }

    /// Deletes key files older than 10 minutes (a spawned pipeline reads its file
    /// immediately, so anything older is a leftover).
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
