import SwiftUI
import SharedKit
#if canImport(AppKit)
import AppKit
#endif

/// A small observable holder for the container-backed ``PipelineConfig`` so the
/// Transcription and Summary tabs edit one shared source of truth and persist on
/// change. Loaded once on init.
@MainActor
@Observable
final class PipelineSettingsStore {
    var config: PipelineConfig
    private let container: Container

    init(container: Container) {
        self.container = container
        self.config = (try? container.loadPipelineConfig()) ?? PipelineConfig()
    }

    func save() { try? container.savePipelineConfig(config) }
}

/// App settings, organized into native preference tabs. App-behavior toggles are
/// `@AppStorage`; pipeline tuning (transcription/summary) lives in the container
/// so `process-session` reads it too.
struct SettingsView: View {
    private let container: Container
    @State private var store: PipelineSettingsStore

    init(container: Container) {
        self.container = container
        _store = State(wrappedValue: PipelineSettingsStore(container: container))
    }

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
            TranscriptionTab(store: store)
                .tabItem { Label("settings.tab.transcription", systemImage: "waveform") }
            SummaryTab(store: store)
                .tabItem { Label("settings.tab.summary", systemImage: "doc.text") }
            ProcessingTab()
                .tabItem { Label("settings.tab.processing", systemImage: "gearshape.2") }
            AdvancedTab(container: container)
                .tabItem { Label("settings.tab.advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 480)
        .onChange(of: store.config) { store.save() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(SettingsKeys.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKeys.captureSystemAudio) private var captureSystemAudio = false
    @AppStorage(SettingsKeys.defaultPlaybackSpeed) private var playbackSpeed = 1.0

    var body: some View {
        Form {
            Section("settings.recording") {
                Toggle("settings.consentReminder", isOn: $consentReminder)
                Text("settings.consentReminder.help").font(.caption).foregroundStyle(.secondary)
                Toggle("settings.systemAudio", isOn: $captureSystemAudio)
                Text("settings.systemAudio.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("settings.playback") {
                Picker("settings.playback.speed", selection: $playbackSpeed) {
                    ForEach(AudioPlayerModel.speeds, id: \.self) { speed in
                        Text(SettingsFormat.speed(speed)).tag(Double(speed))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

private struct TranscriptionTab: View {
    @Bindable var store: PipelineSettingsStore

    var body: some View {
        Form {
            Section("settings.transcription") {
                Picker("settings.transcription.language", selection: $store.config.transcriptionLanguage) {
                    ForEach(SettingsFormat.transcriptionLanguages, id: \.self) { code in
                        Text(SettingsFormat.language(code)).tag(code)
                    }
                }
                Picker("settings.transcription.model", selection: $store.config.transcriptionModel) {
                    Text(verbatim: "large-v3").tag("large-v3")
                    Text(verbatim: "large-v3-turbo").tag("large-v3-turbo")
                }
                Text("settings.transcription.model.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("settings.transcription.vocabulary") {
                Text("settings.transcription.vocabulary.help").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.config.vocabulary)
                    .font(.body.monospaced()).frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Summary

private struct SummaryTab: View {
    @Bindable var store: PipelineSettingsStore

    var body: some View {
        Form {
            Section("settings.summary") {
                Picker("settings.summary.language", selection: $store.config.summaryLanguage) {
                    ForEach(SettingsFormat.summaryLanguages, id: \.self) { code in
                        Text(SettingsFormat.language(code)).tag(code)
                    }
                }
                Picker("settings.summary.model", selection: $store.config.summaryModel) {
                    Text(verbatim: "Opus").tag("opus")
                    Text(verbatim: "Sonnet").tag("sonnet")
                    Text(verbatim: "Haiku").tag("haiku")
                }
                Text("settings.summary.model.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("settings.summary.instructions") {
                Text("settings.summary.help").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.config.summaryInstructions)
                    .font(.body.monospaced()).frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("settings.summary.reset") { store.config.summaryInstructions = "" }
                        .disabled(store.config.summaryInstructions.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Processing

private struct ProcessingTab: View {
    @AppStorage(SettingsKeys.autoProcess) private var autoProcess = false
    @AppStorage(SettingsKeys.notificationsEnabled) private var notifications = true

    var body: some View {
        Form {
            Section("settings.processing") {
                Toggle("settings.autoProcess", isOn: $autoProcess)
                Text("settings.autoProcess.help").font(.caption).foregroundStyle(.secondary)
                Toggle("settings.notifications", isOn: $notifications)
                Text("settings.notifications.help").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    let container: Container
    @AppStorage(SettingsKeys.claudeBinOverride) private var claudeBin = ""
    @AppStorage(SettingsKeys.transcribeShOverride) private var transcribeSh = ""

    private var containerPath: String { (try? container.root().path) ?? "-" }

    var body: some View {
        Form {
            Section("settings.container") {
                Text(containerPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
                Button("settings.container.reveal") { revealContainer() }
            }
            Section("settings.tools") {
                Text("settings.tools.help").font(.caption).foregroundStyle(.secondary)
                TextField("settings.tools.claude", text: $claudeBin, prompt: Text(verbatim: "claude"))
                TextField("settings.tools.transcribe", text: $transcribeSh, prompt: Text(verbatim: "…/transcribe.sh"))
            }
        }
        .formStyle(.grouped)
    }

    private func revealContainer() {
        #if canImport(AppKit)
        guard let root = try? container.root() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
        #endif
    }
}

// MARK: - Formatting helpers

enum SettingsFormat {
    static let transcriptionLanguages = ["auto", "de", "en", "fr", "es", "it"]
    static let summaryLanguages = ["auto", "de", "en"]

    static func language(_ code: String) -> String {
        code == "auto"
            ? String(localized: "settings.lang.auto")
            : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }

    static func speed(_ speed: Float) -> String {
        String(format: "%g\u{00D7}", Double(speed))
    }
}

/// Stable `@AppStorage` / UserDefaults keys.
enum SettingsKeys {
    static let consentReminder = "consentReminderEnabled"
    static let captureSystemAudio = "captureSystemAudioEnabled"
    static let onboardingDone = "onboardingComplete"
    static let autoProcess = "autoProcessNewRecordings"
    static let notificationsEnabled = "notificationsEnabled"
    static let defaultPlaybackSpeed = "defaultPlaybackSpeed"
    static let claudeBinOverride = "claudeBinaryPath"
    static let transcribeShOverride = "transcribeScriptPath"
}
