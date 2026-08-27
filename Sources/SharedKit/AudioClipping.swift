import Foundation

/// Whether a recording's input level was too hot.
///
/// Lives in SharedKit rather than next to the meter in `Apps/Common` so it is
/// reachable from `swift test` - nothing under `Apps/` is. The meter does the
/// per-buffer counting on the realtime thread; the policy lives here.
///
/// Clipping matters because it is one of the few distortions Whisper genuinely
/// cannot recover from, and nothing downstream undoes it: attenuating an
/// already-clipped file only makes the speech quieter. Measured on a real
/// meeting, a "correction" of -16.3 dB applied to clipped audio cost 29% of the
/// transcribed words. So it has to be caught at capture time, while the user can
/// still lower the input level.
public enum AudioClipping {
    /// A sample at or above this magnitude counts as clipped. Just under 1.0 so
    /// samples that only reach full scale through float rounding still count.
    public static let sampleThreshold: Float = 0.999

    /// Fraction of clipped samples above which a recording is worth warning
    /// about. Isolated clipped samples are inaudible and unavoidable on any live
    /// input; a sustained rate means the gain is genuinely too high.
    public static let warningRatio = 0.0005  // 0.05%

    /// Whether `clipped` out of `total` samples is enough to warn.
    public static func isClipping(clipped: Int, total: Int) -> Bool {
        guard total > 0, clipped > 0 else { return false }
        return Double(clipped) / Double(total) > warningRatio
    }

    /// Fraction of samples that hit full scale, 0...1.
    public static func clippedFraction(clipped: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(clipped) / Double(total)
    }

    /// Whether a single sample counts as clipped.
    public static func isClipped(_ sample: Float) -> Bool {
        abs(sample) >= sampleThreshold
    }
}
