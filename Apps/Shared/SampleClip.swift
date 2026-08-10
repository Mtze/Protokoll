import Foundation

/// Locates the bundled ~3 s audio clip used by the System-Test dry run.
enum SampleClip {
    static func url() -> URL? {
        if let bundled = Bundle.main.url(forResource: "systemtest-sample", withExtension: "m4a") {
            return bundled
        }
        // Dev fallback: the checked-in asset next to the repo.
        let candidate = HelperLocator.repoRoot()
            .appendingPathComponent("Apps/Shared/Resources/systemtest-sample.m4a")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
