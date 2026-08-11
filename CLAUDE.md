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
- `Sources/SearchIndex/` - local FTS5 index over the **system `sqlite3`** (ADR-5,
  not GRDB); rebuildable from files (ADR-2). `SearchFilter` = text + project /
  status / date. Note: `search()` needs a non-empty query - browse/filter the
  in-memory `sessions` list, not the index.
- `Sources/MediaKit/` - AVFoundation audio mixing (mic + system → one track,
  ADR-7), in its own SPM target so it's unit-testable via `swift test`.
- `Apps/Mac/` - `MenuBarExtra` app + `Recorder` actor (CAF→m4a, ADR-3).
  `AppCommands.swift` holds all keyboard shortcuts: a menu-bar `Commands` block
  whose context-dependent items read `focusedSceneValue`s (`recordAction`,
  `detailActions`) published by `LibraryView`/`SessionDetailView`. Add new
  shortcuts there, not with ad-hoc `.keyboardShortcut` on buttons.
- `Apps/Shared/` - `AppModel`, SwiftUI views, `Scheduler` (ADR-4),
  `Localizable.xcstrings`, and `Resources/Assets.xcassets` with the shared
  `AppIcon` (wired via `ASSETCATALOG_COMPILER_APPICON_NAME`). Icon source art:
  `docs/branding/`. **`Apps/Shared/` compiles only into the Mac target** - iOS
  and watch have their own `AppModel`/views (`Apps/iOS/`, `Apps/Watch/`).
- `Apps/Common/` - **cross-platform** SwiftUI/AVFoundation shared by all three
  apps: the audio player (scrubber/speed/tap-to-seek), live waveform,
  `ProjectChip`, and the markdown/copy/export document views.
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
- **Pipeline tuning lives in the container**, not env. `PipelineConfig` at
  `<container>/config/pipeline.json` (transcription language/vocabulary/model,
  summary language/model, custom instructions) is written by Settings and read
  by `process-session`, so standalone runs honor it. App-behavior toggles use
  `@AppStorage`/`SettingsKeys` (Mac).
- **Preserve the summarize frontmatter contract.** `claude` must emit a leading
  `---` block with `title:` + `language:`; `Summarizer` parses those to set the
  session title/language. Custom prompt text is *appended* to the built-in
  prompt (`SummarizePrompt.extra`), it never replaces the required format.
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

Dev env overrides: see the table in `README.md`. Deployment floors: macOS 14 /
iOS 17 / watchOS 10. Git: commit each working part, work on a branch, **rebase
before pushing**, never force-push; `.worktrees/` is gitignored.

## Subprocess & tools

- `ProcessCommandRunner` (SharedKit) runs every external command. It **augments
  `PATH`** (`ShellPath.augmented`) so a GUI-launched app finds Homebrew/pip CLIs
  (`ffmpeg`/`claude`/whisper) - GUI apps otherwise get a minimal `PATH`. It also
  sets the child **working directory** (to the session folder for the pipeline)
  so subprocesses don't roam `/` and trigger broad macOS file-access prompts.
- `HelperLocator` (Apps/Shared) finds the bundled `process-session` - a Mac
  **build phase** compiles it and copies it into `Contents/Helpers/`, with
  `transcribe.sh` in `Contents/Resources/`. `ToolLocator` (ProcessSession) reads
  `CLAUDE_BIN` / `CLAUDE_MODEL` / `TRANSCRIBE_*` env defaults (overridden by
  `PipelineConfig` for app runs).
- Recording is **one combined track** (ADR-7): mic + optional system audio are
  mixed into `mic.m4a` on stop, which is what gets transcribed. Screen Recording
  permission is required for system audio; failures surface, never silent.

## Testing conventions

- **Swift Testing** (`@Test`/`@Suite`/`#expect`), not XCTest, unless tooling
  forces XCTest/XCUITest.
- Fake `CommandRunning` for anything that would run Whisper/`claude`.
- Container tests use a temp `LocalFolderContainer`.
- AVFoundation export **works headless** in `swift test` (MediaKit), but
  `AVAudioFile.write` needs a buffer in the file's **processing format** (float),
  not its storage format - a mismatch crashes.

## Gotchas (hard-won)

- **Colored icons don't render in SwiftUI macOS menus** - SF Symbols are forced
  monochrome, and even `Image(nsImage:).renderingMode(.original)` failed. Use a
  **colored emoji** as the indicator (`ProjectColor.emoji(for:)`); the project
  palette is aligned to emoji-backed colors.
- **Permissions** flow through one `PermissionsModel` (Apps/Mac), shared by
  first-run onboarding and the **Settings → Diagnostics** tab (Allow when
  not-determined, Open Settings when denied). Notification auth is requested in
  onboarding, not at launch, so opening the app fires no surprise prompt.
- The **Diagnostics panel** (`DiagnosticsView`) is one view reused by the
  standalone window and the Settings tab; its permission rows are the mic/screen
  checks, filtered out of the tool-checks list to avoid duplication.

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
  (`Casks/protokoll.rb`) served from this repo via a custom tap URL. The reusable
  `.github/workflows/release.yml`, invoked by the root `ci.yml` on a `v*` tag
  (after test + build pass), builds, optionally Developer ID-signs + notarizes
  (secrets-gated, off by default), zips, publishes a GitHub Release, and
  auto-bumps the cask. CI triggers live only in `ci.yml` (reusable
  test/build/release workflows); it runs on PRs + pushes to `main`. To cut a
  release, use the `release-app` skill (`.claude/skills/release-app/`): it picks
  the version, writes user-first release notes, pushes the `vX.Y.Z` tag, and
  attaches the notes once the workflow publishes.
- **User docs:** a self-contained static one-pager lives in `site/index.html`
  (assets in `site/`), deployed to GitHub Pages by `.github/workflows/pages.yml`
  on pushes touching `site/`. Published at `https://mtze.github.io/Protokoll/`.

Session actions (macOS): the sidebar row **context menu** is the home for
per-session actions (`LibraryView.sessionMenuItems(for:)`) - Process/Retry/
Regenerate, Rename, Reveal in Finder, Assign to Project, Delete - and the
"Session" system menu (`AppCommands`) mirrors them for the selected session via
`DetailActions`. The detail pane keeps only the primary action + project menu (no
Reveal/Delete icons). Rename persists a custom title via `AppModel.rename(_:to:)`
(sets `metadata.title`, reindexes; empty reverts to the derived `displayTitle`).

Session deletion: `Container.deleteSession(_:)` removes the whole session folder
(Trash on macOS, outright elsewhere); `AppModel`/`IOSAppModel` `deleteSession(_:)`
also prune the FTS index. Mac exposes it via the sidebar context menu (destructive
confirmation); iOS via swipe-to-delete + confirmation.

Projects/Tags (F7) is **done**: `Project` + `session.metadata.projects` +
`projects.json`; a Settings → **Projects** tab (color from `ProjectColor.palette`);
project chips on rows/detail; an **assign** menu; and a sidebar-header **filter**
(feeding `SearchFilter.projectID`). Sessions also show date **+ time** (multiple
meetings a day).

Targets build via XcodeGen: `Protokoll-Mac`, `Protokoll-iOS`,
`Protokoll-Watch`. Remaining/open work is tracked as GitHub issues (#8-#14):
real iCloud sync (#8), watchOS viewer (#9), F5 agenda (#10), signing/notarization
+ distribution (#11), deferred NH1-NH3 (#12), a first real end-to-end run (#13),
retention options (#14). See "Manual verification required" in the PR/report for
what can't be checked headlessly (live mic, permissions, real iCloud, signing).
