import AVFoundation
import CoreGraphics
import Observation
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
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            notify = granted ? .granted : .denied
            if !granted { openSettings("Privacy_Notifications") }
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
}
