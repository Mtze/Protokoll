import AVFoundation
import Foundation
import Observation

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

    public private(set) var isPlaying = false
    public private(set) var duration: TimeInterval = 0
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var rate: Float = 1.0
    public private(set) var isLoaded = false
    public private(set) var loadedURL: URL?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

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
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let player = self.player {
                    if player.isPlaying {
                        self.currentTime = player.currentTime
                    } else if self.isPlaying {
                        // Playback reached the end on its own.
                        self.finish()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
