import Foundation
import SharedKit

/// Resolves the container the app reads and writes. In dev (M1–M2) this is a
/// local folder in Application Support; M3 swaps in the iCloud ubiquity
/// container behind the same ``ContainerLocating`` seam.
enum AppEnvironment {
    /// A stable per-machine device id used for claims/leases (ADR-4). Persisted
    /// so it survives a machine rename (unlike the host name).
    static var deviceId: String {
        let key = "deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = "mac-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// The dev container root: `~/Library/Application Support/MeetingNotes/Container`.
    static func devContainerRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingNotes/Container", isDirectory: true)
    }

    /// The container used by the app. Honors `MN_CONTAINER_ROOT` for the dev
    /// loop and tests.
    static func makeContainer() -> Container {
        if let override = ProcessInfo.processInfo.environment["MN_CONTAINER_ROOT"], !override.isEmpty {
            return Container(locator: LocalFolderContainer(root: URL(fileURLWithPath: override)))
        }
        return Container(locator: LocalFolderContainer(root: devContainerRoot()))
    }
}
