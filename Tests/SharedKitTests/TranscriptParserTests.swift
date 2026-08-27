import Foundation
import Testing
@testable import SharedKit

@Suite struct TranscriptParserTests {
    // MARK: Markdown (pipeline transcript.md body)

    @Test func parsesPipelineMarkdownSegments() {
        let body = """
        # Transcript

        **[00:00:00]** Hello everyone.

        **[00:00:05]** Let's get started with the agenda.

        **[00:01:12]** First item is the budget.
        """
        let segments = TranscriptParser.parseMarkdown(body)
        #expect(segments.count == 3)
        #expect(segments[0] == TranscriptSegment(start: 0, text: "Hello everyone."))
        #expect(segments[1] == TranscriptSegment(start: 5, text: "Let's get started with the agenda."))
        #expect(segments[2] == TranscriptSegment(start: 72, text: "First item is the budget."))
    }

    @Test func mergesMultiLineSegmentText() {
        let body = """
        **[00:00:03]** First line
        continues here.
        **[00:00:09]** Next segment.
        """
        let segments = TranscriptParser.parseMarkdown(body)
        #expect(segments.count == 2)
        #expect(segments[0].start == 3)
        #expect(segments[0].text == "First line\ncontinues here.")
        #expect(segments[1].text == "Next segment.")
    }

    @Test func acceptsUnboldedAndShortTimestamps() {
        let body = """
        [01:30] Two-part timestamp.
        [00:02:00] Three-part timestamp.
        """
        let segments = TranscriptParser.parseMarkdown(body)
        #expect(segments.count == 2)
        #expect(segments[0].start == 90)
        #expect(segments[1].start == 120)
    }

    // MARK: SRT

    @Test func parsesSRTBlocks() {
        let srt = """
        1
        00:00:00,000 --> 00:00:04,500
        Hello everyone.

        2
        00:00:04,500 --> 00:00:09,000
        Second line here.
        """
        let segments = TranscriptParser.parseSRT(srt)
        #expect(segments.count == 2)
        #expect(segments[0].start == 0)
        #expect(segments[0].text == "Hello everyone.")
        #expect(segments[1].start == 4.5)
        #expect(segments[1].text == "Second line here.")
    }

    @Test func srtMergesMultiLineCues() {
        let srt = """
        1
        00:00:10,000 --> 00:00:12,000
        Line one
        line two
        """
        let segments = TranscriptParser.parseSRT(srt)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Line one\nline two")
    }

    @Test func autoDetectPrefersSRTWhenArrowsPresent() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Detected.
        """
        let segments = TranscriptParser.parse(srt)
        #expect(segments.count == 1)
        #expect(segments[0].start == 1)
    }

    // MARK: Timestamp parsing

    @Test func parseTimestampVariants() {
        #expect(TranscriptParser.parseTimestamp("00:00:00") == 0)
        #expect(TranscriptParser.parseTimestamp("01:02:03") == 3723)
        #expect(TranscriptParser.parseTimestamp("02:00") == 120)
        #expect(TranscriptParser.parseTimestamp("00:00:04,500") == 4.5)
        #expect(TranscriptParser.parseTimestamp("00:00:04.250") == 4.25)
        #expect(TranscriptParser.parseTimestamp("45") == 45)
    }

    // MARK: Malformed-input tolerance

    @Test func emptyInputYieldsNoSegments() {
        #expect(TranscriptParser.parse("") == [])
        #expect(TranscriptParser.parse("   \n  \n").isEmpty)
    }

    @Test func plainTextWithoutTimestampsYieldsNoSegments() {
        let plain = "Just some prose with no timestamps at all.\nAnother line."
        #expect(TranscriptParser.parseMarkdown(plain).isEmpty)
        #expect(TranscriptParser.parse(plain).isEmpty)
    }

    @Test func skipsUnparseableTimestamps() {
        let body = """
        **[not-a-time]** ignored, no valid start yet.
        **[00:00:05]** kept.
        """
        let segments = TranscriptParser.parseMarkdown(body)
        #expect(segments.count == 1)
        #expect(segments[0].start == 5)
        #expect(segments[0].text == "kept.")
    }

    @Test func toleratesEmptySegmentText() {
        let body = """
        **[00:00:05]**
        **[00:00:09]** Has text.
        """
        let segments = TranscriptParser.parseMarkdown(body)
        // The empty segment is dropped; the populated one survives.
        #expect(segments.count == 1)
        #expect(segments[0].start == 9)
    }

    @Test func malformedSRTTimeIsSkipped() {
        let srt = """
        1
        garbage --> also-garbage
        Should be skipped.

