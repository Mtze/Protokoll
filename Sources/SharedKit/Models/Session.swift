import Foundation

/// A session bound to its on-disk folder. Value type: cheap to pass around and
/// `Sendable` across actor boundaries. The folder is the unit of portability
/// (N3) - everything about a meeting lives inside it.
public struct Session: Sendable, Equatable, Identifiable {
    /// The session's folder, e.g. `…/sessions/2026-08-10T14-30_a1b2c3/`.
    public var folder: URL
    public var metadata: SessionMetadata

    public init(folder: URL, metadata: SessionMetadata) {
        self.folder = folder
        self.metadata = metadata
    }

    public var id: String { metadata.id }

    // MARK: Canonical file locations inside the folder

    public var audioDirectory: URL { folder.appendingPathComponent("audio", isDirectory: true) }
    public var micAudioURL: URL { audioDirectory.appendingPathComponent(AudioTrack.mic.fileName) }
    public var systemAudioURL: URL { audioDirectory.appendingPathComponent(AudioTrack.system.fileName) }
    /// Crash-safe intermediate capture file (ADR-3); converted to `mic.m4a` on stop.
    public var micCaptureURL: URL { audioDirectory.appendingPathComponent("mic.caf") }
    public var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
    public var protocolURL: URL { folder.appendingPathComponent("protocol.md") }
    public var agendaURL: URL { folder.appendingPathComponent("agenda.md") }
    public var metadataURL: URL { folder.appendingPathComponent("session.json") }

    /// Path for the Nth rotated protocol version (`protocol.v1.md`, …), N10.
    public func rotatedProtocolURL(version: Int) -> URL {
        folder.appendingPathComponent("protocol.v\(version).md")
    }

    /// Path for the Nth rotated transcript (`transcript.v1.md`, …), ADR-11.
    ///
    /// `transcript.md` stays immutable in normal operation (N10); only an
    /// explicit user-invoked re-transcription replaces it, and then the previous
    /// one is rotated here rather than destroyed.
    public func rotatedTranscriptURL(version: Int) -> URL {
        folder.appendingPathComponent("transcript.v\(version).md")
    }

    /// A human-facing title that is never an empty date-desert (F9): the
    /// explicit title if set, otherwise a localized-friendly fallback derived
    /// from the start time. The pipeline replaces the fallback with a generated
    /// title after summarization.
    public var displayTitle: String {
        if let title = metadata.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return Self.fallbackTitle(for: metadata.startedAt)
    }

    /// Whether a real, non-placeholder title has been assigned.
    public var hasExplicitTitle: Bool {
        guard let title = metadata.title else { return false }
        return !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func fallbackTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Generates stable, sortable, collision-free session identifiers and folder
/// names of the form `<ISO-8601 timestamp>_<shortID>` (see Container-Layout).
public enum SessionID {
    /// A short random suffix (6 lowercase hex chars) that keeps parallel
    /// recordings on Mac and iPhone from colliding.
    public static func shortID() -> String {
        let alphabet = Array("0123456789abcdef")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// Folder name: filesystem-safe ISO timestamp (colons → hyphens) + short ID.
    public static func folderName(startedAt: Date, shortID: String = SessionID.shortID()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // `2026-08-10T14:30:05Z` → `2026-08-10T14-30-05Z`; keep it path-safe.
        let stamp = formatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)_\(shortID)"
    }
}
