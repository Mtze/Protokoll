# Protokoll

[![CI](https://github.com/Mtze/Protokoll/actions/workflows/ci.yml/badge.svg)](https://github.com/Mtze/Protokoll/actions/workflows/ci.yml)

A local, free, privacy-preserving meeting recorder and protocol pipeline for
macOS (and iOS/watchOS in later milestones). Record audio into an iCloud
container of open files; a Mac-side pipeline turns audio into a transcript and a
protocol. Nothing leaves your machine except the sync of your own iCloud
container (N2). See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full spec and
[`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) for the milestone
plan.

## What works today (M1)

- **Mac menubar app** (`MenuBarExtra`): record the microphone, see a live
  recording indicator, an aggregate health dot, and a library of past sessions.
- **Pipeline** (`process-session`): transcribe locally (Whisper) then summarize
  via `claude -p` into a decisions-focused protocol.
- **Diagnostics/Preflight**: checks for `claude`, a Whisper engine, the model,
  `ffmpeg`, PATH, and container access, each with plain-language explanations,
  a Details disclosure, tiered Fix buttons, and an end-to-end **System-Test**.
- Localized **English + German** throughout.

## Prerequisites

- macOS 14+ on Apple Silicon, Xcode 26+, Swift 6.2.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- The app's **Diagnostics** panel installs the rest for you (`ffmpeg`, a Whisper
  engine, the model). Manual fallback:
  ```
  brew install ffmpeg
  pip install mlx-whisper          # Apple Silicon, primary engine
  # or: brew install whisper-cpp && scripts/setup.sh --model large-v3
  ```
- `claude` CLI installed and logged in (`claude login`) - no API key (N1).

## Build & run

```bash
# 1. Build + test the package (SharedKit, pipeline, diagnostics)
swift build
swift test

# 2. Generate the Xcode project (the .xcodeproj is gitignored)
xcodegen generate

# 3. Build the Mac app (unsigned dev build)
xcodebuild -project Protokoll.xcodeproj -scheme Protokoll-Mac \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO

# 4. Run the pipeline by hand on a session folder
.build/debug/process-session <session-folder> --step all
```

### Dev overrides (env)

| Variable | Purpose |
|----------|---------|
| `PROCESS_SESSION_BIN` | Path to the `process-session` binary the app runs. |
| `TRANSCRIBE_SH` | Path to the vendored `scripts/transcribe.sh`. |
| `TRANSCRIBE_MODEL` | Whisper model (`large-v3` prod default; `tiny` for fast dry-runs). |
| `MN_CONTAINER_ROOT` | Override the container folder (dev/tests). |
| `MN_REPO_ROOT` | Repo root for the app's dev helper/asset fallbacks. |
| `CLAUDE_MODEL` | Summarization model (default `opus`). |

In dev the app stores sessions under
`~/Library/Application Support/Protokoll/Container`. The real iCloud
container is wired in M3.

## Layout

```
Sources/SharedKit/     Foundation-only model + container access (ADR-2)
Sources/ProcessSession/ the process-session pipeline CLI (ADR-1)
Sources/Diagnostics/   preflight checks, remediation, System-Test
Apps/Mac/              menubar app + Recorder actor (ADR-3)
Apps/Shared/           SwiftUI views, scheduler (ADR-4), String Catalog
scripts/               vendored transcribe.sh (+ setup.sh)
fastlane/              build/test lanes
```

## Signing & notarization (manual)

Dev builds here are **unsigned** (`CODE_SIGNING_ALLOWED=NO`). For distribution
the Mac app is **non-sandboxed, Developer ID-signed, notarized** (it execs
user-installed CLIs which the App Sandbox forbids - decision #3). That requires
a Developer ID certificate and an Apple Developer account and is a manual step
outside this automated build.

## Testing

`swift test` runs the Swift Testing suites for SharedKit, the pipeline, and
Diagnostics. The subprocess boundary (`CommandRunning`) is faked so tests never
shell out to Whisper or `claude`. `fastlane test` wraps the same.

## Logging & debugging

All apps and the `process-session` CLI log through one facility, `AppLog`
(`Sources/SharedKit/AppLog.swift`), built on Apple's unified logging
(`os.Logger`). Everything shares the subsystem `com.protokoll` with a category
per flow: `recording`, `systemaudio`, `pipeline`, `scheduler`, `diagnostics`,
`container`, `search`.

View logs live from the terminal or in Console.app:

```bash
# Everything from the app + pipeline
log stream --predicate 'subsystem == "com.protokoll"'

# Just one flow
log stream --predicate 'subsystem == "com.protokoll" && category == "pipeline"'

# Past hour, including debug/info
log show --last 1h --debug --info --predicate 'subsystem == "com.protokoll"'
```

Privacy: logs never contain transcript or audio content - only session IDs,
folder names, states, step names, durations, exit codes, and error messages.
