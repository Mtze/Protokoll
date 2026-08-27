import Foundation
import SharedKit

/// A contiguous slice of a transcript, used by the map-reduce summarization of
/// long meetings (N9). Chunk boundaries double as the checkpoints for a future
/// pause/resume (NH3).
public struct TranscriptChunk: Sendable, Equatable {
    public var index: Int
    public var text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }

    /// The wall-clock span this chunk covers, as `HH:MM:SS-HH:MM:SS`, derived from
    /// its first and last `[HH:MM:SS]` markers. `nil` when the chunk has none.
    ///
    /// Labelling partials with a real time range gives the reduce step absolute
    /// time to order by. Loss of chronology is a documented failure mode of
    /// map-reduce minuting, and a bare "Part 3" gives the reducer nothing to
    /// anchor on.
    public var timeRange: String? {
        var first: TimeInterval?
        var last: TimeInterval?
        for line in text.components(separatedBy: "\n") {
            guard let (start, _) = TranscriptParser.leadingTimestamp(in: line) else { continue }
            if first == nil { first = start }
            last = start
        }
        guard let first, let last else { return nil }
        return "\(Self.clock(first))-\(Self.clock(last))"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Splits a transcript into chunks that fit a token budget, preferring to break
/// at speech pauses (blank lines / segment gaps).
///
/// M1 seam: a single-chunk pass-through so short meetings work end-to-end and
/// the summarizer has a stable interface. M2 fills in real budget-aware
/// splitting at speech pauses.
public struct TranscriptChunker: Sendable {
    /// Approximate character budget per chunk (~4 chars/token heuristic).
    ///
    /// Raised from 48k, where map-reduce triggered at roughly 45 minutes of
    /// meeting - the *median* case, so the lossy path was the common path. This
    /// transcript format runs ~1,100 chars/minute, so 200k covers about three
    /// hours and keeps single-shot (which preserves chronology and rationale by
    /// construction) as the normal route. Not raised further on purpose: context
    /// rot is real, and Anthropic's own guidance is that meta-summarization can
    /// catch details a single pass misses. Worth revisiting with a measured
    /// end-to-end run on a long recording.
    public var characterBudget: Int

    public init(characterBudget: Int = 200_000) {
        self.characterBudget = characterBudget
    }

    public func chunk(_ transcript: String) -> [TranscriptChunk] {
        if transcript.count <= characterBudget {
            return [TranscriptChunk(index: 0, text: transcript)]
        }
        // Break at speech pauses: paragraphs (blank-line-separated segments in
        // our transcript format) are natural pause boundaries. Greedily fill
        // each chunk up to the budget without splitting a paragraph.
        let paragraphs = transcript.components(separatedBy: "\n\n")
        var chunks: [TranscriptChunk] = []
        var current = ""
        for paragraph in paragraphs {
            let addition = current.isEmpty ? paragraph : "\n\n" + paragraph
            if !current.isEmpty, current.count + addition.count > characterBudget {
                chunks.append(TranscriptChunk(index: chunks.count, text: current))
                current = paragraph
            } else {
                current += addition
            }
            // A single paragraph larger than the budget becomes its own chunk.
            if current.count >= characterBudget {
                chunks.append(TranscriptChunk(index: chunks.count, text: current))
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(TranscriptChunk(index: chunks.count, text: current))
        }
        return chunks.isEmpty ? [TranscriptChunk(index: 0, text: transcript)] : chunks
    }
}
