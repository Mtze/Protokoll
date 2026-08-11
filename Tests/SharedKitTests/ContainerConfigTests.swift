import Foundation
import Testing
@testable import SharedKit

/// Tests for the container-backed config that stores the user's custom summary
/// instructions (so the app and the pipeline share one source of truth).
struct ContainerConfigTests {
    private func makeContainer() -> Container {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-cfg-\(UUID().uuidString)", isDirectory: true)
        return Container(locator: LocalFolderContainer(root: root))
    }

    @Test func summaryInstructionsRoundTrip() throws {
        let container = makeContainer()
        #expect(try container.loadSummaryInstructions() == "")
        try container.saveSummaryInstructions("Answer in English.")
        #expect(try container.loadSummaryInstructions() == "Answer in English.")
    }

    @Test func blankInstructionsClearTheFile() throws {
        let container = makeContainer()
        try container.saveSummaryInstructions("something")
        try container.saveSummaryInstructions("   \n ")
        #expect(try container.loadSummaryInstructions() == "")
    }

    @Test func configDoesNotDisturbSessionsOrProjects() throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac)
        try container.saveSummaryInstructions("hi")
        #expect(try container.allSessions().contains { $0.id == session.id })
        #expect(try container.loadProjects().isEmpty)
    }
}
