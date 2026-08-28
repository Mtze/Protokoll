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
  (shells out to `scripts/transcribe.sh`) → summarize via a pluggable
  `SummaryEngine` (ADR-9): local `claude -p` (default), the Anthropic Messages
  API, or an OpenAI-compatible endpoint. API calls go through the injectable
  `HTTPPosting` seam (fake it in tests, like `CommandRunning`). The **pipeline
  owns all file writes** (rotation N10, title lift F9).
- `Sources/Diagnostics/` - preflight checks, tiered remediation, System-Test.
  UI-free and testable.
- `Sources/SearchIndex/` - local FTS5 index over the **system `sqlite3`** (ADR-5,
  not GRDB); rebuildable from files (ADR-2). `SearchFilter` = text + project /
  status / date. Note: `search()` needs a non-empty query - browse/filter the
  in-memory `sessions` list, not the index.
- `Sources/MediaKit/` - AVFoundation audio mixing (mic + system → one track,
  ADR-7) and `AudioImporter` (transcode an arbitrary recording to the canonical
  `mic.m4a` for import), in its own SPM target so it's unit-testable via
  `swift test`.
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
  `ProjectChip`, and the document views - `DocumentTextView` renders protocol and
  transcript into one selectable text view (ADR-12), `DocumentViews` keeps the
  Markdown block parser and the copy/export actions.
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
  `protocol.md` → `protocol.vN.md`. The **one** exception is the user-invoked
  "Transcribe Again" action (ADR-11), which rotates `transcript.md` →
  `transcript.vN.md` and forces the summarize too, so the protocol never
  silently describes the previous transcript. All transcript writes go through
  `SessionStore.writeTranscript` so the rotation cannot be bypassed.
- **Pipeline tuning lives in the container**, not env. `PipelineConfig` at
  `<container>/config/pipeline.json` (transcription language/vocabulary/model/
  audio preprocessing, summary language/model, custom instructions, plus the
  summary provider: `summaryProvider`/`summaryApiModel`/`summaryApiBaseURL`/
  `summaryMaxTokens`) is written by Settings and read by `process-session`, so
  standalone runs honor it. The summary body spec is a sibling *file*,
  `config/summary-prompt.md` (absent = default). App-behavior toggles use
  `@AppStorage`/`SettingsKeys` (Mac). **The API key is a secret and never goes in
  the container** (ADR-9): it lives in the macOS Keychain (`SummaryKeychain`,
  Mac) and reaches the pipeline as a 0600 key-file path (`SUMMARY_API_KEY_FILE`),
  never as a raw env var; standalone runs read
  `SUMMARY_API_KEY`/`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`.
- **Automations config follows the same split** (ADR-13). Platform connections
  (`config/connections.json`) and user-defined pipelines (`config/pipelines.json`)
  live in the container with tolerant decoding, edited in Settings →
  **Automations** (`AutomationsSettingsView`, stores mirroring
  `PipelineSettingsStore`). They hold **no secrets and nothing executable**:
  connection API keys live in the Keychain (`ConnectionKeychain`, account =
  connection id), custom MCP launch specs and the step CLI-command allowlist in
  machine-local UserDefaults (`CustomMCPSpec`, `SettingsKeys.stepCommandAllowlist`)
  - the container syncs via iCloud, so a synced command line would be RCE on
  every device. Everything reaches `process-session` as one 0600 manifest file
  (`ConnectionKeyManifest`, `CONNECTION_KEYS_FILE`). Pipeline choice resolves via
  `PipelineResolver`: session override > first assigned project > global default
  > built-in (transcribe + summarize, no actions).
- **Audio is never denoised.** Spectral denoising measurably *raises* WER for
  large Whisper models (ICAART 2024: helps base/small, hurts medium/large).
  `transcribe.sh --preprocess safe` does only `highpass=f=80` plus one **static**
  measured gain (`ebur128` then `volume=NdB`, ~6 s/hour). Never add `loudnorm`
  (its `LRA` is dynamic-range compression and costs ~75 s/hour) and never
  `silenceremove` (it compacts the timeline, desynchronising every transcript
  timestamp after the first pause and breaking tap-to-seek).
