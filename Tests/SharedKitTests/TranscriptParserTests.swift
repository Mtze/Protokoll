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
