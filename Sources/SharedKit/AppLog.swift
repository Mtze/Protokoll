import Foundation
import os

/// The app's single logging facility, built on Apple's unified logging
/// (`os.Logger`). One shared subsystem, one `Logger` per major flow, so any run
/// can be filtered in Console.app or streamed from the terminal:
///
/// ```sh
/// log stream --predicate 'subsystem == "com.meetingnotes"'
/// # or one flow:
/// log stream --predicate 'subsystem == "com.meetingnotes" && category == "pipeline"'
/// ```
///
/// Foundation + `os` only, so it stays usable from the Foundation-only SharedKit
/// as well as every app target.
///
/// Privacy contract: **never log transcript or audio content.** Log session IDs,
/// folder names, pipeline states, step names, durations, exit codes, and error
/// messages. Because these are non-sensitive by design, call sites mark them
/// `privacy: .public` so they are actually readable in the log stream (string
/// interpolations otherwise redact to `<private>`).
public enum AppLog {
    /// The unified-logging subsystem shared by every logger.
    public static let subsystem = "com.meetingnotes"

    /// Microphone recording: start/stop, CAF→m4a conversion, orphan recovery.
    public static let recording = Logger(subsystem: subsystem, category: "recording")

    /// System-audio capture (ScreenCaptureKit) and track mixing (ADR-7).
    public static let systemAudio = Logger(subsystem: subsystem, category: "systemaudio")

    /// The `process-session` pipeline: transcribe / summarize steps.
    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")

    /// The resource-aware scheduler (ADR-4): job lifecycle.
    public static let scheduler = Logger(subsystem: subsystem, category: "scheduler")

    /// Preflight diagnostics and the System-Test dry run.
    public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")

    /// Container / `SessionStore`: session created, saved, load failures.
    public static let container = Logger(subsystem: subsystem, category: "container")

    /// The local full-text search index (ADR-5).
    public static let search = Logger(subsystem: subsystem, category: "search")

    // MARK: Non-sensitive formatting helpers (pure, unit-tested)

    /// The opaque session folder name (`<ISO-ts>_<shortID>`) - safe to log as a
    /// stable session reference without exposing the absolute filesystem path,
    /// which can carry a user name.
    public static func folderName(_ url: URL) -> String {
        url.lastPathComponent
    }

    /// A single-line, non-sensitive description of an error: the localized
    /// message when available, otherwise the type-and-value. Used everywhere so
    /// failure logs read consistently.
    public static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
