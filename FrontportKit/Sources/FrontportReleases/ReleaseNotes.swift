import Foundation

/// Turns upstream release notes into text for the Releases screen.
public enum ReleaseNotes {
    /// A short plain-text summary of Markdown release notes, at most `limit` characters.
    ///
    /// Markdown, HTML, links and images are stripped, and so are sections that are boilerplate in release notes
    /// (downloads, setup guides, contributor lists, "Full Changelog"). Hand-written prose and list items come
    /// first; quoted notices, collapsed `<details>` and GitHub's generated "… by @user in …/pull/N" lines are
    /// used only when there is nothing else. Whole sentences are kept where possible, otherwise the text is cut
    /// at a word and ends with "…".
    public static func summary(_ markdown: String, limit: Int = 220) -> String {
        guard limit > 0 else { return "" }
        let units = Parser(markdown).units()
        // Inline cleanup is the slow part, so it runs only on the units that end up in the summary.
        var sentences = Self.sentences(from: units.filter { !$0.secondary }, limit: limit)
        if sentences.isEmpty {
            sentences = Self.sentences(from: units.filter(\.secondary), limit: limit)
        }
        return fit(sentences, limit: limit)
    }

    // MARK: Composing

    private static func sentences(from units: [Unit], limit: Int) -> [String] {
        var result: [String] = []
        var length = 0
        for unit in units {
            let source = unit.secondary ? Parser.generatedTitle(unit.text) ?? unit.text : unit.text
            guard let text = Inline.text(of: source) else { continue }
            for sentence in split(text) {
                result.append(sentence)
                length += sentence.count + 1
            }
            if length > limit { break }
        }
        return result
    }

    private static func split(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousEndsSentence = false
        for character in text {
            if previousEndsSentence, character == " " {
                result.append(current)
                current = ""
                previousEndsSentence = false
                continue
            }
            current.append(character)
            previousEndsSentence = ".!?".contains(character)
        }
        if !current.isEmpty { result.append(terminated(current)) }
        return result.filter { !$0.isEmpty }
    }

    private static func terminated(_ text: String) -> String {
        var text = text
        while let last = text.last, ",;:-–— ".contains(last) { text.removeLast() }
        guard let last = text.last else { return "" }
        return ".!?…".contains(last) ? text : text + "."
    }

    /// Whole sentences while at least half the room is used; otherwise the text cut at a word, with "…".
    private static func fit(_ sentences: [String], limit: Int) -> String {
        let joined = sentences.joined(separator: " ")
        if joined.count <= limit { return joined }
        var kept = ""
        for sentence in sentences {
            let candidate = kept.isEmpty ? sentence : kept + " " + sentence
            if candidate.count > limit { break }
            kept = candidate
        }
        if kept.count * 2 >= limit { return kept }

        var cut = String(joined.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) * 2 >= limit - 1 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, " ,;:-–—.".contains(last) { cut.removeLast() }
        return cut + "…"
    }
}

// MARK: Block structure

private struct Unit {
    /// A paragraph or list item, inline Markdown still in place.
    var text: String
    /// Notices, collapsed details and generated pull request lines: used only when nothing else is left.
    var secondary: Bool
}

/// A line-based reading of GitHub-flavored Markdown, just deep enough to find the prose.
private struct Parser {
    private static let detailsOpen = "\u{1}details-open"
    private static let detailsClose = "\u{1}details-close"

    /// Headings whose whole section is boilerplate.
    private static let boilerplate: Set<String> = [
        "download", "downloads", "setup guide", "setup", "installation", "install", "how to install",
        "full changelog", "new contributors", "contributors", "credits", "thanks", "special thanks", "checksums",
    ]

    private let lines: [Substring]

    init(_ markdown: String) {
        lines = Self.removingHTML(markdown).split(separator: "\n", omittingEmptySubsequences: false)
    }

