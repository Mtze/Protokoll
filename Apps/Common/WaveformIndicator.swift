import SwiftUI

/// A live audio waveform driven by a rolling buffer of 0...1 levels. Its bars
/// react to the microphone in realtime, so the user can see that recording is
/// actually capturing sound (N4: visible recording indicator).
public struct WaveformIndicator: View {
    private let levels: [Float]
    private let color: Color

    public init(levels: [Float], color: Color = .red) {
        self.levels = levels
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth,
                               height: max(2, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.06), value: levels)
        }
    }
}

/// A recording indicator: a pulsing record dot, the live waveform, and the
/// elapsed time. Shown while a recording is in progress on every platform.
public struct RecordingIndicator: View {
    private let levels: [Float]
    private let startedAt: Date?
    private let compact: Bool

    public init(levels: [Float], startedAt: Date?, compact: Bool = false) {
        self.levels = levels
        self.startedAt = startedAt
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityLabel(Text("recording.active"))
            WaveformIndicator(levels: levels)
                .frame(height: compact ? 18 : 24)
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsed(from: startedAt, to: context.date))
                        .font(compact ? .caption2 : .caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
