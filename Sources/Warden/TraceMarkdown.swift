import Foundation

/// The Markdown agents write in their replies, read the way their command-line interfaces draw it.
/// Foundation's parser takes tens of milliseconds for one long reply, so Live Output uses this small one.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case item(level: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case table([[String]])
    case rule

    var isItem: Bool {
        if case .item = self { return true }
        return false
    }
}

enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let body = line.drop { $0 == " " || $0 == "\t" }
            let indent = line.count - body.count
            if body.isEmpty {
                flush()
                index += 1
            } else if let fence = fence(body) {
                flush()
                var code: [Substring] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].drop { $0 == " " }
                    index += 1
                    if candidate.hasPrefix(fence), candidate.drop(while: { $0 == fence.first }).allSatisfy(\.isWhitespace) { break }
                    code.append(lines[index - 1])
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if let heading = heading(body) {
                flush()
                blocks.append(.heading(heading))
                index += 1
            } else if isRule(body) {
                flush()
                blocks.append(.rule)
                index += 1
            } else if body.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flush()
                var rows = [cells(body)]
                index += 2
                while index < lines.count {
                    let row = lines[index].drop { $0 == " " }
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row))
                    index += 1
                }
                blocks.append(.table(rows))
            } else if body.hasPrefix(">") {
                flush()
                var quote: [Substring] = []
                while index < lines.count {
                    let row = lines[index].drop { $0 == " " }
                    guard row.hasPrefix(">") else { break }
                    quote.append(row.dropFirst().drop { $0 == " " })
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
            } else if let item = listItem(body) {
                flush()
                var text = [item.text]
                index += 1
                // An indented line that starts no other block continues the item.
                while index < lines.count {
                    let next = lines[index]
                    let nextBody = next.drop { $0 == " " || $0 == "\t" }
                    guard !nextBody.isEmpty, next.count - nextBody.count > indent,
                          listItem(nextBody) == nil, fence(nextBody) == nil else { break }
                    text.append(nextBody)
                    index += 1
                }
                blocks.append(.item(level: min(indent / 2, 3), marker: item.marker, text: text.joined(separator: "\n")))
            } else {
                paragraph.append(body)
                index += 1
            }
        }
        flush()
        return blocks
    }

    private static func fence(_ body: Substring) -> String? {
        if body.hasPrefix("```") { return "```" }
        if body.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ body: Substring) -> String? {
        let hashes = body.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = body.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static func isRule(_ body: Substring) -> Bool {
        let marks = body.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: Substring) -> Bool {
        let row = line.trimmingCharacters(in: .whitespaces)
        return row.contains("|") && row.contains("--") && row.allSatisfy { "|-: \t".contains($0) }
    }

    private static func cells(_ row: Substring) -> [String] {
        var row = row.trimmingCharacters(in: .whitespaces)[...]
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func listItem(_ body: Substring) -> (marker: String, text: Substring)? {
        guard let first = body.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            return ("•", rest.drop { $0 == " " || $0 == "\t" })
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let after = body.dropFirst(digits.count)
        guard after.first == "." || after.first == ")", after.dropFirst().first == " " else { return nil }
        return (digits + ".", after.dropFirst().drop { $0 == " " })
    }
}

struct InlineStyle: OptionSet, Hashable {
    let rawValue: UInt8
    static let bold = InlineStyle(rawValue: 1)
    static let italic = InlineStyle(rawValue: 2)
    static let code = InlineStyle(rawValue: 4)
    static let strike = InlineStyle(rawValue: 8)
}

struct InlineRun: Equatable {
    var text: String
    var style: InlineStyle
    /// A link's destination exactly as written: a URL, an absolute path, or a path relative to the session folder.
    var destination: String?
}

/// Code spans, emphasis, strikethrough, links, autolinks, and bare web addresses, after CommonMark's main rules.
enum InlineMarkdown {
    private static let searchLimit = 4_000

    static func runs<S: StringProtocol>(_ text: S) -> [InlineRun] {
        let scalars = Array(text.unicodeScalars)
        var runs: [InlineRun] = []
        scan(scalars, 0..<scalars.count, style: [], destination: nil, depth: 0, into: &runs)
        var merged: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.style == run.style, last.destination == run.destination {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static func scan(_ s: [Unicode.Scalar], _ range: Range<Int>, style: InlineStyle, destination: String?,
                             depth: Int, into runs: inout [InlineRun]) {
        var buffer = String.UnicodeScalarView()
        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(InlineRun(text: String(buffer), style: style, destination: destination))
            buffer = String.UnicodeScalarView()
        }
        let end = range.upperBound
        var i = range.lowerBound
        while i < end {
            let c = s[i]
            switch c {
            case "\\":
                if i + 1 < end, isPunctuation(s[i + 1]) {
                    buffer.append(s[i + 1])
                    i += 2
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "`":
                let count = runLength(s, at: i, end: end)
                if let close = codeClose(s, from: i + count, end: end, count: count) {
                    flush()
                    var content = String(String.UnicodeScalarView(s[(i + count)..<close]))
                    if content.count > 2, content.hasPrefix(" "), content.hasSuffix(" ") {
                        content = String(content.dropFirst().dropLast())
                    }
                    runs.append(InlineRun(text: content, style: style.union(.code), destination: destination))
                    i = close + count
                } else {
                    buffer.append(contentsOf: s[i..<(i + count)])
                    i += count
                }
            case "[", "!":
                let open = c == "!" ? i + 1 : i
                if destination == nil, open < end, s[open] == "[", let link = link(s, open: open, end: end) {
                    flush()
                    if open + 1 < link.labelEnd {
                        scan(s, (open + 1)..<link.labelEnd, style: style, destination: link.destination, depth: depth + 1, into: &runs)
                    } else {
                        runs.append(InlineRun(text: c == "!" ? "image" : link.destination, style: style, destination: link.destination))
                    }
                    i = link.end
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "<":
                if destination == nil, let close = autolink(s, at: i, end: end) {
                    flush()
                    let address = String(String.UnicodeScalarView(s[(i + 1)..<close]))
                    runs.append(InlineRun(text: address, style: style, destination: address))
                    i = close + 1
                } else {
                    buffer.append(c)
                    i += 1
                }
            case "*", "_", "~":
                let count = runLength(s, at: i, end: end)
                if depth < 8, let close = emphasisClose(s, open: i, count: count, range: range) {
                    flush()
                    let added: InlineStyle = c == "~" ? .strike : count == 1 ? .italic : count == 2 ? .bold : [.bold, .italic]
                    scan(s, (i + count)..<close, style: style.union(added), destination: destination, depth: depth + 1, into: &runs)
                    i = close + count
                } else {
                    buffer.append(contentsOf: s[i..<(i + count)])
                    i += count
                }
            case "h":
                if destination == nil, i + 3 < end, s[i + 1] == "t", s[i + 2] == "t", s[i + 3] == "p",
                   i == range.lowerBound || !isWord(s[i - 1]), let close = bareURL(s, at: i, end: end) {
                    flush()
                    let address = String(String.UnicodeScalarView(s[i..<close]))
                    runs.append(InlineRun(text: address, style: style, destination: address))
                    i = close
                } else {
                    buffer.append(c)
                    i += 1
                }
            default:
                buffer.append(c)
                i += 1
            }
        }
        flush()
    }

    private static func runLength(_ s: [Unicode.Scalar], at index: Int, end: Int) -> Int {
        var next = index
        while next < end, s[next] == s[index] { next += 1 }
        return next - index
    }

    private static func codeClose(_ s: [Unicode.Scalar], from start: Int, end: Int, count: Int) -> Int? {
        var j = start
        let limit = min(end, start + searchLimit)
        while j < limit {
            guard s[j] == "`" else { j += 1; continue }
            let length = runLength(s, at: j, end: end)
            if length == count { return j }
            j += length
        }
        return nil
    }

    /// A closing delimiter run of the same length, flanked like CommonMark's. `_` never opens or closes inside a word.
    private static func emphasisClose(_ s: [Unicode.Scalar], open: Int, count: Int, range: Range<Int>) -> Int? {
        let mark = s[open]
        guard mark == "~" ? count == 2 : (1...3).contains(count) else { return nil }
        let after = open + count
        guard after < range.upperBound, !isSpace(s[after]) else { return nil }
        if mark == "_", open > range.lowerBound, isWord(s[open - 1]) { return nil }
        // Scanning from the first character keeps a code span right after the opener paired with its own end.
        var j = after
        let limit = min(range.upperBound, after + searchLimit)
        while j < limit {
            let c = s[j]
            if c == "`" {
                let length = runLength(s, at: j, end: range.upperBound)
                j = codeClose(s, from: j + length, end: range.upperBound, count: length).map { $0 + length } ?? j + length
                continue
            }
            guard c == mark else { j += 1; continue }
            let length = runLength(s, at: j, end: range.upperBound)
            let next = j + length
            let flanked = !isSpace(s[j - 1]) && (mark != "_" || next >= range.upperBound || !isWord(s[next]))
            if length == count, flanked { return j }
            j = next
        }
        return nil
    }

    private static func link(_ s: [Unicode.Scalar], open: Int, end: Int) -> (labelEnd: Int, destination: String, end: Int)? {
        var depth = 0
        var j = open + 1
        let limit = min(end, open + searchLimit)
        var labelEnd: Int?
        while j < limit {
            let c = s[j]
            if c == "\\" { j += 2; continue }
            if c == "[" { depth += 1 }
            if c == "]" {
                if depth == 0 { labelEnd = j; break }
                depth -= 1
            }
            j += 1
        }
        guard let labelEnd, labelEnd + 1 < end, s[labelEnd + 1] == "(" else { return nil }
        j = labelEnd + 2
        while j < end, s[j] == " " { j += 1 }
        let destination: String
        if j < end, s[j] == "<" {
            guard let close = (j + 1..<min(end, j + searchLimit)).first(where: { s[$0] == ">" || s[$0] == "\n" }),
                  s[close] == ">" else { return nil }
            destination = String(String.UnicodeScalarView(s[(j + 1)..<close]))
            j = close + 1
        } else {
            let start = j
            var parens = 0
            while j < end, !isSpace(s[j]) {
                if s[j] == "(" { parens += 1 }
                if s[j] == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                j += 1
            }
            guard j > start else { return nil }
            destination = String(String.UnicodeScalarView(s[start..<j]))
        }
        while j < end, s[j] == " " { j += 1 }
        if j < end, s[j] == "\"" || s[j] == "'" {
            let quote = s[j]
            guard let close = (j + 1..<min(end, j + searchLimit)).first(where: { s[$0] == quote }) else { return nil }
            j = close + 1
            while j < end, s[j] == " " { j += 1 }
        }
        guard j < end, s[j] == ")" else { return nil }
        return (labelEnd, destination, j + 1)
    }

    private static func autolink(_ s: [Unicode.Scalar], at index: Int, end: Int) -> Int? {
        let rest = String(String.UnicodeScalarView(s[(index + 1)..<min(end, index + 9)])).lowercased()
        guard rest.hasPrefix("http://") || rest.hasPrefix("https://") || rest.hasPrefix("mailto:") else { return nil }
        var j = index + 1
        while j < min(end, index + searchLimit) {
            if s[j] == ">" { return j }
            if isSpace(s[j]) || s[j] == "<" { return nil }
            j += 1
        }
        return nil
    }

    private static func bareURL(_ s: [Unicode.Scalar], at index: Int, end: Int) -> Int? {
        let head = String(String.UnicodeScalarView(s[index..<min(end, index + 8)]))
        let scheme = head.hasPrefix("https://") ? 8 : head.hasPrefix("http://") ? 7 : 0
        guard scheme > 0 else { return nil }
        var j = index + scheme
        while j < end, !isSpace(s[j]), !"<>\"`".unicodeScalars.contains(s[j]) { j += 1 }
        // Sentence punctuation and an unmatched closing parenthesis stay outside the address.
        while j > index + scheme {
            let last = s[j - 1]
            if ".,;:!?'*_~".unicodeScalars.contains(last) {
                j -= 1
            } else if last == ")" {
                let slice = s[index..<j]
                if slice.filter({ $0 == ")" }).count > slice.filter({ $0 == "(" }).count { j -= 1 } else { break }
            } else {
                break
            }
        }
        return j > index + scheme ? j : nil
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars.contains(scalar)
    }
}
