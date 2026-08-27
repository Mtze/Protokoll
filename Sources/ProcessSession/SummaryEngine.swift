import Foundation
import SharedKit

/// A pluggable summarization engine (ADR-9). One system prompt plus the
/// transcript ("stdin") in, protocol text out. The three implementations wrap
/// the local `claude` CLI, the Anthropic Messages API, and an OpenAI-compatible
/// endpoint. `Summarizer` owns map-reduce, frontmatter, and the file write;
/// engines only turn a prompt + input into text.
protocol SummaryEngine: Sendable {
    func complete(
        prompt: String,
        input: String,
        model: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String
}

// MARK: - HTTP seam

/// The network boundary, behind a protocol so the API engines can be unit-tested
/// with a fake instead of really hitting the provider (mirrors `CommandRunning`).
public protocol HTTPPosting: Sendable {
    /// POSTs `body` to `url` with `headers`, returning the response body and HTTP
    /// status code.
    func post(url: URL, headers: [String: String], body: Data) throws -> (data: Data, status: Int)
}

/// Real `URLSession`-backed poster. The request is **synchronous** on purpose:
/// the whole `ProcessSession` pipeline is synchronous, blocking CLI code with no
/// actor/cooperative-pool context (ADR-9), so a semaphore wait is safe here.
public struct URLSessionHTTPPoster: HTTPPosting {
    public init() {}

    public func post(url: URL, headers: [String: String], body: Data) throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                box.result = .success((data ?? Data(), status))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        switch box.result {
        case let .success(pair): return pair
        case let .failure(error): throw error
        case .none: throw SummarizationError.emptyOutput
        }
    }

    /// Carries the async callback's result back across the semaphore.
    private final class ResultBox: @unchecked Sendable {
        var result: Result<(Data, Int), Error>?
    }
}

// MARK: - CLI engine

/// The default: shells out to `claude -p` in print mode (N1, no API key).
struct ClaudeCLIEngine: SummaryEngine {
    let runner: CommandRunning
    let claudeBinary: String

    func complete(
        prompt: String,
        input: String,
        model: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        AppLog.pipeline.debug("running claude model=\(model, privacy: .public)")
        let result = try runner.run(
            executable: claudeBinary,
            arguments: [
                // The contract goes in the system prompt, not in `-p`: `-p` comes
                // first on the command line, which puts it before the transcript
                // and is the wrong end for long context. Without this the run also
                // inherited Claude Code's coding-agent persona unopposed.
                "-p", SummarizePrompt.pointerPrompt,
                "--model", model,
                "--append-system-prompt", prompt,
                // "no tools (decision #5)" was only ever a comment; make it true.
                "--permission-mode", "plan",
                "--disallowed-tools", "Bash,Edit,Write,Read,WebFetch,WebSearch",
            ],
            stdin: input,
            environment: nil,
            onStderrLine: onProgress
        )
        guard result.succeeded else {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            AppLog.pipeline.error("claude exited \(result.exitCode, privacy: .public): \(stderr, privacy: .public)")
            throw SummarizationError.providerFailed(stderr)
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw SummarizationError.emptyOutput }
        return output
    }
}

// MARK: - API engines

/// Anthropic Messages API (`POST {baseURL}/v1/messages`).
struct AnthropicEngine: SummaryEngine {
    let http: HTTPPosting
    let apiKey: String
    let baseURL: String
    let maxTokens: Int

    static let defaultBaseURL = "https://api.anthropic.com"

    func complete(
        prompt: String,
        input: String,
        model: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        onProgress?("calling Anthropic API")
        let url = try SummaryAPI.endpoint(base: baseURL.isEmpty ? Self.defaultBaseURL : baseURL,
                                          path: "/v1/messages")
        AppLog.pipeline.debug("anthropic request model=\(model, privacy: .public)")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": prompt,
            "messages": [["role": "user", "content": input]],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, status) = try http.post(
            url: url,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            ],
            body: body
        )
        try SummaryAPI.checkStatus(status, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String != "thinking" })?["text"] as? String
        else {
            throw SummarizationError.emptyOutput
        }
        return try SummaryAPI.clean(text)
    }
}

/// OpenAI-compatible Chat Completions API (`POST {baseURL}/chat/completions`).
/// `baseURL` includes any version path (e.g. `https://api.openai.com/v1`).
struct OpenAIEngine: SummaryEngine {
    let http: HTTPPosting
    let apiKey: String
    let baseURL: String
    let maxTokens: Int

    func complete(
        prompt: String,
        input: String,
        model: String,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> String {
        onProgress?("calling OpenAI-compatible API")
        let url = try SummaryAPI.endpoint(base: baseURL, path: "/chat/completions")
        AppLog.pipeline.debug("openai request model=\(model, privacy: .public)")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": input],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, status) = try http.post(
            url: url,
            headers: [
                "authorization": "Bearer \(apiKey)",
                "content-type": "application/json",
            ],
            body: body
        )
        try SummaryAPI.checkStatus(status, data: data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else {
            throw SummarizationError.emptyOutput
        }
        return try SummaryAPI.clean(text)
    }
}

// MARK: - Shared API helpers

enum SummaryAPI {
    /// Joins a validated `https://` base with an endpoint path.
    static func endpoint(base: String, path: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("https://") else {
            throw SummarizationError.providerFailed("API base URL must be https:// (got \(trimmed))")
        }
        let joined = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) + path : trimmed + path
        guard let url = URL(string: joined) else {
            throw SummarizationError.providerFailed("invalid API URL: \(joined)")
        }
        return url
    }

    /// Throws a clean, provider-agnostic message on a non-2xx status, preferring
    /// the provider's structured `error.message` over the raw body.
    static func checkStatus(_ status: Int, data: Data) throws {
        guard !(200 ..< 300).contains(status) else { return }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            throw SummarizationError.providerFailed(message)
        }
        throw SummarizationError.providerFailed("HTTP \(status)")
    }

    /// Trims whitespace and strips a single wrapping Markdown code fence, which
    /// some models add around the whole reply and which would otherwise hide the
    /// leading `---` frontmatter block (`title:`/`language:`).
    static func clean(_ text: String) throws -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```") {
            var lines = trimmed.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }        // ```lang opener
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { throw SummarizationError.emptyOutput }
        return trimmed
    }

    /// Resolves the API key for an API provider (ADR-9). Prefers a 0600 key-file
    /// (`SUMMARY_API_KEY_FILE`, app-injected so the secret never sits in the
    /// child env), then `SUMMARY_API_KEY`, then the provider-standard vars for
    /// standalone runs.
    static func resolveKey(environment: [String: String], provider: SummaryProviderKind) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        if let path = nonEmpty(environment["SUMMARY_API_KEY_FILE"]),
           let contents = try? String(contentsOfFile: path, encoding: .utf8),
           let key = nonEmpty(contents) {
            return key
        }
        if let key = nonEmpty(environment["SUMMARY_API_KEY"]) { return key }
        switch provider {
        case .anthropic: return nonEmpty(environment["ANTHROPIC_API_KEY"])
        case .openai: return nonEmpty(environment["OPENAI_API_KEY"])
        case .cli: return nil
        }
    }
}

/// The configured provider, parsed from `PipelineConfig.summaryProvider`.
enum SummaryProviderKind: String, Sendable {
    case cli
    case anthropic
    case openai

    init(_ raw: String) { self = SummaryProviderKind(rawValue: raw) ?? .cli }
}
