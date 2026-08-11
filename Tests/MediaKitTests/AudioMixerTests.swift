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

    @Test func throwsWhenNoInputsHaveAudio() async {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).m4a")
        await #expect(throws: AudioMixer.MixError.self) {
            try await AudioMixer.mix([], into: output)
        }
    }
}
