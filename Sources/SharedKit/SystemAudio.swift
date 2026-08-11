import Foundation

/// Abstraction over optional system-audio capture (F2), so the recording glue
/// can be unit-tested with a fake and the concrete ScreenCaptureKit recorder
/// stays in the Mac app.
public protocol SystemAudioCapturing: Sendable {
    /// Starts capturing system audio to `url`. Throws if it cannot start
    /// (e.g. missing Screen Recording permission).
    func start(to url: URL) async throws
    /// Stops capture and returns whether any audio was actually written.
    func stop() async -> Bool
}

/// Result of trying to begin system-audio capture.
public struct SystemAudioOutcome: Sendable, Equatable {
    public var capturing: Bool
    public var error: String?
    public init(capturing: Bool, error: String?) {
        self.capturing = capturing
        self.error = error
    }
}

/// Coordinates a ``SystemAudioCapturing`` and turns failures into a surfaced
/// message instead of a silent mic-only fallback.
public struct SystemAudioController: Sendable {
    private let capture: any SystemAudioCapturing

    public init(capture: any SystemAudioCapturing) {
        self.capture = capture
    }

    public func begin(to url: URL) async -> SystemAudioOutcome {
        do {
            try await capture.start(to: url)
            return SystemAudioOutcome(capturing: true, error: nil)
        } catch {
            return SystemAudioOutcome(capturing: false, error: error.localizedDescription)
        }
    }

    /// Stops capture; returns whether audio was actually recorded.
    public func end() async -> Bool {
        await capture.stop()
    }
}