    func units() -> [Unit] {
        var units: [Unit] = []
        var paragraph: [Substring] = []
        var secondary = false
        var isItem = false
        var inFence = false
        var skipping = false
        var details = 0
        var inQuote = false

        func flush() {
            defer {
                paragraph = []
                isItem = false
            }
            guard !paragraph.isEmpty else { return }
            if let unit = Self.unit(paragraph.joined(separator: " "), secondary: secondary) { units.append(unit) }
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line == Self.detailsOpen || line == Self.detailsClose {
                flush()
                details = max(0, details + (line == Self.detailsOpen ? 1 : -1))
                continue
            }
            if line.isEmpty {
                flush()
                inQuote = false
                continue
            }
            if let heading = Self.heading(line) {
                flush()
                inQuote = false
                skipping = Self.isBoilerplate(heading)
                continue
            }
            if Self.isRule(line) {
                // A setext underline turns the paragraph above it into a heading.
                if "=-".contains(line.first!), paragraph.count == 1, !isItem {
                    skipping = Self.isBoilerplate(String(paragraph[0]))
                    paragraph = []
                } else {
                    flush()
                }
                continue
            }
            if skipping || line.hasPrefix("|") || Self.isLinkDefinition(line) { continue }

            var content = Substring(line)
            if content.hasPrefix(">") {
                content = content.drop { $0 == ">" || $0 == " " }
                inQuote = true
            }
            if content.hasPrefix("[!"), let close = content.firstIndex(of: "]") {
                content = content[content.index(after: close)...].drop { $0 == " " }
            }
            if content.isEmpty { continue }

            if let item = Self.listItem(content) {
                flush()
                paragraph = [item]
                isItem = true
                secondary = inQuote || details > 0
            } else if paragraph.isEmpty {
                paragraph = [content]
                secondary = inQuote || details > 0
            } else {
                paragraph.append(content)
            }
        }
        flush()
        return units
    }

    private static func unit(_ text: String, secondary: Bool) -> Unit? {
        // "@someone made their first contribution in https://…"
        if text.contains("first contribution"), text.contains(/@[\w-]+ made (?:their|his|her) first contribution/) {
            return nil
        }
        // Already-secondary units get their title extracted only if they are used.
        if !secondary, let title = generatedTitle(text) { return Unit(text: title, secondary: true) }
        return Unit(text: text, secondary: secondary)
    }

    /// The title of GitHub's generated "Title by @user in https://github.com/o/r/pull/12", or nil.
    static func generatedTitle(_ text: String) -> String? {
        guard text.contains(" by @") else { return nil }
        return text.firstMatch(of: /^(.*?)\s+by\s+@[\w-]+(?:\[bot\])?\s+in\s+(?:https?:\/\/\S+|#\d+)\s*$/)
            .map { String($0.output.1) }
    }

    // MARK: Line kinds

    /// The text of an ATX heading ("## Title"), or nil when the line isn't one.
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return String(rest).trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
    }

    /// "---", "===", "***" or "___".
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard let mark = marks.first, "=-*_".contains(mark), marks.allSatisfy({ $0 == mark }) else { return false }
        return mark == "=" || marks.count >= 3 || (mark == "-" && marks.count >= 2)
    }

