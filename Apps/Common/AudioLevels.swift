import AVFoundation
import Foundation
import SharedKit

/// Shared helpers for turning audio power into a 0...1 level for meters.
public enum AudioLevels {
    /// Normalize a decibel power reading (roughly -60...0 dB) to 0...1.
    public static func normalize(db: Float, floor: Float = -55) -> Float {
        if db.isNaN || db < floor { return 0 }
        if db >= 0 { return 1 }
        return (db - floor) / (0 - floor)
    }
}

/// Lock-guarded holder for the latest input level, updated from the Mac's
/// realtime `AVAudioEngine` tap (a non-isolated, realtime thread) and read from
/// the main actor for the meter. `@unchecked Sendable`: the `NSLock` serializes
/// all access to the stored value.
public final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float = 0
    private var _clippedFrames = 0
    private var _totalFrames = 0

    public init() {}

    public var value: Float {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    /// Whether enough of the recording hit full scale to call the input too hot.
    ///
    /// Clipping is one of the few distortions Whisper genuinely cannot recover
    /// from, and no amount of downstream processing undoes it - attenuating a
    /// clipped file only makes the speech quieter. So it has to be caught here,
    /// at the source, while the user can still do something about it.
    public var isClipping: Bool {
        lock.lock(); defer { lock.unlock() }
        return AudioClipping.isClipping(clipped: _clippedFrames, total: _totalFrames)
    }

    /// Fraction of samples seen so far that hit full scale (0...1).
    public var clippedFraction: Double {
        lock.lock(); defer { lock.unlock() }
        return AudioClipping.clippedFraction(clipped: _clippedFrames, total: _totalFrames)
    }

    /// Computes RMS power for the buffer, stores the normalized level, and counts
    /// full-scale samples.
    public func update(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        var sum: Float = 0
        var clipped = 0
        for i in 0..<count {
            let sample = samples[i]
            sum += sample * sample
            if AudioClipping.isClipped(sample) { clipped += 1 }
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = AudioLevels.normalize(db: db)
        lock.lock()
        _value = level
        _clippedFrames += clipped
        _totalFrames += count
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        _value = 0
        _clippedFrames = 0
        _totalFrames = 0
        lock.unlock()
    }
}
