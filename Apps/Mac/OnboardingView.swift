import SwiftUI

/// First-launch onboarding. Asks for exactly the permissions Protokoll needs,
/// one at a time, with plain explanations - so nothing is a surprise. Only the
/// microphone is required; Screen Recording (only to capture the other side of
/// a call) and Notifications are optional. Protokoll never needs Photos or
/// broad file access.
struct OnboardingView: View {
    var dismiss: () -> Void
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false

    @State private var step = 0
    @State private var permissions = PermissionsModel()

    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)
            Divider()
            footer.padding(16)
        }
        .frame(width: 480, height: 440)
        .task { await permissions.refresh() }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            info(icon: "checkmark.shield.fill",
                 title: "onboarding.welcome.title", body: "onboarding.welcome.body")
        case 1:
            permission(icon: "mic.fill",
                       title: "onboarding.mic.title", body: "onboarding.mic.body",
                       state: permissions.mic, required: true) { permissions.requestMic() }
        case 2:
            permission(icon: "rectangle.inset.filled.badge.record",
                       title: "onboarding.screen.title", body: "onboarding.screen.body",
                       state: permissions.screen, required: false) { permissions.requestScreen() }
        case 3:
            permission(icon: "bell.badge.fill",
                       title: "onboarding.notify.title", body: "onboarding.notify.body",
                       state: permissions.notify, required: false) { permissions.requestNotify() }
        default:
            info(icon: "checkmark.seal.fill",
                 title: "onboarding.done.title", body: "onboarding.done.body")
        }
    }

    private func info(icon: String, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.tint)
            Text(title).font(.title2).bold()
            Text(body).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permission(icon: String, title: LocalizedStringKey, body: LocalizedStringKey,
                            state: PermissionsModel.Access, required: Bool,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tint)
            HStack(spacing: 6) {
                Text(title).font(.title2).bold()
                if !required {
                    Text("onboarding.optional").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(body).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

            switch state {
            case .granted:
                Label("onboarding.granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                VStack(spacing: 6) {
                    Label("onboarding.denied", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("onboarding.openSettings") { action() }
                }
            case .unknown:
                Button(action: action) { Text("onboarding.allow").frame(minWidth: 160) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Footer / navigation

    private var footer: some View {
        HStack {
            if step == 0 {
                Button("onboarding.skip") { finish() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            } else if step > 0 && step < lastStep {
                Button("onboarding.back") { step -= 1 }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            PageDots(count: lastStep + 1, index: step)
            Spacer()
            if step < lastStep {
                Button(step == 0 ? "onboarding.getStarted" : "onboarding.continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("onboarding.finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        onboardingDone = true
        dismiss()
    }
}

/// Simple page-progress dots.
private struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
