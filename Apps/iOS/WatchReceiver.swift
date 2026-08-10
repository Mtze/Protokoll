import Foundation
import SharedKit
import WatchConnectivity

/// Receives audio transferred from the Apple Watch (ADR-6) and writes it into
/// the container as a new `device: .watch` session. The Mac pipeline processes
/// it like any other recording.
final class WatchReceiver: NSObject, WCSessionDelegate {
    private let container: Container

    init(container: Container) {
        self.container = container
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let startedAt = (file.metadata?["startedAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
        let duration = file.metadata?["duration"] as? TimeInterval
        do {
            var newSession = try container.createSession(device: .watch, startedAt: startedAt)
            try FileManager.default.copyItem(at: file.fileURL, to: newSession.micAudioURL)
            newSession.metadata.duration = duration
            newSession.metadata.endedAt = duration.map { startedAt.addingTimeInterval($0) }
            newSession.metadata.audioTracks = [.mic]
            try container.store.save(newSession)
        } catch {
            // Transfer will be retried by WatchConnectivity if the write failed.
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
