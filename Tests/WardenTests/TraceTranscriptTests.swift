import XCTest
@testable import Warden

final class TraceTranscriptTests: XCTestCase {
    @MainActor
    func testCodexReplyLosesItsMarkupAndCitations() {
        let reply = """
        I’ll merge `main` and rerun the **parser** audit. [Screenshots](</Users/me/Documents/My App/qa/shots/review.jpg>)

        - Typecheck passed
        - p95 was **16.7 ms**

        | Check | State |
        | --- | --- |
        | Build | `ok` |

        <oai-mem-citation>
        <citation_entries>
        MEMORY.md:1947-1948|note=[Warden build and installation workflow]
        </citation_entries>
        </oai-mem-citation>
        """
        let blocks = MarkdownBlocks.parse(TranscriptText.withoutCitations(reply))
        XCTAssertEqual(blocks, [
            .paragraph("I’ll merge `main` and rerun the **parser** audit. [Screenshots](</Users/me/Documents/My App/qa/shots/review.jpg>)"),
            .item(level: 0, marker: "•", text: "Typecheck passed"),
            .item(level: 0, marker: "•", text: "p95 was **16.7 ms**"),
            .table([["Check", "State"], ["Build", "`ok`"]])
        ])

        guard case let .paragraph(text) = blocks[0] else { return XCTFail("Expected a paragraph") }
        let runs = InlineMarkdown.runs(text)
        XCTAssertEqual(runs.map(\.text), ["I’ll merge ", "main", " and rerun the ", "parser", " audit. ", "Screenshots"])
        XCTAssertEqual(runs[1].style, .code)
        XCTAssertEqual(runs[3].style, .bold)
        let link = runs[5].destination.flatMap { TranscriptLinks.url($0, cwd: "/repo") }
        XCTAssertEqual(link, URL(fileURLWithPath: "/Users/me/Documents/My App/qa/shots/review.jpg"))

        XCTAssertFalse(InlineMarkdown.runs("Read snake_case_name, then 2 * 3 * 4.").contains { $0.style.contains(.italic) })
        let spec = InlineMarkdown.runs("Implement **`docs/design/act1-night.md`** (owner decision), then `capture`.")
        XCTAssertEqual(spec.map(\.text), ["Implement ", "docs/design/act1-night.md", " (owner decision), then ", "capture", "."])
        XCTAssertEqual(spec[1].style, [.bold, .code])

        let renderer = TranscriptRenderer(style: .init(provider: .codex, showsCommands: false, cwd: "/repo"))
        let orders = TraceEvent(id: .init(offset: 9, part: 0), kind: .prompt, label: "Prompt",
                                text: "Merged. " + String(repeating: "Keep the build green. ", count: 15) + "Then **read the night spec** in `docs/spec.md`.")
        let drawn = renderer.rendered(orders).string
        XCTAssertTrue(drawn.hasSuffix("…\n"))
        XCTAssertFalse(drawn.contains("**") || drawn.contains("`"))
        XCTAssertEqual(TranscriptLinks.url("Sources/Warden/TraceViews.swift:42", cwd: "/repo"),
                       URL(fileURLWithPath: "/repo/Sources/Warden/TraceViews.swift"))
        XCTAssertNil(TranscriptLinks.url("javascript:alert(1)", cwd: "/repo"))
    }

    func testCodexCodeModeCallsReadAsCommandsAndEdits() {
        let script = #"const r=await Promise.allSettled([ tools.exec_command({cmd:"rg -n 'TODO' Sources/App/Parser.swift","max_output_tokens":2000,"login":false}), tools.exec_command({cmd:"git status --short"}) ]);text(r)"#
        var run = TraceEvent(id: .init(offset: 1, part: 0), kind: .tool, label: "exec", text: script, callID: "call_1")
        run.output = """
        Script completed
        Wall time 1.7 seconds
        Output:

        {"chunk_id":"1b6ddc","wall_time_seconds":1.0,"exit_code":2,"original_token_count":9,"output":"rg: Sources/App/Parser.swift: No such file or directory\\n"}
        """
        let ran = ToolLines.describe(run, provider: .codex, cwd: "/repo")
        XCTAssertEqual(ran.phrase, "$ rg -n 'TODO' Sources/App/Parser.swift  (+1 more)")
        XCTAssertTrue(ran.failed)
        XCTAssertEqual(ran.output, ["rg: Sources/App/Parser.swift: No such file or directory"])

        let patch = """
        const p=await tools.apply_patch(`*** Begin Patch
        *** Update File: /repo/Sources/Warden/TraceViews.swift
        @@
        -        VStack(spacing: 0) {
        +        content(agents, focused: focused)
        +            .frame(maxWidth: .infinity, maxHeight: .infinity)
        *** End Patch`);text(p)
        """
        let edit = TraceEvent(id: .init(offset: 2, part: 0), kind: .tool, label: "exec", text: patch, callID: "call_2")
        XCTAssertEqual(ToolLines.describe(edit, provider: .codex, cwd: "/repo").phrase, "Edited Sources/Warden/TraceViews.swift (+2 -1)")

        let read = TraceEvent(id: .init(offset: 3, part: 0), kind: .tool, label: "Read",
                              text: "{\n  \"file_path\" : \"/repo/Sources/Warden/TraceLog.swift\"\n}", callID: "toolu_1",
                              output: "     1\u{2192}import Foundation\n     2\u{2192}import WardenCore\n     3\u{2192}")
        let claude = ToolLines.describe(read, provider: .claude, cwd: "/repo")
        XCTAssertEqual(claude.phrase, "Read Sources/Warden/TraceLog.swift")
        XCTAssertEqual(claude.output, ["Read 3 lines"])
    }

    func testInjectedInstructionsAndNotificationsAreNotPrompts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let codex = folder.appendingPathComponent("rollout.jsonl")
        try Data(("""
        {"timestamp":"2026-11-23T10:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\\n<INSTRUCTIONS>\\n# Global working agreements\\n</INSTRUCTIONS>"}]}}
        {"timestamp":"2026-11-23T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<hook_prompt hook_run_id=\\"stop:1\\">Findings need review</hook_prompt>"}]}}
        {"timestamp":"2026-11-23T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the build"}]}}
        """ + "\n").utf8).write(to: codex)
        let claude = folder.appendingPathComponent("session.jsonl")
        try Data(("""
        {"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>b1</task-id>\\n</task-notification>"}}
        {"type":"user","message":{"role":"user","content":"Run the tests"}}
        """ + "\n").utf8).write(to: claude)

        let reader = TraceReader()
        let logs = await reader.read([TraceFile(url: codex, provider: .codex), TraceFile(url: claude, provider: .claude)])
        XCTAssertEqual(logs[TraceFile(url: codex, provider: .codex)]?.map(\.text), ["Fix the build"])
        XCTAssertEqual(logs[TraceFile(url: claude, provider: .claude)]?.map(\.text), ["Run the tests"])
    }

    func testSevenAgentsFillTwoBalancedRows() {
        let grid = TraceGrid(count: 7, size: CGSize(width: 1280, height: 800))
        XCTAssertEqual(Dictionary(grouping: grid.frames, by: \.minY).values.map(\.count).sorted(by: >), [4, 3])
    }
}
