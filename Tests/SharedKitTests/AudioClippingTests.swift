import Foundation
import Testing
@testable import SharedKit

/// Clipping detection at capture time.
///
/// This exists because clipping cannot be repaired afterwards: attenuating an
/// already-clipped file only makes the speech quieter, which measurably cost 29%
/// of transcribed words on a real recording. The only useful moment to notice is
/// while recording, so the policy has to be right.
struct AudioClippingTests {
    @Test func fullScaleSamplesCountAsClipped() {
        #expect(AudioClipping.isClipped(1.0))
        #expect(AudioClipping.isClipped(-1.0))
        // Just under full scale still counts - float rounding must not hide it.
        #expect(AudioClipping.isClipped(0.9995))
        #expect(!AudioClipping.isClipped(0.9))
        #expect(!AudioClipping.isClipped(0.0))
        #expect(!AudioClipping.isClipped(-0.5))
    }

    /// A handful of clipped samples on a live input is normal and inaudible;
    /// warning about it would train the user to ignore the warning.
    @Test func isolatedClippedSamplesDoNotWarn() {
        #expect(!AudioClipping.isClipping(clipped: 5, total: 48_000))
        #expect(!AudioClipping.isClipping(clipped: 0, total: 48_000))
    }

    /// A sustained rate means the gain is genuinely too high.
    @Test func sustainedClippingWarns() {
        // 0.1% of a minute at 48 kHz, comfortably over the 0.05% threshold.
        #expect(AudioClipping.isClipping(clipped: 2_880, total: 2_880_000))
        // The real meeting that prompted this: 5630 full-scale samples.
        #expect(AudioClipping.isClipping(clipped: 5_630, total: 3_000_000))
    }

    @Test func thresholdBoundaryIsExclusive() {
        // Exactly at the ratio does not warn; just above does.
        let total = 1_000_000
        let atRatio = Int(Double(total) * AudioClipping.warningRatio)
        #expect(!AudioClipping.isClipping(clipped: atRatio, total: total))
        #expect(AudioClipping.isClipping(clipped: atRatio + 1, total: total))
    }

    @Test func handlesEmptyInput() {
        #expect(!AudioClipping.isClipping(clipped: 0, total: 0))
        #expect(AudioClipping.clippedFraction(clipped: 0, total: 0) == 0)
        // Defensive: a nonzero count with no total must not divide by zero.
        #expect(!AudioClipping.isClipping(clipped: 10, total: 0))
    }

    @Test func reportsTheFraction() {
        #expect(abs(AudioClipping.clippedFraction(clipped: 1, total: 4) - 0.25) < 1e-9)
        #expect(abs(AudioClipping.clippedFraction(clipped: 3, total: 3) - 1.0) < 1e-9)
    }
}
