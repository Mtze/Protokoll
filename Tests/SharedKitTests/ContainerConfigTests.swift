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

    @Test func audioPreprocessingDefaultsToSafe() throws {
        let data = Data(#"{"transcriptionLanguage":"de"}"#.utf8)
        let config = try SessionStore.decoder.decode(PipelineConfig.self, from: data)
        #expect(config.audioPreprocessing == "safe")
    }
}

/// The user-editable summary body spec, stored as a file in the container so it is
/// readable and diffable outside the app (ADR-2/N3), and so that an absent file
/// means "use the default" - which is what makes it need no migration.
@Suite struct SummaryTemplateTests {
    private func makeContainer() -> Container {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-tmpl-\(UUID().uuidString)", isDirectory: true)
        return Container(locator: LocalFolderContainer(root: root))
    }

    @Test func absentFileMeansNoCustomTemplate() throws {
        let container = makeContainer()
        #expect(try container.loadSummaryTemplate() == nil)
        #expect(container.hasCustomSummaryTemplate() == false)
    }

    @Test func roundTrips() throws {
        let container = makeContainer()
        try container.saveSummaryTemplate("Write only decisions.")
        #expect(try container.loadSummaryTemplate() == "Write only decisions.")
        #expect(container.hasCustomSummaryTemplate())
    }

    /// Reset to default deletes the file rather than storing a sentinel.
    @Test func savingNilResetsToTheDefault() throws {
        let container = makeContainer()
        try container.saveSummaryTemplate("custom")
        try container.saveSummaryTemplate(nil)
        #expect(try container.loadSummaryTemplate() == nil)
        #expect(container.hasCustomSummaryTemplate() == false)
    }

    /// Clearing the editor must not send an empty spec to the model.
    @Test func blankTemplateReadsAsAbsent() throws {
        let container = makeContainer()
        try container.saveSummaryTemplate("   \n\t\n ")
        #expect(try container.loadSummaryTemplate() == nil)
    }

    @Test func templateLivesBesidePipelineConfigAndDoesNotDisturbIt() throws {
        let container = makeContainer()
        try container.savePipelineConfig(PipelineConfig(summaryInstructions: "keep me"))
        try container.saveSummaryTemplate("a spec")
        #expect(try container.loadPipelineConfig().summaryInstructions == "keep me")
        #expect(try container.summaryTemplateURL().lastPathComponent == "summary-prompt.md")
    }
}
