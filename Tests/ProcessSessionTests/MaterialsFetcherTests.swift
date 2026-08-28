import Foundation
import Testing
import SharedKit
@testable import ProcessSession

/// Materials fetch (ADR-13, generalized F5): claude+MCP invocation shape,
/// output hardening, hard failure semantics, and local material loading.
struct MaterialsFetcherTests {
    /// Records invocations and captures the mcp-config file's content at call
    /// time (the fetcher deletes it right after the run).
    private final class FakeRunner: CommandRunning, @unchecked Sendable {
        var stdout: String
        var exitCode: Int32 = 0
        private(set) var invocations: [[String]] = []
        private(set) var mcpConfigs: [String] = []

        init(stdout: String) { self.stdout = stdout }

        func run(
            executable: String,
            arguments: [String],
            stdin: String?,
            environment: [String: String]?,
            workingDirectory: URL?,
            onStderrLine: (@Sendable (String) -> Void)?
        ) throws -> CommandResult {
            invocations.append([executable] + arguments)
            if let index = arguments.firstIndex(of: "--mcp-config"), index + 1 < arguments.count,
               let content = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8) {
                mcpConfigs.append(content)
            }
            return CommandResult(exitCode: exitCode, stdout: stdout, stderr: "")
        }
    }

    private func makeSession(materials: [String]) throws -> (Container, Session) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-mat-\(UUID().uuidString)", isDirectory: true)
        let container = Container(locator: LocalFolderContainer(root: root))
        var session = try container.createSession(device: .mac)
        session.metadata.materials = materials
        try container.store.save(session)
        return (container, try container.store.load(folder: session.folder))
    }

    private let outline = PlatformConnection(id: "c1", name: "Team Outline",
                                             kind: PlatformConnection.kindOutline,
                                             baseURL: "https://outline.example.org")

    private func fetcher(_ runner: FakeRunner, connections: [PlatformConnection]? = nil) -> MaterialsFetcher {
        MaterialsFetcher(
            runner: runner,
            tools: ToolLocator(environment: [:]),
            connections: connections ?? [outline],
            secrets: ConnectionSecrets(environment: ["CONNECTION_KEY_C1": "ol-key"])
        )
    }

    @Test func fetchesViaClaudeWithReadOnlyMCP() throws {
        let (_, session) = try makeSession(materials: ["https://outline.example.org/doc/standup-x1"])
        let runner = FakeRunner(stdout: "# Agenda\n\n- Topic A")
        try fetcher(runner).fetchIfNeeded(session: session)

        let argv = try #require(runner.invocations.first)
        #expect(argv.contains("--strict-mcp-config"))
        #expect(argv.contains("sonnet"))
        let allowed = argv[argv.firstIndex(of: "--allowedTools")! + 1]
        #expect(allowed.contains("mcp__outline__get_document"))
        #expect(!allowed.contains("mcp__outline\u{22}"))
        let denied = argv[argv.firstIndex(of: "--disallowedTools")! + 1]
        #expect(denied.contains("Bash"))

        // The mcp-config carried the server with key + API URL, and is gone now.
        let config = try #require(runner.mcpConfigs.first)
        #expect(config.contains("outline-mcp-server"))
        #expect(config.contains("ol-key"))
        #expect(config.contains("https://outline.example.org/api"))
        let path = argv[argv.firstIndex(of: "--mcp-config")! + 1]
        #expect(!FileManager.default.fileExists(atPath: path))

        // The material landed with frontmatter and the fetched body.
        let written = try String(contentsOf: session.materialURL(index: 0), encoding: .utf8)
        #expect(written.contains("source: https://outline.example.org/doc/standup-x1"))
        #expect(written.contains("# Agenda"))
    }

    @Test func skipsExistingUnlessForced() throws {
        let (_, session) = try makeSession(materials: ["https://outline.example.org/doc/a"])
        let runner = FakeRunner(stdout: "content")
        try fetcher(runner).fetchIfNeeded(session: session)
        try fetcher(runner).fetchIfNeeded(session: session)
        #expect(runner.invocations.count == 1)
        try fetcher(runner).fetchIfNeeded(session: session, force: true)
        #expect(runner.invocations.count == 2)
    }

    @Test func editedLinkInvalidatesTheCachedMaterial() throws {
        let (container, session) = try makeSession(materials: ["https://outline.example.org/doc/a"])
        let runner = FakeRunner(stdout: "content A")
        try fetcher(runner).fetchIfNeeded(session: session)
        #expect(runner.invocations.count == 1)

        // Replace the link at the same index: the cached file's source no
        // longer matches, so a non-forced run must refetch.
        var updated = session
        updated.metadata.materials = ["https://outline.example.org/doc/b"]
        try container.store.save(updated)
        let reloaded = try container.store.load(folder: session.folder)
        runner.stdout = "content B"
        try fetcher(runner).fetchIfNeeded(session: reloaded)
        #expect(runner.invocations.count == 2)
        let written = try String(contentsOf: session.materialURL(index: 0), encoding: .utf8)
        #expect(written.contains("source: https://outline.example.org/doc/b"))
        #expect(written.contains("content B"))
    }

    @Test func customConnectionsAreRejectedForFetching() throws {
        let custom = PlatformConnection(id: "c1", name: "Custom", kind: PlatformConnection.kindCustom,
                                        baseURL: "https://wiki.example.org")
        let (_, session) = try makeSession(materials: ["https://wiki.example.org/x"])
        let runner = FakeRunner(stdout: "content")
        // The manifest carries a launch spec, so the server *could* start; the
        // fetch must still fail closed because no read-only tool set exists.
        let manifest = ConnectionKeyManifest(connections: ["c1": .init(key: "k", command: "npx",
                                                                       arguments: ["-y", "srv"],
                                                                       keyEnvVar: "K")])
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-custom-\(UUID().uuidString).json")
        try JSONEncoder().encode(manifest).write(to: file)
        let fetcher = MaterialsFetcher(
            runner: runner, tools: ToolLocator(environment: [:]), connections: [custom],
            secrets: ConnectionSecrets(environment: ["CONNECTION_KEYS_FILE": file.path])
        )
        #expect(throws: MaterialsFetchError.noReadOnlyTools("https://wiki.example.org/x")) {
            try fetcher.fetchIfNeeded(session: session)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func noMatchingConnectionFailsTheStage() throws {
        let (_, session) = try makeSession(materials: ["https://confluence.example.org/x"])
        let runner = FakeRunner(stdout: "content")
        #expect(throws: MaterialsFetchError.noMatchingConnection("https://confluence.example.org/x")) {
            try fetcher(runner).fetchIfNeeded(session: session)
        }
    }

    @Test func errorSentinelAndEmptyOutputFail() throws {
        let (_, session) = try makeSession(materials: ["https://outline.example.org/doc/a"])
        let sentinel = FakeRunner(stdout: "PROTOKOLL_FETCH_ERROR: permission denied")
        #expect(throws: MaterialsFetchError.fetchFailed(url: "https://outline.example.org/doc/a",
                                                        reason: "permission denied")) {
            try fetcher(sentinel).fetchIfNeeded(session: session)
        }
        let empty = FakeRunner(stdout: "   \n")
        #expect(throws: MaterialsFetchError.self) {
            try fetcher(empty).fetchIfNeeded(session: session)
        }
        // Neither attempt may leave a material file behind.
        #expect(!FileManager.default.fileExists(atPath: session.materialURL(index: 0).path))
    }

    @Test func stripsWrappingCodeFence() throws {
        let (_, session) = try makeSession(materials: ["https://outline.example.org/doc/a"])
        let runner = FakeRunner(stdout: "```markdown\n# Doc\n```")
        try fetcher(runner).fetchIfNeeded(session: session)
        let written = try String(contentsOf: session.materialURL(index: 0), encoding: .utf8)
        #expect(written.contains("# Doc"))
        #expect(!written.contains("```"))
    }

    @Test func loadLocalMaterialsOrdersAgendaFirstAndStripsFrontmatter() throws {
        let (_, session) = try makeSession(materials: ["https://outline.example.org/doc/a"])
        try FileManager.default.createDirectory(at: session.materialsDirectory, withIntermediateDirectories: true)
        try "---\nkind: material\n---\n\nfetched doc".write(to: session.materialURL(index: 0),
                                                            atomically: true, encoding: .utf8)
        try "manual agenda".write(to: session.agendaURL, atomically: true, encoding: .utf8)
        let materials = MaterialsFetcher.loadLocalMaterials(for: session)
        #expect(materials == ["manual agenda", "fetched doc"])
    }

    @Test func connectionSecretsPrefersManifestOverEnv() throws {
        let manifest = ConnectionKeyManifest(
            connections: ["c1": .init(key: "from-manifest")], allowedCommands: ["td"]
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-manifest-\(UUID().uuidString).json")
        try JSONEncoder().encode(manifest).write(to: file)
        let secrets = ConnectionSecrets(environment: [
            "CONNECTION_KEYS_FILE": file.path,
            "CONNECTION_KEY_C1": "from-env",
        ])
        #expect(secrets.entry(for: outline)?.key == "from-manifest")
        #expect(secrets.allowedCommands == ["td"])

        let envOnly = ConnectionSecrets(environment: ["CONNECTION_KEY_C1": "from-env"])
        #expect(envOnly.entry(for: outline)?.key == "from-env")
        #expect(ConnectionSecrets.envName(for: "ab-3f") == "CONNECTION_KEY_AB_3F")
    }
}
