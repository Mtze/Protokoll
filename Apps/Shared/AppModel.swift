import Foundation
import Observation
import SharedKit
import Diagnostics
import SearchIndex
import MediaKit

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
    /// True from the moment Stop is pressed until the CAF->m4a export / mix
    /// finishes. The stop button reads it to disable itself so a second tap can't
    /// re-enter `stopRecording` during the multi-second export (which would throw
    /// `notRecording`). Cleared even if the export fails.
    private(set) var isStopping = false
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
    /// Set after a recording whose input clipped; the library shows it as a
    /// dismissible banner. Cleared when a new recording starts.
    var inputClippedWarning: String?

    /// Shared reference so the `NSApplicationDelegate` can gate quit on active
    /// work (confirm-on-quit, ADR-4).
    static weak var shared: AppModel?

    init(container: Container = AppEnvironment.makeContainer()) {
        self.container = container
        self.deviceId = AppEnvironment.deviceId
        let device = self.deviceId
        self.scheduler = Scheduler(container: container) {
            guard let binary = HelperLocator.processSessionBinary() else { return nil }
            let config = try? container.loadPipelineConfig()
            return PipelineRunner(binary: binary, deviceId: device,
                                  runner: ProcessCommandRunner(),
                                  environment: HelperLocator.pipelineEnvironment(config: config))
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

    /// Reloads just the project/tag definitions (after Settings edits, F7).
    func reloadProjects() {
        projects = (try? container.loadProjects()) ?? []
    }

    /// Resolves a session's project IDs to `Project`s (unknown IDs skipped).
    func projects(for session: Session) -> [Project] {
        let ids = Set(session.metadata.projects)
        return projects.filter { ids.contains($0.id) }
    }

    /// Assigns a session to `ids` projects: persists metadata, reloads, and
    /// rebuilds the index so project-filtered search stays correct (F7).
    func setProjects(_ ids: [String], for session: Session) {
        var updated = session
        updated.metadata.projects = ids
        try? container.store.save(updated)
        reloadSessions()
        Task { await rebuildIndex() }
    }

    /// Renames a session by persisting a custom title (F9). An empty title clears
    /// it, reverting `displayTitle` to the derived name. Reindexes so search
    /// matches the new title.
    func rename(_ session: Session, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = session
        updated.metadata.title = trimmed.isEmpty ? nil : trimmed
        try? container.store.save(updated)
        reloadSessions()
        Task { await rebuildIndex() }
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
        guard !isStopping else { return }
        guard await Recorder.requestMicrophoneAccess() else {
            health = .red
            return
        }
        do {
            let session = try container.createSession(device: .mac)
            // Opt-in OS echo cancellation on the mic path (Settings > Recording).
            let voiceProcessing = UserDefaults.standard.bool(forKey: SettingsKeys.voiceProcessing)
            let inputDeviceUID = UserDefaults.standard.string(forKey: SettingsKeys.preferredInputDeviceUID)
            try await recorder.start(
                session: session,
                voiceProcessing: voiceProcessing,
                inputDeviceUID: (inputDeviceUID?.isEmpty ?? true) ? nil : inputDeviceUID
            )
            isRecording = true
            activeRecordingID = session.id
            startLevelMonitoring()
            systemAudioError = nil
            inputClippedWarning = nil
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
        guard isRecording, !isStopping else { return }
        isStopping = true
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
            #if os(macOS)
            // Clipping cannot be repaired after the fact, so say so now rather
            // than let it silently cost transcription accuracy.
            if await recorder.didClip {
                inputClippedWarning = String(localized: "recording.warning.clipped")
            }
            #endif
        } catch {
            // Leave whatever was captured; recovery handles the CAF on relaunch.
        }
        isRecording = false
        activeRecordingID = nil
        stopLevelMonitoring()
        // Clear last, so a view observing `isStopping` re-renders once mic.m4a is
        // finalized and reloadSessions() has refreshed the list - the moment the
        // player and Process action become valid.
        isStopping = false
        reloadSessions()
    }

    // MARK: Import

    /// Surfaced when importing a pre-recorded file failed (unsupported codec,
    /// no audio track, disk error), so it never fails silently.
    private(set) var importError: String?

    /// Imports an existing audio file as a normal session: creates the folder,
    /// transcodes the audio into the canonical `mic.m4a`, and leaves the session
    /// `.recorded` - exactly the on-disk shape a live recording produces. No
    /// `process()` call: the existing `NewSessionNotifier` (auto-process setting)
    /// / notification / Process paths take over just as they do for a recording.
    func importAudio(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var created: Session?
        do {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let startedAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
            var session = try container.createSession(device: .mac, startedAt: startedAt)
            created = session
            try await AudioImporter.makeMicTrack(from: url, into: session.micAudioURL)
            if let duration = await AudioImporter.duration(of: session.micAudioURL) {
                session.metadata.duration = duration
                session.metadata.endedAt = startedAt.addingTimeInterval(duration)
            }
            session.metadata.audioTracks = [.mic]
            session.metadata.pipeline.status = .recorded
            try container.store.save(session)
            importError = nil
            reloadSessions()
        } catch {
            // Roll back the half-built session so no broken .recorded folder is
            // left in the library or picked up by the notifier.
            if let created { try? container.deleteSession(created) }
            importError = (error as? LocalizedError)?.errorDescription ?? String(localized: "import.error.failed")
            AppLog.recording.error("audio import failed: \(AppLog.describe(error), privacy: .public)")
        }
    }

    /// Dismisses the import-error alert.
    func clearImportError() { importError = nil }

    /// Dismisses the system-audio / screen-recording warning banner.
    func clearSystemAudioError() { systemAudioError = nil }

    // MARK: Recording meter

    private func startLevelMonitoring() {
        recordingStartedAt = Date()
        recordingLevels = Array(repeating: 0, count: levelBarCount)
        let barCount = levelBarCount
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { break }
                let mic = self.recorder.meter.value
                #if os(macOS)
                // While capturing system audio (F2), light the waveform for either
                // source so the other side of the call shows up too.
                let level = self.capturingSystemAudio
                    ? RecordingLevel.combined(mic: mic, system: self.systemAudio.currentLevel())
                    : mic
                #else
                let level = mic
                #endif
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

    /// Whether re-transcription makes sense: there is audio to work from, a
    /// transcript already exists (otherwise plain Process is the right action),
    /// and nothing is currently running for this session.
    func canRetranscribe(_ session: Session) -> Bool {
        guard activeJob(for: session.id) == nil else { return false }
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: session.micAudioURL.path)
            && fileManager.fileExists(atPath: session.transcriptURL.path)
    }

    /// Re-runs transcription from the audio, then rebuilds the protocol from the
    /// new transcript (ADR-11).
    ///
    /// Useful after changing the transcription language, vocabulary or model, or
    /// after installing a better engine - an early transcript may contain
    /// hallucination loops the current pipeline no longer produces. The previous
    /// transcript and protocol are rotated to `transcript.vN.md` /
    /// `protocol.vN.md`, so nothing is lost.
    func retranscribe(_ session: Session) {
        scheduler.clearCompleted()
        scheduler.enqueueProcess(session, force: true)
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
        let provider = (try? container.loadPipelineConfig())?.summaryProvider ?? "cli"
        let checks = DiagnosticsRunner.standardChecks(containerRoot: root, summaryProvider: provider) + appChecks
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
