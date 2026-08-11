import SwiftUI

/// Native audio playback UI shared by all platforms: a scrubber, play/pause,
/// and a playback-speed control. Loads the file on appear and releases it on
/// disappear. On watchOS the speed control is a tap-to-cycle button (menus are
/// awkward on the watch); elsewhere it is a menu.
public struct AudioPlayerView: View {
    private let url: URL
    private let titleKey: LocalizedStringKey?

    @State private var player = AudioPlayerModel()
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    public init(url: URL, title: LocalizedStringKey? = nil) {
        self.url = url
        self.titleKey = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let titleKey {
                Label(titleKey, systemImage: "waveform")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Slider(value: sliderBinding, in: 0...max(player.duration, 0.01)) { editing in
                if editing {
                    scrubbing = true
                    scrubValue = player.currentTime
                } else {
                    player.seek(to: scrubValue)
                    scrubbing = false
                }
            }
            .disabled(!player.isLoaded)

            HStack {
                Text(timeString(scrubbing ? scrubValue : player.currentTime)).monospacedDigit()
                Spacer()
                Text(timeString(player.duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(!player.isLoaded)
                .help(player.isPlaying ? "player.pause" : "player.play")
                .accessibilityLabel(Text(player.isPlaying ? "player.pause" : "player.play"))

                Spacer()
                speedControl
            }
        }
        .onAppear { player.load(url) }
        .onChange(of: url) { _, newURL in player.load(newURL) }
        .onDisappear { player.pause() }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { scrubbing ? scrubValue : player.currentTime },
            set: { scrubValue = $0 }
        )
    }

    @ViewBuilder private var speedControl: some View {
        #if os(watchOS)
        Button { player.cycleRate() } label: {
            Text(rateText)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("player.speed"))
        #else
        Menu {
            ForEach(AudioPlayerModel.speeds, id: \.self) { speed in
                Button { player.setRate(speed) } label: {
                    HStack {
                        Text(speedLabel(speed))
                        if speed == player.rate { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label(rateText, systemImage: "speedometer")
        }
        .fixedSize()
        .help("player.speed")
        .accessibilityLabel(Text("player.speed"))
        #endif
    }

    private var rateText: String { speedLabel(player.rate) }

    private func speedLabel(_ speed: Float) -> String {
        String(format: "%g\u{00D7}", Double(speed))  // 1×, 1.25×, 1.5×, 2×
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
