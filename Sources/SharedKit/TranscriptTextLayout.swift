import Foundation

/// A transcript flattened into one string, plus the character range each segment
/// occupies in it.
///
/// The UI renders transcripts into a single text view so a selection can span
/// segments (a stack of per-segment `Text` views can never be selected across).
/// That turns two interactions into arithmetic: a click has to map back to the
/// segment it landed in, and the playhead highlight has to be painted over the
/// right range. Both are exactly the kind of off-by-one that looks fine and
/// seeks to the wrong place, so the mapping lives here where `swift test` can
/// reach it rather than in the view.
///
/// Ranges are `NSRange`, i.e. **UTF-16 offsets**, because that is what
/// `NSAttributedString` and the text views use. Counting `Character`s would
/// drift on any transcript containing an umlaut or an emoji.
public struct TranscriptTextLayout: Sendable, Equatable {
    /// One rendered transcript line: `0:07\tSpoken text\n`.
    public struct Row: Sendable, Equatable {
        /// Index of the segment this row came from.
        public let segment: Int
        /// Seek target, seconds from the start of the recording.
        public let start: TimeInterval
        /// The `0:07` label.
        public let timeRange: NSRange
        /// The spoken text, excluding the label and the separating tab.
        public let textRange: NSRange
        /// Label through the trailing newline. Used for hit-testing and for the
        /// highlight, so a click in the empty space after a short line still
        /// lands on that segment and the highlight reaches the trailing edge.
        public let lineRange: NSRange
    }

    /// The whole transcript as displayed.
    public let text: String
    /// One row per segment, in document order, with non-overlapping ranges.
    public let rows: [Row]

    public static let empty = TranscriptTextLayout(text: "", rows: [])

    public init(text: String, rows: [Row]) {
        self.text = text
        self.rows = rows
    }

    /// Flattens `segments` into `label<tab>text<newline>` lines.
    public init(segments: [TranscriptSegment]) {
        var text = ""
        var rows: [Row] = []
        rows.reserveCapacity(segments.count)
        // UTF-16 length of everything appended so far.
        var location = 0

        for (index, segment) in segments.enumerated() {
            let label = TranscriptSegment.timeLabel(for: segment.start)
            let labelLength = (label as NSString).length
            let textLength = (segment.text as NSString).length
            // label + tab + text + newline
            let lineLength = labelLength + 1 + textLength + 1

            rows.append(
                Row(
                    segment: index,
                    start: segment.start,
                    timeRange: NSRange(location: location, length: labelLength),
                    textRange: NSRange(location: location + labelLength + 1, length: textLength),
                    lineRange: NSRange(location: location, length: lineLength)
                )
            )
            text += "\(label)\t\(segment.text)\n"
            location += lineLength
        }

        self.text = text
        self.rows = rows
    }

    /// The row containing `characterIndex`, or `nil` when the index falls outside
    /// the transcript. Binary search: a click is cheap, but so is getting this
    /// wrong on a 1,500-row document.
    public func row(at characterIndex: Int) -> Row? {
        var low = 0
        var high = rows.count - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let range = rows[mid].lineRange
            if characterIndex < range.location {
                high = mid - 1
            } else if characterIndex >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return rows[mid]
            }
        }
        return nil
    }
}

extension TranscriptSegment {
    /// `m:ss`, or `h:mm:ss` once the recording passes an hour.
    public static func timeLabel(for start: TimeInterval) -> String {
        let total = Int(start.rounded())
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
