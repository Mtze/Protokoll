# Plan: transcription quality, speed, UI lag, summary prompt

Status: **implemented** (2026-08-13). See "What shipped" at the end for the
as-built summary and what still needs manual verification.
Branch: `feature/Transcription-pipeline`
Date: 2026-08-13

Four user-reported problems. Research phase is complete (four parallel agents);
this is the implementation plan. The consistent finding across all four: **the
biggest wins are bugs and misconfiguration in our own code, not new technology.**
Every "adopt library X" question came back *no, or not yet*.

---

## Problem 1 - poor transcription quality / background noise

### What the evidence says

Aggressive denoising is expected to **hurt** at our default model size:

- ICAART 2024 (74 real voicemails, RNNoise + DC-CRNet, Whisper base..large-v2):
  denoising improved WER for *small* models; for medium/large/large-v2 the
  **original audio beat the denoised audio**. We run large-v3.
- arXiv 2512.17562: original beat enhanced in **all 40 configurations**.
- arXiv 2603.04710: separation before Whisper consistently raised WER/CER.
- DeepFilterNet issue #483: ~20% WER regression before Whisper (uncontrolled,
  closed without maintainer reply). DFN is also dormant - last release
  2023-08-31, last commit 2024-09-25.

There is **no measured WER evidence** that `highpass` + loudness normalization
helps. Its justification is mechanistic (linear gain and an 80 Hz shelf cannot
distort the mel bands that carry phonetic information), i.e. *cannot plausibly
hurt*, not *shown to help*. Whisper's `log_mel_spectrogram` already normalizes
per window, and the Moonshine gain-vs-WER sweep shows Whisper is level-robust
except below ~-40 dB.

### Two probable root causes are in our code

1. **`Sources/MediaKit/AudioMixer.swift` sums mic + system audio at unity gain**
   with no `AVMutableAudioMix`. Verified empirically: output peak = sum of input
   peaks. A loud call plus a hot mic clips into the AAC encoder. Clipping is
   unrecoverable downstream and is one of the few distortions Whisper genuinely
   hates.
2. **`Apps/Mac/Recorder.swift:49-63` taps the input node raw** - no
   `setVoiceProcessingEnabled(true)`, so no echo cancellation. Recording on
   laptop speakers means the mic re-records remote participants with a delay.
   No post-hoc denoiser can undo this.

### Decisions

- **Do not ship a denoiser by default.** Burden of proof is on any denoiser to
  show it does not hurt, on real audio.
- **`silenceremove` is a hard no.** Its default `timestamp=write` compacts the
  timeline; every segment start after the first pause shifts earlier by the
  cumulative removed duration. Tap-to-seek would drift without bound. Get the
  anti-hallucination benefit from a VAD that remaps timestamps instead.
- **Use `ebur128` measure + static `volume=NdB`, not `loudnorm`.** Measured on
  an M3 Pro per hour of audio: baseline 2.1 s, `ebur128` 3.3 s + apply 2.4 s,
  versus **`loudnorm` 74.7 s**. `loudnorm`'s `LRA` also performs dynamic-range
  compression - a time-varying non-linear transform, not the safe linear
  operation it is usually assumed to be.

### Steps

1. `AudioMixer.mix`: attach an `AVMutableAudioMix` with `setVolume(0.5, at: .zero)`
   per input track. Unit test in MediaKit asserting no clipping on two hot inputs.
2. `transcribe.sh`: two-pass audio prep - `ebur128` to measure, then
   `highpass=f=80,volume=${GAIN}dB` with the gain clamped to +/-20 dB and a
   true-peak ceiling of -1 dBFS. Target -20 LUFS.
3. `Apps/Mac/Recorder.swift`: opt-in `setVoiceProcessingEnabled(true)` behind a
   `SettingsKeys` toggle (app behavior, not pipeline tuning - so `@AppStorage`,
   per CLAUDE.md). Must fail gracefully; it can throw on some devices and it
   changes the input format.
4. EN + DE strings for the new toggle in `Apps/Shared/Localizable.xcstrings`.

**Deferred pending A/B on real audio:** DeepFilterNet3, `arnndn`, `afftdn`,
Demucs. See the A/B recipe at the end.

---

## Problem 2 - transcription is slow

### Root cause

`detect_engine()` in `scripts/transcribe.sh` falls through to `openai-whisper`
(the reference PyTorch implementation) because nothing else is installed. That
CLI selects `cuda if torch.cuda.is_available() else cpu`, so on an M3 Pro it
runs large-v3 **entirely on CPU**. The GPU sits idle.

