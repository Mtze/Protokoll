import SwiftUI

/// App settings. Consent reminder (N4, § 201 StGB awareness) and the optional
/// system-audio capture toggle (F2) live here. Persisted via `@AppStorage`.
struct SettingsView: View {
    @AppStorage(SettingsKeys.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKeys.captureSystemAudio) private var captureSystemAudio = false

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
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 260)
    }
}

/// Stable `@AppStorage` keys.
enum SettingsKeys {
    static let consentReminder = "consentReminderEnabled"
    static let captureSystemAudio = "captureSystemAudioEnabled"
}
