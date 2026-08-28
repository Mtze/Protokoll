import Foundation
import SharedKit

/// Executes a pipeline's custom action steps after summarize (ADR-13): one
/// `claude -p` run per step with the step's connection attached via
/// `--mcp-config`, access controlled through `--allowedTools`.
///
/// Status discipline: every per-step error is caught and recorded in the
/// session's `pipeline.steps[]` only - action failures never touch the
/// session-level `PipelineStatus`, and a failed step does not abort the ones
/// after it. Each step leaves a local audit artifact at `steps/<id>.md` (N3).
public struct ActionRunner: Sendable {
    let runner: CommandRunning
    let tools: ToolLocator
    let store: SessionStore
    let connections: [PlatformConnection]
    let secrets: ConnectionSecrets
    let projects: [Project]
    /// The `claude --model` for action runs (the configured summary model).
    let model: String

    public init(
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        store: SessionStore = SessionStore(),
        connections: [PlatformConnection] = [],
        secrets: ConnectionSecrets? = nil,
        projects: [Project] = [],
        model: String
    ) {
        self.runner = runner
        self.tools = tools
        self.store = store
        self.connections = connections
        self.secrets = secrets ?? ConnectionSecrets(environment: tools.environment)
        self.projects = projects
        self.model = model
    }

    /// Which steps a run executes: `only` names one step id (explicit re-run,
    /// ignores prior state), `force` re-runs everything enabled, otherwise only
    /// enabled steps that have never completed. Stale/failed steps stay manual
    /// (regenerate decision). A recorded `running` counts as never-completed:
    /// this run holds the claim, so a persisted `running` can only be the
    /// orphan of a run that died mid-step - it must not be skipped forever.
    static func stepsToRun(
        pipeline: PipelineDefinition,
        recorded: [StepState]?,
        only: String?,
        force: Bool
    ) -> [ActionStep] {
        if let only { return pipeline.steps.filter { $0.id == only } }
        let states = Dictionary(uniqueKeysWithValues: (recorded ?? []).map { ($0.stepID, $0.status) })
        return pipeline.steps.filter { step in
            guard step.enabled else { return false }
            if force { return true }
            let status = states[step.id] ?? StepState.pending
            return status == StepState.pending || status == StepState.running
        }
    }

