import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MediaKit
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
    /// Whether the last finished recording clipped. Read by the app to warn once,
    /// after stopping.
    private(set) var didClip = false

    /// Live input level, updated from the realtime tap and read by the meter UI.
    /// A `let` of a `Sendable` type, so the main actor can read it without hops.
    nonisolated let meter = AudioLevelMeter()

    /// Requests microphone access (TCC). Returns `true` if granted.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Begins capturing to `session.micCaptureURL` (CAF).
    ///
    /// `voiceProcessing` enables the OS echo-cancellation / noise-suppression /
    /// AGC front end on the mic path. It matters when the meeting plays through
    /// laptop speakers: the mic re-records the remote participants with a delay,
    /// so the track contains their voices twice - a distortion no post-hoc
    /// denoiser can undo. It is opt-in because it *is* itself an enhancement
    /// chain (so it carries the same "may hurt ASR" risk as any denoiser), it
    /// changes the input format, and it can fail on some devices.
    ///
    /// `inputDeviceUID` selects a specific input device (from Settings). `nil`
    /// keeps the system default. The device is bound *after* the voice-processing
    /// toggle, because enabling AEC swaps in the AUVoiceIO audio unit and would
    /// reset any device set on the old one.
    func start(session: Session, voiceProcessing: Bool = false, inputDeviceUID: String? = nil) throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                AppLog.recording.info("voice processing (AEC) enabled")
            } catch {
                // Never fail the recording over this - carry on unprocessed.
                AppLog.recording.warning("voice processing unavailable: \(AppLog.describe(error), privacy: .public)")
            }
        } else if input.isVoiceProcessingEnabled {
            // A previous run may have left it on; the node outlives one recording.
            try? input.setVoiceProcessingEnabled(false)
        }
        bindInputDevice(inputDeviceUID, on: input)
        // Read the format *after* toggling: voice processing changes it.
        let format = input.outputFormat(forBus: 0)
        try FileManager.default.createDirectory(at: session.audioDirectory, withIntermediateDirectories: true)

        let writer: AudioFileWriter
        do {
            writer = try AudioFileWriter(url: session.micCaptureURL, format: format)
        } catch {
            throw RecorderError.engineFailure(error.localizedDescription)
        }

        let meter = self.meter
        meter.reset()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
            meter.update(buffer)
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
        AppLog.recording.info("recording started session=\(session.id, privacy: .public) folder=\(AppLog.folderName(session.folder), privacy: .public)")
    }

    /// Points the engine's input node at a specific CoreAudio device. A no-op
    /// when `uid` is nil (system default). If the UID no longer resolves (device
    /// unplugged) we log and fall back to the default rather than fail the run.
    private func bindInputDevice(_ uid: String?, on input: AVAudioInputNode) {
        guard let uid, !uid.isEmpty else { return }
        guard let deviceID = AudioInputDevices.deviceID(forUID: uid) else {
            AppLog.recording.warning("preferred input device is unavailable; using system default")
            return
        }
        // Drop any graph format cached from a previous device before rebinding.
        engine.reset()
        guard let audioUnit = input.audioUnit else {
            AppLog.recording.warning("input node has no audio unit; using system default")
            return
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            AppLog.recording.info("input device bound uid=\(uid, privacy: .public)")
        } else {
            AppLog.recording.warning("failed to bind input device status=\(status, privacy: .public); using system default")
        }
    }

    /// Stops capture, finalizes the CAF, and produces `mic.m4a` - mixing in the
    /// system-audio track when present (ADR-7) so the transcript covers the whole
    /// call, not just the mic. Returns the session with updated `endedAt`/`duration`.
    func stop(mixSystemAudio: Bool = false) async throws -> Session {
        guard isRecording, var session, let startedAt else {
            throw RecorderError.engineFailure(String(localized: "recorder.error.notRecording"))
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
        // Read the clipping verdict before resetting the meter. Clipping is baked
        // into the samples and nothing downstream can undo it - attenuating a
        // clipped file only makes the speech quieter - so the only useful moment
        // to say so is here, while the user can still lower the input level.
        let clipped = meter.isClipping
        let clippedFraction = meter.clippedFraction
        meter.reset()
        isRecording = false
        if clipped {
            AppLog.recording.warning("input clipped on \(clippedFraction * 100, format: .fixed(precision: 2), privacy: .public)% of samples session=\(session.id, privacy: .public); input level is too high")
        }
        didClip = clipped

        // Produce mic.m4a via a temp file and an atomic rename, so the player,
        // pipeline, and NewSessionNotifier never observe a half-written export
        // (a partial mic.m4a would leave the audio player stuck disabled).
        let finalURL = session.micAudioURL
        let partialURL = finalURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)
        let systemURL = session.systemAudioURL
        if mixSystemAudio, FileManager.default.fileExists(atPath: systemURL.path) {
            AppLog.recording.info("mixing mic + system audio session=\(session.id, privacy: .public)")
            try await AudioMixer.mix([session.micCaptureURL, systemURL], into: partialURL)
            try? FileManager.default.removeItem(at: systemURL)
        } else {
            AppLog.recording.info("converting CAF to m4a session=\(session.id, privacy: .public)")
            try await Self.convertCAFToM4A(caf: session.micCaptureURL, m4a: partialURL)
        }
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        try? FileManager.default.removeItem(at: session.micCaptureURL)

        let ended = Date()
        session.metadata.endedAt = ended
        session.metadata.duration = ended.timeIntervalSince(startedAt)
        session.metadata.audioTracks = [.mic]
        self.session = nil
        self.startedAt = nil
        AppLog.recording.info("recording stopped session=\(session.id, privacy: .public) duration=\(session.metadata.duration ?? 0, format: .fixed(precision: 1), privacy: .public)s")
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
            AppLog.recording.info("recovering orphaned CAF session=\(session.id, privacy: .public)")
            do {
                try await convertCAFToM4A(caf: caf, m4a: m4a)
                try? fileManager.removeItem(at: caf)
            } catch {
                // Leave the CAF in place; better a raw file than nothing (N5).
                AppLog.recording.error("orphan recovery failed session=\(session.id, privacy: .public): \(AppLog.describe(error), privacy: .public)")
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
