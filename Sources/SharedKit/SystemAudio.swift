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
    /// The current system-audio input level (0...1) for the live waveform, so the
    /// meter reflects the other side of the call too. Returns 0 when idle; the
    /// AVFoundation level computation lives in the Mac recorder.
    func currentLevel() -> Float
}

public extension SystemAudioCapturing {
    func currentLevel() -> Float { 0 }
}

/// Pure helpers for combining live input levels into a single waveform reading.
/// Kept Foundation-only and testable; the audio-buffer math lives in the app.
public enum RecordingLevel {
    /// Combines the mic and system-audio levels so either source lights the
    /// waveform. Uses the max of the two and clamps the result to 0...1;
    /// NaN inputs are treated as silence.
    public static func combined(mic: Float, system: Float) -> Float {
        let cleanMic = mic.isNaN ? 0 : mic
        let cleanSystem = system.isNaN ? 0 : system
        return min(1, max(0, max(cleanMic, cleanSystem)))
    }
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

    /// The current system-audio level (0...1) for the live waveform; 0 when idle.
    public func currentLevel() -> Float {
        capture.currentLevel()
    }
}
