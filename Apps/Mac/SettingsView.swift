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

/// Container-backed store for the user-editable summary body spec
/// (`config/summary-prompt.md`).
///
/// The editor is prefilled with the built-in default so the user *edits* rather
/// than authors from nothing, and ``isCustom`` distinguishes "same as default"
/// from "customized" - saving text equal to the default deletes the file, so
/// unchanged users keep receiving improvements to the default in future versions.
@MainActor
@Observable
final class SummaryTemplateStore {
    /// The text shown in the editor.
    var text: String
    /// Whether a custom template file exists on disk.
    private(set) var isCustom: Bool
    private let container: Container

    init(container: Container) {
        self.container = container
        let stored = (try? container.loadSummaryTemplate()) ?? nil
        self.isCustom = stored != nil
        self.text = stored ?? SummaryTemplate.default
    }

    func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? container.saveSummaryTemplate(
            SummaryTemplate.isDefault(text) || trimmed.isEmpty ? nil : text
        )
        isCustom = container.hasCustomSummaryTemplate()
    }

    /// Discards the customization: deletes the file and restores the default text.
    func resetToDefault() {
        text = SummaryTemplate.default
        try? container.saveSummaryTemplate(nil)
        isCustom = false
    }
}

/// Container-backed store for project/tag definitions (F7), mirroring
/// ``PipelineSettingsStore``.
@MainActor
@Observable
final class ProjectsStore {
    var projects: [Project]
    private let container: Container

    init(container: Container) {
        self.container = container
        self.projects = (try? container.loadProjects()) ?? []
    }

    func save() { try? container.saveProjects(projects) }
    func add() { projects.append(Project(name: "", color: ProjectColor.palette.first ?? "#3B82F6")) }
    func delete(_ project: Project) { projects.removeAll { $0.id == project.id } }
}

/// App settings, organized into native preference tabs. App-behavior toggles are
/// `@AppStorage`; pipeline tuning (transcription/summary) lives in the container
/// so `process-session` reads it too.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    private let container: Container
    @State private var store: PipelineSettingsStore
    @State private var projectsStore: ProjectsStore
    @State private var templateStore: SummaryTemplateStore

    init(container: Container) {
        self.container = container
        _store = State(wrappedValue: PipelineSettingsStore(container: container))
        _projectsStore = State(wrappedValue: ProjectsStore(container: container))
        _templateStore = State(wrappedValue: SummaryTemplateStore(container: container))
    }

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
            TranscriptionTab(store: store)
                .tabItem { Label("settings.tab.transcription", systemImage: "waveform") }
            SummaryTab(store: store, templateStore: templateStore)
                .tabItem { Label("settings.tab.summary", systemImage: "doc.text") }
            ProjectsTab(store: projectsStore)
                .tabItem { Label("settings.tab.projects", systemImage: "tag") }
            ProcessingTab()
                .tabItem { Label("settings.tab.processing", systemImage: "gearshape.2") }
            DiagnosticsSettingsTab()
                .tabItem { Label("settings.tab.diagnostics", systemImage: "stethoscope") }
            AdvancedTab(container: container)
                .tabItem { Label("settings.tab.advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 480)
        .onChange(of: store.config) { store.save() }
        .onChange(of: templateStore.text) { templateStore.save() }
        .onChange(of: projectsStore.projects) {
            projectsStore.save()
            model.reloadProjects()
        }
    }
}

// MARK: - Projects

private struct ProjectsTab: View {
    @Bindable var store: ProjectsStore

