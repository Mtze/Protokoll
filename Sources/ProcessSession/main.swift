import Foundation
import SharedKit

// process-session <folder> [--step transcribe|summarize|all] [--force]
//
// Standalone pipeline CLI (ADR-1: the menubar app runs this as a subprocess).
// Also runnable by hand for debugging or re-running an individual step (N6).

// Ignore SIGPIPE process-wide: writing a subprocess's stdin after it exited
// must surface as an error, not kill this process with a signal.
signal(SIGPIPE, SIG_IGN)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func printUsage() {
    let usage = """
    Usage: process-session <folder> [--step transcribe|summarize|all] [--force]

      <folder>   Path to a session folder (contains session.json and audio/).
      --step     Which step to run. Default: all.
      --force    Re-run a step even if its output already exists (N6, N10).
    """
    print(usage)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("-h") || arguments.contains("--help") {
    printUsage()
    exit(0)
}

var folderPath: String?
var stepSelection: PipelineStepSelection = .all
var force = false

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--step":
        guard index + 1 < arguments.count, let step = PipelineStepSelection(rawValue: arguments[index + 1]) else {
            fail("--step requires one of: transcribe, summarize, all")
        }
        stepSelection = step
        index += 2
    case "--force":
        force = true
        index += 1
    default:
        if argument.hasPrefix("-") { fail("unknown option: \(argument)") }
        if folderPath != nil { fail("more than one folder given") }
        folderPath = argument
        index += 1
    }
}

guard let folderPath else {
    printUsage()
    fail("no session folder given")
}

let folder = URL(fileURLWithPath: folderPath).standardizedFileURL
guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path) else {
    fail("no session.json in \(folder.path)")
}

// The container root is the grandparent of the session folder (…/sessions/<id>/).
let containerRoot = folder.deletingLastPathComponent().deletingLastPathComponent()
let container = Container(locator: LocalFolderContainer(root: containerRoot))

let deviceId = ProcessInfo.processInfo.environment["DEVICE_ID"] ?? Host.current().localizedName ?? "mac"
let pipeline = Pipeline(
    container: container,
    runner: ProcessCommandRunner(),
    deviceId: deviceId
)

let progress: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data("  \(line)\n".utf8))
}

do {
    let session = try pipeline.run(folder: folder, step: stepSelection, force: force, onProgress: progress)
    print("done: \(session.metadata.pipeline.status.name) - \(session.displayTitle)")
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    fail(message)
}
