import AVFoundation
import Foundation
import SharedKit
import WatchConnectivity

/// Lean watch recorder: records to a local `m4a`, then hands it to
/// ``WatchTransfer`` for delivery to the iPhone (ADR-6). No container access and
/// no processing on the watch.
@MainActor
@Observable
final class WatchRecorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startedAt: Date?
    private(set) var isRecording = false
    private(set) var lastStatus: String = ""

    // Live recording meter (N4) + the last clip, kept for native playback.
    private(set) var levels: [Float] = []
    private(set) var recordingStartedAt: Date?
    private(set) var lastRecordingURL: URL?
    private var levelTask: Task<Void, Never>?
    private let levelBarCount = 28

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
    }

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    private func start() async {
        guard await Self.requestMicrophoneAccess() else { lastStatus = String(localized: "recorder.error.permission"); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            self.fileURL = url
            self.startedAt = Date()
            self.isRecording = true
            self.recordingStartedAt = Date()
            self.lastRecordingURL = nil
            startLevelMonitoring()
        } catch {
            lastStatus = error.localizedDescription
        }
    }

    private func stop() async {
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopLevelMonitoring()
        guard let fileURL, let startedAt else { return }
        let duration = Date().timeIntervalSince(startedAt)
        WatchTransfer.shared.send(audio: fileURL, startedAt: startedAt, duration: duration)
        lastStatus = String(localized: "watch.sent")
        lastRecordingURL = fileURL  // keep for local playback
        self.fileURL = nil
        self.startedAt = nil
    }

    // MARK: Recording meter

    private func startLevelMonitoring() {
        levels = Array(repeating: 0, count: levelBarCount)
        let barCount = levelBarCount
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording, let recorder = self.recorder else { break }
                recorder.updateMeters()
                let level = AudioLevels.normalize(db: recorder.averagePower(forChannel: 0))
                var levels = self.levels
                levels.append(level)
                if levels.count > barCount { levels.removeFirst(levels.count - barCount) }
                self.levels = levels
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTask?.cancel()
        levelTask = nil
        levels = []
        recordingStartedAt = nil
    }
}

/// Sends a recording to the paired iPhone via WatchConnectivity (ADR-6).
/// `@unchecked Sendable`: it holds no mutable state, only wraps `WCSession.default`.
final class WatchTransfer: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchTransfer()

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(audio url: URL, startedAt: Date, duration: TimeInterval) {
        guard WCSession.isSupported() else { return }
        let metadata: [String: Any] = [
            "startedAt": startedAt.timeIntervalSince1970,
            "duration": duration,
        ]
        WCSession.default.transferFile(url, metadata: metadata)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}
