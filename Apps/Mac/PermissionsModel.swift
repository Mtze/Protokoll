import AVFoundation
import CoreGraphics
import Observation
import SharedKit
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

/// Shared microphone / Screen Recording / notification permission state and the
/// in-app request actions. Used by first-run onboarding and the Settings
/// diagnostics panel so both drive one source of truth.
@MainActor
@Observable
final class PermissionsModel {
    enum Access { case unknown, granted, denied }

    private(set) var mic: Access = .unknown
    private(set) var screen: Access = .unknown
    private(set) var notify: Access = .unknown

    func requestMic() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            mic = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
            if mic == .denied { openSettings("Privacy_Microphone") }
        }
    }

    func requestScreen() {
        // Triggers the prompt and adds Protokoll to the Screen Recording list;
        // macOS often reports the grant only after a relaunch, so on false we
        // also open the settings pane.
        let granted = CGRequestScreenCaptureAccess()
        screen = granted ? .granted : .denied
        if !granted { openSettings("Privacy_ScreenCapture") }
    }

    func requestNotify() {
        Task {
            // requestAuthorization is what registers the app with the notification
            // system (so it shows up in System Settings) and, when the status is
            // not-determined, shows the prompt. Don't swallow failures silently.
            var granted = false
            do {
                granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } catch {
                AppLog.diagnostics.error("notification authorization request failed: \(AppLog.describe(error), privacy: .public)")
            }
            notify = granted ? .granted : .denied
            if !granted { openNotificationSettings() }
        }
    }

    func refresh() async {
        mic = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        screen = CGPreflightScreenCaptureAccess() ? .granted : .unknown
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notify = .granted
        case .denied: notify = .denied
        default: notify = .unknown
        }
    }

    static func map(_ status: AVAuthorizationStatus) -> Access {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    func openSettings(_ pane: String) {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// On macOS 13+ Notifications is its own top-level System Settings pane, not a
    /// Privacy subpane, so it needs a dedicated URL rather than openSettings(_:).
    func openNotificationSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
