import Foundation
import Testing
@testable import SharedKit

@Suite("Transcript text layout")
struct TranscriptTextLayoutTests {
    private func segments(_ pairs: [(TimeInterval, String)]) -> [TranscriptSegment] {
        pairs.map { TranscriptSegment(start: $0.0, text: $0.1) }
    }

    @Test("Every range addresses exactly the text it claims")
    func rangesAddressTheirText() {
        let layout = TranscriptTextLayout(
            segments: segments([(0, "Guten Morgen"), (7.4, "Wir starten"), (3675, "Ende")])
        )
        let text = layout.text as NSString

        #expect(layout.rows.count == 3)
        #expect(text.substring(with: layout.rows[0].timeRange) == "0:00")
        #expect(text.substring(with: layout.rows[0].textRange) == "Guten Morgen")
        #expect(text.substring(with: layout.rows[1].timeRange) == "0:07")
        #expect(text.substring(with: layout.rows[1].textRange) == "Wir starten")
        // Past an hour the label grows a component; the ranges must follow it.
        #expect(text.substring(with: layout.rows[2].timeRange) == "1:01:15")
        #expect(text.substring(with: layout.rows[2].textRange) == "Ende")
        #expect(text.substring(with: layout.rows[0].lineRange) == "0:00\tGuten Morgen\n")
    }

    /// The reason ranges are UTF-16: umlauts and emoji make `Character` counts
    /// and `NSString` offsets disagree, and the text views speak UTF-16.
    @Test("Ranges stay correct across non-ASCII text")
    func rangesSurviveNonASCII() {
        let layout = TranscriptTextLayout(
            segments: segments([(0, "Zunächst die Grüße 👋🏽"), (5, "Straßenbahn"), (9, "danach")])
        )
        let text = layout.text as NSString

        for row in layout.rows {
            #expect(text.substring(with: row.lineRange).hasSuffix("\n"))
        }
        #expect(text.substring(with: layout.rows[0].textRange) == "Zunächst die Grüße 👋🏽")
        #expect(text.substring(with: layout.rows[1].textRange) == "Straßenbahn")
        #expect(text.substring(with: layout.rows[2].textRange) == "danach")
        #expect(NSMaxRange(layout.rows[2].lineRange) == text.length)
    }

    @Test("Line ranges tile the document without gaps or overlap")
    func lineRangesTile() {
        let layout = TranscriptTextLayout(
            segments: segments((0..<50).map { (Double($0) * 3, "Segment \($0)") })
        )

        var expected = 0
        for row in layout.rows {
            #expect(row.lineRange.location == expected)
            #expect(NSRange(location: row.timeRange.location, length: 0).location == row.lineRange.location)
            #expect(NSMaxRange(row.textRange) + 1 == NSMaxRange(row.lineRange))
            expected = NSMaxRange(row.lineRange)
        }
        #expect(expected == (layout.text as NSString).length)
    }

    @Test("Hit-testing finds the row a character index falls in")
    func hitTestingFindsTheRow() {
        let layout = TranscriptTextLayout(
            segments: segments([(0, "erste"), (4, "zweite"), (8, "dritte")])
        )

        // First character, last character and the newline of each row all belong
        // to that row - a click past the end of a short line must still seek it.
        for row in layout.rows {
            #expect(layout.row(at: row.lineRange.location)?.segment == row.segment)
            #expect(layout.row(at: NSMaxRange(row.lineRange) - 1)?.segment == row.segment)
            #expect(layout.row(at: row.textRange.location)?.segment == row.segment)
        }
        #expect(layout.row(at: 4)?.start == 0)
        #expect(layout.row(at: -1) == nil)
        #expect(layout.row(at: (layout.text as NSString).length) == nil)
    }

    @Test("Hit-testing agrees with a linear scan")
    func hitTestingMatchesLinearScan() {
        let layout = TranscriptTextLayout(
            segments: segments((0..<120).map { (Double($0) * 2.5, "Zeile \($0) mit etwas Text") })
        )
        let length = (layout.text as NSString).length

        for index in stride(from: -2, through: length + 2, by: 3) {
            let linear = layout.rows.first { NSLocationInRange(index, $0.lineRange) }
            #expect(layout.row(at: index)?.segment == linear?.segment)
        }
    }

    @Test("An empty transcript produces no text and no rows")
    func emptyTranscript() {
        let layout = TranscriptTextLayout(segments: [])
        #expect(layout.text.isEmpty)
        #expect(layout.rows.isEmpty)
        #expect(layout.row(at: 0) == nil)
    }

    @Test("Time labels grow a component only past an hour")
    func timeLabels() {
        #expect(TranscriptSegment.timeLabel(for: 0) == "0:00")
        #expect(TranscriptSegment.timeLabel(for: 7.4) == "0:07")
        #expect(TranscriptSegment.timeLabel(for: 59.6) == "1:00")
        #expect(TranscriptSegment.timeLabel(for: 3599) == "59:59")
        #expect(TranscriptSegment.timeLabel(for: 3600) == "1:00:00")
        #expect(TranscriptSegment.timeLabel(for: 3675) == "1:01:15")
    }
}
