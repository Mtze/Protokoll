# Module overview

How the pieces fit. See `ARCHITECTURE.md` for the why, this for the where.

## SharedKit (`Sources/SharedKit`)

Foundation-only, platform-agnostic. The single source of truth for the data
model and container access, reused unchanged by Mac/iOS/watch.

- **Models** (`Models/`): `Session` (folder + metadata, with canonical file-URL
  accessors), `SessionMetadata` (mirrors `session.json`), `PipelineStatus`
  (state machine + `failed(message:)`), `Claim`/`PipelineStep` (lease, ADR-4),
  `Project` (F7), `AudioTrack`/`Device`/`GeoCoordinate`.
- **Container** (`Container/`): `ContainerLocating` seam
  (`LocalFolderContainer` for dev/tests, `UbiquityContainer` for iCloud at M3);
  `Container` (create/list/projects); `SessionStore` - the **sole** reader/
  writer of `session.json`, with atomic writes, protocol rotation (N10), and
  claim acquire/renew/release with staleness takeover.
- `Frontmatter` - a tiny dependency-free YAML frontmatter reader/writer.
- `TranscriptParser` - parses a transcript (the `transcript.md` `**[HH:MM:SS]**`
  body or raw `.srt`) into timestamped `TranscriptSegment`s for the tap-to-seek
  list; tolerant of malformed input (unparseable lines skipped). Unit-tested.
- `CommandRunner` - the `CommandRunning` subprocess boundary (fakeable) reused
  by the pipeline and Diagnostics.
- `AppLog` - the one logging facility (`os.Logger`, subsystem `com.protokoll`,
  a category per flow). Used by every module and app; `MediaKit` depends on
  SharedKit solely for this. Pure helpers `folderName`/`describe` are unit-tested.
  View with `log stream --predicate 'subsystem == "com.protokoll"'`.

## ProcessSession (`Sources/ProcessSession`)

The `process-session` CLI (ADR-1). Steps: iCloud download-wait (N7) → transcribe
(`Transcriber` shells out to `scripts/transcribe.sh`, assembles timestamped
`transcript.md`) → summarize (`Summarizer` pipes the transcript into `claude -p`;
the pipeline owns the write + title lift F9). `Pipeline` manages status + claim.
`TranscriptChunker` is the M2 map-reduce seam (N9). `SummarizePrompt` embeds the
decision-vs-discussion conventions from the meeting-notes skill.

## Diagnostics (`Sources/Diagnostics`)

UI-free preflight. `DiagnosticCheck`s (claude, whisper engine, model, ffmpeg,
PATH, container) each carry a localized title/explanation key and a tiered
`Remediation` (auto-fix / bootstrap-gated / guided). `DiagnosticsRunner`
aggregates `HealthLevel`. `RemediationExecutor` runs auto-fixes with the
bootstrap gate. `SystemTest` runs a bundled clip through the real
`process-session` binary end-to-end.

## Mac app (`Apps/Mac`, `Apps/Shared`)

- `ProtokollApp` - `MenuBarExtra` + Library/Diagnostics windows.
- `Recorder` (actor) - AVAudioEngine → CAF, convert to m4a on stop, orphan
  recovery (ADR-3).
- `Scheduler` (`@Observable`) - resource-aware (transcribe=1, summarize overlaps;
  ADR-4), runs the pipeline binary via `PipelineRunner`.
- `AppModel` - ties container + recorder + scheduler + diagnostics for the UI.
- Views: `MenuContentView`, `LibraryView`, `SessionDetailView`,
  `DiagnosticsView`, `HealthDot`. Strings in `Localizable.xcstrings` (EN+DE).
- `HelperLocator`/`AppEnvironment`/`SampleClip` resolve binaries, the container,
  and the System-Test asset (bundle in prod, env + repo fallback in dev).

## Shared UI (`Apps/Common`)

Cross-platform SwiftUI reused by Mac/iOS/watch. `AudioPlayerView` +
`AudioPlayerModel` (scrubber, speed, tap-to-cycle on watch); an extra
`AudioPlayerView(url:model:title:)` initializer lets a detail view share one
`AudioPlayerModel` between the player and the transcript list. `DocumentViews`
holds `MarkdownText` (dependency-free block renderer - headings/lists/quotes/
code over `AttributedString` inline spans, light+dark), `TranscriptSegmentList`
(time+text rows; tap seeks the shared player, current row highlighted),
and `DocumentActions` (Copy to the platform pasteboard + Export via
`NSSavePanel` on macOS / `ShareLink` on iOS). The recording is one combined
mic+system track (ADR-7), so the detail views label it neutrally
(`player.recording`), not "Microphone"; a separate `System audio` player only
appears for legacy sessions that still carry `system.m4a`.

## Tests (`Tests/`)

Swift Testing. `SharedKitTests` (create/reload/status, rotation, malformed-JSON
tolerance, claim lifecycle, frontmatter, `TranscriptParser` markdown/SRT +
malformed-input tolerance, `AppLog` subsystem + redaction helpers).
`ProcessSessionTests` (transcript assembly, summarize title-lift, full pipeline
via fakes, failure capture). `DiagnosticsTests` (checks, aggregate health,
bootstrap gate, System-Test).
