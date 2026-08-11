import Foundation
import Observation
import SharedKit
import Diagnostics
import SearchIndex

/// The app-wide observable model shared by the menubar and the library window.
/// Owns the container, the session list, the scheduler, and diagnostics state.
@MainActor
@Observable
final class AppModel {
    let container: Container
    let scheduler: Scheduler
    let deviceId: String

    private(set) var sessions: [Session] = []
    private(set) var isRecording = false
    private(set) var activeRecordingID: String?

    // Live recording meter (N4 visible indicator).
    private(set) var recordingLevels: [Float] = []
    private(set) var recordingStartedAt: Date?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private let levelBarCount = 48

    // Search (F10)
    private(set) var searchResults: [SearchHit] = []
    private let index: SearchIndex? = try? SearchIndex(path: SearchIndex.defaultURL())
    private(set) var projects: [Project] = []

    // Diagnostics
    private(set) var checkResults: [CheckResult] = []
    private(set) var health: HealthLevel = .yellow
    private(set) var isRunningDiagnostics = false

    private let recorder = Recorder()
    #if os(macOS)
    private let systemAudio = SystemAudioController(capture: SystemAudioRecorder())
    private var capturingSystemAudio = false
    #endif
    /// Surfaced when system-audio capture (F2) was requested but failed or
    /// produced nothing - so it never fails silently to mic-only again.
    private(set) var systemAudioError: String?

    /// Shared reference so the `NSApplicationDelegate` can gate quit on active
    /// work (confirm-on-quit, ADR-4).
    static weak var shared: AppModel?

    init(container: Container = AppEnvironment.makeContainer()) {
        self.container = container
        self.deviceId = AppEnvironment.deviceId
        let device = self.deviceId
        self.scheduler = Scheduler(container: container) {
            guard let binary = HelperLocator.processSessionBinary() else { return nil }
            return PipelineRunner(binary: binary, deviceId: device,
                                  runner: ProcessCommandRunner(),
                                  environment: HelperLocator.pipelineEnvironment())
        }
        AppModel.shared = self
        // Refresh the list, index, and detail once a step finishes so the new
        // transcript/protocol appear without a manual reload.
        scheduler.onFinished = { [weak self] in
            self?.reloadSessions()
            Task { await self?.rebuildIndex() }
        }
    }

    #if os(macOS)
    @ObservationIgnored private var notifier: NewSessionNotifier?
    #endif

    @ObservationIgnored private var didBootstrap = false

