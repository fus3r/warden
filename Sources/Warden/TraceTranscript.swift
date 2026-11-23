import AppKit
import WardenCore

/// Live Output's terminal colours, after macOS Terminal's Basic profile in each appearance.
enum TracePalette {
    static let pointSize: CGFloat = 11
    static let lineHeight: CGFloat = 15
    static let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
    static let italicFont = italic(font)
    static let boldItalicFont = italic(boldFont)
    /// The width of one character cell.
    static let column = ("0" as NSString).size(withAttributes: [.font: font]).width

    static let backdrop = adaptive(0xD7D7DC, 0x111113)
    static let canvas = adaptive(0xFFFFFF, 0x1E1E1E)
    static let titleBar = adaptive(0xECECEC, 0x2C2C2E)
    static let titleRule = adaptive(0xD3D3D3, 0x121212)
    static let rim = adaptive(0x000000, 0xFFFFFF, alpha: (0.15, 0.11))
    static let text = adaptive(0x1D1D1F, 0xE2E2E4)
    static let strong = adaptive(0x000000, 0xFFFFFF)
    static let dim = adaptive(0x6B6B70, 0x9D9DA3)
    static let faint = adaptive(0xA6A6AB, 0x5F5F64)
    static let code = adaptive(0x0A7266, 0x6CD4C4)
    /// Links share the accent of code and add an underline.
    static let link = code
    static let green = adaptive(0x1E8A3A, 0x32D74B)
    static let red = adaptive(0xC8102E, 0xFF6B6B)
    static let orange = adaptive(0xB34F00, 0xFF9F0A)
    static let yellow = adaptive(0x8A6A00, 0xFFD426)
    static let cursor = adaptive(0x8E8E93, 0xC4C4C9)

    static func adaptive(_ light: UInt32, _ dark: UInt32, alpha: (light: CGFloat, dark: CGFloat) = (1, 1)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let code = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((code >> 16) & 255) / 255, green: CGFloat((code >> 8) & 255) / 255,
                           blue: CGFloat(code & 255) / 255, alpha: isDark ? alpha.dark : alpha.light)
        }
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
    }
}

@MainActor
private enum TraceParagraph {
    private struct Key: Hashable {
        let first: CGFloat
        let head: CGFloat
        let after: CGFloat
        let tabs: [CGFloat]
    }

    private static var styles: [Key: NSParagraphStyle] = [:]

    /// A fixed line height keeps the terminal's rhythm when a line falls back to another font for a symbol.
    static func style(first: CGFloat, head: CGFloat, after: CGFloat, tabs: [CGFloat] = []) -> NSParagraphStyle {
        let key = Key(first: first, head: head, after: after, tabs: tabs)
        if let style = styles[key] { return style }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = TracePalette.lineHeight
        style.maximumLineHeight = TracePalette.lineHeight
        style.firstLineHeadIndent = first
        style.headIndent = head
        style.paragraphSpacing = after
        style.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
        style.defaultTabInterval = TracePalette.column * 4
        styles[key] = style
        return style
    }
}

/// Draws log events as the agent's command-line interface shows them: Claude Code's ⏺ and ⎿, or Codex's • and └.
@MainActor
final class TranscriptRenderer {
    struct Style: Equatable {
        var provider: AgentProvider
        var showsCommands: Bool
        var cwd: String
    }

    private struct Key: Hashable {
        let offset: UInt64
        let part: Int
        let output: Int
        let failed: Bool?
    }

    private static let eventGap: CGFloat = 9
    private static let blockGap: CGFloat = 6
    private static let itemGap: CGFloat = 2

    private(set) var style: Style
    private var cache: [Key: NSAttributedString] = [:]
    private var gutter: CGFloat { TracePalette.column * 2 }

    init(style: Style) {
        self.style = style
    }

    /// Messages and prompts always show. Commands, their output, and turn boundaries need the Commands view.
    static func visible(_ events: [TraceEvent], showsCommands: Bool) -> [TraceEvent] {
        events.filter { event in
            switch event.kind {
            case .message, .prompt: true
            case .tool: showsCommands
            case .turn: event.label != "Turn started" && (showsCommands || event.label != "Turn finished")
            }
        }
    }

