import Foundation
import Testing
@testable import SearchIndex
@testable import SharedKit

private func makeContainer() -> Container {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mn-idx-\(UUID().uuidString)")
    return Container(locator: LocalFolderContainer(root: root))
}

private func makeIndex() throws -> SearchIndex {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)/index.sqlite")
    return try SearchIndex(path: path)
}

@Suite struct SearchIndexTests {
    @Test func indexesAndFindsTranscriptText() async throws {
        let container = makeContainer()
        var session = try container.createSession(device: .mac, title: "Sprint Planning")
        try Data("---\nlanguage: en\n---\n\nWe decided to migrate the database to Postgres.".utf8)
            .write(to: session.transcriptURL)
        session.metadata.pipeline.status = .transcribed
        try container.store.save(session)

        let index = try makeIndex()
        try await index.rebuild(from: container)

        let hits = try await index.search("Postgres")
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Sprint Planning")
        #expect(hits.first?.kind == .transcript)
        #expect(hits.first?.snippet.contains("Postgres") == true)
    }

    @Test func searchesProtocolToo() async throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac, title: "Retro")
        try Data("body".utf8).write(to: session.transcriptURL)
        try Data("## Beschlüsse\n- Ship the widget on Friday.".utf8).write(to: session.protocolURL)
        let index = try makeIndex()
        try await index.rebuild(from: container)
        let hits = try await index.search("widget")
        #expect(hits.contains { $0.kind == .protocolDoc })
    }

    @Test func filtersByStatusAndProject() async throws {
        let container = makeContainer()
        var a = try container.createSession(device: .mac, title: "A")
        try Data("shared keyword alpha".utf8).write(to: a.transcriptURL)
        a.metadata.pipeline.status = .done
        a.metadata.projects = ["work"]
        try container.store.save(a)

        var b = try container.createSession(device: .mac, title: "B")
        try Data("shared keyword beta".utf8).write(to: b.transcriptURL)
        b.metadata.pipeline.status = .recorded
        b.metadata.projects = ["private"]
        try container.store.save(b)

        let index = try makeIndex()
        try await index.rebuild(from: container)

        #expect(try await index.search("keyword").count == 2)
        #expect(try await index.search("keyword", filter: SearchFilter(status: "done")).count == 1)
        #expect(try await index.search("keyword", filter: SearchFilter(projectID: "private")).count == 1)
    }

    @Test func rebuildableFromFilesOnAFreshIndex() async throws {
        // ADR-2: the index is a throwaway view of the files. A brand-new index
        // on another path (a fresh device, or after a corrupt-index delete)
        // rebuilds the same content from the container alone.
        let container = makeContainer()
        let session = try container.createSession(device: .mac, title: "Rebuildable")
        try Data("unique token zeta".utf8).write(to: session.transcriptURL)

        let index = try makeIndex()
        try await index.rebuild(from: container)
        #expect(try await index.search("zeta").count == 1)
        // Rebuild again on the same index is idempotent (no duplicate rows).
        try await index.rebuild(from: container)
        #expect(try await index.search("zeta").count == 1)

        let freshOnNewPath = try makeIndex()
        try await freshOnNewPath.rebuild(from: container)
        #expect(try await freshOnNewPath.search("zeta").count == 1)
    }

    @Test func removeDropsSessionFromResults() async throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac, title: "Deletable")
        try Data("this mentions the mango keyword".utf8).write(to: session.transcriptURL)
        let other = try container.createSession(device: .mac, title: "Keeper")
        try Data("this also mentions the mango keyword".utf8).write(to: other.transcriptURL)

        let index = try makeIndex()
        try await index.rebuild(from: container)
        #expect(try await index.search("mango").count == 2)

        try await index.remove(id: session.id)

        let hits = try await index.search("mango")
        #expect(hits.count == 1)
        #expect(hits.allSatisfy { $0.sessionID != session.id })
        #expect(hits.first?.sessionID == other.id)
    }

    @Test func punctuationInQueryDoesNotThrow() async throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac, title: "Q")
        try Data("email me at test@example.com about the MR!".utf8).write(to: session.transcriptURL)
        let index = try makeIndex()
        try await index.rebuild(from: container)
        // Would break a naive MATCH grammar; ftsQuery escapes it.
        let hits = try await index.search("test@example.com")
        #expect(hits.count == 1)
    }
}