    /// Runs the selected steps in pipeline order and returns the reloaded
    /// session. Never throws for step-level failures.
    @discardableResult
    public func run(
        session: Session,
        pipeline: PipelineDefinition,
        only: String? = nil,
        force: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> Session {
        let steps = Self.stepsToRun(pipeline: pipeline,
                                    recorded: session.metadata.pipeline.steps,
                                    only: only, force: force)
        guard !steps.isEmpty else { return session }

        // Seed the visible step list: an entry per enabled step, keeping the
        // recorded status of steps this run does not touch.
        let running = Set(steps.map(\.id))
        let existing = Dictionary(uniqueKeysWithValues: (session.metadata.pipeline.steps ?? []).map { ($0.stepID, $0) })
        let seeded = pipeline.steps.filter { $0.enabled || existing[$0.id] != nil }.map { step -> StepState in
            if running.contains(step.id) {
                return StepState(stepID: step.id, name: step.name)
            }
            var kept = existing[step.id] ?? StepState(stepID: step.id, name: step.name)
            kept.name = step.name
            return kept
        }
        _ = try store.setStepStates(seeded, in: session.folder)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date = dateFormatter.string(from: session.metadata.startedAt)
        let projectNames = projects
            .filter { session.metadata.projects.contains($0.id) }
            .map(\.name)

        for step in steps {
            onProgress?("running action: \(step.name)")
            _ = try store.updateStepState(StepState(stepID: step.id, name: step.name,
                                                    status: StepState.running),
                                          in: session.folder)
            let started = Date()
            let outcome = runStep(step, session: session, date: date, projectNames: projectNames,
                                  onProgress: onProgress)
            let status: String
            let message: String?
            let report: String
            switch outcome {
            case let .success(text):
                status = StepState.done
                message = nil
                report = text
                AppLog.pipeline.info("action done session=\(session.id, privacy: .public) step=\(step.id, privacy: .public)")
            case let .failure(reason):
                status = StepState.failed
                message = reason
                report = "FAILED: \(reason)"
                AppLog.pipeline.error("action failed session=\(session.id, privacy: .public) step=\(step.id, privacy: .public): \(reason, privacy: .public)")
            }
            try? writeArtifact(report, step: step, status: status, started: started, session: session)
            _ = try store.updateStepState(StepState(stepID: step.id, name: step.name,
                                                    status: status, message: message,
                                                    finishedAt: Date()),
                                          in: session.folder)
        }
        return try store.load(folder: session.folder)
    }

    private enum StepOutcome {
        case success(String)
        case failure(String)
    }

    private func runStep(
        _ step: ActionStep,
        session: Session,
        date: String,
        projectNames: [String],
        onProgress: (@Sendable (String) -> Void)?
    ) -> StepOutcome {
        guard let connection = connections.first(where: { $0.id == step.connectionID }) else {
            return .failure("no connection configured for this step")
        }
        guard let server = MCPServerTemplate.server(for: connection, entry: secrets.entry(for: connection)) else {
            return .failure("connection \"\(connection.name)\" has no MCP launch configuration on this machine")
        }

        // Inputs: session override > default, placeholders resolved; a missing
        // required input fails just this step.
        var inputs: [(key: String, value: String)] = []
        for input in step.inputs {
            let raw = session.metadata.stepInputs?[step.id]?[input.key] ?? input.defaultValue
            let value = ActionPrompt.substitute(raw, session: session, date: date, projectNames: projectNames)
            if input.required, value.trimmingCharacters(in: .whitespaces).isEmpty {
                return .failure("required input \"\(input.key)\" has no value")
            }
            inputs.append((input.key, value))
        }

        guard let protocolDoc = try? String(contentsOf: session.protocolURL, encoding: .utf8) else {
            return .failure("no protocol.md yet - run summarize first")
        }
        let protocolBody = Frontmatter.split(protocolDoc).body
        let materials = MaterialsFetcher.loadLocalMaterials(for: session)
        var transcriptBody: String?
        if step.includeTranscript,
           let transcriptDoc = try? String(contentsOf: session.transcriptURL, encoding: .utf8) {
            transcriptBody = Frontmatter.split(transcriptDoc).body
        }

        // Access control: read = the server's read-only tools, readWrite = the
        // whole server; Bash only for commands the step declares AND the
        // machine approves (double key, ADR-13).
        var allowed = step.access == ActionStep.accessReadWrite ? server.allTools : server.readTools
        let machineApproved = Set(secrets.allowedCommands)
        let bashCommands = step.allowedCommands.filter { machineApproved.contains($0) }
        allowed += bashCommands.map { "Bash(\($0):*)" }
        let denied = MCPServerTemplate.deniedTools.filter { $0 != "Bash" || bashCommands.isEmpty }

        let prompt = ActionPrompt.build(
            step: step,
            connectionName: connection.name.isEmpty ? connection.kind : connection.name,
            resolvedPrompt: ActionPrompt.substitute(step.prompt, session: session,
                                                    date: date, projectNames: projectNames),
            inputs: inputs,
            session: session,
            date: date
        )

        do {
            let configURL = try MCPServerTemplate.writeConfig(for: server)
            defer { try? FileManager.default.removeItem(at: configURL) }
            let result = try runner.run(
                executable: tools.claudeBinary,
                arguments: [
                    "-p", prompt,
                    "--model", model,
                    "--mcp-config", configURL.path,
                    "--strict-mcp-config",
                    "--allowedTools", allowed.joined(separator: ","),
                    "--disallowedTools", denied.joined(separator: ","),
                ],
                stdin: ActionPrompt.input(protocolBody: protocolBody, materials: materials,
                                          transcriptBody: transcriptBody),
                environment: nil,
                workingDirectory: nil,
                onStderrLine: onProgress
            )
            guard result.succeeded else {
                return .failure(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            let report = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if report.hasPrefix("FAILED:") {
                return .failure(report.dropFirst("FAILED:".count).trimmingCharacters(in: .whitespaces))
            }
            return .success(report.isEmpty ? "(no report)" : report)
        } catch {
            return .failure(AppLog.describe(error))
        }
    }

    /// The local audit artifact (`steps/<id>.md`): what ran, when, and the
    /// model's tool-call report. Overwritten per run - it is a log, not a
    /// versioned document.
    private func writeArtifact(
        _ report: String, step: ActionStep, status: String, started: Date, session: Session
    ) throws {
        let formatter = ISO8601DateFormatter()
        let document = """
        ---
        kind: step-report
        step: \(step.name)
        status: \(status)
        started: \(formatter.string(from: started))
        finished: \(formatter.string(from: Date()))
        ---

        \(report)
        """
        try store.writeStepArtifact(document, stepID: step.id, for: session)
    }
}