    func restyle(_ style: Style) {
        guard style != self.style else { return }
        self.style = style
        cache.removeAll()
    }

    func rendered(_ event: TraceEvent) -> NSAttributedString {
        let key = key(event)
        if let cached = cache[key] { return cached }
        let output = NSMutableAttributedString()
        switch event.kind {
        case .message: message(event.text ?? "", into: output)
        case .prompt: prompt(event.text ?? "", into: output)
        case .tool: tool(event, into: output)
        case .turn: turn(event.label, into: output)
        }
        cache[key] = output
        return output
    }

    /// Drops renderings of events that left the log's retained history.
    func keep(only events: [TraceEvent]) {
        guard cache.count > events.count + 32 else { return }
        let live = Set(events.map(key))
        cache = cache.filter { live.contains($0.key) }
    }

    private func key(_ event: TraceEvent) -> Key {
        Key(offset: event.id.offset, part: event.id.part, output: event.output?.utf8.count ?? -1, failed: event.toolFailed)
    }

    // MARK: Events

    private func message(_ text: String, into output: NSMutableAttributedString) {
        let blocks = MarkdownBlocks.parse(TranscriptText.withoutCitations(text))
        let glyph = style.provider == .claude ? "⏺" : "•"
        for (index, block) in blocks.enumerated() {
            let next = blocks.indices.contains(index + 1) ? blocks[index + 1] : nil
            let after = next.map { block.isItem && $0.isItem ? Self.itemGap : Self.blockGap } ?? Self.eventGap
            write(block, lead: index == 0 ? glyph : nil, after: after, into: output)
        }
    }

    private func prompt(_ text: String, into output: NSMutableAttributedString) {
        // A prompt is context for the replies below it, so a long instruction shows only its opening.
        let (lineLimit, characterLimit) = style.showsCommands ? (12, 1_200) : (3, 360)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let content = NSMutableAttributedString()
        append(style.provider == .claude ? ">\t" : "›\t", color: TracePalette.dim, font: TracePalette.boldFont, to: content)
        // Clipping the drawn text, not the Markdown, never leaves a lone ** or backtick behind.
        if inline(lines.prefix(lineLimit).joined(separator: "\n"), color: TracePalette.dim, font: TracePalette.font,
                  to: content, limit: characterLimit) {
            append("…", color: TracePalette.faint, to: content)
        } else if lines.count > lineLimit {
            append("\n…", color: TracePalette.faint, to: content)
        }
        paragraph(content, first: 0, head: gutter, tabs: [gutter], after: Self.eventGap, into: output)
    }

    private func tool(_ event: TraceEvent, into output: NSMutableAttributedString) {
        let line = ToolLines.describe(event, provider: style.provider, cwd: style.cwd)
        let claude = style.provider == .claude
        let bullet = line.failed ? TracePalette.red : event.output == nil || line.running ? TracePalette.dim : TracePalette.green
        let header = NSMutableAttributedString()
        append((claude ? "⏺" : "•") + "\t", color: bullet, to: header)
        append(line.name, color: TracePalette.strong, font: TracePalette.boldFont, to: header)
        if !line.subject.isEmpty {
            if claude {
                append("(", color: TracePalette.dim, to: header)
                append(line.subject, color: TracePalette.text, to: header)
                append(")", color: TracePalette.dim, to: header)
            } else {
                append(" " + line.subject, color: TracePalette.text, to: header)
            }
        }
        paragraph(header, first: 0, head: gutter, tabs: [gutter], after: line.output.isEmpty ? Self.eventGap : 1, into: output)

        guard !line.output.isEmpty else { return }
        let indent = gutter + TracePalette.column * 3
        let body = NSMutableAttributedString()
        append((claude ? "⎿" : "└") + "\t", color: TracePalette.faint, to: body)
        append(line.output.joined(separator: "\n"), color: line.failed ? TracePalette.red : TracePalette.dim, to: body)
        if line.hiddenLines > 0 {
            append("\n… +\(line.hiddenLines) \(line.hiddenLines == 1 ? "line" : "lines")", color: TracePalette.faint, to: body)
        }
        paragraph(body, first: gutter, head: indent, tabs: [indent], after: Self.eventGap, into: output)
    }

