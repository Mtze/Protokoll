import Foundation
import Testing
@testable import SharedKit

private func makeTempContainer() throws -> Container {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mn-tests-\(UUID().uuidString)", isDirectory: true)
    return Container(locator: LocalFolderContainer(root: root))
}

@Suite struct ContainerTests {
    @Test func createReloadAndStatus() throws {
        let container = try makeTempContainer()
        let created = try container.createSession(device: .mac)
        #expect(created.metadata.pipeline.status == .recorded)
        #expect(FileManager.default.fileExists(atPath: created.metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: created.audioDirectory.path))

        let reloaded = try container.store.load(folder: created.folder)
        #expect(reloaded.metadata.id == created.metadata.id)

        _ = try container.store.setStatus(.transcribing, in: created.folder)
        let after = try container.store.load(folder: created.folder)
        #expect(after.metadata.pipeline.status == .transcribing)
    }

    @Test func allSessionsSortedNewestFirst() throws {
        let container = try makeTempContainer()
        let old = try container.createSession(device: .mac, startedAt: Date(timeIntervalSince1970: 1000))
        let new = try container.createSession(device: .ios, startedAt: Date(timeIntervalSince1970: 2000))
        let sessions = try container.allSessions()
        #expect(sessions.count == 2)
        #expect(sessions.first?.id == new.id)
        #expect(sessions.last?.id == old.id)
    }

    @Test func malformedJSONIsSkippedNotCrash() throws {
        let container = try makeTempContainer()
        _ = try container.createSession(device: .mac)
        // Plant a broken session folder.
        let broken = try container.sessionsDirectory().appendingPathComponent("2020-01-01T00-00-00Z_bad", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: broken.appendingPathComponent("session.json"))
        let sessions = try container.allSessions()
        #expect(sessions.count == 1)
    }

    @Test func deleteRemovesTheSessionFolder() throws {
        let container = try makeTempContainer()
        let session = try container.createSession(device: .mac)
        #expect(FileManager.default.fileExists(atPath: session.folder.path))

        try container.deleteSession(session)

        #expect(!FileManager.default.fileExists(atPath: session.folder.path))
        #expect(try container.allSessions().isEmpty)
    }

    @Test func deleteMissingSessionDoesNotThrow() throws {
        let container = try makeTempContainer()
        let session = try container.createSession(device: .mac)
        try container.deleteSession(session)
        // Deleting the already-gone session again is a no-op, not an error.
        try container.deleteSession(session)
        #expect(try container.allSessions().isEmpty)
    }

    @Test func deleteLeavesOtherSessionsUntouched() throws {
        let container = try makeTempContainer()
        let keep = try container.createSession(device: .mac, startedAt: Date(timeIntervalSince1970: 1000))
        let remove = try container.createSession(device: .ios, startedAt: Date(timeIntervalSince1970: 2000))

        try container.deleteSession(remove)

        let remaining = try container.allSessions()
        #expect(remaining.map(\.id) == [keep.id])
        #expect(FileManager.default.fileExists(atPath: keep.folder.path))
    }

    @Test func projectsRoundTrip() throws {
        let container = try makeTempContainer()
        #expect(try container.loadProjects().isEmpty)
        let projects = [Project(name: "Work", color: "#FF0000"), Project(name: "Private", color: "#00FF00")]
        try container.saveProjects(projects)
        let loaded = try container.loadProjects()
        #expect(loaded.map(\.name) == ["Work", "Private"])
    }
}

