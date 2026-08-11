import Foundation
import Testing
@testable import SharedKit

/// The logging facility's testable surface: the shared subsystem wiring and the
/// pure, non-sensitive formatting helpers used at every call site.
struct AppLogTests {
    @Test func subsystemIsStable() {
        // The documented `log stream` predicate depends on this exact value.
        #expect(AppLog.subsystem == "com.protokoll")
    }

    @Test func folderNameReducesToOpaqueSessionFolder() {
        let url = URL(fileURLWithPath: "/Users/someone/Meetings/sessions/2026-08-10T14-30-05Z_a1b2c3")
        // Redacts the absolute path (which carries a user name) to the opaque ID.
        #expect(AppLog.folderName(url) == "2026-08-10T14-30-05Z_a1b2c3")
    }

    @Test func describePrefersLocalizedError() {
        struct Sample: Error, LocalizedError {
            var errorDescription: String? { "whisper not found" }
        }
        #expect(AppLog.describe(Sample()) == "whisper not found")
    }

    @Test func describeFallsBackToTypeAndValue() {
        struct Plain: Error {}
        // Not a LocalizedError, so we still get a non-empty, non-crashing string.
        #expect(!AppLog.describe(Plain()).isEmpty)
    }
}
