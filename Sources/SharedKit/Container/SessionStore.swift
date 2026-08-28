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
        AppLog.container.debug("session saved id=\(session.id, privacy: .public) status=\(session.metadata.pipeline.status.name, privacy: .public)")
    }

    // MARK: Document rotation (N10, ADR-11)

    /// Writes `transcript.md`, rotating any existing one to `transcript.vN.md`.
    ///
    /// In normal operation the transcript is written exactly once and then
    /// treated as immutable (N10). A user-invoked re-transcription is the sole
    /// exception (ADR-11), and it rotates rather than overwrites so the earlier
    /// transcript - and whatever a protocol was derived from - is never lost.
    /// Returns the rotated URL, or `nil` when there was nothing to rotate.
    @discardableResult
    public func writeTranscript(_ text: String, for session: Session) throws -> URL? {
        let fileManager = FileManager.default
        var rotatedTo: URL?
        if fileManager.fileExists(atPath: session.transcriptURL.path) {
            var version = 1
            while fileManager.fileExists(atPath: session.rotatedTranscriptURL(version: version).path) {
                version += 1
            }
            let destination = session.rotatedTranscriptURL(version: version)
            try fileManager.moveItem(at: session.transcriptURL, to: destination)
            rotatedTo = destination
        }
        try atomicWrite(Data(text.utf8), to: session.transcriptURL)
        return rotatedTo
    }

    /// Rotates an existing `protocol.md` to the next free `protocol.vN.md` and
    /// writes fresh protocol text. Returns the rotated URL if one was made.
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
            AppLog.container.info("claim conflict session=\(session.id, privacy: .public) step=\(step.rawValue, privacy: .public) heldBy=\(existing.deviceId, privacy: .public)")
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

    /// Updates the pipeline status and persists. The claim is left untouched
    /// here; the pipeline clears it explicitly on completion/failure.
    @discardableResult
    public func setStatus(_ status: PipelineStatus, in folder: URL) throws -> Session {
        var session = try load(folder: folder)
        session.metadata.pipeline.status = status
        try save(session)
        return session
    }

    // MARK: Action steps (ADR-13)

    /// Replaces the whole recorded step list (used to seed/reset it before an
    /// actions run; `nil` clears it).
    @discardableResult
    public func setStepStates(_ steps: [StepState]?, in folder: URL) throws -> Session {
        var session = try load(folder: folder)
        session.metadata.pipeline.steps = steps
        try save(session)
        return session
    }

    /// Upserts one step's state by `stepID` and persists.
    @discardableResult
    public func updateStepState(_ step: StepState, in folder: URL) throws -> Session {
        var session = try load(folder: folder)
        var steps = session.metadata.pipeline.steps ?? []
        if let index = steps.firstIndex(where: { $0.stepID == step.stepID }) {
            steps[index] = step
        } else {
            steps.append(step)
        }
        session.metadata.pipeline.steps = steps
        try save(session)
        return session
    }

    /// Writes an action step's local audit artifact (`steps/<stepID>.md`),
    /// overwriting any previous run's report - artifacts are logs, N10
    /// rotation applies to protocols only.
    @discardableResult
    public func writeStepArtifact(_ text: String, stepID: String, for session: Session) throws -> URL {
        let url = session.stepArtifactURL(stepID: stepID)
        try atomicWrite(Data(text.utf8), to: url)
        return url
    }

    // MARK: Atomic write helper

    func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `.atomic` writes to a temp file in the same directory then renames, so
        // readers never observe a half-written file.
        try data.write(to: url, options: .atomic)
    }
}
