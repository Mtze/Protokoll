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
