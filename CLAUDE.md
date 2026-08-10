# CLAUDE.md — AI onboarding for MeetingNotes

Authoritative spec: `ARCHITECTURE.md` (German). Milestone plan:
`docs/IMPLEMENTATION_PLAN.md`. Read both before non-trivial work.

## What this is

A local, free, privacy-first meeting recorder + protocol pipeline for macOS/iOS/
watchOS. Apps own no data; the **files in the container are the source of truth**
(N3, ADR-2). Processing is an on-demand subprocess, not a daemon (ADR-1).

## Architecture at a glance

- `Sources/SharedKit/` — **platform-agnostic, Foundation-only** model + container
  access. `SessionStore` is the *sole* reader/writer of `session.json`. Value
  types are `Sendable`. No AppKit/UIKit/SwiftUI here — Mac/iOS/watch reuse it.
- `Sources/ProcessSession/` — the `process-session` pipeline CLI: transcribe
  (shells out to `scripts/transcribe.sh`) → summarize (`claude -p`, print mode).
  The **pipeline owns all file writes** (rotation N10, title lift F9).
- `Sources/Diagnostics/` — preflight checks, tiered remediation, System-Test.
  UI-free and testable.
- `Apps/Mac/` — `MenuBarExtra` app + `Recorder` actor (CAF→m4a, ADR-3).
- `Apps/Shared/` — SwiftUI views, `Scheduler` (ADR-4), `Localizable.xcstrings`.

## Hard rules (do not violate)

- **i18n from line one.** No hardcoded user-facing strings. Add every string to
  `Apps/Shared/Localizable.xcstrings` with **EN + DE**. Use `LocalizedStringKey`/
  `String(localized:)`.
- **SF Symbols only** for icons. Follow Apple HIG (MenuBarExtra,
  NavigationSplitView, Dark Mode, Dynamic Type, accessibility labels).
- **Swift 6 strict concurrency.** Recorder + future Indexer are actors; models
  are `Sendable` value types.
- **`session.json` is canonical.** Only `SessionStore` reads/writes it.
- **`transcript.md` is immutable** once written (N10); regen rotates
  `protocol.md` → `protocol.vN.md`.
- **Subprocess boundary is `CommandRunning`** (in SharedKit) — fake it in tests,
  never shell out for real in unit tests.
- **Deviations from the spec** get a short ADR appended to `ARCHITECTURE.md`
  *first*.
- **Docs are part of the change**: update `README.md`, this file, `AGENTS.md`,
  and `docs/` when structure/commands/conventions shift.

## Commands

```bash
swift build && swift test            # package + tests (Swift Testing)
xcodegen generate                    # regenerate the gitignored .xcodeproj
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes-Mac \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Dev env overrides: see the table in `README.md`.

## Testing conventions

- **Swift Testing** (`@Test`/`@Suite`/`#expect`), not XCTest, unless tooling
  forces XCTest/XCUITest.
- Fake `CommandRunning` for anything that would run Whisper/`claude`.
- Container tests use a temp `LocalFolderContainer`.

## Milestone status

- **M1 (done):** SharedKit, pipeline, Diagnostics, Mac app, i18n, ADR-3/ADR-4.
- **M2–M6:** see `docs/IMPLEMENTATION_PLAN.md`. `chunkTranscript()` in
  ProcessSession is the M2 map-reduce seam (N9).
