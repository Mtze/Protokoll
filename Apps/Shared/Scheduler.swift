import Foundation
import Observation
import SharedKit

/// A processing job tracked for the UI.
@MainActor
@Observable
final class ProcessingJob: Identifiable {
    enum State: Equatable {
        case queued
        case running
        case finished
        case failed(String)
    }

    let id = UUID()
    let sessionID: String
    let title: String
    var step: PipelineRunStep
    var state: State = .queued
    /// Last progress line from the engine (shown in the UI).
    var progress: String = ""

    init(sessionID: String, title: String, step: PipelineRunStep) {
        self.sessionID = sessionID
        self.title = title
        self.step = step
    }
}

extension PipelineRunStep {
    /// Localization key for job rows ("Transcribing" / "Summarizing" / "Actions").
    var labelKey: String {
        switch self {
        case .transcribe: return "step.transcribe"
        case .summarize: return "step.summarize"
        case .actions, .action: return "step.actions"
        }
    }
}

/// The resource-aware scheduler (ADR-4). Not a single global serial queue:
/// **transcribe = 1 globally**, and **one summarize may overlap a transcribe**.
/// Decoupled from the UI so a launchd daemon or a second Mac can host the same
/// core later (NH2). Runs the pipeline binary via ``PipelineRunner``.
@MainActor
@Observable
final class Scheduler {
    private(set) var jobs: [ProcessingJob] = []

    private var transcribeBusy = false
    private var summarizeBusy = false
    // `force` travels with the queued transcribe for the same reason it does for
    // summarize: a re-transcription must not be skipped because transcript.md
    // already exists.
    private var transcribeQueue: [(folder: URL, job: ProcessingJob, force: Bool)] = []
    // `force` travels with the queued job so a regenerate isn't dequeued by a
    // later default-force pump (which would see protocol.md and skip, breaking
    // N10 rotation).
    private var summarizeQueue: [(folder: URL, job: ProcessingJob, force: Bool)] = []
    // Action steps (ADR-13) get their own slot: they are network/MCP-bound and
    // can run for minutes - in the summarize slot they would starve other
    // sessions' local summaries. Per-session ordering still holds via the
    // summarize claim in the pipeline.
    private var actionsBusy = false
    private var actionsQueue: [(folder: URL, job: ProcessingJob, force: Bool)] = []

    private let container: Container
    private let makeRunner: @Sendable () -> PipelineRunner?

    /// Called on the main actor after any step finishes (success or failure) so
    /// the UI can reload sessions/index and reflect the new state.
    var onFinished: (@MainActor () -> Void)?

    /// Called once when a session's whole chain ends (no follow-up job queued
    /// or running for it), with whether the final job succeeded. Drives the
    /// completion notification (F13 counterpart).
    var onSessionCompleted: (@MainActor (_ sessionID: String, _ success: Bool) -> Void)?

    /// Fires ``onSessionCompleted`` unless the session still has work queued
    /// or running (the finishing job's state is already final here).
    private func chainEnded(for sessionID: String, success: Bool) {
        let stillWorking = jobs.contains {
            $0.sessionID == sessionID && ($0.state == .queued || $0.state == .running)
        }
        if !stillWorking { onSessionCompleted?(sessionID, success) }
    }

    init(container: Container, makeRunner: @escaping @Sendable () -> PipelineRunner?) {
        self.container = container
        self.makeRunner = makeRunner
    }

    /// Whether any job is running or queued (used for confirm-on-quit).
    var hasActiveWork: Bool {
        jobs.contains { $0.state == .queued || $0.state == .running }
    }

    /// Enqueues a full process (transcribe → summarize) for a session.
    ///
    /// `force` re-runs transcription even though `transcript.md` exists, and
    /// carries through to the chained summarize so the protocol is rebuilt from
    /// the *new* transcript rather than left describing the old one. The previous
    /// transcript and protocol are rotated, not destroyed (ADR-11).
    func enqueueProcess(_ session: Session, force: Bool = false) {
        let transcribeJob = ProcessingJob(sessionID: session.id, title: session.displayTitle, step: .transcribe)
        jobs.append(transcribeJob)
        transcribeQueue.append((session.folder, transcribeJob, force))
        AppLog.scheduler.info("job enqueued session=\(session.id, privacy: .public) step=transcribe force=\(force, privacy: .public)")
        pumpTranscribe()
    }

    /// Enqueues only a summarize (e.g. regenerate protocol).
    func enqueueSummarize(_ session: Session, force: Bool = false) {
        let job = ProcessingJob(sessionID: session.id, title: session.displayTitle, step: .summarize)
        jobs.append(job)
        summarizeQueue.append((session.folder, job, force))
        AppLog.scheduler.info("job enqueued session=\(session.id, privacy: .public) step=summarize force=\(force, privacy: .public)")
        pumpSummarize()
    }

    /// Enqueues the session's custom action steps (ADR-13): all pending ones,
    /// or one specific step when `only` is set (re-run of a failed/stale step).
    func enqueueActions(_ session: Session, only stepID: String? = nil, force: Bool = false) {
        let step: PipelineRunStep = stepID.map { .action($0) } ?? .actions
        let job = ProcessingJob(sessionID: session.id, title: session.displayTitle, step: step)
        jobs.append(job)
        actionsQueue.append((session.folder, job, force))
        AppLog.scheduler.info("job enqueued session=\(session.id, privacy: .public) step=\(step.argument, privacy: .public) force=\(force, privacy: .public)")
        pumpActions()
    }

