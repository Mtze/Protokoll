import AVFoundation
import Foundation
import SharedKit

/// Captures microphone audio incrementally to a streamable CAF file, then
/// converts to `mic.m4a` on stop (ADR-3: the `.m4a` container isn't finalized
/// until close, so a crash mid-recording would lose everything; CAF PCM is
/// written frame-by-frame and survives, N5).
///
/// Modeled as an `actor` (plan: recorder is an actor). The realtime tap writes
/// through a lock-guarded, non-isolated ``AudioFileWriter`` - the standard way
/// to bridge AVAudioEngine's realtime callback into structured concurrency.
actor Recorder {
    enum RecorderError: Error, LocalizedError {
        case permissionDenied
        case engineFailure(String)
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return String(localized: "recorder.error.permission")
            case let .engineFailure(message): return message
            case let .conversionFailed(message): return message
            }
        }
    }

    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var session: Session?
    private var startedAt: Date?
    private(set) var isRecording = false

    /// Requests microphone access (TCC). Returns `true` if granted.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Begins capturing to `session.micCaptureURL` (CAF).
    func start(session: Session) throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        try FileManager.default.createDirectory(at: session.audioDirectory, withIntermediateDirectories: true)

        let writer: AudioFileWriter
        do {
            writer = try AudioFileWriter(url: session.micCaptureURL, format: format)
        } catch {
            throw RecorderError.engineFailure(error.localizedDescription)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailure(error.localizedDescription)
        }

        self.writer = writer
        self.session = session
        self.startedAt = Date()
        self.isRecording = true
    }

    /// Stops capture, finalizes the CAF, converts it to `mic.m4a`, and returns
    /// the session with updated `endedAt`/`duration`.
    func stop() async throws -> Session {
        guard isRecording, var session, let startedAt else {
            throw RecorderError.engineFailure(String(localized: "recorder.error.notRecording"))
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
        isRecording = false

        try await Self.convertCAFToM4A(caf: session.micCaptureURL, m4a: session.micAudioURL)
        try? FileManager.default.removeItem(at: session.micCaptureURL)

        let ended = Date()
        session.metadata.endedAt = ended
        session.metadata.duration = ended.timeIntervalSince(startedAt)
        session.metadata.audioTracks = [.mic]
        self.session = nil
        self.startedAt = nil
        return session
    }

    /// Recovers a crashed recording: a `mic.caf` with no `mic.m4a` is converted
    /// on launch (ADR-3 leftover-CAF recovery).
    static func recoverOrphans(in container: Container) async {
        guard let sessions = try? container.allSessions() else { return }
        for session in sessions {
            let caf = session.micCaptureURL
            let m4a = session.micAudioURL
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: caf.path), !fileManager.fileExists(atPath: m4a.path) else { continue }
            do {
                try await convertCAFToM4A(caf: caf, m4a: m4a)
                try? fileManager.removeItem(at: caf)
            } catch {
                // Leave the CAF in place; better a raw file than nothing (N5).
                continue
            }
        }
    }

    /// Converts CAF PCM to AAC `.m4a` via AVAssetExportSession (no ffmpeg shell-out).
    private static func convertCAFToM4A(caf: URL, m4a: URL) async throws {
        let asset = AVURLAsset(url: caf)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.conversionFailed(String(localized: "recorder.error.conversion"))
        }
        try? FileManager.default.removeItem(at: m4a)
        export.outputURL = m4a
        export.outputFileType = .m4a
        // Use the completion-handler API (available on the macOS 14 floor); the
        // no-argument async `export()` is macOS 15+.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed {
            throw RecorderError.conversionFailed(export.error?.localizedDescription ?? "export failed")
        }
    }
}

/// Lock-guarded sink for the realtime audio tap. `@unchecked Sendable` because
/// access to the non-Sendable `AVAudioFile` is serialized by the lock.
private final class AudioFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    private var closed = false

    init(url: URL, format: AVAudioFormat) throws {
        // CAF with the input's native PCM settings: written frame-by-frame.
        self.file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try? file.write(from: buffer)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }
}