@Suite struct ProtocolRotationTests {
    @Test func rotatesExistingProtocol() throws {
        let container = try makeTempContainer()
        let session = try container.createSession(device: .mac)

        #expect(try container.store.writeProtocol("v1 body", for: session) == nil)
        #expect(try String(contentsOf: session.protocolURL, encoding: .utf8) == "v1 body")

        let rotated = try container.store.writeProtocol("v2 body", for: session)
        #expect(rotated == session.rotatedProtocolURL(version: 1))
        #expect(try String(contentsOf: session.rotatedProtocolURL(version: 1), encoding: .utf8) == "v1 body")
        #expect(try String(contentsOf: session.protocolURL, encoding: .utf8) == "v2 body")

        let rotated2 = try container.store.writeProtocol("v3 body", for: session)
        #expect(rotated2 == session.rotatedProtocolURL(version: 2))
    }
}

@Suite struct ClaimTests {
    @Test func acquireRenewRelease() throws {
        let container = try makeTempContainer()
        let session = try container.createSession(device: .mac)

        let claimed = try container.store.acquireClaim(step: .transcribe, deviceId: "mac-1", in: session.folder)
        #expect(claimed.metadata.pipeline.claim?.deviceId == "mac-1")

        let renewed = try container.store.renewClaim(deviceId: "mac-1", in: session.folder, now: Date().addingTimeInterval(10))
        #expect(renewed.metadata.pipeline.claim != nil)

        let released = try container.store.releaseClaim(deviceId: "mac-1", in: session.folder)
        #expect(released.metadata.pipeline.claim == nil)
    }

    @Test func liveClaimByAnotherDeviceConflicts() throws {
        let container = try makeTempContainer()
        let session = try container.createSession(device: .mac)
        _ = try container.store.acquireClaim(step: .transcribe, deviceId: "mac-1", in: session.folder)

        #expect(throws: ClaimConflict.self) {
            _ = try container.store.acquireClaim(step: .transcribe, deviceId: "mac-2", in: session.folder)
        }
    }

    @Test func staleClaimCanBeTakenOver() throws {
        let container = try makeTempContainer()
        let session = try container.createSession(device: .mac)
        let past = Date().addingTimeInterval(-(Claim.leaseDuration + 60))
        _ = try container.store.acquireClaim(step: .transcribe, deviceId: "mac-1", in: session.folder, now: past)

        // A fresh acquire "now" should succeed because the old lease expired.
        let taken = try container.store.acquireClaim(step: .transcribe, deviceId: "mac-2", in: session.folder)
        #expect(taken.metadata.pipeline.claim?.deviceId == "mac-2")
    }
}

@Suite struct FrontmatterTests {
    @Test func roundTrip() throws {
        var frontmatter = Frontmatter()
        frontmatter["title"] = "Weekly: Sync"
        frontmatter["language"] = "de"
        let doc = frontmatter.render(body: "# Body\n\nText")
        let (parsed, body) = Frontmatter.split(doc)
        #expect(parsed["title"] == "Weekly: Sync")
        #expect(parsed["language"] == "de")
        #expect(body == "# Body\n\nText")
    }

    @Test func noFrontmatterReturnsWholeBody() throws {
        let (parsed, body) = Frontmatter.split("# Just a heading\n\nno frontmatter")
        #expect(parsed.pairs.isEmpty)
        #expect(body == "# Just a heading\n\nno frontmatter")
    }

    @Test func unterminatedFrontmatterTreatedAsBody() throws {
        let (parsed, body) = Frontmatter.split("---\ntitle: X\n# no closing delimiter\nmore")
        #expect(parsed.pairs.isEmpty)
        #expect(body == "---\ntitle: X\n# no closing delimiter\nmore")
    }

    @Test func valueWithHashIsQuotedAndRoundTrips() throws {
        var frontmatter = Frontmatter()
        frontmatter["color"] = "#FF0000"
        let doc = frontmatter.render(body: "body")
        #expect(doc.contains("\"#FF0000\""))
        #expect(Frontmatter.split(doc).frontmatter["color"] == "#FF0000")
    }

    @Test func statusEncodesFailureMessage() throws {
        let status = PipelineStatus.failed(message: "boom")
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(PipelineStatus.self, from: data)
        #expect(decoded == .failed(message: "boom"))
    }
}
