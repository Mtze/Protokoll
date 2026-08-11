import CoreLocation
import Foundation
import Observation
import SharedKit
import SearchIndex

/// iOS app model (F8/F11/F12): records into the same container, lists and views
/// results synced back from the Mac, and searches locally. No processing here.
@MainActor
@Observable
final class IOSAppModel {
    let container: Container
    private(set) var sessions: [Session] = []
    private(set) var projects: [Project] = []
    private(set) var isRecording = false
    private(set) var searchResults: [SearchHit] = []

    // Live recording meter (N4 visible indicator).
    private(set) var recordingLevels: [Float] = []
    private(set) var recordingStartedAt: Date?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private let levelBarCount = 40

    private let recorder = IOSRecorder()
    private let index: SearchIndex? = try? SearchIndex(path: SearchIndex.defaultURL())
    private let location = LocationProvider()
    private var watchReceiver: WatchReceiver?

    init(container: Container = IOSAppModel.makeContainer()) {
        self.container = container
        // Receive watch recordings and file them into the container (ADR-6).
        self.watchReceiver = WatchReceiver(container: container)
    }

    static func makeContainer() -> Container {
        if let override = ProcessInfo.processInfo.environment["MN_CONTAINER_ROOT"], !override.isEmpty {
            return Container(locator: LocalFolderContainer(root: URL(fileURLWithPath: override)))
        }
        // Dev default: local Documents. M3-proven iCloud container is swapped in
        // behind the same seam for production.
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return Container(locator: LocalFolderContainer(root: docs.appendingPathComponent("Protokoll")))
    }

    func bootstrap() async {
        reload()
        await rebuildIndex()
    }

    func reload() {
        sessions = (try? container.allSessions()) ?? []
        projects = (try? container.loadProjects()) ?? []
    }

    /// Resolves a session's project IDs to `Project`s (F7).
    func projects(for session: Session) -> [Project] {
        let ids = Set(session.metadata.projects)
        return projects.filter { ids.contains($0.id) }
    }

    /// Assigns a session to `ids` projects and persists (F7).
    func setProjects(_ ids: [String], for session: Session) {
        var updated = session
        updated.metadata.projects = ids
        try? container.store.save(updated)
        reload()
        Task { await rebuildIndex() }
    }

    func rebuildIndex() async {
        guard let index else { return }
        let container = self.container
        try? await index.rebuild(from: container)
    }

    func search(_ text: String, filter: SearchFilter = .none) async {
        guard let index, !text.trimmingCharacters(in: .whitespaces).isEmpty else { searchResults = []; return }
        searchResults = (try? await index.search(text, filter: filter)) ?? []
    }

    /// Deletes a session: removes its folder from disk, drops it from the list,
    /// and prunes it from the FTS index (ADR-2).
    func deleteSession(_ session: Session) {
        try? container.deleteSession(session)
        sessions.removeAll { $0.id == session.id }
        let id = session.id
        Task { [index] in try? await index?.remove(id: id) }
    }

    // MARK: Recording

    func startRecording(title: String?, includeGeotag: Bool) async {
        guard await IOSRecorder.requestMicrophoneAccess() else { return }
        let geo = includeGeotag ? await location.currentCoordinate() : nil
        do {
            var session = try container.createSession(device: .ios, title: title)
            if let geo { session.metadata.geo = geo; try container.store.save(session) }
            try await recorder.start(session: session)
            isRecording = true
            startLevelMonitoring()
            reload()
        } catch { isRecording = false }
    }

    func stopRecording() async {
        guard isRecording else { return }
        if let session = try? await recorder.stop() {
            var updated = session
            updated.metadata.pipeline.status = .recorded
            try? container.store.save(updated)
        }
        isRecording = false
        stopLevelMonitoring()
        reload()
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
                let level = await self.recorder.currentLevel()
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
}

/// One-shot location fetch for the optional geotag (F8).
private final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<GeoCoordinate?, Never>?

    func currentCoordinate() async -> GeoCoordinate? {
        manager.requestWhenInUseAuthorization()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.first.map { GeoCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        continuation?.resume(returning: coordinate); continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil); continuation = nil
    }
}
