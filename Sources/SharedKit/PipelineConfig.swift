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
    public var transcriptionModel: String
    /// Summary language: `"auto"` (match the meeting, N8) or an ISO code.
    public var summaryLanguage: String
    /// Summary model alias passed to `claude --model` (`opus`/`sonnet`/`haiku`).
    /// Used only by the `cli` provider.
    public var summaryModel: String
    /// Extra instructions appended to the built-in summary prompt.
    public var summaryInstructions: String
    /// Which engine summarizes: `"cli"` (local `claude`, default), `"anthropic"`
    /// (Anthropic Messages API), or `"openai"` (OpenAI-compatible endpoint).
    public var summaryProvider: String
    /// Full model id for the API providers (freeform, e.g.
    /// `claude-sonnet-4-...` or `gpt-4o`). The `cli` provider uses
    /// ``summaryModel`` instead. No effect when empty.
    public var summaryApiModel: String
    /// Base URL for the API providers. Required for `openai` (e.g.
    /// `https://api.openai.com/v1`); optional override for `anthropic`
    /// (defaults to `https://api.anthropic.com`). Must be `https://`.
    public var summaryApiBaseURL: String
    /// `max_tokens` for the API request (Anthropic requires it).
    public var summaryMaxTokens: Int

    public init(
        transcriptionLanguage: String = "auto",
        vocabulary: String = "",
        transcriptionModel: String = "large-v3",
        summaryLanguage: String = "auto",
        summaryModel: String = "opus",
        summaryInstructions: String = "",
        summaryProvider: String = "cli",
        summaryApiModel: String = "",
        summaryApiBaseURL: String = "",
        summaryMaxTokens: Int = 8192
    ) {
        self.transcriptionLanguage = transcriptionLanguage
        self.vocabulary = vocabulary
        self.transcriptionModel = transcriptionModel
        self.summaryLanguage = summaryLanguage
        self.summaryModel = summaryModel
        self.summaryInstructions = summaryInstructions
        self.summaryProvider = summaryProvider
        self.summaryApiModel = summaryApiModel
        self.summaryApiBaseURL = summaryApiBaseURL
        self.summaryMaxTokens = summaryMaxTokens
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
        summaryLanguage = value(.summaryLanguage, d.summaryLanguage)
        summaryModel = value(.summaryModel, d.summaryModel)
        summaryInstructions = value(.summaryInstructions, d.summaryInstructions)
        summaryProvider = value(.summaryProvider, d.summaryProvider)
        summaryApiModel = value(.summaryApiModel, d.summaryApiModel)
        summaryApiBaseURL = value(.summaryApiBaseURL, d.summaryApiBaseURL)
        summaryMaxTokens = ((try? container.decodeIfPresent(Int.self, forKey: .summaryMaxTokens)) ?? nil)
            ?? d.summaryMaxTokens
    }
}
