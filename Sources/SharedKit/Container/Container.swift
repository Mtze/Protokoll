import Foundation

/// The container: the single source of truth folder holding all sessions and
/// project definitions. Reads and writes go through ``SessionStore``; the
/// container itself just knows the tree layout and how to enumerate it.
public struct Container: Sendable {
    public let locator: ContainerLocating
    public let store: SessionStore

    public init(locator: ContainerLocating, store: SessionStore = SessionStore()) {
        self.locator = locator
        self.store = store
    }

    public func root() throws -> URL { try locator.containerRoot() }

    public func sessionsDirectory() throws -> URL {
        let url = try root().appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func projectsDirectory() throws -> URL {
        let url = try root().appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Sessions

    /// Creates a new session folder with `audio/` and an initial `session.json`
    /// in the `recorded` state.
    @discardableResult
    public func createSession(
        device: Device,
        startedAt: Date = Date(),
        title: String? = nil,
        audioTracks: [AudioTrack] = [.mic]
    ) throws -> Session {
        let id = SessionID.shortID()
        let folderName = SessionID.folderName(startedAt: startedAt, shortID: id)
        let folder = try sessionsDirectory().appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        let metadata = SessionMetadata(
            id: id,
            title: title,
            startedAt: startedAt,
            device: device,
            audioTracks: audioTracks
        )
        let session = Session(folder: folder, metadata: metadata)
        try store.save(session)
        AppLog.container.info("session created id=\(id, privacy: .public) device=\(device.rawValue, privacy: .public) folder=\(folderName, privacy: .public)")
        return session
    }

    /// All sessions in the container, sorted newest first. Folders with a
    /// missing or malformed `session.json` are skipped rather than crashing the
    /// caller (N3 tolerance).
    public func allSessions() throws -> [Session] {
        let directory = try sessionsDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var sessions: [Session] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            // Only surface a load failure for folders that actually claim to be a
            // session (have a session.json); folders without one are not sessions.
            let hasMetadata = FileManager.default.fileExists(
                atPath: entry.appendingPathComponent("session.json").path
            )
            do {
                sessions.append(try store.load(folder: entry))
            } catch where hasMetadata {
                AppLog.container.error("skipping malformed session folder=\(AppLog.folderName(entry), privacy: .public): \(AppLog.describe(error), privacy: .public)")
            } catch {
                // Not a session folder; ignore quietly.
            }
        }
        return sessions.sorted { $0.metadata.startedAt > $1.metadata.startedAt }
    }

    /// Loads a single session by ID, or `nil` if not found.
    public func session(id: String) throws -> Session? {
        try allSessions().first { $0.metadata.id == id }
    }

    /// Deletes a session's entire folder (audio, transcript, protocol, metadata)
    /// from disk. On macOS the folder is moved to the Trash so a deletion is
    /// recoverable; on other platforms it is removed outright. A missing folder
    /// is a no-op, so deleting an already-gone session never throws.
    public func deleteSession(_ session: Session) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: session.folder.path) else { return }
        #if os(macOS)
        try fileManager.trashItem(at: session.folder, resultingItemURL: nil)
        #else
        try fileManager.removeItem(at: session.folder)
        #endif
    }

    // MARK: Projects (F7)

    /// Reads the project/tag definitions, returning an empty list if none exist.
    public func loadProjects() throws -> [Project] {
        let url = try projectsDirectory().appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? SessionStore.decoder.decode([Project].self, from: data)) ?? []
    }

    /// Atomically persists the project/tag definitions.
    public func saveProjects(_ projects: [Project]) throws {
        let url = try projectsDirectory().appendingPathComponent("projects.json")
        let data = try SessionStore.encoder.encode(projects)
        try store.atomicWrite(data, to: url)
    }

    // MARK: Config

    public func configDirectory() throws -> URL {
        let url = try root().appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The pipeline settings (transcription/summary tuning). Returns defaults
    /// when unset or unreadable (tolerant, like ``loadProjects``).
    public func loadPipelineConfig() throws -> PipelineConfig {
        let url = try configDirectory().appendingPathComponent("pipeline.json")
        guard let data = try? Data(contentsOf: url) else { return PipelineConfig() }
        return (try? SessionStore.decoder.decode(PipelineConfig.self, from: data)) ?? PipelineConfig()
    }

    /// Atomically persists the pipeline settings.
    public func savePipelineConfig(_ config: PipelineConfig) throws {
        let url = try configDirectory().appendingPathComponent("pipeline.json")
        let data = try SessionStore.encoder.encode(config)
        try store.atomicWrite(data, to: url)
    }
}
