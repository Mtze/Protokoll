import SwiftUI
import SharedKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Document loading + caching

/// A document read from disk and fully parsed, ready to render with no further
/// work on the main actor.
///
/// This exists because the detail views used to re-read the file *and* re-parse
/// it on every body pass - a ~10.5 ms main-actor hitch for a 1500-segment
/// transcript, repeated whenever anything else in the view invalidated (job
/// progress lines during processing, or the ~18 Hz recording level meter).
struct LoadedDocument: Sendable, Equatable {
    /// Body text with our YAML frontmatter stripped.
    var body: String = ""
    /// Render-ready Markdown blocks, for the protocol pane and as the transcript
    /// fallback when no timestamps were found.
    var blocks: [MarkdownRenderBlock] = []
    /// Parsed transcript segments; empty when the document has no timestamps.
    var segments: [TranscriptSegment] = []
    /// Flattened transcript text plus per-segment character ranges, for the
    /// selectable text view. Empty when ``segments`` is.
    var layout: TranscriptTextLayout = .empty
    /// Identity of the file this was read from - see ``DocumentLoader/key(for:pane:)``.
    /// Views key their own derived work (the attributed string) off this, so a
    /// rebuild cannot race the asynchronous reload that produced the document.
    var key: String = ""

    var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum DocumentLoader {
    /// Identity for `.task(id:)`.
    ///
    /// Includes modification time and size, not just the path: regenerating a
    /// protocol rewrites the *same* URL (`protocol.md`), so keying on the URL
    /// alone would leave a stale parse on screen. `transcript.md` is immutable
    /// once written (N10), so this only really matters for the protocol - but
    /// keying both the same way keeps one code path.
    static func key(for url: URL, pane: String) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(pane)|\(url.path)|\(stamp)|\(size)"
    }

    /// Reads and parses `url`. Safe to call off the main actor; returns an empty
    /// document when the file is missing or unreadable.
    static func load(_ url: URL, parseTranscript: Bool) -> LoadedDocument {
        let key = key(for: url, pane: parseTranscript ? "transcript" : "protocol")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return LoadedDocument() }
        let body = Frontmatter.split(raw).body
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LoadedDocument(body: body, key: key)
        }
        var document = LoadedDocument(body: body, key: key)
        if parseTranscript {
            document.segments = TranscriptParser.parse(body)
            document.layout = TranscriptTextLayout(segments: document.segments)
        }
        // The Markdown blocks double as the no-timestamps fallback, so parse them
        // whenever the transcript parse came back empty.
        if document.segments.isEmpty {
            document.blocks = MarkdownRenderBlock.parse(body)
        }
        return document
    }
}

// MARK: - Markdown rendering

/// A ``MarkdownBlock`` with its inline Markdown already rendered, so rendering a
/// document costs no parsing at all. ``DocumentAttributedText`` turns these into
/// the paragraph styles the document pane displays.
struct MarkdownRenderBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case bullet
        case ordered(number: Int)
        case quote
        case code
        case rule
    }

    let id: Int
    let kind: Kind
    /// Inline-styled text, empty for `.rule` and `.code`.
    let attributed: AttributedString
    /// Verbatim text, used by `.code` (which must not be Markdown-parsed).
    let plain: String

    /// Parses a whole document into render-ready blocks. Call this off the body
    /// path (e.g. from `.task`), not inside a view's `body`.
    static func parse(_ markdown: String) -> [MarkdownRenderBlock] {
        MarkdownBlock.parse(markdown).enumerated().map { index, block in
            switch block {
            case let .heading(level, text):
                return .init(id: index, kind: .heading(level: level), attributed: inline(text), plain: text)
            case let .paragraph(text):
                return .init(id: index, kind: .paragraph, attributed: inline(text), plain: text)
            case let .bullet(text):
                return .init(id: index, kind: .bullet, attributed: inline(text), plain: text)
            case let .ordered(number, text):
                return .init(id: index, kind: .ordered(number: number), attributed: inline(text), plain: text)
            case let .quote(text):
                return .init(id: index, kind: .quote, attributed: inline(text), plain: text)
            case let .code(text):
                return .init(id: index, kind: .code, attributed: AttributedString(), plain: text)
            case .rule:
                return .init(id: index, kind: .rule, attributed: AttributedString(), plain: "")
            }
        }
    }

    /// Inline-only Markdown (bold/italic/`code`/links); falls back to plain text.
    private static func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options))
            ?? AttributedString(string)
    }
}

/// The block kinds `DocumentAttributedText` lays out. Kept internal + testable-shaped.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case ordered(number: Int, text: String)
    case quote(String)
    case code(String)
    case rule

    /// Splits a Markdown document into block-level elements. Consecutive plain
    /// lines fold into one paragraph; fenced ``` blocks pass through verbatim.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(rawLine); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); blocks.append(.rule); continue
            }
            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let item = unorderedItem(trimmed) {
                flushParagraph(); blocks.append(.bullet(item)); continue
            }
            if let (number, text) = orderedItem(trimmed) {
                flushParagraph(); blocks.append(.ordered(number: number, text: text)); continue
            }
            paragraph.append(trimmed)
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func unorderedItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line[digits.endIndex...]
        guard rest.hasPrefix(". ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}

// MARK: - Copy + Export

/// Copy + Export actions for a document (transcript or summary). Copy puts the
/// text on the platform pasteboard; Export saves it (macOS `NSSavePanel`) or
/// shares the file (iOS share sheet). Labels are localized and, on macOS,
/// carry hover `.help`.
struct DocumentActions: View {
    /// The rendered text to copy (frontmatter already stripped).
    let bodyText: String
    /// The on-disk document, shared as-is on iOS.
    let fileURL: URL
    /// Suggested filename for the macOS save panel, e.g. `Weekly Sync – Summary.md`.
    let exportName: String

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                DocumentPasteboard.copy(bodyText)
                flashCopied()
            } label: {
                Label(
                    didCopy ? "action.copied" : "action.copy",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
            }
            .help("action.copy")
            .accessibilityLabel(Text("action.copy"))

            exportButton
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var exportButton: some View {
        #if os(macOS)
        Button {
            DocumentPasteboard.exportViaSavePanel(text: bodyText, suggestedName: exportName)
        } label: {
            Label("action.export", systemImage: "square.and.arrow.up")
        }
        .help("action.export")
        .accessibilityLabel(Text("action.export"))
        #elseif os(iOS)
        ShareLink(item: fileURL) {
            Label("action.export", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(Text("action.export"))
        #else
        EmptyView()
        #endif
    }

    private func flashCopied() {
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }
}

/// Thin wrapper over the platform pasteboard + macOS save panel.
enum DocumentPasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    #if os(macOS)
    @MainActor static func exportViaSavePanel(text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
    #endif
}
