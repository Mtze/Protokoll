import SwiftUI
import SharedKit

#if os(macOS)
import AppKit
typealias DocumentFont = NSFont
typealias DocumentColor = NSColor
#elseif os(iOS)
import UIKit
typealias DocumentFont = UIFont
typealias DocumentColor = UIColor
#endif

// MARK: - The pane

/// The protocol / transcript pane.
///
/// Documents render into **one** text view rather than a stack of SwiftUI
/// `Text`s, because SwiftUI selection never spans sibling `Text` views: with a
/// view per block you can select inside one bullet but never across two, and a
/// row wrapped in a `Button` (the old tap-to-seek transcript row) cannot be
/// selected at all, since the button consumes the drag. One text view gives the
/// whole document a single selection, plus Cmd+A/Cmd+C and the macOS find bar
/// for free (ADR-12).
///
/// It also scrolls itself, so callers must **not** wrap it in a `ScrollView`.
struct DocumentPane: View {
    let document: LoadedDocument
    let model: AudioPlayerModel
    /// False when there is no audio: the transcript is then inert text.
    let canSeek: Bool

    #if os(watchOS)
    var body: some View {
        ScrollView {
            Text(document.body)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #else
    /// Rebuilt only when the document or the text size changes - never on a body
    /// pass. Building costs a few ms on an hour-long transcript, which is fine
    /// once per load and was the whole problem when it happened per render.
    @State private var rendered: NSAttributedString?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The single observed read: an `Int?` that changes once per segment, not
        // per player tick.
        let current: Int? = canSeek ? model.currentSegment : nil
        let onClick: ((Int) -> Void)? = canSeek && !document.layout.rows.isEmpty
            ? { index in seek(atCharacter: index) }
            : nil
        DocumentTextView(
            attributed: rendered ?? NSAttributedString(),
            highlight: highlightRange(for: current),
            onClickCharacter: onClick
        )
        // The key comes from the loaded document itself (path + mtime + size), so
        // a rebuild can never race the parent's asynchronous reload and leave the
        // previous document's text on screen.
        .task(id: "\(document.key)|\(typeSize)") {
            rendered = document.layout.rows.isEmpty
                ? DocumentAttributedText.markdown(document.blocks)
                : DocumentAttributedText.transcript(document.layout)
        }
        // Rows no longer look like buttons, so keep the hint (macOS tooltip).
        .modifier(SeekHelp(enabled: onClick != nil))
    }

    private func highlightRange(for segment: Int?) -> NSRange? {
        guard let segment, document.layout.rows.indices.contains(segment) else { return nil }
        return document.layout.rows[segment].lineRange
    }

    private func seek(atCharacter index: Int) {
        guard let row = document.layout.row(at: index) else { return }
        model.seekAndPlay(to: row.start)
    }
    #endif
}

#if os(macOS) || os(iOS)
/// Adds the hover `.help` only when seeking is possible (an empty help string
/// would show an empty tooltip on macOS).
private struct SeekHelp: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.help("transcript.seek.help") } else { content }
    }
}
#endif

#if os(macOS) || os(iOS)

// MARK: - Attributed text

/// Builds the `NSAttributedString` the text view renders. Block layout that used
/// to be SwiftUI views (headings, bullets, quotes, code) becomes fonts and
/// paragraph styles here, so the document keeps its shape while staying one
/// selectable run of text.
enum DocumentAttributedText {
    /// Left inset of the text in a bulleted or numbered line.
    private static let listIndent: CGFloat = 18
    /// Width of the transcript's time column.
    private static let timeColumn: CGFloat = 70

    static func markdown(_ blocks: [MarkdownRenderBlock]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in blocks {
            output.append(paragraph(for: block))
        }
        return output
    }

    static func transcript(_ layout: TranscriptTextLayout) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = timeColumn
        style.tabStops = [NSTextTab(textAlignment: .left, location: timeColumn)]
        style.paragraphSpacing = 5

