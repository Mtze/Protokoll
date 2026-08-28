import Foundation

/// A processing step that a host machine can claim exclusively.
public enum PipelineStep: String, Codable, Sendable, CaseIterable {
    case transcribe
    case summarize
}

/// A lease baked into `session.json` so multiple machines (or a future
/// background daemon, NH2) never process the same session twice.
///
/// A claim is *live* while its `heartbeat` is recent; a host renews the
/// heartbeat while it works. A claim whose heartbeat is older than
/// ``Claim/leaseDuration`` is considered stale and may be taken over - this
/// covers a host that crashed mid-step (ADR-4).
public struct Claim: Codable, Sendable, Equatable, Hashable {
    /// Stable identifier of the machine holding the claim.
    public var deviceId: String
    /// Which step is being worked on.
    public var step: PipelineStep
    /// When the claim was first acquired.
    public var startedAt: Date
    /// Last liveness signal from the holder; renewed periodically.
    public var heartbeat: Date

    public init(deviceId: String, step: PipelineStep, startedAt: Date, heartbeat: Date) {
        self.deviceId = deviceId
        self.step = step
        self.startedAt = startedAt
        self.heartbeat = heartbeat
    }

    /// Tolerant decode: an unknown `step` written by a newer build maps to
    /// `.summarize` instead of failing the whole `session.json` (ADR-13
    /// groundwork - old readers must keep loading files with future steps).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        let raw = try container.decode(String.self, forKey: .step)
        step = PipelineStep(rawValue: raw) ?? .summarize
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        heartbeat = try container.decode(Date.self, forKey: .heartbeat)
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId, step, startedAt, heartbeat
    }

    /// How long a claim survives without a heartbeat before it is stale.
    public static let leaseDuration: TimeInterval = 120

    /// Whether the claim is still considered live at `now`.
    public func isLive(now: Date = Date()) -> Bool {
        now.timeIntervalSince(heartbeat) < Self.leaseDuration
    }
}