        2
        00:00:03,000 --> 00:00:05,000
        Kept.
        """
        let segments = TranscriptParser.parseSRT(srt)
        #expect(segments.count == 1)
        #expect(segments[0].start == 3)
        #expect(segments[0].text == "Kept.")
    }
}

/// The transcript highlight index. This is the one place in the UI performance
/// work where a fix could be silently *wrong* rather than merely slow, so it is
/// checked against the linear definition it replaced.
@Suite struct TranscriptHighlightIndexTests {
    /// The original implementation, kept as the oracle.
    private func linearIndex(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        var found: Int?
        for (index, segment) in segments.enumerated() {
            if segment.start <= time + 0.05 { found = index } else { break }
        }
        return found
    }

    private let segments = [0.0, 2.5, 7.0, 7.25, 19.0, 60.0, 3600.0]
        .map { TranscriptSegment(start: $0, text: "s\($0)") }

    @Test func matchesTheLinearDefinitionAcrossTheTimeline() {
        // Includes exact starts, just-before, just-after, gaps and beyond-the-end.
        var probes: [TimeInterval] = [-5, -0.04, 0, 0.01, 2.45, 2.5, 6.9, 7, 7.2,
                                      7.25, 18, 19, 59, 60, 3599, 3600, 9999]
        probes += stride(from: 0.0, through: 65.0, by: 0.25)
        for probe in probes {
            #expect(TranscriptSegment.index(at: probe, in: segments) == linearIndex(at: probe, in: segments),
                    "mismatch at t=\(probe)")
        }
    }

    @Test func isNilBeforeTheFirstSegment() {
        #expect(TranscriptSegment.index(at: -1, in: segments) == nil)
        // ...but the tolerance means a hair before 0 still counts as segment 0.
        #expect(TranscriptSegment.index(at: -0.01, in: segments) == 0)
    }

    /// A silent gap must hold the previous segment, not flicker to nil.
    @Test func holdsThePreviousSegmentDuringAGap() {
        #expect(TranscriptSegment.index(at: 30, in: segments) == 4)   // between 19 and 60
        #expect(TranscriptSegment.index(at: 100, in: segments) == 5)  // between 60 and 3600
    }

    @Test func clampsPastTheEnd() {
        #expect(TranscriptSegment.index(at: 100_000, in: segments) == segments.count - 1)
    }

    @Test func handlesEmptyAndSingleSegment() {
        #expect(TranscriptSegment.index(at: 5, in: []) == nil)
        let one = [TranscriptSegment(start: 10, text: "only")]
        #expect(TranscriptSegment.index(at: 5, in: one) == nil)
        #expect(TranscriptSegment.index(at: 10, in: one) == 0)
        #expect(TranscriptSegment.index(at: 500, in: one) == 0)
    }

    /// Adjacent segments sharing a start time must resolve to the last of them,
    /// matching the linear scan.
    @Test func duplicateStartsResolveToTheLast() {
        let dupes = [0.0, 5.0, 5.0, 5.0, 9.0].map { TranscriptSegment(start: $0, text: "x") }
        #expect(TranscriptSegment.index(at: 5, in: dupes) == linearIndex(at: 5, in: dupes))
        #expect(TranscriptSegment.index(at: 5, in: dupes) == 3)
    }
}
