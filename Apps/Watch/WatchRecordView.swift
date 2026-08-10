import SwiftUI

/// The watch record screen: one big record/stop button and a status line.
struct WatchRecordView: View {
    @State private var recorder = WatchRecorder()

    var body: some View {
        VStack(spacing: 12) {
            Button {
                Task { await recorder.toggle() }
            } label: {
                Label(recorder.isRecording ? "menu.stop" : "menu.record",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recorder.isRecording ? .red : .accentColor)
            }
            .controlSize(.large)

            if !recorder.lastStatus.isEmpty {
                Text(recorder.lastStatus).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
