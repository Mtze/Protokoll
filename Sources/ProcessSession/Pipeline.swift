import Foundation
import SharedKit

/// Which step(s) to run: everything, or one ``PipelineRunStep`` (including a
/// single custom action, ADR-13).
public enum PipelineStepSelection: Sendable, Equatable {
    case all
    case only(PipelineRunStep)

    public init?(argument: String) {
        if argument == "all" {
            self = .all
        } else if let step = PipelineRunStep(argument: argument) {
            self = .only(step)
        } else {
            return nil
        }
    }

    /// Conveniences so call sites read like the old flat enum.
    public static let transcribe: PipelineStepSelection = .only(.transcribe)
    public static let summarize: PipelineStepSelection = .only(.summarize)
    public static let actions: PipelineStepSelection = .only(.actions)

    /// The CLI `--step` string, for logging and round-trips.
    public var argument: String {
        switch self {
        case .all: return "all"
        case .only(let step): return step.argument
        }
    }

    var runsTranscribe: Bool { self == .all || self == .only(.transcribe) }
    var runsSummarize: Bool { self == .all || self == .only(.summarize) }
}

/// Waits for an iCloud-hosted file to finish downloading before use (N7).
/// A no-op for local containers, where files are always present.
public struct ICloudDownloadWaiter: Sendable {
    public init() {}

    /// Ensures `url` is materialized locally, kicking off a download and polling
    /// until it lands or `timeout` elapses.
    public func awaitLocal(_ url: URL, timeout: TimeInterval = 300) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            // Not a ubiquitous placeholder we know about; nothing to wait for.
            return
        }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return }
        if status == .current { return }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if current?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

/// Orchestrates the processing of one session: iCloud wait → transcribe →
/// summarize, updating status and holding a claim/lease throughout (ADR-4).
public struct Pipeline: Sendable {
    let container: Container
    let transcriber: Transcriber
    let summarizer: Summarizer
    let materialsFetcher: MaterialsFetcher
    let actionRunner: ActionRunner
    let pipelinesConfig: PipelinesConfig
    let projects: [Project]
    let waiter: ICloudDownloadWaiter
    let deviceId: String

    public init(
        container: Container,
        runner: CommandRunning,
        tools: ToolLocator = ToolLocator(),
        deviceId: String
    ) {
        self.container = container
        let config = (try? container.loadPipelineConfig()) ?? PipelineConfig()
        self.transcriber = Transcriber(runner: runner, tools: tools, store: container.store,
                                       language: config.transcriptionLanguage,
                                       vocabulary: config.vocabulary,
                                       model: config.transcriptionModel,
                                       preprocess: config.audioPreprocessing)
        // Absent template file → built-in default, so standalone runs and app runs
        // agree and there is nothing to migrate.
        let template = (try? container.loadSummaryTemplate()) ?? nil
        self.summarizer = Summarizer(runner: runner, tools: tools, store: container.store,
                                     customInstructions: config.summaryInstructions,
                                     summaryLanguage: config.summaryLanguage,
                                     summaryModel: config.summaryModel,
                                     template: template ?? "",
                                     summaryProvider: config.summaryProvider,
                                     summaryApiModel: config.summaryApiModel,
                                     summaryApiBaseURL: config.summaryApiBaseURL,
                                     summaryMaxTokens: config.summaryMaxTokens)
        let connections = (try? container.loadConnections()) ?? []
        self.materialsFetcher = MaterialsFetcher(
            runner: runner, tools: tools, connections: connections
        )
        self.pipelinesConfig = (try? container.loadPipelines()) ?? PipelinesConfig()
        self.projects = (try? container.loadProjects()) ?? []
        self.actionRunner = ActionRunner(
            runner: runner, tools: tools, store: container.store,
            connections: connections, projects: self.projects,
            model: config.summaryModel.isEmpty ? tools.claudeModel : config.summaryModel
        )
        self.waiter = ICloudDownloadWaiter()
        self.deviceId = deviceId
    }