        let output = NSMutableAttributedString(
            string: layout.text,
            attributes: [
                .font: font(.body),
                .foregroundColor: DocumentColor.documentLabel,
                .paragraphStyle: style,
            ]
        )
        // Time labels are monospaced-digit and secondary so the column reads as a
        // ruler rather than as part of the speech.
        let timeFont = DocumentFont.monospacedDigitSystemFont(
            ofSize: font(.caption1).pointSize, weight: .regular
        )
        output.beginEditing()
        for row in layout.rows {
            output.addAttributes(
                [.font: timeFont, .foregroundColor: DocumentColor.documentSecondaryLabel],
                range: row.timeRange
            )
        }
        output.endEditing()
        return output
    }

    private static func paragraph(for block: MarkdownRenderBlock) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6

        switch block.kind {
        case let .heading(level):
            style.paragraphSpacingBefore = level <= 2 ? 12 : 8
            style.paragraphSpacing = 4
            let base = font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
            return line(
                block.attributed,
                base: bold(base),
                color: .documentLabel,
                style: style,
                bolded: true
            )

        case .paragraph:
            return line(block.attributed, base: font(.body), color: .documentLabel, style: style)

        case .bullet:
            style.headIndent = listIndent
            style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
            style.paragraphSpacing = 3
            return line(
                block.attributed, base: font(.body), color: .documentLabel,
                style: style, prefix: "\u{2022}\t"
            )

        case let .ordered(number):
            style.headIndent = listIndent + 6
            style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent + 6)]
            style.paragraphSpacing = 3
            return line(
                block.attributed, base: font(.body), color: .documentLabel,
                style: style, prefix: "\(number).\t"
            )

        case .quote:
            style.headIndent = listIndent
            style.firstLineHeadIndent = listIndent
            return line(
                block.attributed, base: italic(font(.body)),
                color: .documentSecondaryLabel, style: style, italicized: true
            )

        case .code:
            style.headIndent = 10
            style.firstLineHeadIndent = 10
            let mono = DocumentFont.monospacedSystemFont(ofSize: font(.callout).pointSize, weight: .regular)
            return NSAttributedString(
                string: block.plain + "\n",
                attributes: [
                    .font: mono,
                    .foregroundColor: DocumentColor.documentLabel,
                    .backgroundColor: DocumentColor.documentSecondaryLabel.withAlphaComponent(0.12),
                    .paragraphStyle: style,
                ]
            )

        case .rule:
            // A drawn divider would need a text attachment; a rule glyph carries
            // the same meaning and cannot break the layout.
            style.paragraphSpacingBefore = 8
            return NSAttributedString(
                string: "\u{2E3B}\n",
                attributes: [
                    .font: font(.body),
                    .foregroundColor: DocumentColor.documentSecondaryLabel,
                    .paragraphStyle: style,
                ]
            )
        }
    }

    /// Renders one block's inline Markdown (bold / italic / code / links) into a
    /// paragraph. `AttributedString` from Markdown carries *intents*, not fonts,
    /// so the traits are applied here run by run.
    private static func line(
        _ text: AttributedString,
        base: DocumentFont,
        color: DocumentColor,
        style: NSParagraphStyle,
        prefix: String = "",
        bolded: Bool = false,
        italicized: Bool = false
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        if !prefix.isEmpty {
            output.append(
                NSAttributedString(
                    string: prefix,
                    attributes: [.font: base, .foregroundColor: DocumentColor.documentSecondaryLabel]
                )
            )
        }

        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: runFont(
                    base: base,
                    intent: intent,
                    alreadyBold: bolded,
                    alreadyItalic: italicized
                ),
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            output.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }

        output.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        output.addAttribute(
            .paragraphStyle, value: style, range: NSRange(location: 0, length: output.length)
        )
        return output
    }

    private static func runFont(
        base: DocumentFont,
        intent: InlinePresentationIntent,
        alreadyBold: Bool,
        alreadyItalic: Bool
    ) -> DocumentFont {
        if intent.contains(.code) {
            return DocumentFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        }
        var result = base
        if intent.contains(.stronglyEmphasized), !alreadyBold { result = bold(result) }
        if intent.contains(.emphasized), !alreadyItalic { result = italic(result) }
        return result
    }

    // MARK: Platform font shims

    /// Text-style fonts, so macOS follows the system text size and iOS follows
    /// Dynamic Type (the pane rebuilds when the size category changes).
    private static func font(_ style: DocumentFont.TextStyle) -> DocumentFont {
        DocumentFont.preferredFont(forTextStyle: style)
    }

    private static func bold(_ font: DocumentFont) -> DocumentFont {
        #if os(macOS)
        let descriptor = font.fontDescriptor.withSymbolicTraits(.bold)
        return DocumentFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits([font.fontDescriptor.symbolicTraits, .traitBold])
        else { return font }
        return DocumentFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private static func italic(_ font: DocumentFont) -> DocumentFont {
        #if os(macOS)
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return DocumentFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        guard let descriptor = font.fontDescriptor.withSymbolicTraits([font.fontDescriptor.symbolicTraits, .traitItalic])
        else { return font }
        return DocumentFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }
}

