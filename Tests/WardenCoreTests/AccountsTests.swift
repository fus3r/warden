import XCTest
@testable import WardenCore

final class AccountsTests: XCTestCase {
    func testDefaultAccountsOverrideInheritedAlternativeFolders() {
        let home = URL(fileURLWithPath: "/tmp/warden-accounts")
        let inherited = ["CLAUDE_CONFIG_DIR": "/tmp/other-claude", "CODEX_HOME": "/tmp/other-codex"]
        for (provider, folder, key) in [(AgentProvider.claude, ".claude", "CLAUDE_CONFIG_DIR"),
                                        (.codex, ".codex", "CODEX_HOME")] {
            let account = AgentAccount(provider: provider, folder: home.appendingPathComponent(folder), name: nil)
            let environment = inherited.merging(account.environment) { $1 }
            XCTAssertEqual(environment[key], account.folder.path,
                           "The CLI must read the selected default account even when Warden inherits another folder.")
        }
    }

    func testOtherAccountsAreFoundBesideTheDefaultFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // A second Claude account also has the `sessions` folder of live process records, like `~/.claude`.
        for folder in [".claude/projects", ".claude-work/projects", ".claude-work/sessions", ".codex/sessions",
                       ".codex-watchers/bifrost", "clients/acme-codex/sessions"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let added = home.appendingPathComponent("clients/acme-codex")
        let accounts = Accounts.discover(home: home, added: [added])
        XCTAssertEqual(accounts.map(\.provider), [.claude, .codex, .codex, .claude])
        XCTAssertEqual(accounts.map(\.name), [nil, nil, "acme-codex", "work"])
        XCTAssertEqual(accounts.last?.environment, ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude-work").standardizedFileURL.path])
        // A folder removed in Settings stays out.
        XCTAssertEqual(Accounts.discover(home: home, removed: [home.appendingPathComponent(".claude-work").standardizedFileURL.path]).count, 2)

        // Hooks and the status line learn their account from CLAUDE_CONFIG_DIR.
        XCTAssertNil(AgentAccount.claudeName(environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path], home: home))
        XCTAssertEqual(AgentAccount.claudeName(environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude-work").path], home: home), "work")
    }

    func testAnotherAccountsLimitsAndUseStayApart() {
        let reset = Date().addingTimeInterval(86_400)
        let work = UsageWindow(id: UsageWindow.id(.claude, "seven_day", account: "work"), provider: .claude, label: "7d",
                               usedPercent: 50, resetsAt: reset, observedAt: Date(), evidence: .provider, minutes: 10_080, account: "work")
        XCTAssertEqual(work.id, "Claude-work-seven_day")
        XCTAssertEqual(work.rowLabel, "work 7d")
        XCTAssertEqual(work.name, "Claude (work) 7d")

        let today = UsageLedger.dayString(Date())
        let records = [
            UsageRecord(day: today, provider: .claude, model: "claude-sonnet-5", project: "/tmp/a", usage: TokenUsage(input: 1_000_000), account: "work"),
            UsageRecord(day: today, provider: .claude, model: "claude-sonnet-5", project: "/tmp/b", usage: TokenUsage(input: 3_000_000))
        ]
        // The work account's week counts only its own use.
        XCTAssertEqual(UsageSummary(records: records).totals(since: work)?.cost ?? 0, 2, accuracy: 1e-9)
    }
}
