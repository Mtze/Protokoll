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
        var level: Float = 0
        func start(to url: URL) async throws {
            if let startError { throw startError }
        }
        func stop() async -> Bool { didCapture }
        func currentLevel() -> Float { level }
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

    @Test func controllerSurfacesTheCurrentSystemLevel() {
        let controller = SystemAudioController(capture: FakeCapture(level: 0.42))
        #expect(controller.currentLevel() == 0.42)
    }

    @Test func captureDefaultsToZeroLevel() {
        // A conformer that doesn't override `currentLevel()` reports silence.
        struct Minimal: SystemAudioCapturing {
            func start(to url: URL) async throws {}
            func stop() async -> Bool { false }
        }
        #expect(Minimal().currentLevel() == 0)
    }

    // MARK: RecordingLevel.combined

    @Test func combinedTakesTheLouderSource() {
        #expect(RecordingLevel.combined(mic: 0.2, system: 0.7) == 0.7)
        #expect(RecordingLevel.combined(mic: 0.9, system: 0.1) == 0.9)
    }

    @Test func combinedIsZeroWhenBothAreSilent() {
        #expect(RecordingLevel.combined(mic: 0, system: 0) == 0)
    }

    @Test func combinedClampsToUnitRange() {
        #expect(RecordingLevel.combined(mic: 1.5, system: 0.3) == 1)
        #expect(RecordingLevel.combined(mic: -0.4, system: -0.2) == 0)
    }

    @Test func combinedTreatsNaNAsSilence() {
        #expect(RecordingLevel.combined(mic: .nan, system: 0.5) == 0.5)
        #expect(RecordingLevel.combined(mic: .nan, system: .nan) == 0)
    }
}
