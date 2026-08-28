import Foundation

/// Which kind of device recorded a session.
public enum Device: String, Codable, Sendable {
    case mac
    case ios
    case watch
}

/// An audio track present in a session's `audio/` directory.
public enum AudioTrack: String, Codable, Sendable, CaseIterable {
    /// The microphone recording, always present (`mic.m4a`).
    case mic
    /// Optional system-audio capture for calls (`system.m4a`, F2).
    case system

    /// The on-disk file name for this track.
    public var fileName: String { "\(rawValue).m4a" }
}

/// A geographic coordinate, captured optionally on iOS (F8).
public struct GeoCoordinate: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Progress of one custom action step (ADR-13), recorded by the pipeline.
/// ``status`` is a plain string (``pending``/``running``/``done``/``failed``/
/// ``stale``) so newer writers never break older readers; anything unknown is
/// simply displayed as-is. ``stale`` marks a completed step whose protocol was
/// regenerated afterwards - external re-runs stay a manual decision.
public struct StepState: Codable, Sendable, Equatable {
    public var stepID: String
    /// Denormalized display name, so history stays readable after the step is
    /// renamed or deleted from its pipeline.
    public var name: String
    public var status: String
    public var message: String?
    public var finishedAt: Date?

    public static let pending = "pending"
    public static let running = "running"
    public static let done = "done"
    public static let failed = "failed"
    public static let stale = "stale"

    public init(
        stepID: String,
        name: String,
        status: String = StepState.pending,
        message: String? = nil,
        finishedAt: Date? = nil
    ) {
        self.stepID = stepID
        self.name = name
        self.status = status
        self.message = message
        self.finishedAt = finishedAt
    }
}

/// The pipeline status block for a session, including any active claim (ADR-4)
/// and per-step completion timestamps.
public struct PipelineState: Codable, Sendable, Equatable {
    public var status: PipelineStatus
    public var claim: Claim?
    public var transcribedAt: Date?
    public var summarizedAt: Date?
    /// Per-action progress (ADR-13); `nil` when the resolved pipeline has no
    /// custom steps. Additive so pre-ADR-13 builds keep decoding this file.
    public var steps: [StepState]?

    public init(
        status: PipelineStatus = .recorded,
        claim: Claim? = nil,
        transcribedAt: Date? = nil,
        summarizedAt: Date? = nil,
        steps: [StepState]? = nil
    ) {
        self.status = status
        self.claim = claim
        self.transcribedAt = transcribedAt
        self.summarizedAt = summarizedAt
        self.steps = steps
    }
}

/// The canonical metadata for a session, persisted verbatim as `session.json`
/// (ADR-2). `SharedKit` is the sole reader/writer; the Markdown files mirror a
/// subset of these fields as YAML frontmatter.
public struct SessionMetadata: Codable, Sendable, Equatable {
    /// Stable session ID; equals the folder-name suffix.
    public var id: String
    /// Display title; `nil` until the user or the pipeline sets one (F9).
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var duration: TimeInterval?
    public var device: Device
    /// Optional geotag (iOS only, F8).
    public var geo: GeoCoordinate?
    /// Project IDs referencing `projects.json` (F7).
    public var projects: [String]
    /// Detected or chosen meeting language (N8).
    public var language: String?
    /// Optional consent note (N4, § 201 StGB awareness).
    public var consentNote: String?
    /// Audio tracks present on disk.
    public var audioTracks: [AudioTrack]
    /// Links to the meeting's materials (agenda doc, reference pages), fetched
    /// read-only before summarize (ADR-13, generalized F5).
    public var materials: [String]?
    /// Per-session pipeline override (ADR-13). `nil` = no override; a value
    /// naming no known pipeline resolves to the built-in default.
    public var pipelineID: String?
    /// Per-step input overrides, keyed step ID -> input key -> value (ADR-13).
    public var stepInputs: [String: [String: String]]?
    /// Processing status block.
    public var pipeline: PipelineState

    public init(
        id: String,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        duration: TimeInterval? = nil,
        device: Device,
        geo: GeoCoordinate? = nil,
        projects: [String] = [],
        language: String? = nil,
        consentNote: String? = nil,
        audioTracks: [AudioTrack] = [.mic],
        materials: [String]? = nil,
        pipelineID: String? = nil,
        stepInputs: [String: [String: String]]? = nil,
        pipeline: PipelineState = PipelineState()
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.device = device
        self.geo = geo
        self.projects = projects
        self.language = language
        self.consentNote = consentNote
        self.audioTracks = audioTracks
        self.materials = materials
        self.pipelineID = pipelineID
        self.stepInputs = stepInputs
        self.pipeline = pipeline
    }
}
