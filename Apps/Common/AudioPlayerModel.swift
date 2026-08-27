import AVFoundation
import Foundation
import Observation
import SharedKit

/// A small, cross-platform (macOS/iOS/watchOS) audio playback model built on
/// `AVAudioPlayer`. Drives ``AudioPlayerView`` with play/pause, a scrubbable
/// position, and variable playback speed. End-of-playback is detected by the
/// position ticker rather than a delegate, which keeps everything on the main
/// actor and clear of strict-concurrency hazards.
@MainActor
@Observable
public final class AudioPlayerModel {
    /// Selectable playback speeds.
    public static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// How often the position ticker samples the player.
    ///
    /// 10 Hz, not 20: at a 600 pt scrubber a one-hour clip advances 0.17 pt per
    /// tick at 20 Hz, so the extra ticks buy no visible smoothness while every
    /// one of them invalidates each view that reads ``currentTime``.
    static let tickInterval: Duration = .milliseconds(100)

    public private(set) var isPlaying = false
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var rate: Float = 1.0
    public private(set) var isLoaded = false
    public private(set) var loadedURL: URL?

    /// Index into ``segmentStarts`` of the segment under the playhead.
    ///
    /// This exists so the transcript list can observe a value that changes once
    /// per *segment* (~1,500 times an hour) instead of ``currentTime``, which
    /// changes on every tick (~36,000 times an hour). `Int?` is `Equatable`, and
    /// the `@Observable` macro suppresses same-value writes, so ticks landing
    /// inside the current segment invalidate nothing at all.
    public private(set) var currentSegment: Int?

    /// Segment start times, ascending, for ``currentSegment``. Set by the view
    /// that owns the transcript; empty means no transcript is being followed.
    ///
    /// `@ObservationIgnored` on purpose: assigning the whole transcript must not
    /// invalidate anything, and nothing observes it.
    @ObservationIgnored public var segmentStarts: [TranscriptSegment] = [] {
        didSet { recomputeCurrentSegment() }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {
        // Honor the user's default playback speed (Settings).
        let stored = UserDefaults.standard.double(forKey: "defaultPlaybackSpeed")
        if stored > 0 { rate = Float(stored) }
    }

    /// Loads a file for playback. No-op if the same URL is already loaded.
    public func load(_ url: URL) {
        guard loadedURL != url else { return }
        stopTicker()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0

        guard FileManager.default.fileExists(atPath: url.path) else {
            isLoaded = false; loadedURL = nil; duration = 0
            return
        }
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            isLoaded = false; loadedURL = nil; duration = 0
            return
        }
        newPlayer.enableRate = true
        newPlayer.rate = rate
        newPlayer.prepareToPlay()
        player = newPlayer
        duration = newPlayer.duration
        loadedURL = url
        isLoaded = true
        recomputeCurrentSegment()
    }

    public func playPause() { isPlaying ? pause() : play() }

    public func play() {
        guard let player else { return }
        player.rate = rate
        player.play()
        isPlaying = true
        startTicker()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    /// Seeks to an absolute time (clamped to the clip).
    public func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
        recomputeCurrentSegment()
    }

    /// Recomputes ``currentSegment`` from the playhead. Cheap (binary search) and
    /// a no-op for observers whenever the index has not actually changed.
    private func recomputeCurrentSegment() {
        guard isLoaded, !segmentStarts.isEmpty else {
            currentSegment = nil
            return
        }
        currentSegment = TranscriptSegment.index(at: currentTime, in: segmentStarts)
    }

    /// Seeks to `time` and starts playing from there. Used by the tap-to-seek
    /// transcript list; a no-op until a file is loaded.
    public func seekAndPlay(to time: TimeInterval) {
        guard isLoaded else { return }
        seek(to: time)
        play()
    }

    /// Advances to the next preset speed (used on watchOS where menus are awkward).
    public func cycleRate() {
        let speeds = Self.speeds
        let index = speeds.firstIndex(of: rate) ?? 1
        setRate(speeds[(index + 1) % speeds.count])
    }

    public func setRate(_ newRate: Float) {
        rate = newRate
        player?.rate = newRate
    }

    private func finish() {
        isPlaying = false
        stopTicker()
        currentTime = 0
        player?.currentTime = 0
        recomputeCurrentSegment()
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let player = self.player {
                    if player.isPlaying {
                        self.currentTime = player.currentTime
                        self.recomputeCurrentSegment()
                    } else if self.isPlaying {
                        // Playback reached the end on its own.
                        self.finish()
                        return
                    }
                }
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