    private func turn(_ label: String, into output: NSMutableAttributedString) {
        let failed = label.hasSuffix("failed")
        let stopped = label.hasSuffix("stopped")
        let color = failed ? TracePalette.red : stopped ? TracePalette.orange : TracePalette.faint
        let content = NSMutableAttributedString()
        append((failed ? "✕" : stopped ? "■" : "─") + "\t" + label, color: color, to: content)
        paragraph(content, first: 0, head: gutter, tabs: [gutter], after: Self.eventGap, into: output)
    }

    // MARK: Markdown

    private func write(_ block: MarkdownBlock, lead: String?, after: CGFloat, into output: NSMutableAttributedString) {
        let column = TracePalette.column
        let content = NSMutableAttributedString()
        if let lead { append(lead + "\t", color: TracePalette.strong, to: content) }
        switch block {
        case let .paragraph(text):
            inline(text, color: TracePalette.text, font: TracePalette.font, to: content)
            paragraph(content, first: lead == nil ? gutter : 0, head: gutter, tabs: [gutter], after: after, into: output)
        case let .heading(text):
            inline(text, color: TracePalette.strong, font: TracePalette.boldFont, to: content)
            paragraph(content, first: lead == nil ? gutter : 0, head: gutter, tabs: [gutter], after: after, into: output)
        case let .item(level, marker, text):
            let indent = gutter + CGFloat(level) * column * 2
            let symbol = marker == "•" ? ["•", "◦", "▪", "▫"][min(level, 3)] : marker
            let textIndent = indent + CGFloat(symbol.count + 1) * column
            append(symbol + "\t", color: TracePalette.dim, to: content)
            inline(text, color: TracePalette.text, font: TracePalette.font, to: content)
            paragraph(content, first: lead == nil ? indent : 0, head: textIndent,
                      tabs: lead == nil ? [textIndent] : [indent, textIndent], after: after, into: output)
        case let .quote(text):
            let textIndent = gutter + column * 2
            append("│\t", color: TracePalette.faint, to: content)
            inline(text, color: TracePalette.dim, font: TracePalette.italicFont, to: content)
            paragraph(content, first: lead == nil ? gutter : 0, head: textIndent,
                      tabs: lead == nil ? [textIndent] : [gutter, textIndent], after: after, into: output)
        case let .code(text):
            let indent = gutter + column * 2
            append(TranscriptText.plain(text), color: TracePalette.code, to: content)
            paragraph(content, first: lead == nil ? indent : 0, head: indent, tabs: [indent], after: after, into: output)
        case let .table(rows):
            // Monospace makes alignment free: pad each column to its widest cell, as the command-line agents do.
            let widths = (0..<(rows.map(\.count).max() ?? 0)).map { column in
                rows.map { $0.indices.contains(column) ? Self.plainWidth($0[column]) : 0 }.max() ?? 0
            }
            for (index, row) in rows.enumerated() {
                let header = index == 0
                for (column, width) in widths.enumerated() {
                    if column > 0 { append(" │ ", color: TracePalette.faint, to: content) }
                    let text = row.indices.contains(column) ? row[column] : ""
                    inline(text, color: header ? TracePalette.strong : TracePalette.text,
                           font: header ? TracePalette.boldFont : TracePalette.font, to: content)
                    if column < widths.count - 1 {
                        append(String(repeating: " ", count: max(0, width - Self.plainWidth(text))), color: TracePalette.text, to: content)
                    }
                }
                if header, rows.count > 1 {
                    append("\n" + widths.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─"),
                           color: TracePalette.faint, to: content)
                }
                if index < rows.count - 1 { append("\n", color: TracePalette.text, to: content) }
            }
            paragraph(content, first: lead == nil ? gutter : 0, head: gutter, tabs: [gutter], after: after, into: output)
        case .rule:
            append(String(repeating: "─", count: 12), color: TracePalette.faint, to: content)
            paragraph(content, first: lead == nil ? gutter : 0, head: gutter, tabs: [gutter], after: after, into: output)
        }
    }

    /// The characters a table cell shows once its Markdown is drawn.
    private static func plainWidth(_ text: String) -> Int {
        InlineMarkdown.runs(text).reduce(0) { $0 + $1.text.count }
    }

