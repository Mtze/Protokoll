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

    /// Per-track gain applied when more than one source is mixed. Composition
    /// tracks sum at unity gain, so two hot inputs (a loud call plus a hot mic)
    /// can exceed 0 dBFS and clip into the AAC encoder. Clipping is one of the
    /// few distortions Whisper genuinely cannot recover from, and it is
    /// unrecoverable downstream, so halve each track (-6 dB) to guarantee
    /// headroom. A single source keeps unity gain - there is nothing to sum.
    static let multiTrackGain: Float = 0.5

    /// Mixes `sources` (all inserted at time 0, summed) into a single `.m4a` at
    /// `output`. The result is as long as the longest input. When more than one
    /// source contributes audio, each track is attenuated by
    /// ``multiTrackGain`` so the sum cannot clip.
    public static func mix(_ sources: [URL], into output: URL) async throws {
        let composition = AVMutableComposition()
        var insertedTracks: [AVMutableCompositionTrack] = []
        for url in sources {
            let asset = AVURLAsset(url: url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let assetTrack = audioTracks.first else { continue }
            let duration = try await asset.load(.duration)
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: .zero)
            insertedTracks.append(track)
        }
        let inserted = insertedTracks.count
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
        if inserted > 1 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = insertedTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(multiTrackGain, at: .zero)
                return parameters
            }
            export.audioMix = mix
            AppLog.systemAudio.debug("applied -6 dB per track to avoid clipping the sum")
        }
        // Completion-handler API (the async export() is macOS 15+; floor is 14).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw MixError.exportFailed(export.error?.localizedDescription ?? "export failed")
        }
    }
}
