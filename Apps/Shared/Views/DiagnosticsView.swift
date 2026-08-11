import SwiftUI
import SharedKit
import Diagnostics
#if canImport(AppKit)
import AppKit
#endif

/// The Diagnostics/Preflight panel: an ordered list of checks with plain-language
/// titles, a Details disclosure for the raw output, tiered Fix buttons, and the
/// end-to-end System-Test. All strings localized; icons are SF Symbols.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var permissions = PermissionsModel()
    @State private var fixLog: FixLog?
    @State private var runningSystemTest = false
    @State private var systemTestResult: SystemTest.Outcome?

    /// Tool/dependency checks only - permissions are shown in their own section.
    private var toolChecks: [CheckResult] {
        model.checkResults.filter { $0.id != .microphone && $0.id != .screenRecording }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            permissionsSection
            Divider()
            List {
                ForEach(toolChecks) { result in
                    CheckRow(result: result, remediation: model.remediation(for: result.id)) { fix in
                        runAutoFix(fix)
                    } onGuided: { guidance in
                        follow(guidance)
                    }
                }
                if model.checkResults.isEmpty {
                    Text("diag.running")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            systemTestBar
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle("diag.title")
        .task { await permissions.refresh() }
        .sheet(item: $fixLog) { log in FixLogSheet(log: log) }
    }

    // MARK: Permissions (mirrors onboarding; adjustable after first run)

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("permissions.section").font(.subheadline).bold()
                .padding(.horizontal).padding(.top, 8)
            permissionRow(icon: "mic.fill", title: "onboarding.mic.title", state: permissions.mic,
                          request: { permissions.requestMic() },
                          openSettings: { permissions.openSettings("Privacy_Microphone") })
            permissionRow(icon: "rectangle.inset.filled.badge.record", title: "onboarding.screen.title",
                          state: permissions.screen,
                          request: { permissions.requestScreen() },
                          openSettings: { permissions.openSettings("Privacy_ScreenCapture") })
            permissionRow(icon: "bell.badge.fill", title: "onboarding.notify.title", state: permissions.notify,
                          request: { permissions.requestNotify() },
                          openSettings: { permissions.openSettings("Privacy_Notifications") })
        }
        .padding(.bottom, 6)
    }

    private func permissionRow(icon: String, title: LocalizedStringKey, state: PermissionsModel.Access,
                               request: @escaping () -> Void, openSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            Text(title)
            Spacer()
            switch state {
            case .granted:
                Label("onboarding.granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            case .denied:
                Button("onboarding.openSettings") { openSettings() }.controlSize(.small)
            case .unknown:
                Button("onboarding.allow") { request() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.horizontal).padding(.vertical, 4)
    }

    private var header: some View {
        HStack {
            HealthDot(health: model.health)
            Text("diag.title").font(.headline)
            Spacer()
            Button {
                Task { await model.runDiagnostics() }
            } label: {
                Label("diag.recheck", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRunningDiagnostics)
        }
        .padding()
    }

    private var systemTestBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("diag.systemtest.title").font(.subheadline).bold()
                Text("diag.systemtest.explanation").font(.caption).foregroundStyle(.secondary)
                if let systemTestResult {
                    switch systemTestResult {
                    case let .passed(title):
                        Label(String(localized: "diag.systemtest.passed \(title)"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.caption)
                    case let .failed(reason):
                        Label(reason, systemImage: "xmark.seal.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            }
            Spacer()
            Button {
                runSystemTest()
            } label: {
                if runningSystemTest {
                    ProgressView().controlSize(.small)
                } else {
                    Label("diag.systemtest.run", systemImage: "play.circle")
                }
            }
            .disabled(runningSystemTest)
        }
        .padding()
    }

    // MARK: Actions

    private func runAutoFix(_ fix: AutoFix) {
        let log = FixLog(title: fix.titleKey)
        fixLog = log
        let workingDir = HelperLocator.repoRoot()
        Task.detached {
            let executor = RemediationExecutor(workingDirectory: workingDir)
            let outcome = executor.run(fix) { line in
                Task { @MainActor in log.append(line) }
            }
            await MainActor.run {
                log.finish(outcome)
                Task { await model.runDiagnostics() }
            }
        }
    }

    private func follow(_ guidance: Guidance) {
        #if canImport(AppKit)
        switch guidance {
        case let .terminalCommand(command):
            openInTerminal(command)
        case let .systemSettings(url):
            if let settingsURL = URL(string: url) { NSWorkspace.shared.open(settingsURL) }
        }
        #endif
    }

    #if canImport(AppKit)
    private func openInTerminal(_ command: String) {
        let script = "tell application \"Terminal\" to do script \"\(command)\"\ntell application \"Terminal\" to activate"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
    #endif

    private func runSystemTest() {
        runningSystemTest = true
        systemTestResult = nil
        guard let binary = HelperLocator.processSessionBinary(),
              let clip = SampleClip.url() else {
            systemTestResult = .failed(reason: String(localized: "diag.systemtest.noassets"))
            runningSystemTest = false
            return
        }
        var env = HelperLocator.pipelineEnvironment()
        // Keep the automated dry-run fast; production default stays large-v3.
        env["TRANSCRIBE_MODEL"] = ProcessInfo.processInfo.environment["TRANSCRIBE_MODEL"] ?? "tiny"
        Task.detached {
            let test = SystemTest(processSessionBinary: binary, sampleClip: clip, environment: env)
            let outcome = test.run()
            await MainActor.run {
                systemTestResult = outcome
                runningSystemTest = false
                Task { await model.runDiagnostics() }
            }
        }
    }
}

/// One check row with status icon, title, Details disclosure, and Fix button.
private struct CheckRow: View {
    let result: CheckResult
    let remediation: Remediation
    let onAutoFix: (AutoFix) -> Void
    let onGuided: (Guidance) -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: CheckPresentation.symbol(result.outcome))
                    .foregroundStyle(CheckPresentation.color(result.outcome))
                VStack(alignment: .leading) {
                    Text(CheckPresentation.title(result.id)).font(.body)
                    Text(CheckPresentation.explanation(result.id))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                fixButton
            }
            if showDetails, let detail = result.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 28)
            }
            if result.detail != nil {
                Button(showDetails ? "diag.details.hide" : "diag.details.show") {
                    showDetails.toggle()
                }
                .font(.caption).buttonStyle(.link).padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var fixButton: some View {
        if result.outcome == .passed {
            EmptyView()
        } else {
            switch remediation {
            case let .autoFix(fix):
                Button("diag.fix") { onAutoFix(fix) }.buttonStyle(.borderedProminent).controlSize(.small)
            case let .guided(titleKey, guidance):
                Button(LocalizedStringKey(titleKey)) { onGuided(guidance) }.controlSize(.small)
            case .none:
                EmptyView()
            }
        }
    }
}

/// Observable buffer for a running auto-fix's live log.
@MainActor
@Observable
final class FixLog: Identifiable {
    let id = UUID()
    let title: String
    var lines: [String] = []
    var finished = false
    var succeeded = false

    init(title: String) { self.title = title }

    func append(_ line: String) { lines.append(line) }

    func finish(_ outcome: RemediationExecutor.FixOutcome) {
        finished = true
        switch outcome {
        case .succeeded: succeeded = true
        case let .failed(message): lines.append("error: \(message)"); succeeded = false
        case let .bootstrapRequired(bootstrap):
            lines.append(String(localized: "diag.bootstrap.required \(bootstrap.toolName)"))
            succeeded = false
        }
    }
}

private struct FixLogSheet: View {
    @Bindable var log: FixLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text(LocalizedStringKey(log.title)).font(.headline)
            ScrollView {
                Text(log.lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 460, minHeight: 240)
            .background(.quaternary)
            HStack {
                if !log.finished { ProgressView().controlSize(.small) }
                Spacer()
                Button("common.done") { dismiss() }.disabled(!log.finished)
            }
        }
        .padding()
    }
}
