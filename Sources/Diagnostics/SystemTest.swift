import Foundation
import SharedKit

/// The end-to-end "System-Test" (Selbsttest): push a short bundled clip through
/// the real `process-session` binary (transcribe → summarize) so a green result
/// proves the whole chain, not just that individual tools resolve.
///
/// Kept UI-free and injectable: the app supplies the `process-session` binary
/// path and a bundled audio clip; tests supply a fake runner.
public struct SystemTest: Sendable {
    public enum Outcome: Sendable, Equatable {
        case passed(title: String)
        case failed(reason: String)
    }

    let runner: CommandRunning
    /// Path to the bundled `process-session` executable.
    let processSessionBinary: String
    /// Path to the bundled ~3 s audio clip used as input.
    let sampleClip: URL
    /// Extra environment for the subprocess (e.g. `TRANSCRIBE_SH`,
    /// `TRANSCRIBE_MODEL=tiny` to keep the dry-run fast).
    let environment: [String: String]

    public init(
        runner: CommandRunning = ProcessCommandRunner(),
        processSessionBinary: String,
        sampleClip: URL,
        environment: [String: String] = [:]
    ) {
        self.runner = runner
        self.processSessionBinary = processSessionBinary
        self.sampleClip = sampleClip
        self.environment = environment
    }

    /// Runs the dry run in a throwaway temp container. Progress lines are
    /// forwarded to `onProgress`.
    public func run(onProgress: (@Sendable (String) -> Void)? = nil) -> Outcome {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-systemtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let container = Container(locator: LocalFolderContainer(root: tempRoot))
        do {
            let session = try container.createSession(device: .mac, title: nil)
            try FileManager.default.copyItem(at: sampleClip, to: session.micAudioURL)

            let result = try runner.run(
                executable: processSessionBinary,
                arguments: [session.folder.path, "--step", "all"],
                stdin: nil,
                environment: environment,
                onStderrLine: onProgress
            )
            guard result.succeeded else {
                return .failed(reason: result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            let reloaded = try container.store.load(folder: session.folder)
            let transcriptExists = FileManager.default.fileExists(atPath: session.transcriptURL.path)
            let protocolExists = FileManager.default.fileExists(atPath: session.protocolURL.path)
            guard transcriptExists, protocolExists, reloaded.metadata.pipeline.status == .done else {
                return .failed(reason: "pipeline finished in state \(reloaded.metadata.pipeline.status.name); transcript=\(transcriptExists) protocol=\(protocolExists)")
            }
            return .passed(title: reloaded.displayTitle)
        } catch {
            return .failed(reason: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