    /// "[ref]: https://…".
    private static func isLinkDefinition(_ line: String) -> Bool {
        line.hasPrefix("[") && !line.hasPrefix("[!") && line.contains("]:")
            && line.wholeMatch(of: /\[[^\]]+\]:\s*\S+.*/) != nil
    }

    /// The text of a list item ("- x", "* x", "1. x", "- [x] x"), or nil when the line isn't one.
    private static func listItem(_ line: Substring) -> Substring? {
        var rest: Substring
        if let first = line.first, "*+-".contains(first) {
            rest = line.dropFirst()
        } else {
            let digits = line.prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard (1...3).contains(digits.count) else { return nil }
            rest = line.dropFirst(digits.count)
            guard let mark = rest.first, mark == "." || mark == ")" else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        if rest.count >= 4, rest.hasPrefix("["), "xX ".contains(rest.dropFirst().first!),
            rest.dropFirst(2).first == "]"
        {
            rest = rest.dropFirst(3).drop { $0 == " " }
        }
        return rest
    }

    private static func isBoilerplate(_ heading: String) -> Bool {
        let letters = Inline.text(of: heading, keepLabels: true)?.lowercased()
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return letters.map { boilerplate.contains(String($0).split(separator: " ").joined(separator: " ")) } ?? false
    }

    // MARK: HTML

    /// Drops comments and tags in one pass (tags can span lines, as in `<img\n src=…>`), turning
    /// `<details>` and `</details>` into lines of their own so collapsed content can be told apart.
    private static func removingHTML(_ markdown: String) -> String {
        let source = Array(markdown.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        func starts(with text: String, at position: Int) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard position + scalars.count <= source.count else { return false }
            for (offset, scalar) in scalars.enumerated() {
                guard source[position + offset].properties.lowercaseMapping == String(scalar) else { return false }
            }
            return true
        }

        func append(_ text: String) { output.append(contentsOf: text.unicodeScalars) }

        while index < source.count {
            let scalar = source[index]
            if scalar == "\r" {
                append("\n")
                index += source.indices.contains(index + 1) && source[index + 1] == "\n" ? 2 : 1
                continue
            }
            guard scalar == "<" else {
                output.append(scalar)
                index += 1
                continue
            }
            if starts(with: "<!--", at: index) {
                var end = index + 4
                while end < source.count, !starts(with: "-->", at: end) { end += 1 }
                index = min(end + 3, source.count)
                continue
            }
            let nameStart = index + (source.indices.contains(index + 1) && source[index + 1] == "/" ? 2 : 1)
            guard source.indices.contains(nameStart), source[nameStart].properties.isAlphabetic,
                source[nameStart].isASCII,
                let close = source[nameStart...].firstIndex(of: ">")
            else {
                output.append(scalar)
                index += 1
                continue
            }
            let closing = nameStart == index + 2
            let name = String(String.UnicodeScalarView(source[nameStart..<close].prefix { $0.properties.isAlphabetic }))
            if name.lowercased() == "details" {
                append("\n\(closing ? detailsClose : detailsOpen)\n")
            } else {
                append(" ")
            }
            index = close + 1
        }
        return String(output)
    }
}

// MARK: Inline

private enum Inline {
    /// Inline Markdown to plain text, or nil when nothing worth showing is left: no letters, a "Full
    /// Changelog" line, or a short label such as "1.2.2 Changelog:" that only introduces what follows.
    static func text(of markdown: String, keepLabels: Bool = false) -> String? {
        var text = markdown
        if text.contains("](") || text.contains("][") {
            text = text.replacing(/!\[[^\]]*\](?:\([^)]*\)|\[[^\]]*\])/, with: "")
            text = text.replacing(/\[([^\]]*)\](?:\([^)]*\)|\[[^\]]*\])/) { String($0.output.1) }
        }
        if text.contains("://") { text = text.replacing(/https?:\/\/\S+/, with: "") }
        if text.contains("`") { text = text.replacing(/`+([^`]*)`+/) { String($0.output.1) } }
        if text.contains("*") || text.contains("_") || text.contains("~") {
            text = text.replacing(/\*\*([^*]+)\*\*/) { String($0.output.1) }
            text = text.replacing(/__([^_]+)__/) { String($0.output.1) }
            text = text.replacing(/~~([^~]+)~~/) { String($0.output.1) }
            // Single `*` or `_` emphasis, not inside words such as snake_case.
            text = text.replacing(/(^|[^\w*])\*([^*\s](?:[^*]*[^*\s])?)\*(?![\w*])/) { $0.output.1 + $0.output.2 }
            text = text.replacing(/(^|[^\w_])_([^_\s](?:[^_]*[^_\s])?)_(?![\w_])/) { $0.output.1 + $0.output.2 }
        }
        if text.contains(":") { text = text.replacing(/:[a-z0-9_+-]*[a-z][a-z0-9_+-]*:/, with: "") }
        if text.contains("&") { text = decodeEntities(text) }
        // Leftovers of removed links, such as "Setup guide: ()".
        if text.contains("(") || text.contains("[") { text = text.replacing(/\(\s*\)|\[\s*\]/, with: "") }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for mark in [",", ".", ";", ":", "!", "?"] where text.contains(" " + mark) {
            text = text.replacingOccurrences(of: " " + mark, with: mark)
        }

        guard text.contains(where: \.isLetter) else { return nil }
        if keepLabels { return text }
        if text.lowercased().hasPrefix("full changelog") { return nil }
        if text.hasSuffix(":"), text.split(separator: " ").count <= 5 { return nil }
        return text
    }

    private static func decodeEntities(_ text: String) -> String {
        var text = text.replacing(/&#(x[0-9A-Fa-f]+|\d+);/) { match -> String in
            let value = match.output.1
            let code = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        for (entity, character) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}
