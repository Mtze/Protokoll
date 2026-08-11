import Foundation

/// Hex-color helpers for projects/tags (F7). Foundation-only so the parsing is
/// unit-testable; SwiftUI's `Color(hex:)` builds on `rgb(fromHex:)`.
public enum ProjectColor {
    /// Parses `#RRGGBB` or `RRGGBB` into 0...1 RGB components, or nil if invalid.
    public static func rgb(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A small preset palette. Each color maps to a colored circle emoji so it
    /// can be shown as a menu indicator (see ``emoji(for:)``).
    public static let palette: [String] = [
        "#EF4444", // red
        "#F97316", // orange
        "#EAB308", // yellow
        "#22C55E", // green
        "#3B82F6", // blue
        "#A855F7", // purple
        "#A16207", // brown
    ]

    /// A colored circle emoji for a palette color (a menu-friendly indicator,
    /// since SwiftUI templates SF Symbol menu icons to a single tint).
    public static func emoji(for hex: String) -> String {
        switch hex {
        case "#EF4444": return "🔴"
        case "#F97316": return "🟠"
        case "#EAB308": return "🟡"
        case "#22C55E": return "🟢"
        case "#3B82F6": return "🔵"
        case "#A855F7": return "🟣"
        case "#A16207": return "🟤"
        default: return "⚪"
        }
    }
}
