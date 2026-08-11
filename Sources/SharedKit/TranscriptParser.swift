import Foundation

/// One timestamped chunk of a transcript: a start offset (seconds from the
/// beginning of the recording) and its spoken text. `end` is unused by the UI
/// today, so only the start is modelled - the next segment's start bounds it.
public struct TranscriptSegment: Sendable, Equatable {
    /// Seconds from the start of the recording.
    public let start: TimeInterval
    /// The spoken text for this segment, trimmed.
    public let text: String

    public init(start: TimeInterval, text: String) {
        self.start = start
        self.text = text
    }
}

/// Parses transcripts into timestamped ``TranscriptSegment``s so the UI can
/// render a clean time+text list and seek the audio player on tap.
///
/// Two input shapes are understood, both produced by `transcribe.sh`/the
/// pipeline:
/// - the pipeline's `transcript.md` body, `**[HH:MM:SS]** text` per segment;
/// - raw SubRip (`.srt`), `HH:MM:SS,mmm --> HH:MM:SS,mmm` blocks.
///
/// Pure Foundation, no regex engine - line scanning keeps it predictable and
/// tolerant of malformed input (unparseable lines are skipped, never fatal).
public enum TranscriptParser {
    /// Auto-detects the format and returns its segments. Returns `[]` when no
    /// timestamped structure is found (the caller then falls back to plain text).
    public static func parse(_ text: String) -> [TranscriptSegment] {
        if text.contains("-->") {
            let srt = parseSRT(text)
            if !srt.isEmpty { return srt }
        }
        return parseMarkdown(text)
    }

    /// Parses the pipeline's `transcript.md` body: each segment is introduced by
    /// a `[HH:MM:SS]` marker (optionally wrapped in `**bold**`), and its text
    /// runs until the next marker. Handles `MM:SS` and fractional seconds too.
    public static func parseMarkdown(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var pendingStart: TimeInterval?
        var pendingText = ""

        func flush() {
            guard let start = pendingStart else { return }
            let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TranscriptSegment(start: start, text: trimmed))
            }
            pendingText = ""
        }

        for rawLine in text.components(separatedBy: "\n") {
            if let (start, remainder) = leadingTimestamp(in: rawLine) {
                flush()
                pendingStart = start
                pendingText = remainder
            } else if pendingStart != nil {
                pendingText += pendingText.isEmpty ? rawLine : "\n" + rawLine
            }
        }
        flush()
        return segments
    }

    /// Parses SubRip (`.srt`): numbered blocks of a `start --> end` line
    /// followed by one or more text lines, separated by blank lines.
    public static func parseSRT(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentStart: TimeInterval?
        var currentText: [String] = []

        func flush() {
            guard let start = currentStart else { return }
            let joined = currentText.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                segments.append(TranscriptSegment(start: start, text: joined))
            }
            currentStart = nil
            currentText = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let arrow = line.range(of: "-->") {
                flush()
                let startPart = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                currentStart = parseTimestamp(startPart)
            } else if currentStart != nil {
                if line.isEmpty {
                    flush()
                } else {
                    currentText.append(rawLine.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        flush()
        return segments
    }

    // MARK: - Timestamp scanning

    /// If `line` begins with a `[timestamp]` marker (optionally `**`-wrapped),
    /// returns the parsed start time and the trailing text on that line.
    static func leadingTimestamp(in line: String) -> (start: TimeInterval, remainder: String)? {
        var scan = Substring(line)
        // Skip leading whitespace and an optional bold marker.
        scan = scan.drop { $0 == " " || $0 == "\t" }
        if scan.hasPrefix("**") { scan = scan.dropFirst(2) }
        scan = scan.drop { $0 == " " }
        guard scan.first == "[", let close = scan.firstIndex(of: "]") else { return nil }
        let inner = scan[scan.index(after: scan.startIndex)..<close]
        guard let start = parseTimestamp(String(inner)) else { return nil }

        var remainder = scan[scan.index(after: close)...]
        // Drop a closing bold marker and separating whitespace.
        remainder = remainder.drop { $0 == " " }
        if remainder.hasPrefix("**") { remainder = remainder.dropFirst(2) }
        remainder = remainder.drop { $0 == " " }
        return (start, String(remainder))
    }

    /// Parses `HH:MM:SS`, `MM:SS`, or `SS` with optional `.` / `,` fractional
    /// seconds into a `TimeInterval`. Returns `nil` on anything unparseable.
    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var total: TimeInterval = 0
        for part in parts {
            // Seconds may carry a fractional component; SRT uses a comma.
            let normalized = part.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