    /// Whether the session's resolved pipeline still has enabled steps that
    /// never completed - drives the summarize -> actions chain. Stale/failed
    /// steps are deliberately not auto-rerun (external writes stay manual).
    private func hasPendingActions(_ session: Session) -> Bool {
        let pipelines = (try? container.loadPipelines()) ?? PipelinesConfig()
        let projects = (try? container.loadProjects()) ?? []
        guard let pipeline = PipelineResolver.resolve(session: session.metadata,
                                                      projects: projects, config: pipelines) else {
            return false
        }
        let states = Dictionary(uniqueKeysWithValues:
            (session.metadata.pipeline.steps ?? []).map { ($0.stepID, $0.status) })
        return pipeline.steps.contains { step in
            step.enabled && (states[step.id] ?? StepState.pending) == StepState.pending
        }
    }

    // MARK: Pumps (two independent slots)

    private func pumpTranscribe() {
        guard !transcribeBusy, !transcribeQueue.isEmpty else { return }
        let (folder, job, force) = transcribeQueue.removeFirst()
        transcribeBusy = true
        job.state = .running
        AppLog.scheduler.info("job started session=\(job.sessionID, privacy: .public) step=transcribe")
        runStep(folder: folder, step: .transcribe, force: force, job: job) { [weak self] outcome in
            guard let self else { return }
            self.transcribeBusy = false
            switch outcome {
            case .success:
                job.state = .finished
                AppLog.scheduler.info("job finished session=\(job.sessionID, privacy: .public) step=transcribe")
                // Chain into a summarize once transcription lands. A forced
                // re-transcription forces the summarize too: otherwise
                // protocol.md still exists, the step is skipped, and the session
                // is left with a protocol describing the previous transcript.
                if let session = try? self.container.store.load(folder: folder) {
                    self.enqueueSummarize(session, force: force)
                }
            case let .failure(message):
                job.state = .failed(message)
                AppLog.scheduler.error("job failed session=\(job.sessionID, privacy: .public) step=transcribe: \(message, privacy: .public)")
                self.chainEnded(for: job.sessionID, success: false)
            }
            self.onFinished?()
            self.pumpTranscribe()
        }
    }

    private func pumpSummarize() {
        guard !summarizeBusy, !summarizeQueue.isEmpty else { return }
        let (folder, job, force) = summarizeQueue.removeFirst()
        summarizeBusy = true
        job.state = .running
        AppLog.scheduler.info("job started session=\(job.sessionID, privacy: .public) step=summarize")
        runStep(folder: folder, step: .summarize, force: force, job: job) { [weak self] outcome in
            guard let self else { return }
            self.summarizeBusy = false
            switch outcome {
            case .success:
                job.state = .finished
                AppLog.scheduler.info("job finished session=\(job.sessionID, privacy: .public) step=summarize")
                // Chain into the pipeline's custom actions (ADR-13) when any
                // enabled step has never completed.
                if let session = try? self.container.store.load(folder: folder),
                   self.hasPendingActions(session) {
                    self.enqueueActions(session)
                } else {
                    self.chainEnded(for: job.sessionID, success: true)
                }
            case let .failure(message):
                job.state = .failed(message)
                AppLog.scheduler.error("job failed session=\(job.sessionID, privacy: .public) step=summarize: \(message, privacy: .public)")
                self.chainEnded(for: job.sessionID, success: false)
            }
            self.onFinished?()
            self.pumpSummarize()
        }
    }

    private func pumpActions() {
        guard !actionsBusy, !actionsQueue.isEmpty else { return }
        let (folder, job, force) = actionsQueue.removeFirst()
        actionsBusy = true
        job.state = .running
        AppLog.scheduler.info("job started session=\(job.sessionID, privacy: .public) step=\(job.step.argument, privacy: .public)")
        runStep(folder: folder, step: job.step, force: force, job: job) { [weak self] outcome in
            guard let self else { return }
            self.actionsBusy = false
            switch outcome {
            case .success:
                job.state = .finished
                AppLog.scheduler.info("job finished session=\(job.sessionID, privacy: .public) step=\(job.step.argument, privacy: .public)")
                self.chainEnded(for: job.sessionID, success: true)
            case let .failure(message):
                job.state = .failed(message)
                AppLog.scheduler.error("job failed session=\(job.sessionID, privacy: .public) step=\(job.step.argument, privacy: .public): \(message, privacy: .public)")
                self.chainEnded(for: job.sessionID, success: false)
            }
            self.onFinished?()
            self.pumpActions()
        }
    }

    private enum StepOutcome { case success; case failure(String) }

    /// Runs one step off the main actor (the subprocess call is blocking) and
    /// hops back to the main actor for UI updates.
    private func runStep(
        folder: URL,
        step: PipelineRunStep,
        force: Bool = false,
        job: ProcessingJob,
        completion: @escaping @MainActor (StepOutcome) -> Void
    ) {
        guard let runner = makeRunner() else {
            completion(.failure(String(localized: "scheduler.error.noBinary")))
            return
        }
        Task.detached(priority: .userInitiated) {
            // The secret files materialized for this run (ADR-9/ADR-13) are
            // single-use: delete them as soon as the subprocess is done rather
            // than waiting for the next stale-pruning pass.
            defer {
                for key in ["CONNECTION_KEYS_FILE", "SUMMARY_API_KEY_FILE"] {
                    if let path = runner.environment[key] {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            }
            let outcome: StepOutcome
            do {
                try runner.run(folder: folder, step: step, force: force) { line in
                    Task { @MainActor in job.progress = line }
                }
                outcome = .success
            } catch {
                outcome = .failure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
            await MainActor.run { completion(outcome) }
        }
    }

    /// Clears finished/failed jobs from the list.
    func clearCompleted() {
        jobs.removeAll { job in
            if case .queued = job.state { return false }
            if case .running = job.state { return false }
            return true
        }
    }
}
