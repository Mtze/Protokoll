import Foundation

/// A minimal YAML frontmatter reader/writer for the small, flat key/value
/// subset the Markdown files mirror (title, language, date, …). Foundation-only
/// by design — SharedKit takes no YAML dependency for a handful of scalar keys.
///
/// Frontmatter is delimited by `---` lines at the very top of the document:
/// ```
/// ---
/// title: Weekly Sync
/// language: de
/// ---
/// # body…
/// ```
public struct Frontmatter: Sendable, Equatable {
    /// Ordered key/value pairs (order preserved for stable, diff-friendly output).
    public private(set) var pairs: [(key: String, value: String)]

    public init(_ pairs: [(key: String, value: String)] = []) {
        self.pairs = pairs
    }

    public subscript(_ key: String) -> String? {
        get { pairs.first(where: { $0.key == key })?.value }
        set {
            if let newValue {
                if let index = pairs.firstIndex(where: { $0.key == key }) {
                    pairs[index].value = newValue
                } else {
                    pairs.append((key, newValue))
                }
            } else {
                pairs.removeAll { $0.key == key }
            }
        }
    }

    public static func == (lhs: Frontmatter, rhs: Frontmatter) -> Bool {
        lhs.pairs.count == rhs.pairs.count
            && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    // MARK: Parsing

    /// Splits a document into its frontmatter (if any) and the remaining body.
    public static func split(_ document: String) -> (frontmatter: Frontmatter, body: String) {
        let lines = document.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (Frontmatter(), document)
        }
        var pairs: [(String, String)] = []
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let body = lines[(index + 1)...].joined(separator: "\n")
                // Drop a single leading blank line for tidiness.
                let trimmedBody = body.hasPrefix("\n") ? String(body.dropFirst()) : body
                return (Frontmatter(pairs), trimmedBody)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                value = unquote(value)
                if !key.isEmpty { pairs.append((key, value)) }
            }
            index += 1
        }
        // Unterminated frontmatter: treat the whole thing as body.
        return (Frontmatter(), document)
    }

    // MARK: Rendering

    /// Renders the frontmatter block (with delimiters) followed by `body`.
    /// Returns just `body` when there are no pairs.
    public func render(body: String) -> String {
        guard !pairs.isEmpty else { return body }
        var out = "---\n"
        for (key, value) in pairs {
            out += "\(key): \(Self.quoteIfNeeded(value))\n"
        }
        out += "---\n\n"
        out += body
        return out
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuote = value.contains(":") || value.contains("#")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.isEmpty
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let inner = value.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
    }
}
