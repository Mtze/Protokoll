import Foundation
import Testing
@testable import SharedKit

/// Regression tests for the system-audio (F2) recording glue: track resolution
/// and the controller that turns capture failures into a surfaced message
/// rather than a silent mic-only fallback.
struct SystemAudioTests {
    private struct SampleError: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private struct FakeCapture: SystemAudioCapturing {
        var startError: (any Error)?
        var didCapture: Bool = true
        func start(to url: URL) async throws {
            if let startError { throw startError }
        }
        func stop() async -> Bool { didCapture }
    }

    @Test func systemTrackAppearsOnlyWhenRequestedAndProduced() {
        #expect(AudioTrackResolver.tracks(systemRequested: false, systemProducedAudio: false) == [.mic])
        #expect(AudioTrackResolver.tracks(systemRequested: true, systemProducedAudio: false) == [.mic])
        #expect(AudioTrackResolver.tracks(systemRequested: false, systemProducedAudio: true) == [.mic])
        #expect(AudioTrackResolver.tracks(systemRequested: true, systemProducedAudio: true) == [.mic, .system])
    }

    @Test func controllerReportsSuccessfulStart() async {
        let controller = SystemAudioController(capture: FakeCapture())
        let outcome = await controller.begin(to: URL(fileURLWithPath: "/tmp/system.m4a"))
        #expect(outcome.capturing)
        #expect(outcome.error == nil)
        #expect(await controller.end() == true)
    }

    @Test func controllerSurfacesStartFailureInsteadOfSwallowing() async {
        let controller = SystemAudioController(capture: FakeCapture(startError: SampleError()))
        let outcome = await controller.begin(to: URL(fileURLWithPath: "/tmp/system.m4a"))
        #expect(!outcome.capturing)
        #expect(outcome.error == "boom")
    }

    @Test func controllerReportsWhenNoAudioWasCaptured() async {
        let controller = SystemAudioController(capture: FakeCapture(didCapture: false))
        _ = await controller.begin(to: URL(fileURLWithPath: "/tmp/system.m4a"))
        #expect(await controller.end() == false)
    }
}
