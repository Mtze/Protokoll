import Foundation
import Testing
@testable import SharedKit

/// Tests for the ADR-13 automation model: connections, pipeline definitions,
/// resolver precedence, per-step session state, and forward-tolerant decoding.
struct AutomationModelTests {
    private func makeContainer() -> Container {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-auto-\(UUID().uuidString)", isDirectory: true)
        return Container(locator: LocalFolderContainer(root: root))
    }

    // MARK: config/connections.json

    @Test func connectionsDefaultEmptyAndRoundTrip() throws {
        let container = makeContainer()
        #expect(try container.loadConnections().isEmpty)
        let connection = PlatformConnection(name: "Team Outline", kind: PlatformConnection.kindOutline,
                                            baseURL: "https://outline.example.org")
        try container.saveConnections([connection])
        #expect(try container.loadConnections() == [connection])
    }

    @Test func connectionDecodesPartialJSONWithDefaults() throws {
        let data = Data(#"{"id":"c1","name":"Outline"}"#.utf8)
        let connection = try SessionStore.decoder.decode(PlatformConnection.self, from: data)
        #expect(connection.id == "c1")
        #expect(connection.name == "Outline")
        #expect(connection.kind == PlatformConnection.kindOutline)  // default
        #expect(connection.baseURL.isEmpty)                          // default
    }

    // MARK: config/pipelines.json

    @Test func pipelinesDefaultAndRoundTrip() throws {
        let container = makeContainer()
        #expect(try container.loadPipelines() == PipelinesConfig())
        let step = ActionStep(name: "Update agenda", prompt: "Append the notes to {materials}.",
                              connectionID: "c1", access: ActionStep.accessReadWrite,
                              inputs: [ActionInput(key: "documentURL", label: "Doc", required: true)],
                              allowedCommands: ["td"])
        let config = PipelinesConfig(pipelines: [PipelineDefinition(name: "Standup", steps: [step])],
                                     defaultPipelineID: "")
        try container.savePipelines(config)
        #expect(try container.loadPipelines() == config)
    }

    @Test func pipelineDecodesPartialJSONWithDefaults() throws {
        let data = Data(#"{"pipelines":[{"id":"p1","steps":[{"id":"s1","name":"X"}]}]}"#.utf8)
        let config = try SessionStore.decoder.decode(PipelinesConfig.self, from: data)
        #expect(config.defaultPipelineID.isEmpty)
        let step = try #require(config.pipelines.first?.steps.first)
        #expect(step.id == "s1")
        #expect(step.access == ActionStep.accessRead)  // default
        #expect(step.enabled)                          // default
        #expect(step.inputs.isEmpty)
        #expect(step.allowedCommands.isEmpty)
    }

    // MARK: PipelineResolver precedence

    private let standup = PipelineDefinition(id: "p-standup", name: "Standup")
    private let review = PipelineDefinition(id: "p-review", name: "Review")

    private func config() -> PipelinesConfig {
        PipelinesConfig(pipelines: [standup, review], defaultPipelineID: "p-review")
    }

    private func metadata(projects: [String] = [], pipelineID: String? = nil) -> SessionMetadata {
        SessionMetadata(id: "s1", startedAt: Date(), device: .mac,
                        projects: projects, pipelineID: pipelineID)
    }

    @Test func sessionOverrideWins() {
        let projects = [Project(id: "pr1", name: "A", color: "#fff", pipelineID: "p-review")]
        let resolved = PipelineResolver.resolve(
            session: metadata(projects: ["pr1"], pipelineID: "p-standup"),
            projects: projects, config: config()
        )
        #expect(resolved?.id == "p-standup")
    }

    @Test func sessionOverrideToUnknownMeansBuiltInDefault() {
        let projects = [Project(id: "pr1", name: "A", color: "#fff", pipelineID: "p-review")]
        let resolved = PipelineResolver.resolve(
            session: metadata(projects: ["pr1"], pipelineID: ""),
            projects: projects, config: config()
        )
        #expect(resolved == nil)  // explicit override beats the project default
    }

    @Test func firstAssignedProjectWithPipelineWins() {
        let projects = [
            Project(id: "pr-none", name: "N", color: "#fff"),
            Project(id: "pr-a", name: "A", color: "#fff", pipelineID: "p-standup"),
            Project(id: "pr-b", name: "B", color: "#fff", pipelineID: "p-review"),
        ]
        let resolved = PipelineResolver.resolve(
            session: metadata(projects: ["pr-none", "pr-a", "pr-b"]),
            projects: projects, config: config()
        )
        #expect(resolved?.id == "p-standup")
    }

    @Test func fallsBackToGlobalDefaultThenBuiltIn() {
        #expect(PipelineResolver.resolve(session: metadata(), projects: [], config: config())?.id == "p-review")
        #expect(PipelineResolver.resolve(session: metadata(), projects: [], config: PipelinesConfig()) == nil)
    }

    // MARK: session.json forward/backward tolerance

    @Test func sessionMetadataWithoutNewFieldsDecodes() throws {
        let old = SessionMetadata(id: "s1", startedAt: Date(), device: .mac)
        let data = try SessionStore.encoder.encode(old)
        let decoded = try SessionStore.decoder.decode(SessionMetadata.self, from: data)
        #expect(decoded.materials == nil)
        #expect(decoded.pipelineID == nil)
        #expect(decoded.stepInputs == nil)
        #expect(decoded.pipeline.steps == nil)
    }

    @Test func stepStateWithUnknownStatusRoundTrips() throws {
        let state = StepState(stepID: "s1", name: "X", status: "paused-by-future-build")
        let data = try SessionStore.encoder.encode(state)
        let decoded = try SessionStore.decoder.decode(StepState.self, from: data)
        #expect(decoded.status == "paused-by-future-build")
    }

    @Test func claimWithUnknownStepDecodesAsSummarize() throws {
        let json = #"{"deviceId":"mac-1","step":"actions","startedAt":"2026-08-28T10:00:00Z","heartbeat":"2026-08-28T10:00:00Z"}"#
        let claim = try SessionStore.decoder.decode(Claim.self, from: Data(json.utf8))
        #expect(claim.step == .summarize)
        #expect(claim.deviceId == "mac-1")
    }

    // MARK: SessionStore step-state helpers

    @Test func stepStateHelpersPersist() throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac)
        let store = container.store

        try store.setStepStates([StepState(stepID: "s1", name: "One")], in: session.folder)
        var loaded = try store.load(folder: session.folder)
        #expect(loaded.metadata.pipeline.steps?.map(\.status) == [StepState.pending])

        try store.updateStepState(StepState(stepID: "s1", name: "One", status: StepState.done),
                                  in: session.folder)
        try store.updateStepState(StepState(stepID: "s2", name: "Two", status: StepState.failed,
                                            message: "boom"), in: session.folder)
        loaded = try store.load(folder: session.folder)
        #expect(loaded.metadata.pipeline.steps?.count == 2)
        #expect(loaded.metadata.pipeline.steps?.first?.status == StepState.done)
        #expect(loaded.metadata.pipeline.steps?.last?.message == "boom")

        try store.setStepStates(nil, in: session.folder)
        loaded = try store.load(folder: session.folder)
        #expect(loaded.metadata.pipeline.steps == nil)
    }

    @Test func writeStepArtifactCreatesFile() throws {
        let container = makeContainer()
        let session = try container.createSession(device: .mac)
        let url = try container.store.writeStepArtifact("report", stepID: "s1", for: session)
        #expect(url == session.stepArtifactURL(stepID: "s1"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "report")
    }
}
