import Foundation

/// One account of an agent: the folder that holds its sessions, settings, and sign-in. `~/.claude` and `~/.codex`
/// hold the default accounts; `CLAUDE_CONFIG_DIR` and `CODEX_HOME` point an agent at another, such as `~/.claude-work`.
public struct AgentAccount: Hashable, Identifiable, Sendable {
    public var provider: AgentProvider
    public var folder: URL
    /// Nil for the default account; otherwise a short name from its folder, such as "work" for `~/.claude-work`.
    public var name: String?

    public init(provider: AgentProvider, folder: URL, name: String?) {
        self.provider = provider
        self.folder = folder
        self.name = name
    }

    public var id: String { "\(provider.rawValue):\(folder.path)" }

    /// The account's folder of session logs.
    public var sessions: URL {
        folder.appendingPathComponent(provider == .claude ? "projects" : "sessions", isDirectory: true)
    }

    /// The environment that points the agent's own CLI at this account, empty for the default account.
    public var environment: [String: String] {
        guard name != nil else { return [:] }
        return [provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME": folder.path]
    }

    /// "work" for `~/.claude-work` or `~/.codex_work`, and the folder's own name for any other folder.
    public static func name(for folder: URL, provider: AgentProvider) -> String {
        var name = Substring(folder.lastPathComponent)
        if name.hasPrefix(".") { name = name.dropFirst() }
        let agent = provider == .claude ? "claude" : "codex"
        if name.lowercased().hasPrefix(agent) { name = name.dropFirst(agent.count) }
        while let first = name.first, "-_.".contains(first) { name = name.dropFirst() }
        return name.isEmpty ? folder.lastPathComponent : String(name)
    }

    /// The account a hook or status line runs for, from the environment Claude Code gives it.
    public static func claudeName(environment: [String: String], home: URL) -> String? {
        guard let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard folder.path != home.appendingPathComponent(".claude").standardizedFileURL.path else { return nil }
        return name(for: folder, provider: .claude)
    }
}

public enum Accounts {
    /// The default accounts, other folders in the home folder that hold an agent's sessions, such as
    /// `~/.claude-work`, and folders the user added. Folders the user removed are left out.
    public static func discover(home: URL, codexHome: URL? = nil, added: [URL] = [], removed: Set<String> = [],
                                manager: FileManager = .default) -> [AgentAccount] {
        func holdsSessions(_ folder: URL, _ provider: AgentProvider) -> Bool {
            var isFolder: ObjCBool = false
            let sessions = folder.appendingPathComponent(provider == .claude ? "projects" : "sessions")
            return manager.fileExists(atPath: sessions.path, isDirectory: &isFolder) && isFolder.boolValue
        }
        let claude = home.appendingPathComponent(".claude").standardizedFileURL
        let codex = (codexHome ?? home.appendingPathComponent(".codex")).standardizedFileURL
        var accounts = [AgentAccount(provider: .claude, folder: claude, name: nil),
                        AgentAccount(provider: .codex, folder: codex, name: nil)]
        var candidates = added.map(\.standardizedFileURL)
        let entries = (try? manager.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        candidates += entries.filter { entry in
            let name = entry.lastPathComponent.lowercased()
            return name.hasPrefix(".claude") || name.hasPrefix(".codex")
        }.map(\.standardizedFileURL)
        for folder in candidates where folder != claude && folder != codex && !removed.contains(folder.path) {
            guard !accounts.contains(where: { $0.folder == folder }) else { continue }
            // A Claude folder also has a `sessions` folder, of live process records, so its name or `projects`
            // decides first.
            let name = folder.lastPathComponent.lowercased()
            let providers: [AgentProvider] = name.contains("codex") ? [.codex] : name.contains("claude") ? [.claude] : [.claude, .codex]
            for provider in providers where holdsSessions(folder, provider) {
                accounts.append(AgentAccount(provider: provider, folder: folder, name: AgentAccount.name(for: folder, provider: provider)))
                break
            }
        }
        return accounts
    }
}
