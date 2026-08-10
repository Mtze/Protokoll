# Implementation Plan — Meeting Recorder & Protokoll-Pipeline

## Context

Greenfield repo: only `ARCHITECTURE.md` (authoritative spec) + a fresh git repo, no commits. The spec describes a local, free, privacy-preserving pipeline for macOS + iOS (+ later watchOS): apps record audio into an iCloud container of open files, and a Mac-side `process-session` step turns audio → transcript → protocol. Apps own no data; every local DB is a rebuildable index (ADR-2); processing runs as an on-demand subprocess (ADR-1).

We build a **thin vertical slice first** (Mac records → pipeline transcribes + summarizes → Mac shows the result), then layer on milestones. This plan also encodes the engineering standards and design decisions settled in a detailed design interview (see **Decisions locked in** and **Engineering standards**).

Reusable asset — the user's `meeting-notes` skill already ships hardened local transcription + summarization conventions we reuse rather than reinvent:
- `~/.claude/skills/meeting-notes/scripts/transcribe.sh` — engine auto-detect (mlx-whisper → whisper.cpp → faster-whisper), ffmpeg 16 kHz prep, `--prompt` vocab seeding, writes `.txt`/`.srt`/`.json`, refuses cloud engines (N2).
- `~/.claude/skills/meeting-notes/scripts/setup.sh` — installs whisper.cpp + model.
- `~/.claude/skills/meeting-notes/references/agenda-format.md` — decision-vs-discussion / owner-per-action-item summary conventions.