**Why nothing else was installed:** `WhisperEngineCheck.remediation`
(`Sources/Diagnostics/Checks.swift:57`) runs `pip install --upgrade mlx-whisper`,
which fails on Homebrew Python with `error: externally-managed-environment`
(PEP 668). The one-click fix in Settings has never worked on this machine. This
is a live bug.

### Measured on a real 52-min German meeting from the container

| Configuration | Wall time | Degenerate loops |
|---|---|---|
| openai-whisper large-v3, CPU (today) | 2 h 51 m | 6 runs, max 141 segs |
| mlx-whisper large-v3, default decoding | 28 m 18 s | 4 runs, max 637 segs |
| **mlx-whisper + `condition_on_previous_text=False`** | **6 m 38 s** | **0** |

~26x faster **with better output**. Same weights, fp16, no quantization.

Note the middle row: a faster engine *alone* made hallucination worse (one
phrase repeated 634x; the last ~25 minutes entirely garbage). The decoding flag
is what fixes quality and it costs nothing.

### Quality context

- Existing completed transcripts are already damaged: 38.9% of segments exactly
  1 s apart, 6 degenerate runs. The premise "large-v3 on CPU = highest quality"
  is false in practice. The 1-second segments also break tap-to-seek.
- **Stay on large-v3 fp16.** Turbo costs ~11% relative German WER
  (flozi00/asr-german-mixed-evals, consistent across Tuda-De / MLS / CV 19.0).
  Quantization is disproportionately expensive on hard audio (arXiv 2511.08093).
  We do not need the speed.
- **Keep shelling out to `transcribe.sh`.** `CommandRunning` is our test seam;
  WhisperKit is not yet `Sendable` (collides with Swift 6 strict concurrency);
  and a runaway engine in a subprocess can be killed, which matters - see below.

### Rejected

