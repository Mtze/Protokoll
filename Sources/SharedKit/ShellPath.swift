import Foundation

/// Builds a `PATH` that includes the usual Homebrew/pip locations.
///
/// A macOS app launched from Finder or Xcode inherits a minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits `/opt/homebrew/bin`, so
/// user-installed CLIs (`ffmpeg`, `claude`, whisper) look "not installed" to
/// every subprocess. We prepend the inherited entries (so real user overrides
/// win) and append the standard tool directories that are missing.
public enum ShellPath {
    /// Standard directories where CLIs land, in priority order.
    public static let standardToolDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// Returns a deduplicated `PATH`: the existing entries first, then the
    /// user's `~/.local/bin`, then any missing standard tool directories.
    public static func augmented(base: String?, home: String?) -> String {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ dir: String) {
            guard !dir.isEmpty, seen.insert(dir).inserted else { return }
            ordered.append(dir)
        }
        (base ?? "").split(separator: ":").map(String.init).forEach(add)
        if let home, !home.isEmpty { add(home + "/.local/bin") }
        standardToolDirectories.forEach(add)
        return ordered.joined(separator: ":")
    }
}
