import Foundation

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
}

/// Splits a transcript into chunks that fit a token budget, preferring to break
/// at speech pauses (blank lines / segment gaps).
///
/// M1 seam: a single-chunk pass-through so short meetings work end-to-end and
/// the summarizer has a stable interface. M2 fills in real budget-aware
/// splitting at speech pauses.
public struct TranscriptChunker: Sendable {
    /// Approximate character budget per chunk (~4 chars/token heuristic).
    public var characterBudget: Int

    public init(characterBudget: Int = 48_000) {
        self.characterBudget = characterBudget
    }

    public func chunk(_ transcript: String) -> [TranscriptChunk] {
        if transcript.count <= characterBudget {
            return [TranscriptChunk(index: 0, text: transcript)]
        }
        // M1 behavior: single chunk. When it exceeds the budget the summarizer
        // still runs single-shot (decision #5: M1 is single-shot; long
        // transcripts get real map-reduce in M2). This method is the seam.
        return [TranscriptChunk(index: 0, text: transcript)]
    }
}
