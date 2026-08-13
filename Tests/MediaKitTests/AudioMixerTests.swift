import AVFoundation
import Foundation
import Testing
@testable import MediaKit

/// Regression tests for combining mic + system audio into one track (ADR-7).
struct AudioMixerTests {
    /// Writes a mono 16 kHz tone of `seconds` to a CAF file. Uses the standard
    /// float format so the buffer matches the file's processing format.
    private func writeTone(seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData {
            for i in 0..<Int(frames) {
                channel[0][i] = Float(sin(Double(i) * 0.05)) * 0.3
            }
        }
        try file.write(from: buffer)
    }

    @Test func mixesTwoClipsIntoOneOfTheLongerLength() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let short = dir.appendingPathComponent("mic.caf")
        let long = dir.appendingPathComponent("system.caf")
        let output = dir.appendingPathComponent("mixed.m4a")
        try writeTone(seconds: 1.0, to: short)
        try writeTone(seconds: 2.5, to: long)

        try await AudioMixer.mix([short, long], into: output)

        #expect(FileManager.default.fileExists(atPath: output.path))
        let duration = try await AVURLAsset(url: output).load(.duration)
        // The mix spans the longer input, proving the second track was included.
        #expect(abs(CMTimeGetSeconds(duration) - 2.5) < 0.3)
    }

    /// Writes a mono 16 kHz tone at `amplitude` (1.0 = full scale).
    private func writeTone(seconds: Double, amplitude: Float, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData {
            for i in 0..<Int(frames) {
                channel[0][i] = Float(sin(Double(i) * 0.05)) * amplitude
            }
        }
        try file.write(from: buffer)
    }

    /// Reads the peak absolute sample of an audio file.
    private func peakAmplitude(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        var peak: Float = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(16_384, file.length - file.framePosition))
            guard remaining > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else { break }
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channels[channel][i]))
                }
            }
        }
        return peak
    }

    /// Two in-phase near-full-scale tones sum past full scale at unity gain.
    /// The -6 dB per-track mix must keep the result inside 0 dBFS.
    @Test func mixingTwoHotTracksDoesNotClip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliptest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        let output = dir.appendingPathComponent("mixed.m4a")
        // 0.9 + 0.9 = 1.8 at unity gain: hard clipping without the audio mix.
        try writeTone(seconds: 1.0, amplitude: 0.9, to: mic)
        try writeTone(seconds: 1.0, amplitude: 0.9, to: system)

        try await AudioMixer.mix([mic, system], into: output)

        let peak = try peakAmplitude(of: output)
        // AAC can overshoot slightly on transients; the point is we are near 0.9
        // (the attenuated sum) rather than pinned at 1.0 by clipping.
        #expect(peak <= 1.0)
        #expect(peak < 0.99)
    }

    /// A lone source must not be attenuated - there is nothing to sum with.
    @Test func singleTrackKeepsUnityGain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gaintest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mic = dir.appendingPathComponent("mic.caf")
        let output = dir.appendingPathComponent("mixed.m4a")
        try writeTone(seconds: 1.0, amplitude: 0.5, to: mic)

        try await AudioMixer.mix([mic], into: output)

        let peak = try peakAmplitude(of: output)
        // Would be ~0.25 if the -6 dB mix were applied to a single track.
        #expect(peak > 0.4)
    }

    @Test func throwsWhenNoInputsHaveAudio() async {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).m4a")
        await #expect(throws: AudioMixer.MixError.self) {
            try await AudioMixer.mix([], into: output)
        }
    }
}
