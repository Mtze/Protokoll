import Foundation

/// The processing lifecycle of a session, persisted in `session.json`.
///
/// The happy path is a linear progression; `failed` carries a human-readable
/// message so the UI can show an actionable error instead of a cryptic state.
/// Every step is individually re-runnable (see requirement N6).
public enum PipelineStatus: Sendable, Equatable, Hashable {
    /// Audio captured, nothing processed yet.
    case recorded
    /// Transcription in progress.
    case transcribing
    /// `transcript.md` written and immutable (N10).
    case transcribed
    /// Summarization in progress.
    case summarizing
    /// `protocol.md` written; the session is complete.
    case done
    /// A step failed; the associated value explains why.
    case failed(message: String)
}

extension PipelineStatus {
    /// The bare state name, without any failure detail.
    public var name: String {
        switch self {
        case .recorded: return "recorded"
        case .transcribing: return "transcribing"
        case .transcribed: return "transcribed"
        case .summarizing: return "summarizing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// Whether a transcript is expected to exist on disk in this state.
    public var hasTranscript: Bool {
        switch self {
        case .transcribed, .summarizing, .done: return true
        default: return false
        }
    }
}

// Persisted as `{ "state": "failed", "message": "…" }` so the JSON stays
// self-describing and forward-compatible.
extension PipelineStatus: Codable {
    private enum CodingKeys: String, CodingKey { case state, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case "recorded": self = .recorded
        case "transcribing": self = .transcribing
        case "transcribed": self = .transcribed
        case "summarizing": self = .summarizing
        case "done": self = .done
        case "failed":
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .failed(message: message)
        default:
            // Tolerate unknown states from a newer writer rather than crashing.
            self = .failed(message: "unknown pipeline state: \(state)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .state)
        if case let .failed(message) = self {
            try container.encode(message, forKey: .message)
        }
    }
}
