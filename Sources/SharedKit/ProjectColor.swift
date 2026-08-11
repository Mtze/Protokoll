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

    /// A small, accessible preset palette for the project color picker.
    public static let palette: [String] = [
        "#3B82F6", // blue
        "#22C55E", // green
        "#A855F7", // purple
        "#F97316", // orange
        "#EF4444", // red
        "#14B8A6", // teal
        "#EAB308", // amber
        "#EC4899", // pink
    ]
}
