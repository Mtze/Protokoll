import Foundation
import Testing
@testable import SearchIndex
@testable import SharedKit

/// Project filtering combined with full-text search, and staying correct when a
/// session's project assignment changes (F7).
struct ProjectFilterTests {
    private func makeContainer() -> Container {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-pf-\(UUID().uuidString)", isDirectory: true)
        return Container(locator: LocalFolderContainer(root: root))
    }

    private func makeIndex() throws -> SearchIndex {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("idx-\(UUID().uuidString).sqlite")
        return try SearchIndex(path: path)
    }

    @Test func combinesTextAndProjectFilter() async throws {
        let container = makeContainer()
        var a = try container.createSession(device: .mac, title: "A")
        try Data("shared keyword alpha".utf8).write(to: a.transcriptURL)
        a.metadata.projects = ["work"]
        try container.store.save(a)

        var b = try container.createSession(device: .mac, title: "B")
        try Data("shared keyword beta".utf8).write(to: b.transcriptURL)
        b.metadata.projects = ["private"]
        try container.store.save(b)

        let index = try makeIndex()
        try await index.rebuild(from: container)

        #expect(try await index.search("keyword").count == 2)
        let work = try await index.search("keyword", filter: SearchFilter(projectID: "work"))
        #expect(work.count == 1)
        #expect(work.first?.sessionID == a.id)
    }

    @Test func reassigningProjectsUpdatesFiltering() async throws {
        let container = makeContainer()
        var session = try container.createSession(device: .mac, title: "S")
        try Data("gamma keyword".utf8).write(to: session.transcriptURL)
        session.metadata.projects = ["work"]
        try container.store.save(session)

        let index = try makeIndex()
        try await index.rebuild(from: container)
        #expect(try await index.search("gamma", filter: SearchFilter(projectID: "work")).count == 1)

        session.metadata.projects = ["private"]
        try container.store.save(session)
        try await index.rebuild(from: container)
        #expect(try await index.search("gamma", filter: SearchFilter(projectID: "work")).count == 0)
        #expect(try await index.search("gamma", filter: SearchFilter(projectID: "private")).count == 1)
    }
}
