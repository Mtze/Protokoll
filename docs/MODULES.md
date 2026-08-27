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
`TranscriptChunker` is the map-reduce seam (N9), and `TranscriptChunk.timeRange`
labels each partial with the wall-clock span it covers so the reduce step has
absolute time to order by.

`SummarizePrompt` splits the prompt three ways (ADR-9): the **enforced contract**
in `systemPrompt` (frontmatter, title/language, grounding rules - passed via
`--append-system-prompt`), the **body spec** from `SummaryTemplate.default` /
`config/summary-prompt.md` (user-editable, chronological by default), and a
one-line postamble. `userMessage` puts the transcript *before* the instructions,
per Anthropic's long-context guidance. `FrontmatterRepair.swift` then guarantees
the contract deterministically - stripping fences and short chatter, synthesizing
a missing title/language, and stamping the pipeline-owned `date`/`duration`/
`session` keys - so a non-compliant model response can no longer be written
verbatim with the title silently skipped. `map` is deliberately shape-neutral so
any body spec stays reachable on long meetings.

`Transcriber` also enforces a wall-clock budget (`max(15 min, 10x audio)`) via
`CommandRunning`'s `timeout:` overload, so a wedged engine fails visibly instead
of renewing its claim heartbeat forever.

## Diagnostics (`Sources/Diagnostics`)

UI-free preflight. `DiagnosticCheck`s (claude, whisper engine, **engine speed**, model, ffmpeg,
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
holds the Markdown block parser (`MarkdownBlock`/`MarkdownRenderBlock` -
headings/lists/quotes/code with `AttributedString` inline spans) and
`DocumentActions` (Copy to the platform pasteboard + Export via `NSSavePanel` on
macOS / `ShareLink` on iOS).

`DocumentTextView` renders both panes. Protocol and transcript go into **one**
read-only `NSTextView`/`UITextView` (ADR-11) so a selection can span bullets and
segments - a stack of SwiftUI `Text` views never can, and the old transcript rows
were `Button`s, which swallow the drag entirely. `DocumentAttributedText` turns
blocks into fonts + `NSParagraphStyle`s; `TranscriptTextLayout` (SharedKit,
tested) maps character offsets to segments, which is what a click-to-seek and the
playhead highlight need. The pane owns its scrolling - do not wrap it in a
`ScrollView`. watchOS has no such text view and falls back to plain scrollable text.

`DocumentLoader`/`LoadedDocument` read and parse a document **off the main actor**
and cache it keyed on URL + mtime, so the detail views no longer re-read and
re-parse on every body pass. The attributed string is built once per document
(keyed on `LoadedDocument.key`, never per body pass), and the highlight is driven
by `AudioPlayerModel.currentSegment` - an `Int?` that changes once per segment,
where `currentTime` changes on every 10 Hz tick. See the performance notes in
`CLAUDE.md` before changing any of this; an hour-long meeting is 1000-1500 rows. The recording is one combined
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
