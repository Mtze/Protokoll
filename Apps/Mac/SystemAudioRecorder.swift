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

    /// Latest system-audio level (0...1), written on the stream's sample-handler
    /// queue and read from the main actor for the waveform. A `nonisolated let`
    /// of a lock-guarded, `Sendable` holder (mirrors `Recorder.meter`).
    nonisolated let levelMeter = SystemAudioLevelMeter()

    /// Current system-audio input level for the live waveform (0...1).
    nonisolated func currentLevel() -> Float { levelMeter.value }

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

        levelMeter.reset()
        let output = try AudioStreamOutput(url: url, levelMeter: levelMeter)
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
        levelMeter.reset()
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
    private let levelMeter: SystemAudioLevelMeter
    private var started = false
    private var sampleCount = 0

    init(url: URL, levelMeter: SystemAudioLevelMeter) throws {
        self.levelMeter = levelMeter
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
        if let level = Self.level(from: sampleBuffer) { levelMeter.store(level) }
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

    /// Computes a normalized RMS level (0...1) for the buffer using the same
    /// dB curve as the mic meter (`AudioLevels.normalize`). Handles Float32 and
    /// Int16 PCM, interleaved or not, and returns `nil` for empty/unreadable
    /// buffers so the last level is kept. No audio content is retained or logged.
    static func level(from sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return nil }

        var bufferListSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil) == noErr, bufferListSize > 0 else { return nil }

        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        let audioBufferList = listPointer.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer) == noErr, blockBuffer != nil else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = asbd.mBitsPerChannel
        var sumSquares: Float = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if isFloat, bits == 32 {
                let n = byteCount / MemoryLayout<Float>.size
                guard n > 0 else { continue }
                let samples = data.bindMemory(to: Float.self, capacity: n)
                for i in 0..<n { let s = samples[i]; sumSquares += s * s }
                count += n
            } else if bits == 16 {
                let n = byteCount / MemoryLayout<Int16>.size
                guard n > 0 else { continue }
                let samples = data.bindMemory(to: Int16.self, capacity: n)
                for i in 0..<n { let s = Float(samples[i]) / 32_768; sumSquares += s * s }
                count += n
            }
        }
        guard count > 0 else { return nil }
        let rms = (sumSquares / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return AudioLevels.normalize(db: db)
    }
}

/// Lock-guarded holder for the latest system-audio level (0...1). Written on the
/// stream's sample-handler queue and read from the main actor for the meter.
/// `@unchecked Sendable`: the `NSLock` serializes all access to the value.
final class SystemAudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float = 0

    var value: Float {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func store(_ level: Float) {
        lock.lock(); _value = level; lock.unlock()
    }

    func reset() {
        lock.lock(); _value = 0; lock.unlock()
    }
}
