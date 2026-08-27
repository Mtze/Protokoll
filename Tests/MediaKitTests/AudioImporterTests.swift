import AVFoundation
import Foundation
import Testing
@testable import MediaKit

/// Tests for importing a pre-recorded file as the canonical `mic.m4a` (the
/// on-disk shape the pipeline consumes).
struct AudioImporterTests {
    /// Writes a mono 16 kHz tone of `seconds` to a CAF file (float buffer matches
    /// the file's processing format).
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

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("importtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func transcodesSourceIntoMicTrackWithoutLeftoverTemp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.caf")
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        let destination = audioDir.appendingPathComponent("mic.m4a")
        try writeTone(seconds: 1.5, to: source)

        try await AudioImporter.makeMicTrack(from: source, into: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        // No half-written temp file lingers next to the destination.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: audioDir.path)
            .filter { $0.hasPrefix(".importing-") }
        #expect(leftovers.isEmpty)

        let duration = await AudioImporter.duration(of: destination)
        #expect(duration != nil)
        #expect(abs((duration ?? 0) - 1.5) < 0.3)
    }

    @Test func overwritesExistingDestination() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.caf")
        let destination = dir.appendingPathComponent("audio/mic.m4a")
        try writeTone(seconds: 1.0, to: source)

        try await AudioImporter.makeMicTrack(from: source, into: destination)
        // A second import into the same path succeeds and leaves a valid file.
        try await AudioImporter.makeMicTrack(from: source, into: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(await AudioImporter.duration(of: destination) != nil)
    }

    @Test func throwsAndLeavesNoDestinationForSourceWithoutAudio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A bogus, non-audio file: transcoding must throw, not produce a session.
        let source = dir.appendingPathComponent("bogus.m4a")
        try Data("not audio".utf8).write(to: source)
        let destination = dir.appendingPathComponent("audio/mic.m4a")

        await #expect(throws: Error.self) {
            try await AudioImporter.makeMicTrack(from: source, into: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
