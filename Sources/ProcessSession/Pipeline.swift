import Foundation
import SharedKit

/// Which step(s) to run.
public enum PipelineStepSelection: String, Sendable {
    case transcribe
    case summarize
    case all
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

        if step == .transcribe || step == .all {
            let alreadyDone = FileManager.default.fileExists(atPath: session.transcriptURL.path)
            if force || !alreadyDone {
                session = try runTranscribe(session: session, onProgress: onProgress)
            }
        }

        if step == .summarize || step == .all {
            let alreadyDone = FileManager.default.fileExists(atPath: session.protocolURL.path)
            if force || !alreadyDone {
                session = try runSummarize(session: session, onProgress: onProgress)
            }
        }

        return session
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

    private func runSummarize(session: Session, onProgress: (@Sendable (String) -> Void)?) throws -> Session {
        let store = container.store
        let name = AppLog.folderName(session.folder)
        AppLog.pipeline.info("summarize start session=\(session.id, privacy: .public) folder=\(name, privacy: .public)")
        let started = Date()
        _ = try store.acquireClaim(step: .summarize, deviceId: deviceId, in: session.folder)
        _ = try store.setStatus(.summarizing, in: session.folder)
        do {
            var updated = try withHeartbeat(folder: session.folder) {
                try summarizer.summarize(session: session, onProgress: onProgress)
            }
            updated.metadata.pipeline.status = .done
            updated.metadata.pipeline.claim = nil
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
