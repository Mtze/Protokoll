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
            recorder.record()
            self.recorder = recorder
            self.fileURL = url
            self.startedAt = Date()
            self.isRecording = true
        } catch {
            lastStatus = error.localizedDescription
        }
    }

    private func stop() async {
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let fileURL, let startedAt else { return }
        let duration = Date().timeIntervalSince(startedAt)
        WatchTransfer.shared.send(audio: fileURL, startedAt: startedAt, duration: duration)
        lastStatus = String(localized: "watch.sent")
        self.fileURL = nil
        self.startedAt = nil
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
