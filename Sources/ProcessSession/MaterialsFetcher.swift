import Foundation
import SharedKit

public enum MaterialsFetchError: Error, LocalizedError, Equatable {
    case noMatchingConnection(String)
    case notLaunchable(String)
    case fetchFailed(url: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .noMatchingConnection(url):
            return "No connection matches the material link \(url). Add one under Settings > Automations."
        case let .notLaunchable(url):
            return "The connection for \(url) has no MCP launch configuration on this machine."
        case let .fetchFailed(url, reason):
            return "Fetching material \(url) failed: \(reason)"
        }
    }
}

/// Fetches a session's material links (ADR-13, generalized F5) into
/// `materials/<n>.md` before summarize, via a read-only `claude -p` run with
/// the matching connection's MCP server. Deliberately **hard-failing**: a
/// material the user attached but the pipeline cannot deliver fails the
/// summarize stage instead of silently degrading the protocol.
public struct MaterialsFetcher: Sendable {
    let runner: CommandRunning
    let tools: ToolLocator
    let connections: [PlatformConnection]
    let secrets: ConnectionSecrets

    /// Fetching is verbatim copying, not writing - a fast model keeps the
    /// pre-summary latency low (user decision; actions use `summaryModel`).
    static let fetchModel = "sonnet"

    /// The failure sentinel the fetch prompt demands on error, so a tool
    /// failure can never masquerade as document content.
    static let errorSentinel = "PROTOKOLL_FETCH_ERROR:"

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        connections: [PlatformConnection] = [],
        secrets: ConnectionSecrets? = nil
    ) {
        self.runner = runner
        self.tools = tools
        self.connections = connections
        self.secrets = secrets ?? ConnectionSecrets(environment: tools.environment)
    }

    /// Fetches every material link that is missing (or all of them when
    /// `force`), writing `materials/<n>.md` in link order. Throws on the first
    /// failure. A no-op for sessions without material links.
    public func fetchIfNeeded(
        session: Session,
        force: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws {
        let links = session.metadata.materials ?? []
        guard !links.isEmpty else { return }
        try FileManager.default.createDirectory(at: session.materialsDirectory,
                                                withIntermediateDirectories: true)
        for (index, link) in links.enumerated() {
            let destination = session.materialURL(index: index)
            if !force, FileManager.default.fileExists(atPath: destination.path) { continue }
            onProgress?("fetching material \(index + 1)/\(links.count)")
            let content = try fetch(link: link, onProgress: onProgress)
            try write(content, source: link, to: destination)
        }
        AppLog.pipeline.info("materials fetched session=\(session.id, privacy: .public) count=\(links.count, privacy: .public)")
    }

    /// Matches a link to a connection by host (the host of the connection's
    /// base URL). Todoist-style links match their platform host too.
    func connection(for link: String) -> PlatformConnection? {
        guard let host = URL(string: link)?.host?.lowercased() else { return nil }
        return connections.first {
            URL(string: $0.baseURL)?.host?.lowercased() == host
        }
    }

    private func fetch(link: String, onProgress: (@Sendable (String) -> Void)?) throws -> String {
        guard let connection = connection(for: link) else {
            throw MaterialsFetchError.noMatchingConnection(link)
        }
        guard let server = MCPServerTemplate.server(for: connection, entry: secrets.entry(for: connection)) else {
            throw MaterialsFetchError.notLaunchable(link)
        }
        let configURL = try MCPServerTemplate.writeConfig(for: server)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let prompt = """
        Fetch the document at \(link) using the available MCP tools and output its complete \
        markdown content verbatim. No commentary, no code fences, nothing but the document. \
        If you cannot fetch it, output exactly one line: \(Self.errorSentinel) <short reason>
        """
        let result: CommandResult
        do {
            result = try runner.run(
                executable: tools.claudeBinary,
                arguments: [
                    "-p", prompt,
                    "--model", Self.fetchModel,
                    "--mcp-config", configURL.path,
                    "--strict-mcp-config",
                    "--allowedTools", server.readTools.joined(separator: ","),
                    "--disallowedTools", MCPServerTemplate.deniedTools.joined(separator: ","),
                ],
                stdin: nil,
                environment: nil,
                workingDirectory: nil,
                onStderrLine: onProgress
            )
        } catch {
            throw MaterialsFetchError.fetchFailed(url: link, reason: AppLog.describe(error))
        }
        guard result.succeeded else {
            let reason = result.stderr.isEmpty ? result.stdout : result.stderr
            throw MaterialsFetchError.fetchFailed(url: link, reason: reason)
        }
        let cleaned = (try? SummaryAPI.clean(result.stdout))
            ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            throw MaterialsFetchError.fetchFailed(url: link, reason: "empty output")
        }
        if cleaned.hasPrefix(Self.errorSentinel) {
            let reason = cleaned.dropFirst(Self.errorSentinel.count).trimmingCharacters(in: .whitespaces)
            throw MaterialsFetchError.fetchFailed(url: link, reason: reason)
        }
        return cleaned
    }

    private func write(_ content: String, source: String, to destination: URL) throws {
        let formatter = ISO8601DateFormatter()
        let document = """
        ---
        kind: material
        source: \(source)
        fetched: \(formatter.string(from: Date()))
        ---

        \(content)
        """
        try Data(document.utf8).write(to: destination, options: .atomic)
    }

    /// The material bodies available on disk for a session, in stable order:
    /// a manually placed `agenda.md` first (N3 drop-in), then `materials/<n>.md`
    /// in link order. Frontmatter is stripped; blank files are skipped.
    public static func loadLocalMaterials(for session: Session) -> [String] {
        var documents: [String] = []
        if let agenda = try? String(contentsOf: session.agendaURL, encoding: .utf8) {
            documents.append(agenda)
        }
        let count = session.metadata.materials?.count ?? 0
        for index in 0..<count {
            if let text = try? String(contentsOf: session.materialURL(index: index), encoding: .utf8) {
                documents.append(text)
            }
        }
        return documents
            .map { Frontmatter.split($0).body.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