Toolchain confirmed: Swift 6.2 / Xcode 26.3, `claude`, `ffmpeg` present. **Not installed yet:** a whisper engine + `large-v3` model (the app's setup flow handles this, see Diagnostics).

---

## Decisions locked in (from the design interview)

1. **Apple Developer Team available** → iCloud ubiquity container is viable; cross-device premise holds.
2. **Project generation: XcodeGen** (`project.yml`). The `.xcodeproj` is a gitignored build artifact regenerated via a build step. Rationale: agent-driven, multi-target growth needs reviewable declarative config, not an opaque `.pbxproj`.
3. **Mac app: non-sandboxed, Developer ID-signed, not App Store.** The pipeline must exec user-installed CLIs (`claude`, whisper, `ffmpeg`) which the App Sandbox forbids. iOS/watch stay sandboxed but do no processing (F11), so no conflict.
4. **Transcription: mlx-whisper `large-v3` primary** (Apple Silicon, full quality per F3), whisper.cpp `large-v3` documented fallback; the Swift pipeline **shells out to the vendored `transcribe.sh`** rather than reimplementing whisper handling.
5. **Summarization: pure `claude -p` print mode, no tools.** Transcript piped on stdin; `claude` prints the protocol to stdout; **the Swift pipeline owns all file writes** (rotation N10, atomic writes). Auto-title (F9) comes back as YAML frontmatter the pipeline parses. Model pinned to the strongest available (Opus) via a config constant (N1, no key). **M1 is single-shot** → long transcripts fail cleanly until M2 adds map-reduce (N9).
6. **Recording format: capture to streamable CAF PCM incrementally, convert to `mic.m4a` on stop** (N5 crash-safety — `.m4a` isn't finalized until close). Leftover-CAF-with-no-m4a recovery on launch. → **ADR-3**.
7. **Swift Testing** for unit tests, XCTest/XCUITest only where tooling requires; **Swift 6 strict concurrency from day one** (recorder + future indexer as actors, Sendable value-type models).
8. **iCloud wiring sequencing:** local-folder `ContainerLocating` seam through M1–M2; **real iCloud ubiquity container stood up on the Mac at the start of M3** (proves entitlement/provisioning + N7 download-wait while debugging one app), so M4 (iOS) is pure app work.
9. **Helper packaging:** `process-session` binary and `transcribe.sh` are **bundled in the app** (`Contents/Helpers/`, `Contents/Resources/`), Developer ID-signed for notarization; external tools resolved from PATH; `PROCESS_SESSION_BIN` env override for the dev loop.
10. **Diagnostics/Preflight is a first-class M1 subsystem** — easy setup is a hard requirement (see its section).
11. **Resource-aware scheduler** (not a global serial queue): **transcribe = 1 globally**, **summarize = 1 allowed to overlap a transcribe**. Executor lives **behind a protocol, decoupled from the app UI**, so a launchd daemon or a *second Mac* can host the identical core later (NH2). **Claim/lease baked into `session.json` from M1** (`deviceId`/`step`/`startedAt`/heartbeat) for multi-machine safety. Confirm-on-quit; killed jobs leave a checkpoint and are re-runnable (N6). → **ADR-4**.
12. **Agenda integration (F5) is descoped for now.** Summarize produces the generic protocol structure; the `agenda.md` slot remains in the layout as a future hook — no attach UI, no auto-detect, no fill-in-place.
13. **Search index: GRDB (FTS5) at M3** — one SPM dependency added only then; SharedKit + pipeline stay dependency-free until then.
14. **watchOS is M6** (foundation laid now via platform-agnostic SharedKit); its container-sync path (WatchConnectivity vs CloudKit) is an explicit open ADR before that milestone.

---

## Target repo layout

```
meeting-notes/
├── ARCHITECTURE.md                   # spec + ADRs (append ADR-3/ADR-4; changes are conscious)
├── CLAUDE.md  +  AGENTS.md           # AI onboarding: layout, conventions, commands (kept current)
├── README.md                         # human quickstart: prereqs, build, run, test
├── docs/                             # developer docs (module overviews, HIG/UX notes, decisions)
├── project.yml                       # XcodeGen manifest (targets, entitlements, settings)
├── Package.swift                     # SPM: SharedKit (lib) + process-session (executable)
├── Sources/
│   ├── SharedKit/                    # platform-agnostic model + container access (Foundation only)
│   └── ProcessSession/               # the pipeline CLI
├── Tests/{SharedKitTests,ProcessSessionTests}/
├── Apps/
│   ├── Mac/  iOS/  Watch/            # per-platform app sources
│   └── Shared/                       # shared SwiftUI views + String Catalog + Diagnostics UI
├── fastlane/                         # Fastfile: build/test now; screenshots/distribution later
└── scripts/transcribe.sh            # vendored from the skill (+ faster_whisper_run.py)
```

App targets depend on the local SwiftPM `SharedKit`. `.xcodeproj` is generated by `xcodegen` (gitignored). Pipeline builds standalone with `swift build`.

---

## Engineering standards (cross-cutting — every milestone)

- **i18n from line one.** No hardcoded user-facing strings: SwiftUI `Text`/`LocalizedStringKey`, non-view `String(localized:)`, all in a **String Catalog (`.xcstrings`)**, base **English + German** early. Orthogonal to N8 (summary language is a pipeline decision).
- **Apple HIG + native feel.** `MenuBarExtra`/`NavigationSplitView` idioms, standard Settings, Dark Mode, Dynamic Type, accessibility labels, keyboard support. **Icons are SF Symbols only.** HIG/UX decisions recorded in `docs/`.
- **Docs as part of each change.** DocC comments on public SharedKit API; `README`, `docs/`, and **`CLAUDE.md`/`AGENTS.md` updated in the same change** whenever structure/commands/conventions shift.
- **Test everything meaningful** (Swift Testing) and **verify the real product end-to-end each milestone**, not just green tests.
- **Commit habit:** branch off `main`, **commit each part as soon as it works** (imperative subject + why), PR per milestone, never commit to `main` directly. Trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Recurring external quality review:** after each working chunk/milestone, spawn a **fresh reviewer agent** (+ optionally `agy`) and run `/code-review`; fold findings back before moving on.
- **Simplicity is a hard requirement.** Simplest correct design wins; if stuck or a solution feels too complex, **spawn a sub-agent (or `agy`) to find the simpler version** and adopt it. Sub-agents may be spawned freely / in parallel.
- **Compatibility, cheaply:** intentional deployment floors (macOS 14 / iOS 17 / watchOS 10); use `@available` for genuinely-better new APIs rather than lowering the floor. Never trade features/usability for reach.
- **Intentional architecture changes:** any deviation from the spec is assessed in writing and recorded as an ADR in `ARCHITECTURE.md` before implementing.

---

## Design conventions (structural)

- **Container root injectable** via `ContainerLocating`: real iCloud ubiquity container (`FileManager.url(forUbiquityContainerIdentifier:)`) in prod, plain folder in dev/tests.
- **SharedKit is platform-agnostic** (Foundation only — no AppKit/UIKit/SwiftUI) so Mac/iOS/watchOS reuse it unchanged.
- **`session.json` canonical** (ADR-2); frontmatter mirrors it; `SharedKit` is sole reader/writer.
- **Folder name stable/opaque** (`<ISO-ts>_<shortID>`); title is metadata only (F9).
- **`transcript.md` immutable** (N10); protocol regen rotates `protocol.md` → `protocol.vN.md`.
- **Status machine** `recorded → transcribing → transcribed → summarizing → done` + `failed(message)`; every step re-runnable with `--force` (N6); each in-flight step carries a **claim/lease** (ADR-4).

---

## Milestone 1 — Thin vertical slice + easy setup (detailed)

End state: install-time setup is friendly and self-verifying; record in the menubar → "Verarbeiten" → transcript + protocol appear in a minimal library, all localized, tested, committed in working increments.

### 1a. `SharedKit` (Foundation library)
`Session`/`SessionMetadata`/`PipelineStatus`/`Claim` Codable structs mirroring `session.json` (incl. claim/lease fields); `Container` (`createSession()`, `allSessions()`); `SessionStore` (atomic write, `rotateProtocol()`, claim acquire/renew/release with staleness check). DocC comments. Swift Testing: create→status→reload, rotation, malformed-JSON tolerance, claim acquire/expire.

### 1b. Pipeline `process-session` (Swift executable)
`process-session <folder> [--step transcribe|summarize|all] [--force]`. Steps: (1) **await iCloud** (N7, no-op locally); (2) **transcribe** via bundled `transcribe.sh` (mlx `large-v3`) → `transcript.md` + frontmatter, immutable (N10); (3) **summarize** — pipe `transcript.md` into `claude -p` (print mode, no tools, generic protocol structure, N8 meeting-language, title frontmatter), pipeline rotates + writes `protocol.md`, writes back `title` when unset; (4) **persist status + claim** each step; errors → `failed(message)`. `chunkTranscript()` is a stubbed seam (M2). Tests: frontmatter parse, subprocess wrapper via fakes, status/claim transitions.

### 1c. Diagnostics / Preflight subsystem (first-class)
A `Diagnostics` module: an ordered list of `Check`s (claude installed+logged in, whisper engine + `large-v3` model, `ffmpeg`, PATH, container writable, mic permission), each with a plain-language title/explanation, a **"Details" disclosure** for the raw error, and an optional tiered `Remediation`:
- **Auto-fix (one click, live progress log):** `brew install ffmpeg`, `pip install mlx-whisper`, model download via `setup.sh`.
- **Bootstrap-gated:** if `brew`/`python3` missing, offer to install that first as an explicit, clearly-labeled bigger step; decline → copy-paste instructions. Never silently install a package manager.
- **Guided (deep-link):** `claude` login → open Terminal with the command; mic/Screen-Recording → deep-link the exact System Settings pane.
Menubar shows an **aggregate health dot** (green/yellow/red). An explicit **"System-Test" (Selbsttest)** runs all checks **plus an end-to-end dry run** — a bundled ~3 s clip pushed through transcribe → summarize — so green proves the whole chain. All strings localized.

### 1d. Mac menubar app (minimal, HIG-correct, localized)
`MenuBarExtra` (SF Symbol mic) with **visible recording indicator** (N4) and the health dot; `Recorder` **actor** — `AVAudioEngine` tap → incremental `mic.caf`, convert to `mic.m4a` on stop (ADR-3), start/stop write `session.json`; **resource-aware scheduler** (transcribe=1, summarize overlaps; claim/lease; confirm-on-quit) hosting the bundled `process-session`; `LibraryView` (`NavigationSplitView`) listing sessions + transcript/protocol panes. Entitlements: `NSMicrophoneUsageDescription`, iCloud container declared (used from M3), non-sandboxed Developer ID.

### 1e. Wiring, tooling & docs
`project.yml` (XcodeGen) + `Package.swift`; vendor `transcribe.sh` + bundle it; `PROCESS_SESSION_BIN` dev override; **fastlane** `test`/`build` lanes (screenshots/distribution scaffolded TODO); `README` (setup via the app's Diagnostics + manual fallback), `CLAUDE.md`/`AGENTS.md`, `docs/` seed; **append ADR-3 (capture format) and ADR-4 (scheduler + claim/lease)** to `ARCHITECTURE.md`. Commit each piece; open the M1 PR; fresh-agent + `/code-review` pass before closing.

---

## Milestones 2–6 (outlined)

**M2 — Robust pipeline.** Map-reduce for long transcripts (N9): `chunkTranscript()` at speech pauses within a token budget → per-chunk `claude -p` → synthesis pass; chunk boundaries = future NH3 checkpoints. System audio (F2) via `ScreenCaptureKit` audio-only `SCStream` → `system.m4a` (Screen-Recording permission, added to Diagnostics). Consent reminder + `consentNote` (N4). Per-step failure/retry UX. Scheduler's summarize-overlaps-transcribe path exercised for real.

**M3 — Real iCloud + library/search/projects (F6/F7/F10).** Stand up the real iCloud container on the Mac (entitlement/provisioning, validate N7). Local **GRDB FTS5** index in App Support (ADR-2): an `Indexer` **actor** watching the container, full-text over transcript+protocol, filters by project/date/status, fully rebuildable. `projects.json` (`id`/`name`/`color`) + group/filter UI. Full HIG library window.

**M4 — iOS app (F8/F11/F12).** Add iOS target (XcodeGen) reusing SharedKit + shared localized views. Lean recorder → same container (CAF→m4a), optional title + geotag (`CLLocation` → `geo`); no on-device processing. Viewer + own FTS5 search. Runs against the M3-proven container. fastlane `snapshot` screenshots wired here.

**M5 — Notifications & polish (F13).** Mac watches the container for new/iCloud-arrived sessions → local `UNNotification` with an action button; click enqueues onto the scheduler (respecting the claim/lease so a second host doesn't double-process). Mixed-language handling (N8), versioning/title polish. fastlane distribution (`gym`/`pilot`).

**M6 — watchOS (foundation now, app if time permits).** Native watch recorder (`AVAudioRecorder`) reusing SharedKit models. **Open ADR before building:** watch↔container sync (WatchConnectivity → iPhone → container, vs CloudKit) — the watch can't touch the ubiquity container directly.

**Deferred (designed-for, not built):** background **daemon / second-Mac worker** (NH2) hosting the same decoupled scheduler via the claim/lease; **agenda integration** (F5); pause/resume via chunk checkpoints (NH3); diarization (NH1).

---

## Risks / call-outs

- **iCloud provisioning** (entitlement + container) must be set up before M3; the Team makes it possible but it's real config work.
- **watchOS↔container sync is unspecified** — needs a deliberate ADR before M6.
- **Whisper install + multi-GB model** — handled by Diagnostics auto-fix, but first-run transcription is slow (~0.3–1× realtime); large meetings need M2's map-reduce.
- **ScreenCaptureKit (M2)** needs Screen-Recording permission (added to Diagnostics); `claude -p` relies on the existing login (N1).
- **Deployment floors** (macOS 14 / iOS 17 / watchOS 10) are an intentional modern-API choice; revisit only if lowering them is free.

---

## Verification

**Milestone 1 end-to-end (primary):**
1. `swift build`; `swift test` + `fastlane test` green; `xcodegen generate` produces a buildable project.
2. Fresh-machine setup: open the app → **Diagnostics** flags missing `ffmpeg`/whisper/model → **Fix buttons** install them → health dot goes green.
3. Run **"System-Test"** → the bundled clip transcribes + summarizes → green proves the whole chain.
4. Record ~1 min; confirm `audio/mic.caf` grows live (N5) and finalizes to `mic.m4a` on stop; `session.json` → `recorded`. Kill the app mid-recording → relaunch recovers the CAF to `mic.m4a`.
5. "Verarbeiten" walks `transcribing → transcribed → summarizing → done`; `transcript.md` + `protocol.md` appear; auto-title filled when unset; protocol language matches the meeting (N8); a claim/lease appears during processing and clears after.
6. Library lists the session; panes render transcript + protocol. Toggle locale EN↔DE → all UI strings switch (i18n).
7. `process-session <folder> --step summarize --force` rotates old protocol → `protocol.v1.md` and writes fresh (N10).
8. Negative: broken `session.json` and a missing `claude` both degrade to a friendly, actionable state — no crash, no cryptic `failed`.
9. Fresh-agent review + `/code-review` clean; `README`/`CLAUDE.md`/`AGENTS.md` reflect shipped state; ADR-3/ADR-4 present in `ARCHITECTURE.md`.

**Later milestones:** M2 — a 90-min recording yields a coherent protocol via map-reduce without context overflow, and a summary overlaps a transcription; M3 — FTS5 search hits across transcript+protocol and survives an index delete+rebuild, real iCloud download-wait (N7) observed; M4 — an iOS-recorded session appears and processes on the Mac, screenshots generate; M5 — a notification action starts processing without double-processing across hosts; M6 — a watch recording reaches the container and processes on the Mac.
