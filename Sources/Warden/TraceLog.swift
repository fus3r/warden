import Foundation
import WardenCore

/// The scanner identifies the exact file for a conversation. These paths stay in the Mac app.
struct TraceSource: Identifiable, Equatable {
    struct ID: Hashable {
        let provider: AgentProvider
        let account: String?
        let sessionID: String

        init(provider: AgentProvider, account: String?, sessionID: String) {
            self.provider = provider
            self.account = account
            self.sessionID = sessionID
        }

        init(_ session: AgentSession) {
            self.init(provider: session.provider, account: session.account, sessionID: session.id)
        }
    }

    var session: AgentSession
    let file: URL?

    var id: ID { ID(session) }
    var parentID: ID? {
        session.parentID.map { ID(provider: session.provider, account: session.account, sessionID: $0) }
    }
    var name: String { session.title ?? session.project }
    var log: TraceFile? { file.map { TraceFile(url: $0, provider: session.provider) } }
}

struct TraceFile: Hashable, Sendable {
    let url: URL
    let provider: AgentProvider
}

struct TraceEvent: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Comparable, Sendable {
        let offset: UInt64
        let part: Int

        static func < (left: Self, right: Self) -> Bool {
            (left.offset, left.part) < (right.offset, right.part)
        }
    }

    enum Kind: Equatable, Sendable { case prompt, message, tool, turn }

    let id: ID
    let kind: Kind
    let label: String
    var text: String?
    var callID: String?
    var output: String?
    var toolFailed: Bool?
}

