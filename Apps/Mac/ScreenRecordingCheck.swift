import CoreGraphics
import Foundation
import Diagnostics
import SharedKit

/// App-evaluated check for Screen Recording permission, required for optional
/// system-audio capture (F2). Warns (not fails) when absent, since system audio
/// is optional; guides the user to the exact Settings pane.
struct ScreenRecordingCheck: DiagnosticCheck {
    let id = CheckID.screenRecording
    let titleKey = "diag.screen.title"
    let explanationKey = "diag.screen.explanation"
    var remediation: Remediation {
        .guided(titleKey: "diag.microphone.fix",
                .systemSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
    }

    func run(runner: CommandRunning) -> CheckResult {
        // Non-prompting preflight of Screen Recording authorization.
        CGPreflightScreenCaptureAccess()
            ? CheckResult(id: id, outcome: .passed, detail: "authorized")
            : CheckResult(id: id, outcome: .warning, detail: "not granted (only needed for system audio, F2)")
    }
}