    /// Loads the session list and recovers any crashed recordings (ADR-3).
    /// Idempotent: safe if the primary window reopens after being closed.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await Recorder.recoverOrphans(in: container)
        reloadSessions()
        await rebuildIndex()
        await runDiagnostics()
        #if os(macOS)
        // Watch for new/iCloud-arrived sessions (F13).
        let notifier = NewSessionNotifier(container: container) { [weak self] session in
            self?.process(session)
        }
        notifier.start()
        self.notifier = notifier
        #endif
    }

    func reloadSessions() {
        sessions = (try? container.allSessions()) ?? []
        projects = (try? container.loadProjects()) ?? []
    }

    /// Rebuilds the local FTS index from the files (ADR-2).
    func rebuildIndex() async {
        guard let index else { return }
        let container = self.container
        try? await index.rebuild(from: container)
    }

    /// Full-text search across transcript + protocol (F10).
    func search(_ text: String, filter: SearchFilter = .none) async {
        guard let index, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? await index.search(text, filter: filter)) ?? []
    }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard await Recorder.requestMicrophoneAccess() else {
            health = .red
            return
        }
        do {
            let session = try container.createSession(device: .mac)
            try await recorder.start(session: session)
            isRecording = true
            activeRecordingID = session.id
            startLevelMonitoring()
            systemAudioError = nil
            #if os(macOS)
            // Optionally capture system audio in parallel (F2). Surface failures
            // instead of silently recording mic-only.
            if UserDefaults.standard.bool(forKey: SettingsKeys.captureSystemAudio) {
                let outcome = await systemAudio.begin(to: session.systemAudioURL)
                capturingSystemAudio = outcome.capturing
                systemAudioError = outcome.error
            }
            #endif
            reloadSessions()
        } catch {
            isRecording = false
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        #if os(macOS)
        var systemProduced = false
        if capturingSystemAudio {
            systemProduced = await systemAudio.end()
            capturingSystemAudio = false
            if !systemProduced {
                systemAudioError = String(localized: "systemaudio.error.empty")
            }
        }
        #endif
        do {
            // Mix the system-audio track into the single mic.m4a so the whole
            // call is transcribed (ADR-7), not just the mic.
            #if os(macOS)
            var session = try await recorder.stop(mixSystemAudio: systemProduced)
            #else
            var session = try await recorder.stop()
            #endif
            session.metadata.pipeline.status = .recorded
            try container.store.save(session)
        } catch {
            // Leave whatever was captured; recovery handles the CAF on relaunch.
        }
        isRecording = false
        activeRecordingID = nil
        stopLevelMonitoring()
        reloadSessions()
    }

    // MARK: Recording meter

    private func startLevelMonitoring() {
        recordingStartedAt = Date()
        recordingLevels = Array(repeating: 0, count: levelBarCount)
        let barCount = levelBarCount
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { break }
                let level = self.recorder.meter.value
                var levels = self.recordingLevels
                levels.append(level)
                if levels.count > barCount { levels.removeFirst(levels.count - barCount) }
                self.recordingLevels = levels
                try? await Task.sleep(nanoseconds: 55_000_000)
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTask?.cancel()
        levelTask = nil
        recordingLevels = []
        recordingStartedAt = nil
    }

    // MARK: Processing

    func process(_ session: Session) {
        scheduler.enqueueProcess(session)
    }

    /// Clears a session's finished/failed jobs and processes it again.
    func retry(_ session: Session) {
        scheduler.clearCompleted()
        scheduler.enqueueProcess(session)
    }

    /// The in-flight (queued/running/failed) job for a session, if any.
    func activeJob(for sessionID: String) -> ProcessingJob? {
        scheduler.jobs.last { $0.sessionID == sessionID && $0.state != .finished }
    }

    func regenerateProtocol(_ session: Session) {
        scheduler.enqueueSummarize(session, force: true)
    }

    /// Deletes a session: removes its folder from disk (Trash on macOS), drops it
    /// from the in-memory list, and prunes it from the FTS index (ADR-2).
    func deleteSession(_ session: Session) {
        try? container.deleteSession(session)
        sessions.removeAll { $0.id == session.id }
        let id = session.id
        Task { [index] in try? await index?.remove(id: id) }
    }

    /// Sessions that still need processing (F13 surfacing).
    var unprocessedSessions: [Session] {
        sessions.filter { $0.metadata.pipeline.status == .recorded }
    }

    // MARK: Diagnostics

    func runDiagnostics() async {
        isRunningDiagnostics = true
        let root = try? container.root()
        // Append the app-evaluated microphone permission check (the shell runner
        // can't resolve TCC).
        var appChecks: [any DiagnosticCheck] = [MicrophoneCheck()]
        #if os(macOS)
        appChecks.append(ScreenRecordingCheck())
        #endif
        let checks = DiagnosticsRunner.standardChecks(containerRoot: root) + appChecks
        let runner = DiagnosticsRunner(checks: checks)
        let results = await Task.detached { runner.runAll() }.value
        checkResults = results
        health = HealthLevel.aggregate(results)
        isRunningDiagnostics = false
    }

    func remediation(for id: CheckID) -> Remediation {
        var appChecks: [any DiagnosticCheck] = [MicrophoneCheck()]
        #if os(macOS)
        appChecks.append(ScreenRecordingCheck())
        #endif
        let checks = DiagnosticsRunner.standardChecks(containerRoot: try? container.root()) + appChecks
        return DiagnosticsRunner(checks: checks).remediation(for: id)
    }
}