/// Tails only the logs shown in an open viewer. Large outputs can span many megabytes.
actor TraceReader {
    private static let initialByteLimit: UInt64 = 4_194_304
    private static let byteLimit: UInt64 = 1_048_576
    private static let messageLimit = 40
    private static let toolLimit = 100

    private struct Cursor {
        let fileNumber: UInt64
        var modified = Date.distantPast
        var size: UInt64 = 0
        var nextLine: UInt64 = 0
        var events: [TraceEvent] = []
    }

    private enum Item {
        case event(TraceEvent.Kind, label: String, text: String? = nil, callID: String? = nil)
        case result(callID: String, text: String?, failed: Bool)
    }

    private var cursors: [TraceFile: Cursor] = [:]

    func read(_ files: [TraceFile]) -> [TraceFile: [TraceEvent]] {
        let shown = Set(files)
        cursors = cursors.filter { shown.contains($0.key) }
        var snapshot: [TraceFile: [TraceEvent]] = [:]
        for file in files {
            guard !Task.isCancelled else { break }
            snapshot[file] = update(file)
        }
        return snapshot
    }

    private func update(_ file: TraceFile) -> [TraceEvent]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date else {
            cursors[file] = nil
            return nil
        }
        var cursor = cursors[file] ?? Cursor(fileNumber: fileNumber)
        if cursor.fileNumber != fileNumber || cursor.size > size {
            cursor = Cursor(fileNumber: fileNumber)
        }
        if cursor.modified == modified, cursor.size == size { return cursor.events }

        let limit = cursor.modified == .distantPast ? Self.initialByteLimit : Self.byteLimit
        let tail = size > limit ? size - limit : 0
        let start = max(tail, cursor.nextLine)
        // One preceding byte tells us whether the bounded tail begins on a line boundary.
        let offset = start > cursor.nextLine ? start - 1 : start
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
            if let firstBreak = data.firstIndex(of: 10), let end = data.lastIndex(of: 10) {
                let first = offset == start ? data.startIndex : firstBreak + 1
                if first <= end {
                    for line in data[first..<end].split(separator: 10) {
                        append(Data(line), provider: file.provider, offset: offset + UInt64(line.startIndex),
                               events: &cursor.events)
                    }
                }
                cursor.nextLine = offset + UInt64(end) + 1
            }
        } catch {
            return nil
        }
        cursor.size = size
        cursor.modified = modified
        // A long run of tool calls must not evict the agent's last written updates.
        let messages = cursor.events.filter { $0.kind == .message }.suffix(Self.messageLimit)
        let tools = cursor.events.filter { $0.kind == .tool }.suffix(Self.toolLimit)
        let other = cursor.events.filter { $0.kind == .prompt || $0.kind == .turn }.suffix(Self.messageLimit)
        cursor.events = (Array(messages) + tools + other).sorted { $0.id < $1.id }
        cursors[file] = cursor
        return cursor.events
    }

    private func append(_ line: Data, provider: AgentProvider, offset: UInt64, events: inout [TraceEvent]) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let items = provider == .codex ? Self.codex(object) : Self.claude(object)
        for (part, item) in items.enumerated() {
            switch item {
            case let .event(kind, label, text, callID):
                events.append(TraceEvent(id: .init(offset: offset, part: part), kind: kind,
                                         label: label, text: text, callID: callID))
            case let .result(callID, text, failed):
                guard let index = events.lastIndex(where: { $0.callID == callID }) else { continue }
                events[index].output = text
                events[index].toolFailed = failed
            }
        }
    }

    private static func codex(_ object: [String: Any]) -> [Item] {
        guard let payload = object["payload"] as? [String: Any] else { return [] }
        if object["type"] as? String == "event_msg" {
            switch payload["type"] as? String {
            case "task_started": return [.event(.turn, label: "Turn started")]
            case "task_complete": return [.event(.turn, label: payload["error"] == nil ? "Turn finished" : "Turn failed")]
            case "turn_aborted": return [.event(.turn, label: "Turn stopped")]
            default: return []
            }
        }
        // response_item is the message/tool record. item_completed mirrors many of these.
        guard object["type"] as? String == "response_item" else { return [] }
        switch payload["type"] as? String {
        case "message":
            guard let role = payload["role"] as? String, role == "assistant" || role == "user",
                  payload["phase"] as? String != "analysis" else { return [] }
            let blocks = payload["content"] as? [[String: Any]] ?? []
            let blockType = role == "assistant" ? "output_text" : "input_text"
            let texts = blocks.filter { $0["type"] as? String == blockType }.compactMap { $0["text"] as? String }
                .filter { role == "assistant" || isPromptText($0) }
            guard let text = excerpt(texts.joined(separator: "\n"), limit: 16_000) else { return [] }
            return [.event(role == "assistant" ? .message : .prompt, label: role == "assistant" ? "Reply" : "Prompt", text: text)]
        case "function_call", "custom_tool_call":
            guard let name = payload["name"] as? String else { return [] }
            let qualified = (payload["namespace"] as? String).map { "\($0).\(name)" } ?? name
            let input = payload["arguments"] as? String ?? payload["input"] as? String
            return [.event(.tool, label: qualified, text: excerpt(input), callID: payload["call_id"] as? String)]
        case "function_call_output", "custom_tool_call_output":
            guard let id = payload["call_id"] as? String else { return [] }
            return [.result(callID: id, text: outputText(payload["output"]), failed: false)]
        default: return []
        }
    }

    private static func claude(_ object: [String: Any]) -> [Item] {
        guard let role = object["type"] as? String, role == "assistant" || role == "user",
              let message = object["message"] as? [String: Any] else { return [] }
        if object["isApiErrorMessage"] as? Bool == true { return [.event(.turn, label: "Request failed")] }
        if message["model"] as? String == "<synthetic>" || object["isMeta"] as? Bool == true { return [] }
        let blocks = message["content"] as? [[String: Any]]
            ?? (message["content"] as? String).map { [["type": "text", "text": $0]] } ?? []
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let raw = block["text"] as? String, role == "assistant" || isPromptText(raw),
                      let text = excerpt(raw, limit: 16_000) else { return nil }
                return .event(role == "assistant" ? .message : .prompt, label: role == "assistant" ? "Reply" : "Prompt", text: text)
            case "tool_use":
                guard let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any]
                let details = input?["command"] as? String ?? input.flatMap {
                    (try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                }
                return .event(.tool, label: name, text: excerpt(details), callID: block["id"] as? String)
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { return nil }
                return .result(callID: id, text: outputText(block["content"]), failed: block["is_error"] as? Bool == true)
            default: return nil
            }
        }
    }

    private static func isPromptText(_ text: String) -> Bool {
        // Codex has written its instructions header both with and without the folder after it.
        !["# AGENTS.md instructions", "<environment_context>", "<command-name>", "<command-message>", "<local-command-",
          "<task-notification>", "<system-reminder>", "<hook_prompt"]
            .contains { text.hasPrefix($0) }
    }

    private static func outputText(_ value: Any?) -> String? {
        let blocks = value as? [[String: Any]] ?? []
        let texts = blocks.filter { ["text", "input_text", "output_text"].contains($0["type"] as? String ?? "") }
            .compactMap { $0["text"] as? String }
        return excerpt(value as? String ?? texts.joined(separator: "\n"))
    }

    private static func excerpt(_ value: String?, limit: Int = 6_000) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let clipped = value.prefix(limit)
        return clipped.endIndex == value.endIndex ? value : String(clipped) + "\n…"
    }
}