- **The gain policy never attenuates.** The true-peak ceiling limits how much
  `compute_gain` *boosts* and nothing else. Attenuating audio that is already
  clipped cannot un-clip it - the distortion is in the samples - it only makes
  speech quieter, which is the one thing that reliably hurts Whisper. Getting
  this wrong once silently dropped 3.5 minutes of speech from a real meeting
  (741 words -> 528 on the same 5 minutes). `transcribe.sh --self-test` covers
  the policy and runs in CI; add a case there before changing it.
- **Preserve the summarize frontmatter contract** (ADR-10). Three parts, and the
  split is the design: the **enforced contract** (`SummarizePrompt.systemPrompt`,
  passed via `--append-system-prompt`) owns `title:` + `language:`, the title/
  language rules and the grounding rules; the **body spec**
  (`SummaryTemplate.default` in SharedKit, overridable via
  `<container>/config/summary-prompt.md`) says only *what* the protocol contains
  and defaults to a chronological account; a one-line **postamble** repeats the
  contract last. `Summarizer.repairFrontmatter` then *guarantees* the contract in
  Swift - the prompt asks, the repair pass enforces - so a hostile template can
  change a summary's shape but never break the file. **The transcript has no
  speaker labels**, so never write a prompt that demands per-person attribution.
  The map step stays built-in and **shape-neutral** so any body spec is reachable
  on long meetings.
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

## Performance (hard-won, measured)

- **Install a GPU engine.** `detect_engine()` falls through to `openai-whisper`,
  the reference PyTorch build, whose CLI picks `cuda if available else cpu` - so
  on Apple silicon it runs `large-v3` entirely on the **CPU**. Measured on a real
  52-min German meeting: **2 h 51 m** that way versus **6 m 38 s** with
  mlx-whisper plus the conditioning flag below, with *better* output. Install with
  `uv tool install mlx-whisper`, **never `pip`** - Homebrew Python enforces PEP 668
  and `pip install` fails with `externally-managed-environment`, which is why the
  one-click Diagnostics fix silently never worked.
- **`condition_on_previous_text` is duration-gated, not off.** Carrying decoded
  text between windows is how one hallucinated window poisons the rest: the same
  meeting had 6 degenerate runs, the worst 141 consecutive 1-second segments,
  which also wrecks tap-to-seek. But on a *short* clip disabling it measurably
  hurt (lowercase, unpunctuated), so `transcribe.sh --condition auto` keeps it
  under 10 minutes and drops it above. **Never evaluate this flag on a short
  clip.**
- **The System-Test cannot catch throughput problems** - it uses a ~3 s clip with
  `TRANSCRIBE_MODEL=tiny`, so it validates plumbing only.
- **Long transcripts need care.** An hour is 1000-1500 segments. Documents render
  in **one text view** (`DocumentPane` → `DocumentTextView`, ADR-12), so TextKit
  lays out only the visible fragments. Build the `NSAttributedString` **once per
  document** - key it on `LoadedDocument.key` (path + mtime + size), never on a
  body pass - and drive the playhead highlight from
  `AudioPlayerModel.currentSegment`, an `Int?` that changes once per segment,
  never from `currentTime`, which changes every tick; moving it is two attribute
  edits, not a re-render. `DocumentLoader` parses off the main actor and caches
  on URL + **mtime** (regenerating a protocol rewrites the same URL).

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

Import pre-recorded audio (macOS): **Import Audio…** (toolbar, menu-bar panel, or
`⌘I`) turns an existing file into a session. `AudioImporter.makeMicTrack`
transcodes it to `audio/mic.m4a` (atomic rename so the pipeline / notifier never
see a partial file) and `AppModel.importAudio` leaves the session `.recorded` -
the *same* on-disk shape a recording produces, so the existing auto-process /
notification / **Process** paths drive it, unchanged. `NewSessionNotifier` only
acts on a `.recorded` session **once `mic.m4a` exists** (a session.json is
written before its audio, for both import and live recording).

Session actions (macOS): the sidebar row **context menu** is the home for
per-session actions (`LibraryView.sessionMenuItems(for:)`) - Process/Retry/
Regenerate, **Transcribe Again**, Rename, Reveal in Finder, Assign to Project,
Delete - and the "Session" system menu (`AppCommands`) mirrors them for the
selected session via `DetailActions`. "Transcribe Again" appears only when
`AppModel.canRetranscribe` holds (audio + an existing transcript, nothing
running) and confirms first, since it costs minutes. The detail pane keeps only the primary action + project menu (no
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