    var body: some View {
        Form {
            Section("settings.tab.projects") {
                ForEach($store.projects) { $project in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("project.name", text: $project.name)
                            Button(role: .destructive) { store.delete(project) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("project.delete")
                        }
                        SwatchPicker(selection: $project.color)
                    }
                    .padding(.vertical, 2)
                }
                Button { store.add() } label: { Label("project.new", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
        .settingsPane()
    }
}

/// A row of tappable color swatches; the selected one gets a ring. Replaces the
/// hex-code menu with a friendly visual picker.
private struct SwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ProjectColor.palette, id: \.self) { option in
                Button { selection = option } label: {
                    Circle()
                        .fill(Color(hex: option))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle()
                                .stroke(Color.primary, lineWidth: 2)
                                .padding(-3)
                                .opacity(option == selection ? 1 : 0)
                        }
                }
                .buttonStyle(.plain)
                .help(SettingsFormat.colorName(option))
                .accessibilityLabel(Text(SettingsFormat.colorName(option)))
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(SettingsKeys.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKeys.captureSystemAudio) private var captureSystemAudio = false
    @AppStorage(SettingsKeys.voiceProcessing) private var voiceProcessing = false
    @AppStorage(SettingsKeys.preferredInputDeviceUID) private var inputDeviceUID = ""
    @AppStorage(SettingsKeys.defaultPlaybackSpeed) private var playbackSpeed = 1.0
    @State private var inputDevices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("settings.recording") {
                Picker("settings.recording.inputDevice", selection: $inputDeviceUID) {
                    Text("settings.recording.inputDevice.default").tag("")
                    ForEach(inputDevices) { device in
                        Text(verbatim: device.name).tag(device.uid)
                    }
                }
                Text("settings.recording.inputDevice.help").font(.caption).foregroundStyle(.secondary)
                Toggle("settings.consentReminder", isOn: $consentReminder)
                Text("settings.consentReminder.help").font(.caption).foregroundStyle(.secondary)
                Toggle("settings.systemAudio", isOn: $captureSystemAudio)
                Text("settings.systemAudio.help").font(.caption).foregroundStyle(.secondary)
                Toggle("settings.voiceProcessing", isOn: $voiceProcessing)
                Text("settings.voiceProcessing.help").font(.caption).foregroundStyle(.secondary)
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
        .settingsPane()
        .onAppear { inputDevices = AudioInputDevices.available() }
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
            Section("settings.transcription.audio") {
                Picker("settings.transcription.preprocessing", selection: $store.config.audioPreprocessing) {
                    Text("settings.transcription.preprocessing.safe").tag("safe")
                    Text("settings.transcription.preprocessing.off").tag("off")
                }
                Text("settings.transcription.preprocessing.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("settings.transcription.vocabulary") {
                Text("settings.transcription.vocabulary.help").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.config.vocabulary)
                    .font(.body.monospaced()).frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .settingsPane()
    }
}

// MARK: - Summary

private struct SummaryTab: View {
    @Bindable var store: PipelineSettingsStore
    @Bindable var templateStore: SummaryTemplateStore
    @State private var apiKey: String = ""

    /// The Keychain account for the currently selected API provider.
    private var keyProvider: String { store.config.summaryProvider == "openai" ? "openai" : "anthropic" }
    private var isAPI: Bool { store.config.summaryProvider != "cli" }
    private var baseURLInvalid: Bool {
        let value = store.config.summaryApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.lowercased().hasPrefix("https://")
    }

    var body: some View {
        Form {
            Section("settings.summary") {
                Picker("settings.summary.provider", selection: $store.config.summaryProvider) {
                    Text("settings.summary.provider.cli").tag("cli")
                    Text("settings.summary.provider.anthropic").tag("anthropic")
                    Text("settings.summary.provider.openai").tag("openai")
                }
                Picker("settings.summary.language", selection: $store.config.summaryLanguage) {
                    ForEach(SettingsFormat.summaryLanguages, id: \.self) { code in
                        Text(SettingsFormat.language(code)).tag(code)
                    }
                }
                if store.config.summaryProvider == "cli" {
                    Picker("settings.summary.model", selection: $store.config.summaryModel) {
                        Text(verbatim: "Opus").tag("opus")
                        Text(verbatim: "Sonnet").tag("sonnet")
                        Text(verbatim: "Haiku").tag("haiku")
                    }
                    Text("settings.summary.model.help").font(.caption).foregroundStyle(.secondary)
                }
            }
            if isAPI {
                Section("settings.summary.api") {
                    SecureField("settings.summary.api.key", text: $apiKey)
                    TextField("settings.summary.api.model", text: $store.config.summaryApiModel,
                              prompt: Text(verbatim: store.config.summaryProvider == "anthropic"
                                           ? "claude-sonnet-4-5" : "gpt-4o"))
                    TextField("settings.summary.api.baseurl", text: $store.config.summaryApiBaseURL,
                              prompt: Text(verbatim: store.config.summaryProvider == "anthropic"
                                           ? "https://api.anthropic.com" : "https://api.openai.com/v1"))
                    if baseURLInvalid {
                        Label("settings.summary.api.baseurl.invalid", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Label("settings.summary.api.privacy", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("settings.summary.template") {
                Text("settings.summary.template.help").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $templateStore.text)
                    .font(.body.monospaced()).frame(minHeight: 220)
                HStack {
                    if templateStore.isCustom {
                        Label("settings.summary.template.customized", systemImage: "pencil")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("settings.summary.template.reset") { templateStore.resetToDefault() }
                        .disabled(!templateStore.isCustom)
                }
                Text("settings.summary.template.recovery").font(.caption).foregroundStyle(.secondary)
            }
            Section("settings.summary.instructions") {
                Text("settings.summary.help").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.config.summaryInstructions)
                    .font(.body.monospaced()).frame(minHeight: 100)
                HStack {
                    Spacer()
                    Button("settings.summary.reset") { store.config.summaryInstructions = "" }
                        .disabled(store.config.summaryInstructions.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPane()
        .onAppear { apiKey = SummaryKeychain.key(for: keyProvider) ?? "" }
        .onChange(of: store.config.summaryProvider) { apiKey = SummaryKeychain.key(for: keyProvider) ?? "" }
        .onChange(of: apiKey) { if isAPI { SummaryKeychain.setKey(apiKey, for: keyProvider) } }
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
        .settingsPane()
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

// MARK: - Layout

/// Adds a hairline divider between the tab bar (in the window toolbar) and the
/// tab's content, so the two are visually separated.
private struct SettingsPane: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content
        }
    }
}

private extension View {
    func settingsPane() -> some View { modifier(SettingsPane()) }
}

// MARK: - Diagnostics

/// Embeds the shared Diagnostics panel (permissions + tool checks + System-Test)
/// in Settings, refreshing the checks when the tab appears.
private struct DiagnosticsSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DiagnosticsView()
            .task { await model.runDiagnostics() }
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

    /// Friendly, localized name for a palette color (used as swatch tooltip/label).
    static func colorName(_ hex: String) -> LocalizedStringKey {
        switch hex {
        case "#EF4444": return "color.red"
        case "#F97316": return "color.orange"
        case "#EAB308": return "color.yellow"
        case "#22C55E": return "color.green"
        case "#3B82F6": return "color.blue"
        case "#A855F7": return "color.purple"
        case "#A16207": return "color.brown"
        default: return "color.custom"
        }
    }
}

/// Stable `@AppStorage` / UserDefaults keys.
enum SettingsKeys {
    static let consentReminder = "consentReminderEnabled"
    static let captureSystemAudio = "captureSystemAudioEnabled"
    static let voiceProcessing = "voiceProcessingEnabled"
    static let preferredInputDeviceUID = "preferredInputDeviceUID"
    static let onboardingDone = "onboardingComplete"
    static let autoProcess = "autoProcessNewRecordings"
    static let notificationsEnabled = "notificationsEnabled"
    static let defaultPlaybackSpeed = "defaultPlaybackSpeed"
    static let claudeBinOverride = "claudeBinaryPath"
    static let transcribeShOverride = "transcribeScriptPath"
}
