import AVFoundation
import Foundation
import SharedKit

/// Turns an arbitrary pre-recorded audio file into the canonical `mic.m4a` the
/// pipeline expects, so an existing recording (a call captured elsewhere, a
/// voice memo, an mp3) can be imported as a normal session. The processing
/// pipeline is unchanged; import just reproduces the on-disk shape a recording
/// leaves behind. Lives alongside `AudioMixer` so the transcode is unit-testable
/// via `swift test`.
public enum AudioImporter {
    /// Produces a complete `mic.m4a` at `destination` from `source`. Always
    /// transcodes to canonical AAC/m4a (validating the source has an audio
    /// track), then atomically renames into place so the pipeline / notifier
    /// never observe a partial `mic.m4a`.
    public static func makeMicTrack(from source: URL, into destination: URL) async throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Transcode to a temp file (still .m4a so the export session is happy),
        // then a same-directory rename makes the final file appear atomically.
        let temp = dir.appendingPathComponent(".importing-\(UUID().uuidString).m4a")
        do {
            // Reuse the tested single-source transcode (AVAssetExportPresetAppleM4A);
            // it throws .noAudioTrack when the file has no audio, and extracts the
            // audio track from mp4/mov containers.
            try await AudioMixer.mix([source], into: temp)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Best-effort duration for metadata; nil if unreadable or non-finite.
    public static func duration(of url: URL) async -> TimeInterval? {
        guard let cm = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(cm)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
