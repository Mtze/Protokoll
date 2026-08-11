import Foundation

/// The primary action a session's detail view should offer, derived from the
/// *persisted* pipeline status so it survives an app restart (a failed session
/// still offers Retry after relaunch, even though the in-memory job is gone).
public enum SessionAction: Equatable, Sendable {
    case process      // fresh recording, never processed
    case retry        // failed or interrupted mid-run - re-run it
    case regenerate   // done - regenerate the protocol
    case none         // a job is currently in flight; the progress box shows it

    public static func forDetail(status: PipelineStatus, hasActiveJob: Bool) -> SessionAction {
        if hasActiveJob { return .none }
        switch status {
        case .recorded: return .process
        case .done: return .regenerate
        case .failed, .transcribing, .transcribed, .summarizing: return .retry
        }
    }
}
