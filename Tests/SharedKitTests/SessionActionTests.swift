import Foundation
import Testing
@testable import SharedKit

/// Regression tests: the detail action is derived from persisted status, so a
/// failed session still offers Retry after an app restart (in-memory job gone).
struct SessionActionTests {
    @Test func failedSessionOffersRetryWithoutAnActiveJob() {
        #expect(SessionAction.forDetail(status: .failed(message: "whisper not found"), hasActiveJob: false) == .retry)
    }

    @Test func interruptedMidRunStatesOfferRetry() {
        #expect(SessionAction.forDetail(status: .transcribing, hasActiveJob: false) == .retry)
        #expect(SessionAction.forDetail(status: .transcribed, hasActiveJob: false) == .retry)
        #expect(SessionAction.forDetail(status: .summarizing, hasActiveJob: false) == .retry)
    }

    @Test func recordedOffersProcessAndDoneOffersRegenerate() {
        #expect(SessionAction.forDetail(status: .recorded, hasActiveJob: false) == .process)
        #expect(SessionAction.forDetail(status: .done, hasActiveJob: false) == .regenerate)
    }

    @Test func anActiveJobSuppressesTheButton() {
        // While a job runs, the progress box owns the UI - no duplicate button.
        #expect(SessionAction.forDetail(status: .failed(message: "x"), hasActiveJob: true) == SessionAction.none)
        #expect(SessionAction.forDetail(status: .recorded, hasActiveJob: true) == SessionAction.none)
    }
}

/// The "Re-run actions" affordance (ADR-13): offered for failed, stale, and
/// orphaned-running steps of a done session, but never while a job is active.
struct RerunnableStepsTests {
    @Test func offersRerunForFailedStaleAndOrphanedRunning() {
        for status in [StepState.failed, StepState.stale, StepState.running] {
            let steps = [StepState(stepID: "s1", name: "X", status: status)]
            #expect(SessionAction.hasRerunnableSteps(status: .done, steps: steps, hasActiveJob: false))
        }
        let done = [StepState(stepID: "s1", name: "X", status: StepState.done)]
        #expect(!SessionAction.hasRerunnableSteps(status: .done, steps: done, hasActiveJob: false))
        #expect(!SessionAction.hasRerunnableSteps(status: .done, steps: nil, hasActiveJob: false))
    }

    @Test func activeJobBlocksRerun() {
        let steps = [StepState(stepID: "s1", name: "X", status: StepState.failed)]
        #expect(!SessionAction.hasRerunnableSteps(status: .done, steps: steps, hasActiveJob: true))
    }

    @Test func nonDoneStatusOffersNoRerun() {
        let steps = [StepState(stepID: "s1", name: "X", status: StepState.failed)]
        #expect(!SessionAction.hasRerunnableSteps(status: .failed(message: "x"), steps: steps, hasActiveJob: false))
    }
}
