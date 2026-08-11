import Foundation
import Testing
@testable import SharedKit

/// Tests for the container-backed PipelineConfig that the app and pipeline share.
struct ContainerConfigTests {
    private func makeContainer() -> Container {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-cfg-\(UUID().uuidString)", isDirectory: true)
        return Container(locator: LocalFolderContainer(root: root))
    }

    @Test func defaultsWhenMissing() throws {
        #expect(try makeContainer().loadPipelineConfig() == PipelineConfig())
    }

    @Test func roundTrip() throws {
        let container = makeContainer()
        var config = PipelineConfig()
        config.transcriptionLanguage = "de"
        config.vocabulary = "Ceph, Proxmox"
        config.transcriptionModel = "large-v3-turbo"
        config.summaryLanguage = "en"
        config.summaryModel = "sonnet"
        config.summaryInstructions = "Add a TL;DR."
        try container.savePipelineConfig(config)
        #expect(try container.loadPipelineConfig() == config)
    }

    @Test func partialJSONDecodesWithDefaults() throws {
        let data = Data(#"{"transcriptionLanguage":"en","summaryInstructions":"x"}"#.utf8)
        let config = try SessionStore.decoder.decode(PipelineConfig.self, from: data)
        #expect(config.transcriptionLanguage == "en")
        #expect(config.summaryInstructions == "x")
        #expect(config.transcriptionModel == "large-v3")  // default
        #expect(config.summaryModel == "opus")            // default
        #expect(config.summaryLanguage == "auto")         // default
    }

    @Test func configDoesNotDisturbSessionsOrProjects() throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac)
        try container.savePipelineConfig(PipelineConfig(summaryInstructions: "hi"))
        #expect(try container.allSessions().contains { $0.id == session.id })
        #expect(try container.loadProjects().isEmpty)
    }
}
