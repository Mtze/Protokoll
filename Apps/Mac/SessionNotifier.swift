import Foundation
import SharedKit
import UserNotifications

/// Watches the container for new, unprocessed sessions (e.g. an iCloud-arrived
/// iPhone recording) and posts a local notification with a "Process" action
/// (F13, ADR-1: processing stays a conscious user decision). Tapping the action
/// enqueues the job on the scheduler, respecting the claim/lease so a second
/// host doesn't double-process (ADR-4).
@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let container: Container
    private let onProcess: (Session) -> Void
    /// Sessions to leave alone *for now* without marking them known: the one
    /// still recording and the one showing the post-stop materials card
    /// (ADR-13) - once stopped, `mic.m4a` exists, so without this hold
    /// auto-process would race the card the user is still filling in.
    private let isHeld: (String) -> Bool
    private var knownIDs: Set<String> = []
    private var timer: Timer?

    /// Invoked when the user taps a "processing finished" notification, with
    /// the session id to surface.
    private let onReveal: (String) -> Void

    private nonisolated static let actionProcess = "PROCESS"
    private nonisolated static let categoryNew = "NEW_SESSION"
    private nonisolated static let categoryDone = "SESSION_DONE"

    init(container: Container,
         isHeld: @escaping (String) -> Bool = { _ in false },
         onReveal: @escaping (String) -> Void = { _ in },
         onProcess: @escaping (Session) -> Void) {
        self.container = container
        self.isHeld = isHeld
        self.onReveal = onReveal
        self.onProcess = onProcess
        super.init()
    }

    /// Requests notification authorization, registers the action, and starts
    /// polling. The first scan seeds the baseline so existing sessions don't
    /// fire a notification.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(
            identifier: Self.actionProcess,
            title: String(localized: "action.process"),
            options: [.foreground]
        )
        let newCategory = UNNotificationCategory(
            identifier: Self.categoryNew, actions: [action], intentIdentifiers: []
        )
        // Completion notifications have no buttons; tapping them reveals the
        // session.
        let doneCategory = UNNotificationCategory(
            identifier: Self.categoryDone, actions: [], intentIdentifiers: []
        )
        center.setNotificationCategories([newCategory, doneCategory])
        // Authorization is requested during onboarding, not at launch, so the
        // app doesn't fire a surprise notification prompt. If not granted, macOS
        // silently drops the notifications below.

        knownIDs = Set((try? container.allSessions())?.map(\.id) ?? [])
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func scan() {
        let sessions = (try? container.allSessions()) ?? []
        let defaults = UserDefaults.standard
        let autoProcess = defaults.bool(forKey: SettingsKeys.autoProcess)
        // Notifications default on when the user hasn't set the toggle.
        let notificationsOn = defaults.object(forKey: SettingsKeys.notificationsEnabled) as? Bool ?? true
        for session in sessions where !knownIDs.contains(session.id) {
            // Held sessions (recording in progress, post-stop card showing) are
            // skipped without being marked known, so a later scan still
            // evaluates them fresh.
            if isHeld(session.id) { continue }
            // A live recording / in-progress import writes session.json as
            // .recorded before audio/mic.m4a exists; wait for the audio before
            // acting, and don't mark the session known yet so a later scan still
            // picks it up once the file lands (the importer's atomic rename
            // guarantees it appears complete, never partial).
            if session.metadata.pipeline.status == .recorded,
               !FileManager.default.fileExists(atPath: session.micAudioURL.path) {
                continue
            }
            knownIDs.insert(session.id)
            guard session.metadata.pipeline.status == .recorded else { continue }
            if autoProcess {
                onProcess(session)               // process automatically (Settings)
            } else if notificationsOn {
                notify(session)                  // otherwise nudge with a notification
            }
        }
    }

    /// Posts the "processing finished" notification once a session's whole
    /// chain succeeded (F13 counterpart; only on success and status `.done` -
    /// failures stay in-app). Respects the notifications toggle.
    func notifyCompleted(_ session: Session) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKeys.notificationsEnabled) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notify.done.title")
        let steps = session.metadata.pipeline.steps ?? []
        if steps.isEmpty {
            content.body = String(localized: "notify.done.body \(session.displayTitle)")
        } else {
            let failed = steps.filter { $0.status == StepState.failed }.count
            if failed == 0 {
                content.body = String(localized: "notify.done.body.actions \(session.displayTitle) \(steps.count)")
            } else {
                content.body = String(localized: "notify.done.body.failed \(session.displayTitle) \(failed)")
            }
        }
        content.categoryIdentifier = Self.categoryDone
        content.userInfo = ["sessionID": session.id]
        let request = UNNotificationRequest(identifier: "done-\(session.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notify(_ session: Session) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notify.new.title")
        content.body = String(localized: "notify.new.body \(session.displayTitle)")
        content.categoryIdentifier = Self.categoryNew
        content.userInfo = ["sessionID": session.id]
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    @MainActor private func handleProcess(id: String) {
        guard let session = try? container.session(id: id) else { return }
        onProcess(session)
    }

    // MARK: UNUserNotificationCenterDelegate
    // nonisolated: the delegate delivers non-Sendable objects; extract the
    // Sendable session id here, then hop to the main actor.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        let category = response.notification.request.content.categoryIdentifier
        if response.actionIdentifier == Self.actionProcess {
            await MainActor.run { self.handleProcess(id: id) }
        } else if category == Self.categoryDone,
                  response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { self.onReveal(id) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
