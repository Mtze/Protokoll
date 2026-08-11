import SwiftUI
import SharedKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private extension View {
    /// `.textSelection(.enabled)` where it exists; a no-op on watchOS.
    @ViewBuilder func selectableText() -> some View {
        #if os(watchOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}

// MARK: - Markdown rendering

/// A small, dependency-free block renderer for the Markdown prose in
/// `protocol.md` / `transcript.md`. `AttributedString(markdown:)` only styles
/// *inline* spans (bold/italic/code/links); block structure (headings, lists,
/// rules) is laid out here so the summary reads like a document, not a wall of
/// text. Colors come from the system so it looks right in light and dark mode.
struct MarkdownText: View {
    let markdown: String

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectableText()
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level))
                .bold()
                .padding(.top, level <= 2 ? 6 : 2)
        case let .paragraph(text):
            Text(inline(text))
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .ordered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary).frame(width: 3)
                Text(inline(text)).italic().foregroundStyle(.secondary)
            }
        case let .code(text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }

    /// Inline-only Markdown (bold/italic/`code`/links); falls back to plain text.
    private func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: string, options: options))
            ?? AttributedString(string)
    }
}

/// The block kinds `MarkdownText` lays out. Kept internal + testable-shaped.
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

// MARK: - Tap-to-seek transcript list

/// Renders parsed transcript segments as a clean time+text list. Tapping a row
/// seeks the shared audio model to that segment's start and plays from there;
/// the segment under the playhead is highlighted. When `canSeek` is false
/// (no audio loaded), rows are inert.
struct TranscriptSegmentList: View {
    let segments: [TranscriptSegment]
    let model: AudioPlayerModel
    let canSeek: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                row(index: index, segment: segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(index: Int, segment: TranscriptSegment) -> some View {
        let isCurrent = index == currentIndex
        Button {
            model.seekAndPlay(to: segment.start)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(timeLabel(segment.start))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 62, alignment: .leading)
                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                isCurrent ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSeek)
        .modifier(SeekHelp(canSeek: canSeek))
        .selectableText()
    }

    /// Index of the last segment whose start is at or before the playhead.
    private var currentIndex: Int? {
        guard canSeek, model.isLoaded else { return nil }
        let time = model.currentTime
        var found: Int?
        for (index, segment) in segments.enumerated() {
            if segment.start <= time + 0.05 { found = index } else { break }
        }
        return found
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Adds the hover `.help` only when seeking is possible (an empty help string
/// would show an empty tooltip on macOS).
private struct SeekHelp: ViewModifier {
    let canSeek: Bool
    func body(content: Content) -> some View {
        if canSeek { content.help("transcript.seek.help") } else { content }
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