- **Parakeet TDT v3** - German is at parity with large-v3 at ~15x throughput,
  but: no language pinning (NVIDIA issue #14799), vendor-acknowledged weak
  code-switching (German meetings with English tech terms are exactly this),
  cross-language contamination, and reports of **silent sentence deletion** -
  worse than hallucination, because a deleted sentence is invisible in review.
  FluidAudio additionally applies a French-tuned English blocklist when passed
  `language: .german` (+2.9pp WER, issue #840, fix PR open not merged), and its
  `ASRResult` has no `segments` array and no detected `language` - both consumed
  by `Transcriber.assembleTranscript`.
- **parakeet-mlx** - cannot run on macOS 14 (MLX needs macOS 15+, issue #16).
  Below our floor.
- **Apple SpeechAnalyzer** - macOS 26 only, and confirmed by an Apple engineer
  to have **no custom vocabulary** on `SpeechTranscriber`. Our `vocabulary`
  config field would silently become a no-op. No diarization.

### Implementation traps (found during benchmarking - read before starting)

- **Do not validate the decoding flag on a short clip.** On a 4-minute isolated
  clip `condition_on_previous_text=False` made output *worse* (lowercase,
  unpunctuated). On the full 52-minute file it was decisively better. The prefix
  helps local fluency but is the transmission vector for long-form collapse:
  once one window hallucinates, the bad prefix propagates for 25 minutes. **Any
  decoding change must be evaluated on full-length audio only.**
- **The System-Test cannot catch this class of bug.** It runs a ~3-second clip
  with `TRANSCRIBE_MODEL=tiny` - it validates plumbing, not throughput or
  long-form behavior. A separate "speed test" over ~60 s of real audio with the
  *real* model, reporting measured RTF and a projected ETA, would have surfaced
  this on day one.
- **Engine ordering currently lives in two places and they already differ
  subtly**: `transcribe.sh:52-60` (`detect_engine()`) and `Checks.swift:63`. A
  Diagnostics check that does not mirror `detect_engine()` exactly will lie.
  Prefer adding `transcribe.sh --print-engine` as the single source of truth and
  having the check shell out to it.
- **`WhisperModelCheck` returns `.passed`** for mlx with detail "mlx downloads
  the model on first use" - but the first large-v3 download is **2.9 GB**. Should
  be a `.warning` naming the size, or a pre-download offer.
- Also pass `--language de` rather than relying on auto-detect.

### Steps

1. `transcribe.sh`: pass `--condition_on_previous_text False` on the
   openai-whisper branch and `--condition-on-previous-text False` on the mlx
   branch. Consider `--hallucination_silence_threshold` (needs word timestamps).
   **Do not hardcode it globally.** The measured reversal (worse on a 4-min clip,
   decisively better on the 52-min file) means short recordings can regress.
   Either gate it on audio duration (the script already computes `DURATION`) or
   expose it in `PipelineConfig`. The evidence base is one meeting, so the flag
   needs an off switch.
2. `Sources/Diagnostics/Checks.swift`: change the remediation to
   `uv tool install mlx-whisper` and the bootstrap `toolName` to `uv`.
   Verified on this machine: `uv tool dir --bin` is `~/.local/bin`, which
   `ShellPath.augmented` already covers.
3. New `CheckID.whisperEnginePerformance`, warning-tier: `.passed` for mlx or
   whisper.cpp, **`.warning`** when only `openai-whisper` resolves.
   `HealthLevel.aggregate` gives the yellow menubar dot for free. Phrase the
   detail in wall-clock terms ("a 1-hour meeting will take about 3 hours"), not
   jargon. Keep it a warning, not a failure - on an Intel Mac openai-whisper is
   the correct choice.
4. **Watchdog.** There is no timeout anywhere on the transcription subprocess.
   Add a duration-relative budget in `Pipeline` (e.g. fail at
   `max(15 min, 10x audio duration)`), surfaced as a failed status with retry.
   A stuck job currently renews its `Claim` heartbeat indefinitely, so a wedged
   job is indistinguishable from a working one - one has been running 19h43m at
   233% CPU and 9 GB RSS.
5. README + setup.sh: steer to `uv tool install mlx-whisper`.

---

## Problem 3 - UI lag on long transcripts

### Verified diagnosis (measured, release build, 1500 segments)

| Cause | Cost | Symptom |
|---|---|---|
| `VStack` not `LazyVStack` (`DocumentViews.swift:199`) | ~20k view nodes always resident | **scroll lag** (scrolling does not re-run bodies, so this is the only cause that explains it) |
| `timeLabel`'s `String(format:)` per row per pass | **26 ms/s** | play/pause lag |
| `currentIndex` linear scan, called once per row (`:208`, `:237`) | 14 ms/s | play/pause lag |
| `TranscriptParser.parse` per `SessionDetailView` pass | **10.5 ms**, and `documentBody` is evaluated **twice** per pass (`:237`, `:261`) | hitches |
| Per-row `.help(LocalizedStringKey)` | ~30k bundle lookups/s | play/pause lag |

Corrections to the initial read: the index scan early-terminates at `else { break }`,
so it is O(k) in playhead position, not O(N) - it grows as playback progresses
and reclaims only ~14 ms/s. The disk read (`String(contentsOf:)`, 190 KB) is
0.024 ms and is **not** worth fixing. `SessionDetailView.body` does *not* read
`currentTime`, confirmed.

**Additional path neither of us listed:** while recording, `LibraryView.swift:70-74`
reads `model.recordingLevels`, rewritten every 55 ms (~18 Hz). That invalidates
`LibraryView.body`, which rebuilds `SessionDetailView` - and `onDelete`/`onRename`
are closures, defeating SwiftUI's struct comparison. Recording with a long
transcript selected is worse than playback.

`MarkdownText` has both the same bugs, so long protocols lag identically.

### Key mechanism

The `@Observable` macro in Swift 6.2.4 emits an equality guard
(`shouldNotifyObservers`), verified against this toolchain. `currentTime` is a
`Double` that changes every tick so the guard never fires - but a derived `Int?`
**segment index** fires almost never. Feeding the list a quantized
`currentSegment` drops list invalidation from ~72,000/hour to ~1,500/hour (~48x).

### Steps

1. `DocumentViews.swift`: `VStack` -> `LazyVStack`; hoist `currentIndex` to a
   single binary search per body; extract `private struct TranscriptRow: View`
   taking `isCurrent: Bool` **with the button action built inside its body, never
   passed as a stored closure** (a captured closure defeats struct comparison);
   precompute time labels; hoist the `.help` key to a `String` constant.
2. `AudioPlayerModel`: add `@ObservationIgnored var segmentStarts` and
   `private(set) var currentSegment: Int?`, updated by binary search in the
   ticker; drop the ticker 20 Hz -> 10 Hz. `TranscriptSegmentList` reads only
   `currentSegment`.
   **Define gap behavior deliberately:** when the playhead sits in silence
   between segments, `currentSegment` holds the *previous* segment (matching
   today's linear scan, which returns the last segment whose start is <= time).
   Cover this in the SharedKit test.
   Layering note: putting transcript knowledge in the audio model is a known
   smell, raised by two independent reviews. The alternative is a small
   `@Observable TranscriptHighlight` fed by `.onChange(of: model.currentTime)` on
   a zero-size sentinel view, so only the sentinel observes `currentTime`. That
   works but is opaque to future readers. **Decision: take the simple version and
   document why**; revisit if `AudioPlayerModel` gains a second consumer.
3. Move the "index of segment at time t" binary search into SharedKit so it is
   testable via `swift test` (nothing in `Apps/` is reachable from the SPM tests).
4. `SessionDetailView` + `Apps/iOS/LibraryListView.swift`: cache body + parsed
   segments in `@State` via `.task(id:)`, parsing off the main actor
   (`TranscriptSegment` is `Sendable`); evaluate `documentBody` once per pass.
   **Key the task on URL + mtime, not URL alone** - regenerating a protocol
   rewrites the same URL and would otherwise leave a stale cache. `transcript.md`
   is immutable (N10) so only `protocol.md` actually needs the mtime component,
   but key both for uniformity.
5. Same lazy + cached-parse treatment for `MarkdownText`.

Known pre-existing limitation, not a regression: `.selectableText()` is applied
per row, so cross-segment text selection is already impossible.

**Deferred:** `.scrollPosition(id:)` playhead auto-follow, `List` on iOS for
recycling, per-segment `@Observable`. `List` on macOS may build all rows eagerly
anyway and conflicts with our per-row `Button`.

### Verification

Only the binary search is unit-testable (and it is the one place a fix can be
silently *wrong*) - test it against the existing linear definition. SwiftUI body
counts are not automatable; use `Self._printChanges()` and the Instruments
SwiftUI template on a **release** build. Add to the PR checklist: start a
recording with a long transcript selected.

---

## Problem 4 - summary prompt is unusable

### Assumptions the current prompt bakes in

The damaging ones:

- **A6 - mandated hallucination.** The prompt demands an `Owner` column and "who
  does what by when", but `Transcriber.assembleTranscript` emits
  `**[HH:MM:SS]** text` and nothing else. **There is no diarization, ever.** The
  prompt structurally requires inferring names from content.
- **A5/A1/A4 - non-decision content has nowhere to go.** Four mandatory sections
  plus "be concise" and no length target. Discussion, reasoning and disagreement
  are none of those four things, so they are dropped.
- **A8 - user instructions are explicitly subordinated.** `extraBlock` says
  "honor these, but ALWAYS keep the Markdown structure above". This is why
  adding custom instructions did not fix anything.
- **A11/A14 - the map step is lossy and is the common path.** `SummarizePrompt.map`
  filters each chunk to the same four buckets before `reduce` runs. At
  `characterBudget = 48_000` this triggers at ~45 minutes of meeting, i.e. the
  median case. **Rewriting only the final prompt cannot fix long meetings.**

### Bugs found

- **Silent frontmatter failure** (`Summarizer.swift:94-108`). `Frontmatter.split`
  returns an empty frontmatter whenever line 1 is not `---`. One word of preamble
  or a ```` ```markdown ```` fence means: `protocol.md` written verbatim
  *including the chatter*, F9 auto-title silently skipped, language silently not
  set, nothing thrown, nothing logged. `protocolBody` is computed and discarded.
- **Instructions precede the transcript.** Probed against the real `claude` CLI:
  it composes the turn as `[-p prompt]` then `[stdin]`. Anthropic's guidance is
  the opposite - longform data first, query last, worth up to ~30% past 20k
  tokens, which a 45-minute meeting clears.
- **No system prompt is set at all**, so this runs on top of Claude Code's
  coding-agent persona. And "no tools (decision #5)" is a comment, not a flag.

### Design (per the user's "full user-editable template" decision)

**The user template is an output *spec*, not the whole prompt.**

- **Part A - enforced**, in `--append-system-prompt`: frontmatter contract,
  title/language rules, grounding rules (closed-world, permission to say "not
  specified", **the no-speaker-labels rule**, ASR-errors rule, injection rule).
- **Part B - user-editable**, `config/summary-prompt.md`: the body spec. Default
  is a chronological account - one section per 3-10 minutes headed
  `## [HH:MM:SS] <topic>`, decisions/action items **only if the meeting actually
  produced them**.
- **Part C - postamble**: one-sentence contract reminder, for recency.

File over `PipelineConfig` string: multi-line prose as JSON is escaped soup, and
**absent file = default eliminates migration entirely**. Fits ADR-2/N3 (files are
the source of truth). Keep `summaryInstructions` as the additive tweak, so
existing users see no change beyond the new default.

**Map/reduce:** one template. `reduce` uses the same user template (the "your
input is ordered notes" framing lives in the enforced preamble, so the template
stays input-agnostic). `map` stays built-in but is **rewritten to be
shape-neutral** so any output spec remains reachable. Three editable templates is
rejected: users would edit `build` and not `reduce`, so a 55-minute meeting would
silently render differently from a 40-minute one with no UI indication.

**Timestamps:** section headings only, explicitly banned at bullet level (a
timestamp per bullet pushes toward re-transcription). Monotonicity is
machine-checkable.

**Frontmatter emitted by the model stays exactly `title` + `language`.** Anything
the app already knows (date, duration, project) is **stamped by the pipeline**,
not generated - hallucination-proof by construction, and it matches "the pipeline
owns all file writes". **Participants: no** - there is no diarization, and a wrong
attendee list is a high-cost, privacy-sensitive error.

### Steps

1. Rewrite `build` / `map` / `reduce` in `SummarizePrompt.swift`; drop the
   self-defeating clause in `extraBlock`.
2. `Summarizer`: deterministic frontmatter repair (strip fences, strip chatter,
   synthesize missing `title`/`language` from session metadata, stamp
   `date`/`duration`/`session`, re-render, log a warning). Closes the silent bug.
   **Be conservative when stripping**: only drop leading text under a length
   threshold; above it, keep everything and log. The repair must never silently
   delete real protocol content, and it must stay *visible* (logged warning, and
   ideally a subtle indicator) rather than masking a model failure.
3. `Summarizer.runClaude`: document-first stdin (`<transcript>` then
   `<instructions>`), contract via `--append-system-prompt`, add
   `--disallowed-tools` / `--permission-mode`.
4. `config/summary-prompt.md` load/save/reset; absent = built-in default.
5. `TranscriptChunker`: add `timeRange` to `TranscriptChunk`, label partials
   `## Part 1 (00:00:00-00:44:12)`. Chronology loss is a documented failure mode.
6. Settings -> Summary: template editor prefilled with the default, plus Reset.
   EN + DE strings.
7. **ADR-9** in `ARCHITECTURE.md` - the body spec is a user-owned file; the
   frontmatter contract and grounding rules are not.
8. Raise `characterBudget` to ~200k chars (~3 h) as a tested middle step, not
   400k on theory. Counterweight: context rot, and Anthropic's own claim that
   meta-summarization catches details a single pass misses. Needs the real
   end-to-end run (issue #13).

Default template kept in **English, unlocalized** - prompt language and output
language are independent, and a localized default makes "Reset" resolve
differently per UI language. Precedent: `PipelineConfig.vocabulary`.

**But the template must say so explicitly.** An English template describing
`## [HH:MM:SS] <what that stretch was about>` will otherwise produce English
structural headings above German bullets. Add an unambiguous line: *section
headings, and every word you write, are in the meeting's language - the English
here describes what to write, not what language to write it in.* Add a test with
a German transcript asserting no English structural headings leak through.

### Recovery story

`writeProtocol` rotates `protocol.md` -> `protocol.vN.md` and `transcript.md` is
immutable (N10). A bad template can never destroy a prior good protocol or the
source. Recovery is always "reset template, regenerate". Surface this in the
Settings help text.

---

## Stated uncertainties

- **No ground-truth WER was computed anywhere in this research.** What was
  measured is structural pathology (repetition runs, 1-second-grid segments,
  punctuation collapse) plus wall-clock time - both unambiguous. A real German
  WER comparison needs a hand-corrected reference transcript. **Do this before
  fully trusting the quality claims.**
- All speed benchmarks ran under CPU contention from the runaway job, so the
  mlx numbers are conservative.
- `hallucination_silence_threshold` and VAD are untested - experiments, not
  conclusions. whisper.cpp and WhisperKit were not benchmarked on this machine.
- The Problem 3 claim that per-row view construction is the dominant cost is
  reasoned from Apple docs and a third-party benchmark, not measured - SwiftUI
  views cannot be instantiated headlessly. Everything in the cost table *is*
  measured.
- Problem 4's diagnosis came from reading the prompt, not from a real bad
  `protocol.md`. If one exists, reading it would sharpen the default template.

## Cross-cutting

- `PipelineConfig.vocabulary` is documented in-source as "the single biggest
  transcript-quality lever". That claim is **unverified and contested** -
  Argmax's OpenBench shows keyword prompting making Whisper *worse*
  (earnings22-keywords 15.4% -> 21.24% WER). Worth an A/B before we keep
  advertising it.
- Docs to update in the same change (per CLAUDE.md): `README.md`, `CLAUDE.md`,
  `AGENTS.md`, `docs/MODULES.md`, and ADR-9 in `ARCHITECTURE.md`.

## Suggested order

**Revised after independent review.** The mixer gain fix moves to the front: it
is the one change whose absence causes *irreversible* damage. Every test
recording made while working on the other three problems would be permanently
clipped, including the audio used to validate them.

1. **Problem 1, step 1 only - the `AudioMixer` gain fix.** Do this before any
   further test recordings.
2. Problem 2: decoding flag + mlx + Diagnostics fixes + watchdog. Highest value
   per line changed, and it makes every later test cycle ~26x faster.
3. Problem 3: minimal fix first, then the quantized-index version.
4. Problem 4: prompts + repair pass, then the template mechanism.
5. Problem 1, remainder: safe filter chain + AEC toggle. A/B before any denoiser.

## Independent review (agy) - accepted corrections

1. **Sequencing.** Mixer gain first (above). Clipping is unrecoverable and
   contaminates the audio used to validate everything else.
2. **`.task(id: currentDocumentURL)` is not sufficient.** Regenerating a protocol
   rewrites the *same* URL, so the cached parse goes stale - split-brain between
   disk and UI. Key on **URL + mtime**, or drive invalidation from the existing
   `AppModel` reload after pipeline completion.
3. **The English default template will leak English headings into German
   summaries.** The contract says "write in the meeting's language", but the
   template's own prose is English, so the model may emit
   `## [00:14:32] Discussion` above German bullets. The template must state
   explicitly that **section headings follow the meeting language too**. (This
   does not change the decision to keep the template English - it changes what
   the template says.)
4. **Silence/gap behavior is unspecified.** Define deliberately whether
   `currentSegment` goes `nil`, holds the previous value, or snaps to nearest
   when the playhead sits in a gap. The current linear scan holds the previous
   segment; the binary search must match that on purpose, and the SharedKit test
   must cover it.
5. **`condition_on_previous_text=False` rests on one meeting.** The measured
   reversal (worse on a 4-min clip, decisively better on the 52-min file) means a
   blanket flag risks regressing short recordings. Make it duration-conditional
   or expose it in `PipelineConfig`; do not hardcode it globally.
6. **The frontmatter repair pass must not eat valid content.** Conservative rule
   only: strip a leading fence and short chatter under a length threshold; above
   it, keep everything and log. Repair must be *visible* (warning logged, ideally
   surfaced) rather than silently masking a model failure.
7. **`uv tool install` needs a failure path** for offline/sandboxed machines -
   the existing `Bootstrap` covers "uv missing" but not "install failed".

### Reviewer points not accepted, and why

- **"Extracting `TranscriptRow` does not bypass `@Observable` invalidation,
  because any parent or row accessing `currentSegment` still invalidates."**
  This misreads the design: **rows never read `currentSegment`**. Only the parent
  reads it and passes `isCurrent: Bool` down, so rows are not observers. SwiftUI
  compares the child structs by value and only re-runs the bodies of the two
  whose `Bool` flipped. The parent re-running is expected and cheap. The genuinely
  fragile part - which the review did not raise - is that `TranscriptRow` must
  stay memcmp-comparable, hence no stored closures.
- **"Map/reduce schema mismatch."** Restates the tradeoff the plan already
  documents. It is real, but the mitigation is that `map` is rewritten from a
  lossy four-bucket filter into a shape-neutral running account, plus raising
  `characterBudget` so map/reduce stops being the median path.

## A/B recipe (problem 1, before adopting any denoiser)

Take a 5-minute excerpt with representative noise. Run baseline, then
`highpass=f=80,volume=NdB`, then `+afftdn=nr=10:nf=-30:tn=1`, then DeepFilterNet
at `-a 12`. Hand-correct the baseline into a reference (~10 min of work), score
with `jiwer` after normalizing case and punctuation. **Also count failure modes,
not just WER** - a chain that lowers WER 1 point but introduces a 90-second
repetition loop is worse. Sanity-check first with
`ffmpeg -i clip.m4a -af volumedetect -f null -`: `max_volume` at ~0.0 dB means
the mix is clipping and problem 1 step 1 must land before anything is evaluated.

---

# What shipped

All five workstreams landed. `swift test`: **165 tests, 28 suites, passing**. All
three app targets build (Mac, iOS, watchOS).

## Problem 1 - audio

- `AudioMixer`: `AVMutableAudioMix` at -6 dB per track when more than one source
  contributes (`multiTrackGain`). Single sources keep unity gain. Test
  `mixingTwoHotTracksDoesNotClip` was verified to *fail* without the fix
  (measured peak **1.83**, i.e. 83% over full scale).
- `transcribe.sh --preprocess safe|off` (default `safe`): two-pass `ebur128`
  measure then `highpass=f=80,volume=NdB`, gain clamped to +/-20 dB with a
  -1 dBFS true-peak ceiling, target -20 LUFS. Verified on real audio: a -50.2
  LUFS input took the +20 dB clamp and landed at -30.2 LUFS with the peak safely
  under the ceiling.
- Opt-in `setVoiceProcessingEnabled` (OS echo cancellation) behind
  `SettingsKeys.voiceProcessing`. Fails soft - a device that refuses it logs a
  warning and records unprocessed. The input format is read *after* the toggle,
  since voice processing changes it.
- No denoiser shipped, per the evidence.

## Problem 2 - speed

- `--condition auto|on|off`, duration-gated at 600 s (`CONDITION_THRESHOLD_SECONDS`),
  wired into all four engine branches (`--condition_on_previous_text` /
  `--condition-on-previous-text` / `--no-context` / `FW_CONDITION`).
  **A robustness bug surfaced during testing**: with a non-numeric `ffprobe`
  duration ("N/A"), awk compared it as a *string* and `"N/A" > "600"` is true,
  silently disabling conditioning. Fixed with `+d > +t` numeric coercion.
- `transcribe.sh --print-engine` as the single source of truth for engine choice.
- Diagnostics: remediation now `uv tool install mlx-whisper` with a `uv`
  bootstrap (`brew install uv`) - the old `pip install` failed on Homebrew Python
  with PEP 668, which is why the one-click fix never worked. New
  `WhisperEnginePerformanceCheck` warns (yellow, not red) when only the CPU
  engine resolves on Apple silicon, phrased in wall-clock terms. Passes on Intel,
  where openai-whisper is the correct choice. `WhisperModelCheck` now warns about
  the ~2.9 GB first download unless the weights are cached.
- Watchdog: `CommandRunning` gained a `timeout:` overload (SIGTERM, then SIGKILL
  after 5 s) throwing `CommandTimedOut`. Added as a *separate* protocol
  requirement with a forwarding default, so no test fake needed changing.
  `Transcriber` applies `max(15 min, 10x audio duration)` and maps a timeout to
  an actionable `TranscriptionError.timedOut`.

## Problem 3 - UI lag

- `TranscriptSegment.index(at:in:)` in SharedKit: binary search, verified against
  the original linear scan as an oracle across ~280 probes including exact
  starts, gaps, duplicate starts, empty input and beyond-the-end. Gap behaviour
  is now *specified*: hold the previous segment.
- `AudioPlayerModel`: ticker 20 Hz -> 10 Hz; new `currentSegment: Int?` recomputed
  by binary search, plus `@ObservationIgnored segmentStarts`. The list observes
  only `currentSegment`, so the `@Observable` equality guard makes in-segment
  ticks invalidate nothing.
- `TranscriptSegmentList`: `LazyVStack`, and each row is a separate `Equatable`
  `TranscriptRow` taking `isCurrent: Bool` with its action built **inside** `body`.
  Time labels precomputed in `TranscriptRowItem` (kills `String(format:)` on the
  render path). `Equatable` conformance is `nonisolated` - SwiftUI compares views
  off the main actor and the row holds a `@MainActor` model.
- `MarkdownText` takes pre-parsed `MarkdownRenderBlock`s (inline `AttributedString`
  rendered once) and uses `LazyVStack`.
- `DocumentLoader`/`LoadedDocument` in `Apps/Common`, shared by the Mac and iOS
  detail views: reads + parses off the main actor via `Task.detached`, cached by
  `.task(id:)` keyed on **URL + mtime + size** so regenerating `protocol.md` (same
  URL) reloads.

## Problem 4 - summary prompt

- Three-way split per **ADR-9**: enforced contract via `--append-system-prompt`,
  user-editable body spec, one-line postamble. Default body spec is a
  chronological account; decisions/action items are conditional, not mandatory.
- Grounding rules explicitly forbid inventing speaker attribution, state that
  headings follow the meeting's language (so an English template cannot leak
  English headings into a German summary), and permit "not specified".
- `SummaryTemplate` lives in **SharedKit**, not ProcessSession - the Mac app does
  not link the helper module. `config/summary-prompt.md`; absent = default, and
  saving text equal to the default *deletes* the file so unchanged users keep
  receiving improvements.
- `FrontmatterRepair.swift`: strips fences, drops leading chatter only under 200
  characters (longer is kept - losing real content is worse than a cosmetic
  wart), synthesizes a missing title (explicit -> first `# ` heading -> derived)
  and language (from the transcriber's detection), stamps pipeline-owned
  `date`/`duration_minutes`/`session`, and logs every repair.
- `userMessage` puts the transcript **before** the instructions, XML-tagged.
  `--disallowed-tools` + `--permission-mode plan` make "no tools (decision #5)"
  actually true.
- Map step rewritten shape-neutral and kept built-in; `TranscriptChunk.timeRange`
  labels partials `## Part 1 (00:00:00-00:44:12)`. `characterBudget` 48k -> 200k
  so single-shot is the normal path.
- Tests: hostile-template-still-yields-valid-frontmatter, custom template reaches
  reduce but **never** map, nine frontmatter-repair regressions, template
  round-trip/reset/blank handling.

## Still needs manual verification (cannot be checked headlessly)

1. **A real German meeting end-to-end** after `uv tool install mlx-whisper`, with
   a hand-corrected reference transcript. No ground-truth WER was computed
   anywhere in this work - the quality claims rest on structural pathology counts
   and wall-clock time. This is the main open item (issue #13).
2. **Scroll and play/pause smoothness** with a 1000+ segment transcript, on a
   **release** build. SwiftUI body counts are not automatable; use
   `Self._printChanges()` and the Instruments SwiftUI template. Also test
   *recording while a long transcript is selected* - that exercises the ~18 Hz
   `recordingLevels` path, which these fixes mitigate but do not remove.
3. **Echo cancellation** on real hardware, with and without headphones.
4. **The summary template editor** round-trip in Settings, and whether the new
   default output is actually usable for the intended purpose.
5. **`--preprocess safe` on a real noisy recording**, ideally A/B'd against `off`
   per the recipe above, before trusting it beyond "cannot plausibly hurt".

---

# Real-meeting verification (2026-08-13, after implementation)

`uv tool install mlx-whisper`, then the 51.7-minute German meeting
(`2026-08-12T11-07-15Z_907cd9`) through the real pipeline.

## Result

| | segments | words | 1s-apart | runs >=10 | longest run |
|---|---|---|---|---|---|
| baseline (openai-whisper CPU, conditioning on) | 1228 | 8689 | 38.9% | 6 | 140 |
| mlx-whisper GPU, conditioning off | 778 | 8036 | 10.0% | **0** | 3 |

**2 h 51 m -> 5 m 44 s (~30x)**, hallucination loops gone. The baseline's 8689
words include **975 words inside degenerate loops**, so its real content was
~7714; the new run has 8036 words of real content with none of the filler.

## A bug this caught, which the test suite could not

The first real run lost **~3.5 minutes of actual speech** (15:37-19:57), emitting
the stock phrase "Vielen Dank." once per 30-second Whisper window.

Cause: the loudness formula let the true-peak ceiling force an *attenuation*.
This recording is already hard-clipped (5630 samples pinned at 0 dBFS) with a very
wide crest factor - mean -28.7 dB against a 0 dB peak. The formula computed
-16.3 dB to pull the +15.3 dBFS inter-sample peak under the ceiling, taking
integrated loudness to **-44.6 LUFS**, past where Whisper degrades sharply
(cf. the Moonshine gain-vs-WER sweep). Isolated A/B on the same five minutes:
**741 words unattenuated, 528 words at -16.3 dB.**

The logic error: **attenuating cannot un-clip audio that is already clipped** -
the distortion is in the samples - so it only makes speech quieter. The peak
ceiling must only ever limit how much we *boost*. Corrected formula:

```
want = target - integrated
head = ceiling - truePeak
if want <= 0: gain = want                      # cutting also lowers the peak
else:         gain = min(want, max(head, 0))   # boost, never into clipping
```

For this file it now applies **0.00 dB** and the dropout window is fully
recovered (122 -> 735 words, baseline 737).

**Lesson for the next change here:** this bug only appears on audio with a large
crest factor, which no synthetic test had. The gain calculation lives in `awk`
inside `transcribe.sh`, where none of the Swift tests reach it - that is the
coverage gap that let it ship. Moving the calculation into Swift (or adding a
shell test harness) is the outstanding remediation.

## Also learned about these recordings

- The mic path itself clips: `Recorder` taps `inputNode` and writes through with
  no headroom control or clipping detection. The `AudioMixer` fix only covers the
  mic+system summing path, and this session was **mic-only**
  (`audioTracks: ['mic']`), so the mixer was not involved in its clipping.
- The 19-hour runaway job finished on its own after ~22 hours. For that 86-minute
  file the new watchdog budget would be ~14.4 h, so it would have been killed and
  surfaced as a retryable failure instead of grinding silently.

## Still open after this run

1. **The rewritten summary prompt has never run against real `claude`** - only
   fakes. The contract is guaranteed in Swift, but whether the chronological
   default is *usable* is untested. Largest untested surface.
2. **No ground-truth WER.** All claims above are structural (loop counts, word
   deltas), not accuracy against a hand-corrected reference.
3. Gain-formula test coverage (above).
4. Mic-path clipping detection/headroom.
5. The ~18 Hz `recordingLevels` -> `SessionDetailView` rebuild path.
6. Existing sessions still hold their damaged transcripts; nothing was reprocessed
   in place.
