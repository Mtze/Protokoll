import Foundation
import Testing
import SharedKit
@testable import ProcessSession

/// Custom action execution (ADR-13): invocation shape, access control, status
/// discipline (step failures never touch session status, later steps still
/// run), audit artifacts, and the step-selection rules.
struct ActionRunnerTests {
    private final class FakeRunner: CommandRunning, @unchecked Sendable {
        /// stdout per invocation, in order (last repeats).
        var stdouts: [String]
        var exitCode: Int32 = 0
        private(set) var invocations: [(arguments: [String], stdin: String?)] = []
        private(set) var mcpConfigs: [String] = []

        init(stdouts: [String]) { self.stdouts = stdouts }

        func run(
            executable: String, arguments: [String], stdin: String?,
            environment: [String: String]?, workingDirectory: URL?,
            onStderrLine: (@Sendable (String) -> Void)?
        ) throws -> CommandResult {
            invocations.append((arguments, stdin))
            if let index = arguments.firstIndex(of: "--mcp-config"), index + 1 < arguments.count,
               let content = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8) {
                mcpConfigs.append(content)
            }
            let stdout = invocations.count <= stdouts.count ? stdouts[invocations.count - 1] : stdouts.last ?? ""
            return CommandResult(exitCode: exitCode, stdout: stdout, stderr: "")
        }
    }

    private let connection = PlatformConnection(id: "c1", name: "Team Outline",
                                                kind: PlatformConnection.kindOutline,
                                                baseURL: "https://outline.example.org")

    private func makeSession() throws -> (Container, Session) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-act-\(UUID().uuidString)", isDirectory: true)
        let container = Container(locator: LocalFolderContainer(root: root))
        var session = try container.createSession(device: .mac)
        session.metadata.title = "Standup"
        session.metadata.materials = ["https://outline.example.org/doc/x"]
        try container.store.save(session)
        try "---\nkind: transcript\n---\n\nT-BODY".write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        try "---\ntitle: Standup\n---\n\nP-BODY".write(to: session.protocolURL, atomically: true, encoding: .utf8)
        return (container, try container.store.load(folder: session.folder))
    }

    private func makeRunner(_ fake: FakeRunner, store: SessionStore,
                            allowedCommands: [String] = []) throws -> ActionRunner {
        let manifest = ConnectionKeyManifest(connections: ["c1": .init(key: "ol-key")],
                                             allowedCommands: allowedCommands)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-act-manifest-\(UUID().uuidString).json")
        try JSONEncoder().encode(manifest).write(to: file)
        return ActionRunner(
            runner: fake,
            tools: ToolLocator(environment: [:]),
            store: store,
            connections: [connection],
            secrets: ConnectionSecrets(environment: ["CONNECTION_KEYS_FILE": file.path]),
            projects: [Project(id: "pr1", name: "AET", color: "#fff")],
            model: "opus"
        )
    }

    private func step(_ id: String = "s1", access: String = ActionStep.accessReadWrite,
                      prompt: String = "Update the agenda at {materials}.",
                      includeTranscript: Bool = false,
                      inputs: [ActionInput] = [],
                      allowedCommands: [String] = []) -> ActionStep {
        ActionStep(id: id, name: "Update Outline", prompt: prompt, connectionID: "c1",
                   access: access, includeTranscript: includeTranscript,
                   inputs: inputs, allowedCommands: allowedCommands)
    }

    @Test func runsStepWithScaffoldMarkersAndAccess() throws {
        let (container, session) = try makeSession()
        let fake = FakeRunner(stdouts: ["updated the doc"])
        let runner = try makeRunner(fake, store: container.store)
        let pipeline = PipelineDefinition(id: "p1", name: "Standup", steps: [step()])

        let updated = try runner.run(session: session, pipeline: pipeline)

        let (arguments, stdin) = try #require(fake.invocations.first)
        let prompt = arguments[arguments.firstIndex(of: "-p")! + 1]
        #expect(prompt.contains("protokoll:\(session.id)/s1:begin"))
        #expect(prompt.contains("REPLACE the marked section"))
        #expect(prompt.contains("https://outline.example.org/doc/x"))  // {materials} resolved
        #expect(prompt.contains("\"Standup\""))
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "opus")
        #expect(arguments.contains("--strict-mcp-config"))
        // readWrite grants the whole server, and no fetched material exists so
        // stdin carries protocol + the material link list only.
        let allowed = arguments[arguments.firstIndex(of: "--allowedTools")! + 1]
        #expect(allowed == "mcp__outline")
        #expect(stdin?.contains("<protocol>\nP-BODY\n</protocol>") == true)
        #expect(stdin?.contains("<transcript>") == false)

        let state = try #require(updated.metadata.pipeline.steps?.first)
        #expect(state.status == StepState.done)
        let artifact = try String(contentsOf: session.stepArtifactURL(stepID: "s1"), encoding: .utf8)
        #expect(artifact.contains("updated the doc"))
        #expect(updated.metadata.pipeline.status == .recorded)  // session status untouched
    }

    @Test func readAccessAndTranscriptFlag() throws {
        let (container, session) = try makeSession()
        let fake = FakeRunner(stdouts: ["ok"])
        let runner = try makeRunner(fake, store: container.store)
        let pipeline = PipelineDefinition(id: "p1", name: "P",
                                          steps: [step(access: ActionStep.accessRead, includeTranscript: true)])
        _ = try runner.run(session: session, pipeline: pipeline)
        let (arguments, stdin) = try #require(fake.invocations.first)
        let allowed = arguments[arguments.firstIndex(of: "--allowedTools")! + 1]
        #expect(allowed.contains("mcp__outline__get_document"))
        #expect(!allowed.contains("Bash"))
        let denied = arguments[arguments.firstIndex(of: "--disallowedTools")! + 1]
        #expect(denied.contains("Bash"))
        #expect(stdin?.contains("<transcript>\nT-BODY\n</transcript>") == true)
    }

    @Test func bashEscapeHatchNeedsBothKeys() throws {
        let (container, session) = try makeSession()
        // Step declares td + rm; the machine only approves td.
        let fake = FakeRunner(stdouts: ["ok"])
        let runner = try makeRunner(fake, store: container.store, allowedCommands: ["td"])
        let pipeline = PipelineDefinition(id: "p1", name: "P",
                                          steps: [step(allowedCommands: ["td", "rm"])])
        _ = try runner.run(session: session, pipeline: pipeline)
        let arguments = try #require(fake.invocations.first).arguments
        let allowed = arguments[arguments.firstIndex(of: "--allowedTools")! + 1]
        #expect(allowed.contains("Bash(td:*)"))
        #expect(!allowed.contains("rm"))
        let denied = arguments[arguments.firstIndex(of: "--disallowedTools")! + 1]
        #expect(!denied.contains("Bash"))

        // Without machine approval, no Bash at all.
        let unapproved = FakeRunner(stdouts: ["ok"])
        let strict = try makeRunner(unapproved, store: container.store)
        _ = try strict.run(session: session, pipeline: pipeline, force: true)
        let strictArgs = try #require(unapproved.invocations.first).arguments
        #expect(!strictArgs[strictArgs.firstIndex(of: "--allowedTools")! + 1].contains("Bash"))
        #expect(strictArgs[strictArgs.firstIndex(of: "--disallowedTools")! + 1].contains("Bash"))
    }

    @Test func failedStepDoesNotAbortLaterStepsOrTouchStatus() throws {
        let (container, session) = try makeSession()
        let fake = FakeRunner(stdouts: ["FAILED: no such document", "second ok"])
        let runner = try makeRunner(fake, store: container.store)
        let pipeline = PipelineDefinition(id: "p1", name: "P",
                                          steps: [step("s1"), step("s2")])
        let updated = try runner.run(session: session, pipeline: pipeline)
        #expect(fake.invocations.count == 2)
        let states = try #require(updated.metadata.pipeline.steps)
        #expect(states.map(\.status) == [StepState.failed, StepState.done])
        #expect(states.first?.message == "no such document")
        #expect(updated.metadata.pipeline.status == .recorded)
        let artifact = try String(contentsOf: session.stepArtifactURL(stepID: "s1"), encoding: .utf8)
        #expect(artifact.contains("FAILED: no such document"))
    }

    @Test func missingRequiredInputFailsJustThatStep() throws {
        let (container, session) = try makeSession()
        let fake = FakeRunner(stdouts: ["ok"])
        let runner = try makeRunner(fake, store: container.store)
        let needsInput = step("s1", inputs: [ActionInput(key: "boardURL", label: "Board", required: true)])
        let pipeline = PipelineDefinition(id: "p1", name: "P", steps: [needsInput, step("s2")])
        let updated = try runner.run(session: session, pipeline: pipeline)
        #expect(fake.invocations.count == 1)  // only s2 ran
        let states = try #require(updated.metadata.pipeline.steps)
        #expect(states.first?.status == StepState.failed)
        #expect(states.first?.message?.contains("boardURL") == true)
        #expect(states.last?.status == StepState.done)
    }

    @Test func stepInputsOverrideDefaultsAndSubstitute() throws {
        let (container, initial) = try makeSession()
        var session = initial
        session.metadata.stepInputs = ["s1": ["boardURL": "{title} board"]]
        try container.store.save(session)
        session = try container.store.load(folder: session.folder)
        let fake = FakeRunner(stdouts: ["ok"])
        let runner = try makeRunner(fake, store: container.store)
        let withInput = step("s1", inputs: [ActionInput(key: "boardURL", label: "Board",
                                                        defaultValue: "unused", required: true)])
        _ = try runner.run(session: session, pipeline: PipelineDefinition(id: "p", name: "P", steps: [withInput]))
        let prompt = try #require(fake.invocations.first).arguments[1]
        #expect(prompt.contains("boardURL: Standup board"))
    }

    @Test func orphanedRunningStepIsRetried() throws {
        // A persisted `running` can only be the orphan of a run that died
        // mid-step (this run holds the claim), so it must run again.
        let (container, session) = try makeSession()
        try container.store.setStepStates(
            [StepState(stepID: "s1", name: "X", status: StepState.running)],
            in: session.folder
        )
        let reloaded = try container.store.load(folder: session.folder)
        let fake = FakeRunner(stdouts: ["recovered"])
        let runner = try makeRunner(fake, store: container.store)
        let updated = try runner.run(session: reloaded,
                                     pipeline: PipelineDefinition(id: "p", name: "P", steps: [step("s1")]))
        #expect(fake.invocations.count == 1)
        #expect(updated.metadata.pipeline.steps?.first?.status == StepState.done)
    }

    @Test func stepSelectionRules() {
        let enabled = step("s1")
        var disabled = step("s2"); disabled.enabled = false
        let done = step("s3")
        let stale = step("s4")
        let pipeline = PipelineDefinition(id: "p", name: "P", steps: [enabled, disabled, done, stale])
        let recorded = [
            StepState(stepID: "s3", name: "", status: StepState.done),
            StepState(stepID: "s4", name: "", status: StepState.stale),
        ]
        // Default: only never-completed enabled steps.
        #expect(ActionRunner.stepsToRun(pipeline: pipeline, recorded: recorded, only: nil, force: false)
            .map(\.id) == ["s1"])
        // Force: everything enabled.
        #expect(ActionRunner.stepsToRun(pipeline: pipeline, recorded: recorded, only: nil, force: true)
            .map(\.id) == ["s1", "s3", "s4"])
        // Explicit re-run by id ignores prior state and the enabled flag.
        #expect(ActionRunner.stepsToRun(pipeline: pipeline, recorded: recorded, only: "s4", force: false)
            .map(\.id) == ["s4"])
        #expect(ActionRunner.stepsToRun(pipeline: pipeline, recorded: recorded, only: "s2", force: false)
            .map(\.id) == ["s2"])
    }
}

