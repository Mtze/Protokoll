import SwiftUI
import Diagnostics

/// The aggregate health indicator (green/yellow/red) shown in the menubar and
/// the diagnostics header. SF Symbol only, with an accessibility label.
struct HealthDot: View {
    let health: HealthLevel

    var body: some View {
        Image(systemName: health.symbolName)
            .foregroundStyle(health.color)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: LocalizedStringKey {
        switch health {
        case .green: return "health.green"
        case .yellow: return "health.yellow"
        case .red: return "health.red"
        }
    }
}
