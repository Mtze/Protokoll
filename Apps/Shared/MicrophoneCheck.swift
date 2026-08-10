import AVFoundation
import Foundation
import Diagnostics
import SharedKit

/// An app-evaluated diagnostic for microphone permission (TCC) - the runner
/// can't resolve this via a shell probe, so the app appends it (as the
/// Diagnostics core anticipates). Guides the user to the exact Settings pane.
struct MicrophoneCheck: DiagnosticCheck {
    let id = CheckID.microphone
    let titleKey = "diag.microphone.title"
    let explanationKey = "diag.microphone.explanation"
    var remediation: Remediation {
        .guided(titleKey: "diag.microphone.fix",
                .systemSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
    }

    func run(runner: CommandRunning) -> CheckResult {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return CheckResult(id: id, outcome: .passed, detail: "authorized")
        case .notDetermined:
            return CheckResult(id: id, outcome: .warning, detail: "not yet requested")
        default:
            return CheckResult(id: id, outcome: .failed, detail: "denied or restricted")
        }
    }
}