    /// Appends text with its inline Markdown drawn, up to `limit` visible characters. True when it stopped short.
    @discardableResult
    private func inline(_ text: String, color: NSColor, font: NSFont, to content: NSMutableAttributedString,
                        limit: Int = .max) -> Bool {
        let boldBase = font == TracePalette.boldFont
        var budget = limit
        for var run in InlineMarkdown.runs(text) {
            guard budget > 0 else { return true }
            let clipped = run.text.count > budget
            if clipped { run.text = String(run.text.prefix(budget)) }
            budget -= run.text.count
            let bold = boldBase || run.style.contains(.bold)
            let italic = font == TracePalette.italicFont || run.style.contains(.italic)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: bold ? (italic ? TracePalette.boldItalicFont : TracePalette.boldFont)
                    : (italic ? TracePalette.italicFont : TracePalette.font),
                .foregroundColor: run.style.contains(.code) ? TracePalette.code
                    : run.style.contains(.bold) && color == TracePalette.text ? TracePalette.strong : color
            ]
            if run.style.contains(.strike) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let destination = run.destination, let url = TranscriptLinks.url(destination, cwd: style.cwd) {
                attributes[.link] = url
                attributes[.toolTip] = url.isFileURL ? (url.path as NSString).abbreviatingWithTildeInPath : url.absoluteString
            }
            content.append(NSAttributedString(string: run.text.replacingOccurrences(of: "\t", with: "    "), attributes: attributes))
            if clipped { return true }
        }
        return false
    }

    private func append(_ string: String, color: NSColor, font: NSFont = TracePalette.font, to content: NSMutableAttributedString) {
        content.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
    }

    /// Ends a block. Its first line holds the lead symbol, its other lines hang at `head`, and only its last line
    /// carries the space before the next block.
    private func paragraph(_ content: NSMutableAttributedString, first: CGFloat, head: CGFloat, tabs: [CGFloat],
                           after: CGFloat, into output: NSMutableAttributedString) {
        content.append(NSAttributedString(string: "\n", attributes: [.font: TracePalette.font]))
        let string = content.string as NSString
        var location = 0
        var line = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let spacing = NSMaxRange(range) >= string.length ? after : 0
            let style = line == 0
                ? TraceParagraph.style(first: first, head: head, after: spacing, tabs: tabs)
                : TraceParagraph.style(first: head, head: head, after: spacing)
            content.addAttribute(.paragraphStyle, value: style, range: range)
            location = NSMaxRange(range)
            line += 1
        }
        output.append(content)
    }
}