    /// Runs the requested step(s). `force` re-runs a step even if its output
    /// already exists. Progress lines are forwarded to `onProgress`.
    @discardableResult
    public func run(
        folder: URL,
        step: PipelineStepSelection,
        force: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> Session {
        let store = container.store
        var session = try store.load(folder: folder)

        if step.runsTranscribe {
            let alreadyDone = FileManager.default.fileExists(atPath: session.transcriptURL.path)
            if force || !alreadyDone {
                session = try runTranscribe(session: session, onProgress: onProgress)
            }
        }

        if step.runsSummarize {
            let alreadyDone = FileManager.default.fileExists(atPath: session.protocolURL.path)
            if force || !alreadyDone {
                session = try runSummarize(session: session, force: force, onProgress: onProgress)
            }
        }

        // Custom action steps (ADR-13), after the core stages. `.all` runs the
        // resolved pipeline's never-completed steps; explicit selections run
        // what they name. Step failures live in `pipeline.steps[]` only.
        let actionsOnly: String?
        let runActions: Bool
        switch step {
        case .all, .only(.actions):
            actionsOnly = nil
            runActions = true
        case let .only(.action(id)):
            actionsOnly = id
            runActions = true
        default:
            actionsOnly = nil
            runActions = false
        }
        if runActions,
           let pipeline = PipelineResolver.resolve(session: session.metadata,
                                                   projects: projects, config: pipelinesConfig) {
            session = try runActionStage(session: session, pipeline: pipeline,
                                         only: actionsOnly,
                                         force: force && step != .all,
                                         onProgress: onProgress)
        }

        // Reconcile a stale `.failed`: if both core outputs exist and this run
        // completed without throwing, the failure it records is from a previous
        // run whose retry skipped every stage - restore `.done` so the session
        // is not stuck red forever.
        if case .failed = session.metadata.pipeline.status,
           FileManager.default.fileExists(atPath: session.transcriptURL.path),
           FileManager.default.fileExists(atPath: session.protocolURL.path) {
            session = try store.setStatus(.done, in: session.folder)
        }

        return session
    }

    /// Wraps the action steps in the summarize claim + heartbeat (they reuse
    /// the existing claim vocabulary on purpose - old builds keep decoding
    /// `session.json`, ADR-13).
    private func runActionStage(
        session: Session,
        pipeline: PipelineDefinition,
        only: String?,
        force: Bool,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> Session {
        let store = container.store
        AppLog.pipeline.info("actions start session=\(session.id, privacy: .public) pipeline=\(pipeline.id, privacy: .public)")
        _ = try store.acquireClaim(step: .summarize, deviceId: deviceId, in: session.folder)
        defer { _ = try? store.releaseClaim(deviceId: deviceId, in: session.folder) }
        return try withHeartbeat(folder: session.folder) {
            try actionRunner.run(session: session, pipeline: pipeline,
                                 only: only, force: force, onProgress: onProgress)
        }
    }

    private func runTranscribe(session: Session, onProgress: (@Sendable (String) -> Void)?) throws -> Session {
        let store = container.store
        let name = AppLog.folderName(session.folder)
        AppLog.pipeline.info("transcribe start session=\(session.id, privacy: .public) folder=\(name, privacy: .public)")
        let started = Date()
        try waiter.awaitLocal(session.micAudioURL)
        _ = try store.acquireClaim(step: .transcribe, deviceId: deviceId, in: session.folder)
        _ = try store.setStatus(.transcribing, in: session.folder)
        do {
            var updated = try withHeartbeat(folder: session.folder) {
                try transcriber.transcribe(session: session, onProgress: onProgress)
            }
            updated.metadata.pipeline.status = .transcribed
            updated.metadata.pipeline.claim = nil
            try store.save(updated)
            AppLog.pipeline.info("transcribe done session=\(session.id, privacy: .public) duration=\(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")
            return updated
        } catch {
            AppLog.pipeline.error("transcribe failed session=\(session.id, privacy: .public): \(AppLog.describe(error), privacy: .public)")
            try? recordFailure(folder: session.folder, error: error)
            throw error
        }
    }

    private func runSummarize(session: Session, force: Bool = false, onProgress: (@Sendable (String) -> Void)?) throws -> Session {
        let store = container.store
        let name = AppLog.folderName(session.folder)
        AppLog.pipeline.info("summarize start session=\(session.id, privacy: .public) folder=\(name, privacy: .public)")
        let started = Date()
        _ = try store.acquireClaim(step: .summarize, deviceId: deviceId, in: session.folder)
        _ = try store.setStatus(.summarizing, in: session.folder)
        do {
            var updated = try withHeartbeat(folder: session.folder) {
                // Materials first (ADR-13): a link the user attached but the
                // pipeline cannot deliver fails the stage - no silent
                // degradation of the protocol.
                try materialsFetcher.fetchIfNeeded(session: session, force: force, onProgress: onProgress)
                return try summarizer.summarize(session: session, onProgress: onProgress)
            }
            updated.metadata.pipeline.status = .done
            updated.metadata.pipeline.claim = nil
            if force {
                // The protocol just changed under previously completed steps:
                // mark them stale. Re-running them (and their external writes)
                // stays a manual decision (ADR-13).
                updated.metadata.pipeline.steps = updated.metadata.pipeline.steps?.map { state in
                    var state = state
                    if state.status == StepState.done { state.status = StepState.stale }
                    return state
                }
            }
            try store.save(updated)
            AppLog.pipeline.info("summarize done session=\(session.id, privacy: .public) duration=\(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")
            return updated
        } catch {
            AppLog.pipeline.error("summarize failed session=\(session.id, privacy: .public): \(AppLog.describe(error), privacy: .public)")
            try? recordFailure(folder: session.folder, error: error)
            throw error
        }
    }

    /// Runs `body` while renewing the claim heartbeat on a background timer, so
    /// a long step (minutes of `large-v3`) never lets the lease go stale and get
    /// taken over by another host (ADR-4).
    private func withHeartbeat<T>(folder: URL, _ body: () throws -> T) rethrows -> T {
        let store = container.store
        let device = deviceId
        let interval = Claim.leaseDuration / 3
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { _ = try? store.renewClaim(deviceId: device, in: folder) }
        timer.resume()
        defer { timer.cancel() }
        return try body()
    }

    private func recordFailure(folder: URL, error: Error) throws {
        let store = container.store
        var session = try store.load(folder: folder)
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        session.metadata.pipeline.status = .failed(message: message)
        session.metadata.pipeline.claim = nil
        try store.save(session)
    }
}
