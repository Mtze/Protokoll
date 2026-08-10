import Foundation
import Observation
import SharedKit
import Diagnostics

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

    // Diagnostics
    private(set) var checkResults: [CheckResult] = []
    private(set) var health: HealthLevel = .yellow
    private(set) var isRunningDiagnostics = false

    private let recorder = Recorder()

    /// Shared reference so the `NSApplicationDelegate` can gate quit on active
    /// work (confirm-on-quit, ADR-4).
    static weak var shared: AppModel?

    init(container: Container = AppEnvironment.makeContainer()) {
        self.container = container
        self.deviceId = AppEnvironment.deviceId
        let device = self.deviceId
        self.scheduler = Scheduler(container: container) {
            guard let binary = HelperLocator.processSessionBinary() else { return nil }
            return PipelineRunner(binary: binary, deviceId: device)
        }
        AppModel.shared = self
    }

    /// Loads the session list and recovers any crashed recordings (ADR-3).
    func bootstrap() async {
        await Recorder.recoverOrphans(in: container)
        reloadSessions()
        await runDiagnostics()
    }

    func reloadSessions() {
        sessions = (try? container.allSessions()) ?? []
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
            reloadSessions()
        } catch {
            isRecording = false
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        do {
            var session = try await recorder.stop()
            session.metadata.pipeline.status = .recorded
            try container.store.save(session)
        } catch {
            // Leave whatever was captured; recovery handles the CAF on relaunch.
        }
        isRecording = false
        activeRecordingID = nil
        reloadSessions()
    }

    // MARK: Processing

    func process(_ session: Session) {
        scheduler.enqueueProcess(session)
    }

    func regenerateProtocol(_ session: Session) {
        scheduler.enqueueSummarize(session, force: true)
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
        let checks = DiagnosticsRunner.standardChecks(containerRoot: root) + [MicrophoneCheck()]
        let runner = DiagnosticsRunner(checks: checks)
        let results = await Task.detached { runner.runAll() }.value
        checkResults = results
        health = HealthLevel.aggregate(results)
        isRunningDiagnostics = false
    }

    func remediation(for id: CheckID) -> Remediation {
        let checks = DiagnosticsRunner.standardChecks(containerRoot: try? container.root()) + [MicrophoneCheck()]
        return DiagnosticsRunner(checks: checks).remediation(for: id)
    }
}
