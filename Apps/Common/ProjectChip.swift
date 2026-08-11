import SwiftUI
import SharedKit

public extension Color {
    /// Builds a color from a `#RRGGBB` hex string; falls back to gray if invalid.
    init(hex: String) {
        if let rgb = ProjectColor.rgb(fromHex: hex) {
            self = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self = .gray
        }
    }
}

/// A small project/tag chip - a color dot plus the project name in a capsule.
/// Mirrors the pipeline-status badge idiom; shared by Mac and iOS (F7).
public struct ProjectChip: View {
    private let name: String
    private let color: Color

    public init(name: String, colorHex: String) {
        self.name = name
        self.color = Color(hex: colorHex)
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(.secondary)
    }
}
