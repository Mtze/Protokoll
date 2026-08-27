# Plan: selectable protocol + transcript

Status: **implemented** (2026-08-27).
Branch: `feature/Transcription-pipeline` (folded into the same PR as the
transcription/summary work).

## Problem

Reported by the user: you cannot select *part* of the protocol or the transcript.
Copying a few bullet points out of a summary means copying the whole document
(`action.copy`) and deleting the rest by hand.

## Why it did not work

`.textSelection(.enabled)` was already set on both renderers
(`DocumentViews.swift`), so the missing-modifier explanation is wrong. Two real
causes:

1. **Transcript:** every row was a `Button` (tap-to-seek). A button consumes the
   drag, so the text inside it was never selectable - the modifier had no effect
   at all.
2. **Protocol:** each block was its own `Text` view. SwiftUI selection never
   spans sibling `Text`s, so at best a single bullet was selectable and never a
   range of them. This is the case the user actually hit.

Neither is fixable by tuning the SwiftUI tree: (2) is a framework limitation.

## Decision (ADR-11)

Render each document into **one** read-only text view - `NSTextView` on macOS,
`UITextView` on iOS - from an `NSAttributedString`. Retire `MarkdownText` and
`TranscriptSegmentList`.

Rejected alternatives:

- **Per-element selection only** (drop the `Button`, keep the view stack): does
  not solve the reported problem, since selecting across bullets stays
  impossible.
- **`.link` attributes for tap-to-seek:** the obvious TextKit route, but AppKit
  lets a link be *dragged* out of the view, which breaks selection by dragging -
  the one thing this change exists to fix.

## How the interactions survive

- **Tap-to-seek:** `ClickableTextView.mouseDown` records the character index,
  calls `super` (which runs AppKit's selection tracking until mouse-up), and
  seeks only if the resulting selection is empty, i.e. it was a click and not a
  drag. iOS uses a `UITapGestureRecognizer` with `cancelsTouchesInView = false`,
  so the built-in long-press/double-tap selection gestures still work.
- **Playhead highlight:** two attribute edits (remove the old background, add the
  new), triggered by `AudioPlayerModel.currentSegment` - unchanged, still an
  `Int?` that changes once per segment rather than per 10 Hz tick.
- **Performance:** TextKit lays out only visible line fragments, so the
  `LazyVStack` requirement is satisfied by the framework. The
  `NSAttributedString` is built once per document, keyed on `LoadedDocument.key`
  (path + mtime + size) so a rebuild cannot race the asynchronous reload and
  leave the previous document on screen.

## Where the risk is

The character-offset arithmetic: an off-by-one seeks to the wrong segment or
highlights the wrong line, and it looks plausible either way. It also has to be
UTF-16, because that is what `NSAttributedString` uses and transcripts are full
of umlauts. So it lives in `SharedKit/TranscriptTextLayout.swift`, not in the
view, and is covered by `Tests/SharedKitTests/TranscriptTextLayoutTests.swift`:
ranges address exactly their substrings, line ranges tile the document with no
gaps or overlap, non-ASCII text (umlauts, an emoji with a skin-tone modifier)
keeps the offsets right, and hit-testing is checked against a linear scan across
the whole document including out-of-range indices.

Styling correctness is deliberately *not* tested: a wrong font is visible, a
wrong range is not.

## What shipped

- `Sources/SharedKit/TranscriptTextLayout.swift` + tests (7).
- `Apps/Common/DocumentTextView.swift`: `DocumentPane`, `DocumentAttributedText`,
  the platform representable, `ClickableTextView`.
- `Apps/Common/DocumentViews.swift`: `LoadedDocument` gains `layout` + `key`;
  `MarkdownText`, `TranscriptSegmentList`, `TranscriptRow`, `TranscriptRowItem`
  removed.
- Both detail views (`Apps/Shared/Views/SessionDetailView.swift`,
  `Apps/iOS/LibraryListView.swift`) drop their `ScrollView` - the pane scrolls
  itself.
- Docs: ADR-11, `CLAUDE.md` performance + module notes, `docs/MODULES.md`,
  `README.md`.

Verified: `swift test` 183 tests / 31 suites pass; Mac, iOS and watchOS targets
all build.

**Manual verification required** (interaction, not reachable headlessly):
dragging a selection across bullets and across transcript segments, `⌘C` on a
partial selection, `⌘F` in the document, click-to-seek still firing on a plain
click but *not* at the end of a drag, and the playhead highlight tracking
playback.
