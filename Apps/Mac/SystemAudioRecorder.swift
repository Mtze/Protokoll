import AVFoundation
import Foundation
import ScreenCaptureKit
import SharedKit

/// Optional system-audio capture for calls (F2) via ScreenCaptureKit's
/// audio-only `SCStream` - no BlackHole or kernel extension needed. Writes a
/// separate `system.m4a` track alongside the mic, which also gives rough
/// speaker separation later (NH1) for free. Requires Screen Recording
/// permission.
///
/// An `actor` coordinating the stream; the stream output writes AAC via an
/// `AVAssetWriter`.
actor SystemAudioRecorder {
    private var stream: SCStream?
    private var output: AudioStreamOutput?

    enum SystemAudioError: Error, LocalizedError {
        case noDisplay
        case notSupported

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available for system-audio capture."
            case .notSupported: return "System-audio capture requires macOS 13 or later."
            }
        }
    }

    /// Starts capturing system audio to `url` (`system.m4a`).
    func start(to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        // A tiny video size keeps the (unused) video path cheap; we only consume audio.
        configuration.width = 2
        configuration.height = 2

        let output = try AudioStreamOutput(url: url)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
    }

    /// Stops capture and finalizes `system.m4a`.
    func stop() async {
        try? await stream?.stopCapture()
        await output?.finish()
        stream = nil
        output = nil
    }
}

/// Writes captured audio sample buffers to an `.m4a` (AAC) via `AVAssetWriter`.
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "systemaudio.write")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false

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
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() async {
        guard started else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
