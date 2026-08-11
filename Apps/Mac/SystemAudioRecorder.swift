import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SharedKit

/// Optional system-audio capture for calls (F2) via ScreenCaptureKit's
/// audio-only `SCStream` - no BlackHole or kernel extension needed. Writes a
/// separate `system.m4a` track alongside the mic, which also gives rough
/// speaker separation later (NH1) for free.
///
/// Requires Screen Recording permission; without it `SCShareableContent` yields
/// nothing, which is the usual reason "only my mic is recorded". We preflight
/// the permission and throw a clear error instead of failing silently.
actor SystemAudioRecorder: SystemAudioCapturing {
    private var stream: SCStream?
    private var output: AudioStreamOutput?

    enum SystemAudioError: Error, LocalizedError {
        case permissionDenied
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return String(localized: "systemaudio.error.permission")
            case .noDisplay: return String(localized: "systemaudio.error.noDisplay")
            }
        }
    }

    /// Starts capturing system audio to `url` (`system.m4a`).
    func start(to url: URL) async throws {
        // Screen Recording permission is required for system audio. Preflight it
        // and trigger the prompt / add the app to the list if it is missing.
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            AppLog.systemAudio.error("system-audio capture blocked: Screen Recording permission missing")
            throw SystemAudioError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            AppLog.systemAudio.error("system-audio capture failed: no display available")
            throw SystemAudioError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // We only consume audio, but a valid (non-degenerate) video size is
        // required for the stream to start; keep it small and cheap.
        configuration.width = 128
        configuration.height = 128
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = try AudioStreamOutput(url: url)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        AppLog.systemAudio.info("system-audio capture started file=\(url.lastPathComponent, privacy: .public)")
    }

    /// Stops capture, finalizes `system.m4a`, and reports whether any audio was
    /// actually written (so the app can warn when nothing was captured).
    func stop() async -> Bool {
        try? await stream?.stopCapture()
        let captured = await output?.finish() ?? false
        stream = nil
        output = nil
        AppLog.systemAudio.info("system-audio capture stopped captured=\(captured, privacy: .public)")
        return captured
    }
}

/// Writes captured audio sample buffers to an `.m4a` (AAC) via `AVAssetWriter`.
/// All mutable state is touched only on `queue` (the stream's sample-handler
/// queue and the finish continuation), so `@unchecked Sendable` is safe.
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "systemaudio.write")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var sampleCount = 0

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            sampleCount += 1
        }
    }

    /// Finalizes on `queue` (where `started`/`sampleCount` are mutated) and
    /// reports whether the file has real audio.
    func finish() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard self.started else { continuation.resume(returning: false); return }
                self.input.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed && self.sampleCount > 0)
                }
            }
        }
    }
}
