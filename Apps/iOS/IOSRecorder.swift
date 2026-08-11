import AVFoundation
import Foundation
import SharedKit

/// Lean iOS recorder (F11): captures to a streamable CAF via `AVAudioRecorder`,
/// converts to `mic.m4a` on stop (same crash-safety as ADR-3). No processing on
/// device - the Mac pipeline does that.
actor IOSRecorder {
    private var recorder: AVAudioRecorder?
    private var session: Session?
    private var startedAt: Date?
    private(set) var isRecording = false

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
    }

    /// Current normalized input level (0...1) for the recording meter.
    func currentLevel() -> Float {
        guard let recorder, isRecording else { return 0 }
        recorder.updateMeters()
        return AudioLevels.normalize(db: recorder.averagePower(forChannel: 0))
    }

    func start(session: Session) throws {
        guard !isRecording else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default)
        try audioSession.setActive(true)
        try FileManager.default.createDirectory(at: session.audioDirectory, withIntermediateDirectories: true)

        // Linear PCM in a CAF container: written progressively, crash-safe (N5).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        let recorder = try AVAudioRecorder(url: session.micCaptureURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        self.session = session
        self.startedAt = Date()
        self.isRecording = true
    }

    func stop() async throws -> Session {
        guard isRecording, var session, let startedAt else {
            throw RecorderError.notRecording
        }
        recorder?.stop()
        recorder = nil
        isRecording = false

        try await convertCAFToM4A(caf: session.micCaptureURL, m4a: session.micAudioURL)
        try? FileManager.default.removeItem(at: session.micCaptureURL)

        let ended = Date()
        session.metadata.endedAt = ended
        session.metadata.duration = ended.timeIntervalSince(startedAt)
        session.metadata.audioTracks = [.mic]
        self.session = nil
        self.startedAt = nil
        return session
    }

    enum RecorderError: Error, LocalizedError {
        case notRecording
        case conversionFailed(String)
        var errorDescription: String? {
            switch self {
            case .notRecording: return String(localized: "recorder.error.notRecording")
            case let .conversionFailed(message): return message
            }
        }
    }

    private func convertCAFToM4A(caf: URL, m4a: URL) async throws {
        let asset = AVURLAsset(url: caf)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.conversionFailed(String(localized: "recorder.error.conversion"))
        }
        try? FileManager.default.removeItem(at: m4a)
        export.outputURL = m4a
        export.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed {
            throw RecorderError.conversionFailed(export.error?.localizedDescription ?? "export failed")
        }
    }
}
