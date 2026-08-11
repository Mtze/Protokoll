# CLAUDE.md - AI onboarding for Protokoll

Authoritative spec: `ARCHITECTURE.md` (German). Milestone plan:
`docs/IMPLEMENTATION_PLAN.md`. Read both before non-trivial work.

## What this is

A local, free, privacy-first meeting recorder + protocol pipeline for macOS/iOS/
watchOS. Apps own no data; the **files in the container are the source of truth**
(N3, ADR-2). Processing is an on-demand subprocess, not a daemon (ADR-1).

## Architecture at a glance

- `Sources/SharedKit/` - **platform-agnostic, Foundation-only** model + container
  access. `SessionStore` is the *sole* reader/writer of `session.json`. Value
  types are `Sendable`. No AppKit/UIKit/SwiftUI here - Mac/iOS/watch reuse it.
- `Sources/ProcessSession/` - the `process-session` pipeline CLI: transcribe
  (shells out to `scripts/transcribe.sh`) → summarize (`claude -p`, print mode).
  The **pipeline owns all file writes** (rotation N10, title lift F9).
- `Sources/Diagnostics/` - preflight checks, tiered remediation, System-Test.
  UI-free and testable.
- `Apps/Mac/` - `MenuBarExtra` app + `Recorder` actor (CAF→m4a, ADR-3).
- `Apps/Shared/` - SwiftUI views, `Scheduler` (ADR-4), `Localizable.xcstrings`.
- `Sources/SharedKit/AppLog.swift` - the one logging facility (`os.Logger`,
  subsystem `com.protokoll`, a category per flow). Every module + app uses it.

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
- **Subprocess boundary is `CommandRunning`** (in SharedKit) - fake it in tests,
  never shell out for real in unit tests.
- **Log via `AppLog`, never `print`** in library/app code. Pick the matching
  category (`recording`/`systemaudio`/`pipeline`/`scheduler`/`diagnostics`/
  `container`/`search`); mark non-sensitive interpolations `privacy: .public` so
  they show in the stream. **Never log transcript/audio content or absolute
  paths with a user name** - log session IDs, `AppLog.folderName(url)`, states,
  durations, exit codes, `AppLog.describe(error)`. View with
  `log stream --predicate 'subsystem == "com.protokoll"'`.
- **Deviations from the spec** get a short ADR appended to `ARCHITECTURE.md`
  *first*.
- **Docs are part of the change**: update `README.md`, this file, `AGENTS.md`,
  and `docs/` when structure/commands/conventions shift.

## Commands

```bash
swift build && swift test            # package + tests (Swift Testing)
xcodegen generate                    # regenerate the gitignored .xcodeproj
xcodebuild -project Protokoll.xcodeproj -scheme Protokoll-Mac \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Dev env overrides: see the table in `README.md`.

## Testing conventions

- **Swift Testing** (`@Test`/`@Suite`/`#expect`), not XCTest, unless tooling
  forces XCTest/XCUITest.
- Fake `CommandRunning` for anything that would run Whisper/`claude`.
- Container tests use a temp `LocalFolderContainer`.

## Milestone status

- **M1 (done):** SharedKit, pipeline, Diagnostics + System-Test, Mac app
  (recorder/scheduler/library), i18n, ADR-3/ADR-4. Fresh-review folded.
- **M2 (mostly done):** map-reduce for long transcripts (N9); consent reminder +
  Settings (N4); system-audio capture via ScreenCaptureKit (F2) + Screen
  Recording check. Per-step retry UX is basic.
- **M3 (core done):** local FTS5 index over the system SQLite (ADR-5, replaces
  GRDB) with rebuild-from-files; live library search (F10). Real iCloud
  container is stood up behind the `UbiquityContainer` seam (entitlement/
  provisioning is a manual step).
- **M4 (done):** iOS app (Apps/iOS) - lean recorder (F11), geotag (F8), viewer +
  FTS search (F12), reuses SharedKit + SearchIndex + the String Catalog.
- **M5 (done):** new-recording notifications with a Process action (F13).
- **M6 (foundation):** watchOS target + ADR-6 (WatchConnectivity -> iPhone ->
  container); iOS `WatchReceiver` files watch recordings into the container.
- **Distribution (ADR-8):** the Mac app ships as a Homebrew cask
  (`Casks/protokoll.rb`) served from this repo via a custom tap URL. A
  tag-triggered workflow (`.github/workflows/release.yml`) builds, optionally
  Developer ID-signs + notarizes (secrets-gated, off by default), zips, publishes
  a GitHub Release, and auto-bumps the cask.

Session deletion: `Container.deleteSession(_:)` removes the whole session folder
(Trash on macOS, outright elsewhere); `AppModel`/`IOSAppModel` `deleteSession(_:)`
also prune the FTS index. Mac exposes it via a sidebar context menu + a detail
trash button (destructive confirmation); iOS via swipe-to-delete + confirmation.

Targets build via XcodeGen: `Protokoll-Mac`, `Protokoll-iOS`,
`Protokoll-Watch`. See "Manual verification required" in the PR/report for
what can't be checked headlessly (live mic, permissions, real iCloud, signing).
Projects UI (group/filter chips) and F5 agenda integration remain future work.
