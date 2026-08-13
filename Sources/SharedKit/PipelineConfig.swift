import Foundation

/// User-tunable settings that affect the processing pipeline. Stored in the
/// container (`config/pipeline.json`) so the app writes it from Settings and
/// `process-session` reads it at run time - including standalone runs - with no
/// env plumbing. Decoding is tolerant: any missing key falls back to its
/// default, so older/partial files keep working.
public struct PipelineConfig: Codable, Sendable, Equatable {
    /// Transcription language: `"auto"` (detect) or an ISO code like `"de"`/`"en"`.
    public var transcriptionLanguage: String
    /// Domain vocabulary seeded to whisper (`transcribe.sh --prompt`) - product
    /// names, acronyms, hostnames. The single biggest transcript-quality lever.
    public var vocabulary: String
    /// Whisper model: `"large-v3"` (quality) or `"large-v3-turbo"` (faster).
    ///
    /// Keep `large-v3`: turbo cuts the decoder from 32 layers to 4 and costs
    /// roughly 11% relative WER on German, which matters most on exactly the
    /// noisy, accented, code-switching audio meetings produce.
    public var transcriptionModel: String
    /// Audio preparation before transcription: `"safe"` (high-pass at 80 Hz plus a
    /// measured static gain) or `"off"` (straight 16 kHz conversion).
    ///
    /// Deliberately not a denoiser setting. Spectral denoising is measured to
    /// *raise* WER for large Whisper models, so there is nothing safe to offer.
    public var audioPreprocessing: String
    /// Summary language: `"auto"` (match the meeting, N8) or an ISO code.
    public var summaryLanguage: String
    /// Summary model alias passed to `claude --model` (`opus`/`sonnet`/`haiku`).
    public var summaryModel: String
    /// Extra instructions appended to the built-in summary prompt.
    public var summaryInstructions: String

    public init(
        transcriptionLanguage: String = "auto",
        vocabulary: String = "",
        transcriptionModel: String = "large-v3",
        audioPreprocessing: String = "safe",
        summaryLanguage: String = "auto",
        summaryModel: String = "opus",
        summaryInstructions: String = ""
    ) {
        self.transcriptionLanguage = transcriptionLanguage
        self.vocabulary = vocabulary
        self.transcriptionModel = transcriptionModel
        self.audioPreprocessing = audioPreprocessing
        self.summaryLanguage = summaryLanguage
        self.summaryModel = summaryModel
        self.summaryInstructions = summaryInstructions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = PipelineConfig()
        func value(_ key: CodingKeys, _ fallback: String) -> String {
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil ?? fallback
        }
        transcriptionLanguage = value(.transcriptionLanguage, d.transcriptionLanguage)
        vocabulary = value(.vocabulary, d.vocabulary)
        transcriptionModel = value(.transcriptionModel, d.transcriptionModel)
        audioPreprocessing = value(.audioPreprocessing, d.audioPreprocessing)
        summaryLanguage = value(.summaryLanguage, d.summaryLanguage)
        summaryModel = value(.summaryModel, d.summaryModel)
        summaryInstructions = value(.summaryInstructions, d.summaryInstructions)
    }
}
