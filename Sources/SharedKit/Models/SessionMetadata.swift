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

/// The pipeline status block for a session, including any active claim (ADR-4)
/// and per-step completion timestamps.
public struct PipelineState: Codable, Sendable, Equatable {
    public var status: PipelineStatus
    public var claim: Claim?
    public var transcribedAt: Date?
    public var summarizedAt: Date?

    public init(
        status: PipelineStatus = .recorded,
        claim: Claim? = nil,
        transcribedAt: Date? = nil,
        summarizedAt: Date? = nil
    ) {
        self.status = status
        self.claim = claim
        self.transcribedAt = transcribedAt
        self.summarizedAt = summarizedAt
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
        self.pipeline = pipeline
    }
}
