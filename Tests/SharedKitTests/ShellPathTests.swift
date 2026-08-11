import Foundation
import Testing
@testable import SharedKit

/// Regression tests for PATH augmentation - the fix for "ffmpeg is not
/// installed" when it is (a GUI app's minimal PATH omits /opt/homebrew/bin).
struct ShellPathTests {
    @Test func addsHomebrewAndLocalBinToAMinimalPath() {
        let path = ShellPath.augmented(base: "/usr/bin:/bin", home: "/Users/x")
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.contains("/usr/local/bin"))
        #expect(parts.contains("/Users/x/.local/bin"))
    }

    @Test func preservesExistingEntriesFirst() {
        let path = ShellPath.augmented(base: "/custom/tool/bin:/usr/bin", home: nil)
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.first == "/custom/tool/bin")
    }

    @Test func deduplicatesRepeatedDirectories() {
        let path = ShellPath.augmented(base: "/opt/homebrew/bin:/usr/bin", home: nil)
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test func handlesEmptyOrNilBase() {
        let path = ShellPath.augmented(base: nil, home: nil)
        #expect(path.split(separator: ":").map(String.init).contains("/opt/homebrew/bin"))
        #expect(!path.hasPrefix(":"))
    }
}
