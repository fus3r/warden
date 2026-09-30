import AppKit
import XCTest
@testable import WardenCore

final class SessionNavigationTests: XCTestCase {
    private let id = "3f5d880f-7ac4-42a9-a018-1c46a219eabf"

    func testClosedSDKSessionAtRootResumesItsOwnConversation() throws {
        let session = AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: "/", updatedAt: Date())
        let unrelated = AgentProcess(id: 101, provider: .claude, surface: "Terminal", cwd: "/")
        XCTAssertNil(SessionNavigation.process(for: session, in: [unrelated]))
        let account = AgentAccount(provider: .claude, folder: URL(fileURLWithPath: "/Users/me/.claude"), name: nil)
        let command = try XCTUnwrap(SessionNavigation.command(for: session, executable: URL(fileURLWithPath: "/usr/local/bin/claude"), account: account))
        XCTAssertTrue(command.hasSuffix("'--resume' '\(id)'"))
    }

    func testTranscriptOwnerWinsOverAnotherAgentInTheSameFolder() {
        var session = AgentSession(id: id, provider: .codex, surface: "Terminal", cwd: "/project", updatedAt: Date())
        let first = AgentProcess(id: 101, provider: .codex, surface: "Terminal", cwd: "/project", tty: "ttys001")
        let owner = AgentProcess(id: 202, provider: .codex, surface: "Terminal", cwd: "/project", tty: "ttys002")
        let files = "p101\nn/logs/rollout-other.jsonl\np202\nn/logs/rollout-2026-09-26-\(id).jsonl\n"
        XCTAssertEqual(SessionNavigation.process(for: session, in: [first, owner], openFiles: files)?.id, 202)
        XCTAssertNil(SessionNavigation.process(for: session, in: [first, owner]))
        XCTAssertNil(SessionNavigation.process(for: session, in: [first]))
        session.ended = true
        XCTAssertNil(SessionNavigation.process(for: session, in: [first, owner], openFiles: files))
    }

    func testRecordedPIDNeverFallsBackToAnUnrelatedProcess() {
        var session = AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: "/project", updatedAt: Date())
        session.host = SessionHost(pid: 202)
        let first = AgentProcess(id: 101, provider: .claude, surface: "Terminal", cwd: "/project")
        let owner = AgentProcess(id: 202, provider: .claude, surface: "Terminal", cwd: "/elsewhere")
        XCTAssertEqual(SessionNavigation.process(for: session, in: [first, owner])?.id, 202)
        XCTAssertNil(SessionNavigation.process(for: session, in: [first]))
    }

    func testSharedCodexDaemonFindsTheNamedEditorTerminalAmongAgentsInTheSameFolder() {
        let session = AgentSession(id: id, provider: .codex, surface: "VS Code", cwd: "/project/warden",
                                   phase: .needsAttention, attention: .choice, updatedAt: Date(), title: "Fix terminal navigation")
        let other = AgentProcess(id: 101, provider: .codex, surface: "Terminal", cwd: session.cwd, tty: "ttys001")
        let owner = AgentProcess(id: 202, provider: .codex, surface: "Terminal", cwd: session.cwd, tty: "ttys002")
        // The shared daemon, excluded from the agent list, owns the transcript of both TUI clients.
        let files = "p900\nn/logs/rollout-2026-09-28-\(id).jsonl\n"
        XCTAssertNil(SessionNavigation.process(for: session, in: [other, owner], openFiles: files))
        let names = [101: "✳ Keep Mac Open | warden", 202: "⠦ Fix terminal navigation | warden"]
        XCTAssertEqual(SessionNavigation.process(for: session, in: [other, owner], openFiles: files, terminalNames: names)?.id, 202)
    }

    func testEditorTitleMustMatchInFullAndBeUnique() {
        var session = AgentSession(id: id, provider: .codex, surface: "VS Code", cwd: "/project",
                                   phase: .needsAttention, updatedAt: Date(), title: "Fix navigation")
        let first = AgentProcess(id: 101, provider: .codex, surface: "Terminal", cwd: session.cwd, tty: "ttys001")
        let second = AgentProcess(id: 202, provider: .codex, surface: "Terminal", cwd: session.cwd, tty: "ttys002")
        let name = "Fix navigation | project"
        XCTAssertNil(SessionNavigation.process(for: session, in: [first, second], terminalNames: [101: name, 202: "✳ " + name]))
        XCTAssertNil(SessionNavigation.process(for: session, in: [first], terminalNames: [101: "Fix navigation later | project"]))
        XCTAssertNil(SessionNavigation.process(for: session, in: [first], terminalNames: [101: "Old " + name]))
        XCTAssertEqual(SessionNavigation.process(for: session, in: [first], terminalNames: [101: name])?.id, 101)
        session.ended = true
        XCTAssertNil(SessionNavigation.process(for: session, in: [first], terminalNames: [101: name]))
    }

    func testEditorTitleDoesNotOverrideRecordedOwnershipOrMatchAnotherFolder() {
        var session = AgentSession(id: id, provider: .codex, surface: "VS Code", cwd: "/one/project",
                                   updatedAt: Date(), title: "Fix navigation")
        let process = AgentProcess(id: 101, provider: .codex, surface: "Terminal", cwd: "/two/project", tty: "ttys001")
        let names = [101: "✳ Fix navigation | project"]
        XCTAssertNil(SessionNavigation.process(for: session, in: [process], terminalNames: names))
        session.cwd = "/two/project"
        session.host = SessionHost(pid: 202)
        XCTAssertNil(SessionNavigation.process(for: session, in: [process], terminalNames: names))
    }

    func testBackgroundAttachAndCodexResumeKeepTheAccount() throws {
        var session = AgentSession(id: id, provider: .claude, surface: "Background", cwd: "/project", updatedAt: Date())
        session.backgroundID = "bg-1234"
        session.account = "work"
        let account = AgentAccount(provider: .claude, folder: URL(fileURLWithPath: "/Users/me/.claude-work"), name: "work")
        let executable = URL(fileURLWithPath: "/usr/local/bin/claude")
        let command = try XCTUnwrap(SessionNavigation.command(for: session, executable: executable, account: account))
        XCTAssertTrue(command.contains("CLAUDE_CONFIG_DIR=/Users/me/.claude-work"))
        XCTAssertTrue(command.hasSuffix("'attach' 'bg-1234'"))
        XCTAssertNil(SessionNavigation.command(for: session, executable: executable,
                     account: AgentAccount(provider: .claude, folder: account.folder, name: nil)))
        let codex = AgentSession(id: id, provider: .codex, surface: "Terminal", cwd: "/project", updatedAt: Date())
        let codexCommand = try XCTUnwrap(SessionNavigation.command(for: codex,
             executable: URL(fileURLWithPath: "/usr/local/bin/codex"),
             account: AgentAccount(provider: .codex, folder: URL(fileURLWithPath: "/Users/me/.codex"), name: nil)))
        XCTAssertTrue(codexCommand.hasSuffix("'resume' '\(id)'"))
        XCTAssertTrue(codexCommand.contains("CODEX_HOME=/Users/me/.codex"))
    }

    func testResumeCommandPreservesPathsThroughAppleScriptAndTheShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("a 'quote' $(touch injected) \"end\"")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = folder.appendingPathComponent("fake cli")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$CLAUDE_CONFIG_DIR\" \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let account = AgentAccount(provider: .claude, folder: folder.appendingPathComponent("account's folder"), name: nil)
        let session = AgentSession(id: id, provider: .claude, surface: "Terminal", cwd: folder.path, updatedAt: Date())
        let command = try XCTUnwrap(SessionNavigation.command(for: session, executable: executable, account: account))
        var error: NSDictionary?
        let script = NSAppleScript(source: "return \(SessionNavigation.appleScriptLiteral(command))")
        let decoded = script?.executeAndReturnError(&error).stringValue
        XCTAssertNil(error)
        XCTAssertEqual(decoded, command)
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", try XCTUnwrap(decoded)]
        task.currentDirectoryURL = root
        task.standardOutput = pipe
        try task.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(output, "\(folder.path)\n\(account.folder.path)\n--resume\n\(id)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }
}
