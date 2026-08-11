import AVFoundation
import Foundation

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

    public init() {}

    public var value: Float {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    /// Computes RMS power for the buffer and stores the normalized level.
    public func update(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let samples = channels[0]
        var sum: Float = 0
        for i in 0..<count {
            let sample = samples[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let level = AudioLevels.normalize(db: db)
        lock.lock(); _value = level; lock.unlock()
    }

    public func reset() {
        lock.lock(); _value = 0; lock.unlock()
    }
}
