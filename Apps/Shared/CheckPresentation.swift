import SwiftUI
import Diagnostics

/// Maps a ``CheckID`` and outcome to localized strings + SF Symbols for the UI.
/// Keeps all user-facing strings in the String Catalog (i18n from line one).
enum CheckPresentation {
    static func title(_ id: CheckID) -> LocalizedStringKey {
        switch id {
        case .claude: return "diag.claude.title"
        case .whisperEngine: return "diag.whisper.title"
        case .whisperEnginePerformance: return "diag.enginePerf.title"
        case .whisperModel: return "diag.model.title"
        case .ffmpeg: return "diag.ffmpeg.title"
        case .npx: return "diag.npx.title"
        case .path: return "diag.path.title"
        case .containerWritable: return "diag.container.title"
        case .microphone: return "diag.microphone.title"
        case .screenRecording: return "diag.screen.title"
        }
    }

    static func explanation(_ id: CheckID) -> LocalizedStringKey {
        switch id {
        case .claude: return "diag.claude.explanation"
        case .whisperEngine: return "diag.whisper.explanation"
        case .whisperEnginePerformance: return "diag.enginePerf.explanation"
        case .whisperModel: return "diag.model.explanation"
        case .ffmpeg: return "diag.ffmpeg.explanation"
        case .npx: return "diag.npx.explanation"
        case .path: return "diag.path.explanation"
        case .containerWritable: return "diag.container.explanation"
        case .microphone: return "diag.microphone.explanation"
        case .screenRecording: return "diag.screen.explanation"
        }
    }

    static func symbol(_ outcome: CheckOutcome) -> String {
        switch outcome {
        case .passed: return "checkmark.circle.fill"
        case .warning, .unknown: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    static func color(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .passed: return .green
        case .warning, .unknown: return .yellow
        case .failed: return .red
        }
    }
}

extension HealthLevel {
    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}
