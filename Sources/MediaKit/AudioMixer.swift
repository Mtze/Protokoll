import AVFoundation
import Foundation
import SharedKit

/// Mixes several audio files into one, so a meeting recorded as separate mic
/// and system-audio tracks becomes a single track the pipeline can transcribe
/// end to end (ADR-7). Lives in its own module so the mixing is unit-testable
/// via `swift test` (SharedKit stays Foundation-only).
public enum AudioMixer {
    public enum MixError: Error, LocalizedError {
        case noAudioTrack
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "No audio track to mix."
            case let .exportFailed(message): return message
            }
        }
    }

    /// Mixes `sources` (all inserted at time 0, summed) into a single `.m4a` at
    /// `output`. The result is as long as the longest input.
    public static func mix(_ sources: [URL], into output: URL) async throws {
        let composition = AVMutableComposition()
        var inserted = 0
        for url in sources {
            let asset = AVURLAsset(url: url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let assetTrack = audioTracks.first else { continue }
            let duration = try await asset.load(.duration)
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: .zero)
            inserted += 1
        }
        guard inserted > 0 else {
            AppLog.systemAudio.error("mix failed: no audio track in \(sources.count, privacy: .public) source(s)")
            throw MixError.noAudioTrack
        }
        AppLog.systemAudio.info("mixing \(inserted, privacy: .public) track(s) into \(output.lastPathComponent, privacy: .public)")

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MixError.exportFailed("could not create export session")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a
        // Completion-handler API (the async export() is macOS 15+; floor is 14).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw MixError.exportFailed(export.error?.localizedDescription ?? "export failed")
        }
    }
}
