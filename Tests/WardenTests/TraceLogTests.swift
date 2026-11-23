import XCTest
@testable import Warden

final class TraceLogTests: XCTestCase {
    private let timestamp = "2026-11-23T09:35:46.123Z"

    func testHeadlessCodexTraceUpdatesAnExistingToolWhenItsResultArrives() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = TraceFile(url: url, provider: .codex)
        let reader = TraceReader()
        let first = """
        \(line("event_msg", #""payload":{"type":"task_started"}"#))
        \(line("response_item", #""payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>local</environment_context>"},{"type":"input_text","text":"Check the entrance layout"}]}"#))
        \(line("response_item", #""payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"provider instructions"}]}"#))
        \(line("response_item", #""payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"private reasoning"}]}"#))
        \(line("response_item", #""payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"I’ll inspect the entrances."}]}"#))
        \(line("response_item", #""payload":{"type":"custom_tool_call","name":"exec","input":"read entrance.json","call_id":"call_1"}"#))
        \(line("event_msg", #""payload":{"type":"item_completed","item":{"type":"CommandExecution","command":"read entrance.json"}}"#))
        """ + "\n"
        try Data(first.utf8).write(to: url)
        let began = await reader.read([log])[log] ?? []
        XCTAssertEqual(began.map(\.label), ["Turn started", "Prompt", "Reply", "exec"])
        XCTAssertEqual(began.first { $0.kind == .prompt }?.text, "Check the entrance layout")
        XCTAssertEqual(began.first { $0.kind == .message }?.text, "I’ll inspect the entrances.")
        XCTAssertNil(began.last?.output)

        let result = line("response_item", #""payload":{"type":"custom_tool_call_output","call_id":"call_1","output":[{"type":"input_text","text":"Two entrances"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}"#)
        try append(String(result.dropLast(6)), to: url)
        let partial = await reader.read([log])[log]
        XCTAssertEqual(partial, began)

        try append(String(result.suffix(6)) + "\n" + line("event_msg", #""payload":{"type":"task_complete"}"#) + "\n", to: url)
        let ended = await reader.read([log])[log] ?? []
        XCTAssertEqual(ended.map(\.label), began.map(\.label) + ["Turn finished"])
        XCTAssertEqual(ended.dropLast().map(\.id), began.map(\.id))
        XCTAssertEqual(ended.first { $0.kind == .tool }?.output, "Two entrances")

        let calls = (0..<120).map { call in
            line("response_item", """
            "payload":{"type":"custom_tool_call","name":"exec","input":"check door \(call)","call_id":"check_\(call)"}
            """)
        }
        try append(calls.joined(separator: "\n") + "\n", to: url)
        let busy = await reader.read([log])[log] ?? []
        XCTAssertEqual(busy.filter { $0.kind == .tool }.count, 100)
        XCTAssertEqual(busy.first { $0.kind == .message }?.text, "I’ll inspect the entrances.")
    }

    func testClaudeChildTraceReadsRecentEventsAfterAnOversizedLine() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = TraceFile(url: url, provider: .claude)
        let reader = TraceReader()
        let older = line("user", #""sessionId":"parent","isSidechain":true,"message":{"content":"Older prompt"}"#)
        let large = line("attachment", #""attachment":""# + String(repeating: "x", count: 4_300_000) + #"""#)
        let assistant = line("assistant", #""sessionId":"parent","agentId":"child","isSidechain":true,"message":{"content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"Checking the doors."},{"type":"tool_use","id":"tool_1","name":"Bash","input":{"command":"check-doors"}}]}"#)
        let tool = line("user", #""sessionId":"parent","agentId":"child","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"tool_1","is_error":true,"content":"Door test failed"}]}"#)
        try Data(([older, large, assistant, tool].joined(separator: "\n") + "\n").utf8).write(to: url)

        let events = await reader.read([log])[log] ?? []
        XCTAssertEqual(events.map(\.label), ["Reply", "Bash"])
        XCTAssertEqual(events.first?.text, "Checking the doors.")
        XCTAssertEqual(events.last?.text, "check-doors")
        XCTAssertEqual(events.last?.output, "Door test failed")
        XCTAssertEqual(events.last?.toolFailed, true)
        let unchanged = await reader.read([log])[log]
        XCTAssertEqual(unchanged, events)
    }

    private func line(_ type: String, _ fields: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"\(type)",\(fields)}
        """
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
