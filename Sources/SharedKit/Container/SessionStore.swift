import Foundation

/// Raised when a claim cannot be acquired because another host holds a live one.
public struct ClaimConflict: Error, Equatable, Sendable {
    public let heldBy: String
    public let step: PipelineStep
}

/// The sole reader/writer of `session.json` (ADR-2). All persistence goes
/// through here so writes are atomic and the canonical model stays consistent.
///
/// Stateless: every method reads or writes the file fresh, which keeps the
/// claim/lease logic correct across separate processes (the app and the
/// `process-session` subprocess both mutate the same file).
public struct SessionStore: Sendable {
    public init() {}

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: session.json

    /// Loads and decodes a session from its folder.
    public func load(folder: URL) throws -> Session {
        let url = folder.appendingPathComponent("session.json")
        let data = try Data(contentsOf: url)
        let metadata = try Self.decoder.decode(SessionMetadata.self, from: data)
        return Session(folder: folder, metadata: metadata)
    }

    /// Atomically persists a session's metadata to `session.json`.
    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(at: session.folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(session.metadata)
        try atomicWrite(data, to: session.metadataURL)
    }

    // MARK: Protocol rotation (N10)

    /// Rotates an existing `protocol.md` to the next free `protocol.vN.md` and
    /// writes fresh protocol text. Returns the rotated URL if one was made.
    ///
    /// The raw transcript is never touched; only protocols rotate, so nothing is
    /// lost when a protocol is regenerated.
    @discardableResult
    public func writeProtocol(_ text: String, for session: Session) throws -> URL? {
        let fileManager = FileManager.default
        var rotatedTo: URL?
        if fileManager.fileExists(atPath: session.protocolURL.path) {
            var version = 1
            while fileManager.fileExists(atPath: session.rotatedProtocolURL(version: version).path) {
                version += 1
            }
            let destination = session.rotatedProtocolURL(version: version)
            try fileManager.moveItem(at: session.protocolURL, to: destination)
            rotatedTo = destination
        }
        try atomicWrite(Data(text.utf8), to: session.protocolURL)
        return rotatedTo
    }

    // MARK: Claim / lease (ADR-4)

    /// Acquires an exclusive claim on a step for `deviceId`, or throws
    /// ``ClaimConflict`` if another host holds a live claim. A stale claim
    /// (heartbeat older than the lease) is taken over. Persists immediately.
    @discardableResult
    public func acquireClaim(
        step: PipelineStep,
        deviceId: String,
        in folder: URL,
        now: Date = Date()
    ) throws -> Session {
        var session = try load(folder: folder)
        if let existing = session.metadata.pipeline.claim,
           existing.deviceId != deviceId,
           existing.isLive(now: now) {
            throw ClaimConflict(heldBy: existing.deviceId, step: existing.step)
        }
        session.metadata.pipeline.claim = Claim(
            deviceId: deviceId, step: step, startedAt: now, heartbeat: now
        )
        try save(session)
        return session
    }

    /// Renews the heartbeat of the current claim if held by `deviceId`.
    @discardableResult
    public func renewClaim(deviceId: String, in folder: URL, now: Date = Date()) throws -> Session {
        var session = try load(folder: folder)
        if var claim = session.metadata.pipeline.claim, claim.deviceId == deviceId {
            claim.heartbeat = now
            session.metadata.pipeline.claim = claim
            try save(session)
        }
        return session
    }

    /// Releases the claim if held by `deviceId`.
    @discardableResult
    public func releaseClaim(deviceId: String, in folder: URL) throws -> Session {
        var session = try load(folder: folder)
        if let claim = session.metadata.pipeline.claim, claim.deviceId == deviceId {
            session.metadata.pipeline.claim = nil
            try save(session)
        }
        return session
    }

    /// Updates the pipeline status (clearing any claim when reaching a terminal
    /// state) and persists.
    @discardableResult
    public func setStatus(_ status: PipelineStatus, in folder: URL) throws -> Session {
        var session = try load(folder: folder)
        session.metadata.pipeline.status = status
        try save(session)
        return session
    }

    // MARK: Atomic write helper

    func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        // Replace in place so readers never see a half-written file.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