private extension DocumentColor {
    /// System label colors, so both themes are handled by AppKit/UIKit rather
    /// than by us picking two shades.
    static var documentLabel: DocumentColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    static var documentSecondaryLabel: DocumentColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    /// Playhead highlight. Tinted from the accent color so it tracks the theme.
    static var documentHighlight: DocumentColor {
        #if os(macOS)
        NSColor.controlAccentColor.withAlphaComponent(0.18)
        #else
        UIColor.tintColor.withAlphaComponent(0.18)
        #endif
    }
}

// MARK: - The text view

/// A read-only, fully selectable text view. Owns its own scrolling.
///
/// The attributed string is only pushed into the view when the *instance*
/// changes, and the playhead highlight is two attribute edits rather than a
/// re-render, so following playback costs nothing per tick.
struct DocumentTextView {
    let attributed: NSAttributedString
    /// Range to paint as the current segment, `nil` for documents without a
    /// playhead.
    let highlight: NSRange?
    /// Called with the character index of a click; `nil` disables seeking.
    let onClickCharacter: ((Int) -> Void)?

    @MainActor final class Coordinator: NSObject {
        var rendered: NSAttributedString?
        var highlighted: NSRange?
        var onClickCharacter: ((Int) -> Void)?

        #if os(iOS)
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView = recognizer.view as? UITextView, let onClickCharacter else { return }
            let point = recognizer.location(in: textView)
            guard let position = textView.closestPosition(to: point) else { return }
            onClickCharacter(textView.offset(from: textView.beginningOfDocument, to: position))
        }
        #endif
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    /// Swaps in new text (identity comparison - the pane rebuilds the string only
    /// when the document changes) and moves the highlight.
    @MainActor fileprivate func sync(_ storage: NSTextStorage?, coordinator: Coordinator) {
        guard let storage else { return }
        coordinator.onClickCharacter = onClickCharacter

        if coordinator.rendered !== attributed {
            storage.setAttributedString(attributed)
            coordinator.rendered = attributed
            coordinator.highlighted = nil
        }
        guard coordinator.highlighted != highlight else { return }
        storage.beginEditing()
        if let old = coordinator.highlighted, NSMaxRange(old) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: old)
        }
        if let new = highlight, NSMaxRange(new) <= storage.length {
            storage.addAttribute(.backgroundColor, value: DocumentColor.documentHighlight, range: new)
        }
        storage.endEditing()
        coordinator.highlighted = highlight
    }
}

#if os(macOS)

extension DocumentTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let textView = ClickableTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        // Cmd+F over the document, which the stack of Text views never offered.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.coordinator = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClickableTextView else { return }
        sync(textView.textStorage, coordinator: context.coordinator)
    }
}

/// Turns a click into a seek without giving up selection.
///
/// `super.mouseDown` runs AppKit's selection tracking loop until the mouse comes
/// up, so afterwards an empty selection means the gesture was a click and not a
/// drag. Handling the seek before `super` instead would swallow drags; using a
/// link attribute instead would let AppKit drag the "link" out of the view.
private final class ClickableTextView: NSTextView {
    weak var coordinator: DocumentTextView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let handler = coordinator?.onClickCharacter else { return }
        handler(index)
    }
}

#elseif os(iOS)

extension DocumentTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 24, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true

        // A tap seeks; selection still comes from the built-in long-press and
        // double-tap recognizers, which this one does not cancel.
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        sync(textView.textStorage, coordinator: context.coordinator)
    }
}

#endif
#endif
