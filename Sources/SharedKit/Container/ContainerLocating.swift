import Foundation

/// Resolves the container root - the single source of truth folder that holds
/// `sessions/` and `projects/`.
///
/// This seam lets dev builds and tests run against a plain local folder while
/// production uses the real iCloud ubiquity container, without any other code
/// knowing the difference (see Design conventions).
public protocol ContainerLocating: Sendable {
    /// The container root directory, created on disk if needed.
    func containerRoot() throws -> URL
}

/// A container backed by an ordinary local folder. Used in dev and tests, and
/// as the M1-M2 default before real iCloud is wired up (M3).
public struct LocalFolderContainer: ContainerLocating {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func containerRoot() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// A container backed by the app's iCloud ubiquity container. Stood up for real
/// on the Mac at the start of M3 (per the plan's iCloud sequencing).
public struct UbiquityContainer: ContainerLocating {
    public let identifier: String?

    /// - Parameter identifier: the ubiquity container ID, or `nil` for the
    ///   app's primary container.
    public init(identifier: String? = nil) {
        self.identifier = identifier
    }

    public func containerRoot() throws -> URL {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
            throw ContainerError.iCloudUnavailable
        }
        let root = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

public enum ContainerError: Error, LocalizedError, Equatable {
    case iCloudUnavailable
    case sessionNotFound(id: String)

    public var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud is unavailable. Sign in to iCloud and enable iCloud Drive for this app."
        case let .sessionNotFound(id):
            return "No session found with id \(id)."
        }
    }
}
