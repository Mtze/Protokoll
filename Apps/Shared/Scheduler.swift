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
    var step: PipelineStep
    var state: State = .queued
    /// Last progress line from the engine (shown in the UI).
    var progress: String = ""

    init(sessionID: String, title: String, step: PipelineStep) {
        self.sessionID = sessionID
        self.title = title
        self.step = step
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
    private var transcribeQueue: [(folder: URL, job: ProcessingJob)] = []
    // `force` travels with the queued job so a regenerate isn't dequeued by a
    // later default-force pump (which would see protocol.md and skip, breaking
    // N10 rotation).
    private var summarizeQueue: [(folder: URL, job: ProcessingJob, force: Bool)] = []

    private let container: Container
    private let makeRunner: @Sendable () -> PipelineRunner?

    /// Called on the main actor after any step finishes (success or failure) so
    /// the UI can reload sessions/index and reflect the new state.
    var onFinished: (@MainActor () -> Void)?

    init(container: Container, makeRunner: @escaping @Sendable () -> PipelineRunner?) {
        self.container = container
        self.makeRunner = makeRunner
    }

    /// Whether any job is running or queued (used for confirm-on-quit).
    var hasActiveWork: Bool {
        jobs.contains { $0.state == .queued || $0.state == .running }
    }

    /// Enqueues a full process (transcribe → summarize) for a session.
    func enqueueProcess(_ session: Session) {
        let transcribeJob = ProcessingJob(sessionID: session.id, title: session.displayTitle, step: .transcribe)
        jobs.append(transcribeJob)
        transcribeQueue.append((session.folder, transcribeJob))
        pumpTranscribe()
    }

    /// Enqueues only a summarize (e.g. regenerate protocol).
    func enqueueSummarize(_ session: Session, force: Bool = false) {
        let job = ProcessingJob(sessionID: session.id, title: session.displayTitle, step: .summarize)
        jobs.append(job)
        summarizeQueue.append((session.folder, job, force))
        pumpSummarize()
    }

    // MARK: Pumps (two independent slots)

    private func pumpTranscribe() {
        guard !transcribeBusy, !transcribeQueue.isEmpty else { return }
        let (folder, job) = transcribeQueue.removeFirst()
        transcribeBusy = true
        job.state = .running
        runStep(folder: folder, step: .transcribe, job: job) { [weak self] outcome in
            guard let self else { return }
            self.transcribeBusy = false
            switch outcome {
            case .success:
                job.state = .finished
                // Chain into a summarize once transcription lands.
                if let session = try? self.container.store.load(folder: folder) {
                    self.enqueueSummarize(session)
                }
            case let .failure(message):
                job.state = .failed(message)
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
        runStep(folder: folder, step: .summarize, force: force, job: job) { [weak self] outcome in
            guard let self else { return }
            self.summarizeBusy = false
            switch outcome {
            case .success: job.state = .finished
            case let .failure(message): job.state = .failed(message)
            }
            self.onFinished?()
            self.pumpSummarize()
        }
    }

    private enum StepOutcome { case success; case failure(String) }

    /// Runs one step off the main actor (the subprocess call is blocking) and
    /// hops back to the main actor for UI updates.
    private func runStep(
        folder: URL,
        step: PipelineStep,
        force: Bool = false,
        job: ProcessingJob,
        completion: @escaping @MainActor (StepOutcome) -> Void
    ) {
        guard let runner = makeRunner() else {
            completion(.failure(String(localized: "scheduler.error.noBinary")))
            return
        }
        Task.detached(priority: .userInitiated) {
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