enum TranscriptText {
    /// Codex appends memory citations for its own records and its interface hides them.
    static func withoutCitations(_ text: String) -> String {
        guard text.contains("<oai-mem-citation>") else { return text }
        var result = ""
        var rest = text[...]
        while let open = rest.range(of: "<oai-mem-citation>") {
            result += rest[..<open.lowerBound]
            if let close = rest.range(of: "</oai-mem-citation>", range: open.upperBound..<rest.endIndex) {
                rest = rest[close.upperBound...]
            } else {
                rest = rest[rest.endIndex...]
            }
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Command output as a terminal leaves it: no escape sequences, the last write of each carriage-returned line,
    /// and spaces for tabs.
    static func plain(_ text: String) -> String {
        var text = text
        if text.contains("\u{1B}") {
            text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        if text.contains("\r") {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
                .joined(separator: "\n")
        }
        return text.replacingOccurrences(of: "\t", with: "    ")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func firstLine(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        return lines.count > 1 ? first + " …" : first
    }
}

/// One tool call as the agent's interface summarises it.
struct ToolLine: Equatable {
    var name: String
    var subject: String
    var isCommand = false
    var output: [String] = []
    var hiddenLines = 0
    var failed = false
    /// A Codex script still running in a background cell.
    var running = false

    /// The short form for a status line, such as "$ swift build" or "Read TraceViews.swift".
    var phrase: String {
        if isCommand { return "$ " + subject }
        return subject.isEmpty ? name : name + " " + subject
    }
}

enum ToolLines {
    private static let shownLines = 3

    static func describe(_ event: TraceEvent, provider: AgentProvider, cwd: String, output: Bool = true) -> ToolLine {
        var line = provider == .claude ? claude(event, cwd: cwd, output: output) : codex(event, cwd: cwd, output: output)
        line.subject = TranscriptText.clip(line.subject.replacingOccurrences(of: "\n", with: " "), 240)
        if event.toolFailed == true { line.failed = true }
        return line
    }

    /// What the agent last ran, for its status line.
    static func phrase(_ event: TraceEvent, provider: AgentProvider, cwd: String) -> String {
        describe(event, provider: provider, cwd: cwd, output: false).phrase
    }

    private static func claude(_ event: TraceEvent, cwd: String, output includesOutput: Bool) -> ToolLine {
        let input = event.text ?? ""
        let fields = json(input)
        func value(_ key: String) -> String? { (fields[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var line: ToolLine
        switch event.label {
        case "Bash": line = ToolLine(name: "Bash", subject: TranscriptText.firstLine(input), isCommand: true)
        case "Read": line = ToolLine(name: "Read", subject: display(value("file_path"), cwd: cwd))
        case "Write": line = ToolLine(name: "Write", subject: display(value("file_path"), cwd: cwd))
        case "Edit", "MultiEdit": line = ToolLine(name: "Update", subject: display(value("file_path"), cwd: cwd))
        case "NotebookEdit": line = ToolLine(name: "Update", subject: display(value("notebook_path"), cwd: cwd))
        case "Grep", "Glob": line = ToolLine(name: "Search", subject: value("pattern").map { "pattern: \"\($0)\"" } ?? "")
        case "WebSearch": line = ToolLine(name: "Web Search", subject: value("query").map { "\"\($0)\"" } ?? "")
        case "WebFetch": line = ToolLine(name: "Fetch", subject: value("url") ?? "")
        case "Agent", "Task": line = ToolLine(name: "Agent", subject: value("description") ?? "")
        case "TodoWrite": line = ToolLine(name: "Update Todos", subject: "")
        default:
            let parts = event.label.components(separatedBy: "__")
            let name = parts.count >= 3 && parts[0] == "mcp"
                ? "\(parts[1]) - \(parts[2...].joined(separator: "__")) (MCP)" : event.label
            line = ToolLine(name: name, subject: summary(of: fields) ?? (fields.isEmpty ? TranscriptText.firstLine(input) : ""))
        }
        guard includesOutput else { return line }
        let output = event.output ?? ""
        if event.label == "Read", event.toolFailed != true, !output.isEmpty {
            let count = output.split(separator: "\n", omittingEmptySubsequences: false).count
            line.output = ["Read \(count)\(output.hasSuffix("\n…") ? "+" : "") lines"]
        } else {
            (line.output, line.hiddenLines) = excerpt(output)
        }
        return line
    }

    private static func codex(_ event: TraceEvent, cwd: String, output includesOutput: Bool) -> ToolLine {
        let input = event.text ?? ""
        var line: ToolLine
        switch event.label {
        case "exec": line = script(input, cwd: cwd)
        case "exec_command", "shell", "shell_command", "local_shell", "container.exec":
            line = ToolLine(name: "Ran", subject: command(arguments: input) ?? TranscriptText.firstLine(input), isCommand: true)
        case "apply_patch": line = patch(input, cwd: cwd) ?? ToolLine(name: "Edited", subject: "files")
        case "wait": line = ToolLine(name: "Waited", subject: "")
        case "clock.sleep":
            let milliseconds = (json(input)["duration_ms"] as? NSNumber)?.doubleValue
            line = ToolLine(name: "Waited", subject: milliseconds.map { StatusText.elapsed($0 / 1000) } ?? "")
        case "update_plan": line = ToolLine(name: "Updated Plan", subject: "")
        case "view_image": line = ToolLine(name: "Viewed Image", subject: display(json(input)["path"] as? String, cwd: cwd))
        default: line = ToolLine(name: "Called", subject: event.label)
        }
        guard includesOutput else { return line }
        let result = codexOutput(event.output)
        (line.output, line.hiddenLines) = excerpt(result.text)
        line.failed = result.failed
        line.running = result.running
        if result.running, line.output.isEmpty { line.output = ["Running in the background"] }
        return line
    }

    /// Codex's code mode runs a script that calls its tools, such as `tools.exec_command({cmd: "…"})`.
    private static func script(_ script: String, cwd: String) -> ToolLine {
        if let edit = patch(script, cwd: cwd) { return edit }
        let commands = literals(after: "cmd", in: script)
        if let first = commands.first {
            let more = commands.count > 1 ? "  (+\(commands.count - 1) more)" : ""
            return ToolLine(name: "Ran", subject: TranscriptText.firstLine(first) + more, isCommand: true)
        }
        if script.contains("web__run") || script.contains("web.run") { return ToolLine(name: "Searched", subject: "the web") }
        var tools: [String] = []
        var rest = script[...]
        while let range = rest.range(of: "tools.") {
            let name = rest[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty, !tools.contains(String(name)) { tools.append(String(name)) }
            rest = rest[range.upperBound...]
        }
        return tools.isEmpty ? ToolLine(name: "Ran Script", subject: "") : ToolLine(name: "Called", subject: tools.joined(separator: ", "))
    }

    private static func patch(_ text: String, cwd: String) -> ToolLine? {
        guard text.contains("*** Update File: ") || text.contains("*** Add File: ") || text.contains("*** Delete File: ") else { return nil }
        // A patch passed as a JSON string keeps its line breaks escaped.
        let body = text.contains("\n*** ") ? text : text.replacingOccurrences(of: "\\n", with: "\n")
        var files: [String] = []
        var added = 0
        var removed = 0
        for line in body.split(separator: "\n") {
            if let prefix = ["*** Update File: ", "*** Add File: ", "*** Delete File: "].first(where: { line.hasPrefix($0) }) {
                let file = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !files.contains(file) { files.append(file) }
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }
        guard let first = files.first else { return nil }
        var subject = display(first, cwd: cwd)
        if files.count > 1 {
            subject += " and \(files.count - 1) more"
        } else if !text.hasSuffix("\n…") {
            subject += " (+\(added) -\(removed))"
        }
        return ToolLine(name: "Edited", subject: subject)
    }

    private static func command(arguments: String) -> String? {
        let fields = json(arguments)
        if let command = fields["cmd"] as? String { return TranscriptText.firstLine(command) }
        if let command = fields["command"] as? String { return TranscriptText.firstLine(command) }
        guard let parts = fields["command"] as? [String], !parts.isEmpty else { return nil }
        if parts.count >= 3, ["bash", "zsh", "sh"].contains((parts[0] as NSString).lastPathComponent), parts[1].hasPrefix("-") {
            return TranscriptText.firstLine(parts[2])
        }
        return parts.joined(separator: " ")
    }

    /// The string values a script assigns to `key`, such as each `cmd: "…"` in a code-mode call.
    static func literals(after key: String, in script: String) -> [String] {
        let s = Array(script.unicodeScalars)
        let name = Array(key.unicodeScalars)
        var values: [String] = []
        var i = 0
        while i + name.count < s.count, values.count < 24 {
            guard s[i] == name[0], Array(s[i..<(i + name.count)]) == name,
                  i == 0 || !(s[i - 1].properties.isAlphabetic || s[i - 1] == "_") else { i += 1; continue }
            var j = i + name.count
            if j < s.count, s[j] == "\"" || s[j] == "'" { j += 1 }
            while j < s.count, s[j] == " " { j += 1 }
            guard j < s.count, s[j] == ":" else { i += 1; continue }
            j += 1
            while j < s.count, s[j] == " " || s[j] == "\n" { j += 1 }
            guard j < s.count, s[j] == "\"" || s[j] == "'" || s[j] == "`" else { i = j; continue }
            let quote = s[j]
            var value = String.UnicodeScalarView()
            var closed = false
            j += 1
            while j < s.count {
                let c = s[j]
                if c == "\\", j + 1 < s.count {
                    let escaped = s[j + 1]
                    switch escaped {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "r": break
                    case "u":
                        if j + 5 < s.count, let code = UInt32(String(String.UnicodeScalarView(s[(j + 2)...(j + 5)])), radix: 16),
                           let scalar = Unicode.Scalar(code) {
                            value.append(scalar)
                            j += 4
                        }
                    default: value.append(escaped)
                    }
                    j += 2
                    continue
                }
                j += 1
                if c == quote {
                    closed = true
                    break
                }
                value.append(c)
            }
            if closed { values.append(String(value)) }
            i = j
        }
        return values
    }

    /// Codex's code-mode results start with "Script completed" and list each command's JSON result.
    static func codexOutput(_ raw: String?) -> (text: String, failed: Bool, running: Bool) {
        guard let raw, !raw.isEmpty else { return ("", false, false) }
        guard raw.hasPrefix("Script ") else {
            if let marker = raw.range(of: "\nOutput:\n"), raw.distance(from: raw.startIndex, to: marker.lowerBound) < 400 {
                let header = raw[..<marker.lowerBound]
                let code = header.range(of: "exited with code ").flatMap { Int(header[$0.upperBound...].prefix { $0.isNumber }) }
                return (String(raw[marker.upperBound...]), (code ?? 0) != 0, false)
            }
            return (raw, false, false)
        }
        let running = raw.hasPrefix("Script running")
        var failed = raw.hasPrefix("Script failed")
        guard let marker = raw.range(of: "\nOutput:\n") else { return ("", failed, running) }
        var lines: [String] = []
        for row in raw[marker.upperBound...].split(separator: "\n") {
            guard row.hasPrefix("{") else {
                lines.append(String(row))
                continue
            }
            if let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any] {
                if let code = object["exit_code"] as? Int, code != 0 { failed = true }
                if let output = object["output"] as? String, !output.isEmpty { lines.append(output) }
            } else if let start = row.range(of: "\"output\":\"") {
                // The log keeps a bounded excerpt, which can cut the last result short.
                lines.append(row[start.upperBound...].replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        return (lines.joined(separator: "\n"), failed, running)
    }

    private static func excerpt(_ text: String) -> ([String], Int) {
        guard !text.isEmpty else { return ([], 0) }
        var lines: [Substring] = []
        for row in TranscriptText.plain(text).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = row
            while line.last == " " { line = line.dropLast() }
            guard line != "<persisted-output>", line != "</persisted-output>", !line.hasPrefix("Wall time") else { continue }
            lines.append(line)
        }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }),
              let last = lines.lastIndex(where: { !$0.isEmpty }) else { return ([], 0) }
        let body = lines[first...last]
        let shown = body.prefix(shownLines).map { TranscriptText.clip(String($0), 220) }
        return (shown, body.count - shown.count)
    }

    private static func summary(of fields: [String: Any]) -> String? {
        let preferred = ["command", "query", "url", "file_path", "path", "description", "prompt", "pattern", "action", "name"]
        for key in preferred + fields.keys.sorted() {
            if let value = fields[key] as? String, !value.isEmpty { return TranscriptText.firstLine(value) }
        }
        return nil
    }

    private static func display(_ path: String?, cwd: String) -> String {
        guard let path, !path.isEmpty else { return "" }
        if !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private static func json(_ text: String) -> [String: Any] {
        guard text.hasPrefix("{") else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}

enum TranscriptLinks {
    /// Agents link web pages, absolute paths, and paths relative to the session folder, sometimes with a line number.
    static func url(_ destination: String, cwd: String) -> URL? {
        let destination = destination.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return nil }
        let lower = destination.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            return URL(string: destination)
                ?? destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        }
        if lower.hasPrefix("file://") { return URL(string: destination) }
        // Other schemes could start an app; agents have no reason to link them here.
        if destination.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return nil }
        var path = destination.removingPercentEncoding ?? destination
        if let anchor = path.firstIndex(of: "#") { path = String(path[..<anchor]) }
        if let line = path.range(of: ":[0-9]+(:[0-9]+)?$", options: .regularExpression) { path.removeSubrange(line) }
        path = (path as NSString).expandingTildeInPath
        guard !path.isEmpty else { return nil }
        if !path.hasPrefix("/") {
            guard !cwd.isEmpty else { return nil }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path)
    }

    /// Opens documents and images in their app. Other files and folders are revealed in Finder, never run.
    @MainActor
    static func open(_ url: URL) {
        if url.isFileURL {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                NSSound.beep()
                return
            }
            let viewable: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "pdf", "md", "markdown",
                                         "txt", "log", "json", "csv", "tsv", "mov", "mp4", "m4a", "wav"]
            if !isFolder.boolValue, viewable.contains(url.pathExtension.lowercased()) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}