/// Pipeline-level status behavior around actions (ADR-13).
struct ActionPipelineStatusTests {
    private final class FakeRunner: CommandRunning, @unchecked Sendable {
        var stdout: String
        private(set) var count = 0
        init(stdout: String = "") { self.stdout = stdout }
        func run(executable: String, arguments: [String], stdin: String?,
                 environment: [String: String]?, workingDirectory: URL?,
                 onStderrLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
            count += 1
            return CommandResult(exitCode: 0, stdout: stdout, stderr: "")
        }
    }

    private func makeProcessedSession(status: PipelineStatus) throws -> (Container, Session) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-pipe-\(UUID().uuidString)", isDirectory: true)
        let container = Container(locator: LocalFolderContainer(root: root))
        var session = try container.createSession(device: .mac)
        try "---\nkind: transcript\n---\n\nbody".write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        try "---\ntitle: X\n---\n\nprotocol".write(to: session.protocolURL, atomically: true, encoding: .utf8)
        session.metadata.pipeline.status = status
        try container.store.save(session)
        return (container, try container.store.load(folder: session.folder))
    }

    /// A `.failed` left by an earlier run must not survive a run in which every
    /// stage was skipped because its output already exists (the old
    /// retry-stays-red gap).
    @Test func staleFailedReconcilesToDoneOnNoOpRun() throws {
        let (container, session) = try makeProcessedSession(status: .failed(message: "old"))
        let runner = FakeRunner()
        let pipeline = Pipeline(container: container, runner: runner, deviceId: "t")
        let result = try pipeline.run(folder: session.folder, step: .all)
        #expect(runner.count == 0)
        #expect(result.metadata.pipeline.status == .done)
    }

    /// A forced summarize (regenerate) marks completed steps stale - external
    /// re-runs stay a manual decision.
    @Test func forcedSummarizeMarksDoneStepsStale() throws {
        let (container, session) = try makeProcessedSession(status: .done)
        try container.store.setStepStates(
            [StepState(stepID: "s1", name: "X", status: StepState.done),
             StepState(stepID: "s2", name: "Y", status: StepState.failed)],
            in: session.folder
        )
        let runner = FakeRunner(stdout: "---\ntitle: X\nlanguage: en\n---\n\nnew protocol")
        let pipeline = Pipeline(container: container, runner: runner, deviceId: "t")
        let result = try pipeline.run(folder: session.folder, step: .summarize, force: true)
        #expect(result.metadata.pipeline.steps?.map(\.status) == [StepState.stale, StepState.failed])
        #expect(result.metadata.pipeline.status == .done)
    }
}
