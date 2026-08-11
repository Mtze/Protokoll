import SwiftUI

/// App settings. Consent reminder (N4, § 201 StGB awareness), the optional
/// system-audio capture toggle (F2), and the custom summary instructions live
/// here. Toggles persist via `@AppStorage`; the summary instructions are stored
/// in the container so the pipeline reads them too.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKeys.captureSystemAudio) private var captureSystemAudio = false
    @State private var summaryInstructions = ""

    var body: some View {
        Form {
            Section("settings.recording") {
                Toggle("settings.consentReminder", isOn: $consentReminder)
                Text("settings.consentReminder.help")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("settings.systemAudio", isOn: $captureSystemAudio)
                Text("settings.systemAudio.help")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("settings.summary") {
                Text("settings.summary.help")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $summaryInstructions)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                HStack {
                    Spacer()
                    Button("settings.summary.reset") { summaryInstructions = "" }
                        .disabled(summaryInstructions.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .onAppear { summaryInstructions = (try? model.container.loadSummaryInstructions()) ?? "" }
        .onChange(of: summaryInstructions) { _, new in
            try? model.container.saveSummaryInstructions(new)
        }
    }
}

/// Stable `@AppStorage` keys.
enum SettingsKeys {
    static let consentReminder = "consentReminderEnabled"
    static let captureSystemAudio = "captureSystemAudioEnabled"
    static let onboardingDone = "onboardingComplete"
}
