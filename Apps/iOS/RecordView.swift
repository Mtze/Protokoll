import SwiftUI
import SharedKit

/// The iOS record tab: title, optional geotag, a big record button, and the
/// § 201 StGB consent reminder (N4).
struct RecordView: View {
    @Environment(IOSAppModel.self) private var model
    @AppStorage("consentReminderEnabled") private var consentReminder = true
    @State private var title = ""
    @State private var includeGeotag = false
    @State private var showingConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ios.record.title", text: $title)
                    Toggle("ios.record.geotag", isOn: $includeGeotag)
                }
                Section {
                    Button {
                        if model.isRecording {
                            Task { await model.stopRecording() }
                        } else if consentReminder {
                            showingConsent = true
                        } else {
                            Task { await startRecording() }
                        }
                    } label: {
                        Label(model.isRecording ? "menu.stop" : "menu.record",
                              systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(model.isRecording ? .red : .accentColor)
                    }
                    .controlSize(.large)
                }
                if model.isRecording {
                    Section {
                        RecordingIndicator(levels: model.recordingLevels, startedAt: model.recordingStartedAt)
                            .frame(height: 32)
                    }
                }
            }
            .navigationTitle("app.name")
            .confirmationDialog("consent.title", isPresented: $showingConsent, titleVisibility: .visible) {
                Button("consent.confirm") { Task { await startRecording() } }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("consent.message")
            }
        }
    }

    private func startRecording() async {
        await model.startRecording(title: title.isEmpty ? nil : title, includeGeotag: includeGeotag)
        title = ""
    }
}
