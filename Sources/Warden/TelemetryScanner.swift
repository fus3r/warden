import AppKit
import Foundation
import WardenCore

struct ScanResult {
    var sessions: [AgentSession]
    var windows: [UsageWindow]
    /// The latest plan details from each account's CLI.
    var plans: [PlanDetails] = []
    var processes: [AgentProcess]
    var nativeApps: [String]
    var scannedAt: Date
}

// WardenStore serializes calls with isScanning. Only its background queue touches this state.
final class TelemetryScanner: @unchecked Sendable {
    private struct Cached {
        var modified: Date
        var size: Int
        var session: AgentSession
    }

    private var cache: [String: Cached] = [:]
    private var codexIndexes: [String: (modified: Date, size: Int, titles: [String: String])] = [:]
    private var storedWindows: [String: UsageWindow]?
    private var lastPrune = Date.distantPast
    /// When each account's limits were last asked for, by account id.
    private var usageReads: [String: Date] = [:]
    private var plans: [String: PlanDetails] = [:]
    private var agentViews: [String: (entries: [AgentViewEntry], readAt: Date)] = [:]
    private var lastAgentViewRead = Date.distantPast
    private let manager = FileManager.default

    /// `refreshUsage` asks for current account limits sooner, for example when the menu opens.
    func scan(accounts: [AgentAccount], refreshUsage: Bool = false) -> ScanResult {
        let now = Date()
        var sessions: [AgentSession] = []
        // Claude transcripts with no conversation yet, such as the session a /clear opens.
        var emptyTranscripts = Set<String>()
        var busySubagents: [String: Int] = [:]
        // Codex keeps spawned threads and reviews in logs of their own, so more of its logs are read, and the
        // threads then count toward the session that started them. The limit counts logs of all accounts together.
        for (provider, limit) in [(AgentProvider.codex, 56), (AgentProvider.claude, 28)] {
            var files: [(file: URL, modified: Date, account: String?)] = []
            for account in accounts where account.provider == provider {
                let (found, subagents) = recentFiles(at: account.sessions, since: now.addingTimeInterval(-6 * 3600), now: now)
                files += found.map { ($0.0, $0.1, account.name) }
                for (session, transcripts) in subagents {
                    // A subagent works until its own turn ends with its report.
                    let working = transcripts.filter { parse($0, provider: .claude, account: account.name, now: now)?.phase == .working }
                    if !working.isEmpty { busySubagents[session] = working.count }
                }
            }
            for (file, _, account) in files.sorted(by: { $0.modified > $1.modified }).prefix(limit) {
                if let parsed = parse(file, provider: provider, account: account, now: now) { sessions.append(parsed) }
                else if provider == .claude { emptyTranscripts.insert(file.deletingPathExtension().lastPathComponent) }
            }
        }

        for thread in sessions where thread.isSubagent && thread.phase == .working && thread.updatedAt > now.addingTimeInterval(-1800) {
            if let parent = thread.parentID { busySubagents[parent, default: 0] += 1 }
        }
        sessions.removeAll { $0.isSubagent }

        var titles: [String: String] = [:]
        for account in accounts where account.provider == .codex {
            titles.merge(codexTitles(account.folder.appendingPathComponent("session_index.jsonl"))) { first, _ in first }
        }
        for index in sessions.indices where sessions[index].provider == .codex && sessions[index].title == nil {
            sessions[index].title = titles[sessions[index].id]
        }

        let bridge = readBridge(now: now)
        var seen = Set<String>()
        sessions = sessions.map { session in
            seen.insert(session.id)
            return TelemetryParser.merge(session, status: bridge.status[session.id], event: bridge.events[session.id])
        }
        var unlistedWindows: [UsageWindow] = []
        for (id, status) in bridge.status where !seen.contains(id) {
            guard status.updatedAt > now.addingTimeInterval(-6 * 3600) else { continue }
            // A session is listed once its transcript holds a conversation. Its status line still reports limits.
            if emptyTranscripts.contains(id) {
                unlistedWindows += status.windows
                continue
            }
            // Without a transcript, bridge events are the only activity record, so they always apply.
            let base = AgentSession(id: id, provider: .claude, surface: "Claude Code", cwd: status.cwd,
                                    updatedAt: .distantPast)
            sessions.append(TelemetryParser.merge(base, status: status, event: bridge.events[id]))
        }
        for (id, event) in bridge.events where !seen.contains(id) && bridge.status[id] == nil && !emptyTranscripts.contains(id) {
            guard event.at > now.addingTimeInterval(-6 * 3600) else { continue }
            let base = AgentSession(id: id, provider: .claude, surface: "Claude Code", cwd: event.cwd,
                                    updatedAt: .distantPast)
            sessions.append(TelemetryParser.merge(base, status: nil, event: event))
        }

        var unique: [String: AgentSession] = [:]
        for session in sessions {
            let key = "\(session.provider.rawValue):\(session.id)"
            if let old = unique[key], old.updatedAt >= session.updatedAt { continue }
            unique[key] = session
        }
        sessions = unique.values.filter { Accounts.follows($0.provider, account: $0.account, in: accounts) }

        let (processes, apps) = processSnapshot()
        for view in claudeAgents(accounts, now: now, soon: refreshUsage, running: processes.contains { $0.provider == .claude }) {
            for entry in view.entries {
                guard let id = entry.sessionID else { continue }
                if let index = sessions.firstIndex(where: { $0.provider == .claude && $0.id == id }) {
                    sessions[index] = ClaudeAgentView.merge(sessions[index], entry: entry, readAt: view.readAt)
                } else if entry.isBackground, entry.isWaiting || entry.isBusy {
                    // A background session can wait on you long after its log last changed.
                    var base = AgentSession(id: id, provider: .claude, surface: "Background", cwd: entry.cwd,
                                            updatedAt: view.readAt.addingTimeInterval(-3), title: entry.name)
                    base.account = view.account
                    sessions.append(ClaudeAgentView.merge(base, entry: entry, readAt: view.readAt))
                }
            }
            // Claude Code names each live session's process, which finds its terminal tab without the bridge.
            for index in sessions.indices where sessions[index].host?.tty == nil {
                if let pid = sessions[index].host?.pid { sessions[index].host?.tty = ProcessDetails.tty(of: pid) }
            }
        }
        for index in sessions.indices {
            guard let pid = sessions[index].host?.pid, !ProcessDetails.isAlive(pid, name: sessions[index].host?.processName) else { continue }
            sessions[index].ended = true
            if sessions[index].phase == .working || sessions[index].phase == .needsAttention {
                sessions[index].phase = .idle
                sessions[index].attention = nil
                sessions[index].detail = nil
            }
        }
        let running = SessionLiveness.running(sessions, processes: processes)
        for index in sessions.indices {
            var session = sessions[index]
            // Subagents that still write keep a Claude session working after its own turn ends, as background
            // agents do. The session then finishes when Claude answers their results.
            session.activeSubagents = session.ended ? 0 : busySubagents[session.id] ?? 0
            if session.activeSubagents > 0, session.phase != .needsAttention {
                session.phase = .working
            }
            // A session waiting for a usage limit to reset stays open until Claude continues it.
            let running = running.contains(session.id) || session.activeSubagents > 0
                || (session.resumesAt.map { $0 > now.addingTimeInterval(-600) } ?? false)
            if session.phase == .unknown, session.updatedAt > now.addingTimeInterval(-45),
               processes.contains(where: { $0.provider == session.provider }) {
                session.phase = .working
                session.phaseEvidence = .inferred
            }
            if session.phase == .working, session.updatedAt < now.addingTimeInterval(-120), !running {
                session.phase = .unknown
            }
            // An interrupted session waits for you only while its agent is still open.
            if session.attention == .interrupted, !running {
                session.phase = .idle
                session.attention = nil
            }
            // A run started by a program ends with its turn: once its process is gone, nothing waits for you.
            // A failure stays in its detail, so Recent Sessions says what stopped it.
            // A background session from Claude's agent view has no process id there, so it keeps its wait.
            if session.isHeadless, session.backgroundID == nil, session.phase == .needsAttention, !running {
                if session.attention != .failure { session.detail = nil }
                session.phase = .idle
                session.attention = nil
            }
            sessions[index] = session
        }
        sessions.sort { left, right in
            if left.phase == .needsAttention && right.phase != .needsAttention { return true }
            if right.phase == .needsAttention && left.phase != .needsAttention { return false }
            return left.updatedAt > right.updatedAt
        }
        sessions = Array(sessions.prefix(30))

        let windows = mergeWindows(sessions.flatMap(\.windows) + unlistedWindows + accountUsage(accounts, now: now, soon: refreshUsage),
                                   accounts: accounts, now: now)
        if now.timeIntervalSince(lastPrune) > 3600 {
            lastPrune = now
            // Logs no longer among the recent ones leave the cache, so it stays small while Warden runs for weeks.
            cache = cache.filter { $0.value.modified > now.addingTimeInterval(-7 * 3600) }
            prune(WardenPaths.eventDirectory, olderThan: now.addingTimeInterval(-2 * 86_400))
            prune(WardenPaths.statusDirectory, olderThan: now.addingTimeInterval(-7 * 86_400))
        }
        let current = Set(accounts.map(\.id))
        return ScanResult(sessions: sessions, windows: windows, plans: plans.filter { current.contains($0.key) }.map(\.value),
                          processes: processes, nativeApps: apps, scannedAt: now)
    }

    /// A session from the start and recent end of its log, cached until the file changes.
    private func parse(_ file: URL, provider: AgentProvider, account: String?, now: Date) -> AgentSession? {
        guard let attrs = try? manager.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        if let cached = cache[file.path], cached.modified == modified, cached.size == size { return cached.session }
        let tailLimit = provider == .codex ? 1_048_576 : 524_288
        guard let (head, tail) = readEdges(file, size: size, tailLimit: tailLimit) else { return nil }
        var parsed = provider == .codex
            ? TelemetryParser.codex(head: head, tail: tail, filename: file.lastPathComponent, modifiedAt: modified, account: account)
            : TelemetryParser.claude(head: head, tail: tail, filename: file.lastPathComponent, modifiedAt: modified, account: account)
        if provider == .codex, parsed?.phase == .unknown,
           modified > now.addingTimeInterval(-120), size > 1_048_576,
           let (wideHead, wideTail) = readEdges(file, size: size, tailLimit: 8_388_608),
           let resolved = TelemetryParser.codex(head: wideHead, tail: wideTail, filename: file.lastPathComponent,
                                                modifiedAt: modified, account: account) {
            parsed = resolved
        }
        // A line longer than the tail, such as a screenshot's tool result, can leave no whole entry to read.
        if provider == .claude, parsed == nil, size > tailLimit,
           let (wideHead, wideTail) = readEdges(file, size: size, tailLimit: 8_388_608) {
            parsed = TelemetryParser.claude(head: wideHead, tail: wideTail, filename: file.lastPathComponent,
                                            modifiedAt: modified, account: account)
        }
        // A turn whose start left the tail keeps the start an earlier read of the same log found.
        if var session = parsed, session.phase == .working, let earlier = cache[file.path]?.session,
           let start = earlier.turnStartedAt, start < (session.turnStartedAt ?? .distantFuture),
           provider == .codex ? session.turnStartedAt == nil && [.working, .needsAttention].contains(earlier.phase)
                              : session.turnPromptID != nil && session.turnPromptID == earlier.turnPromptID {
            session.turnStartedAt = start
            parsed = session
        }
        if let parsed { cache[file.path] = Cached(modified: modified, size: size, session: parsed) }
        return parsed
    }

    /// Claude Code's own session list for each Claude account, read while a Claude process runs: once a minute, or
    /// sooner when the menu opens. Hooks and logs already give most states at once; this adds waits they cannot show.
    private func claudeAgents(_ accounts: [AgentAccount], now: Date, soon: Bool,
                              running: Bool) -> [(entries: [AgentViewEntry], readAt: Date, account: String?)] {
        guard running else {
            agentViews = [:]
            return []
        }
        let claude = accounts.filter { $0.provider == .claude }
        if now.timeIntervalSince(lastAgentViewRead) >= (soon ? 10 : 60) {
            lastAgentViewRead = now
            agentViews = [:]
            for account in claude {
                if let entries = AccountUsage.claudeAgents(account: account) { agentViews[account.id] = (entries, now) }
            }
        }
        return claude.compactMap { account in agentViews[account.id].map { ($0.entries, $0.readAt, account.name) } }
    }

    /// Limits change with use on any device, so each provider's CLI is asked every ten minutes,
    /// or after one minute when asked. Session logs and the status line still supply values between reads.
    /// The reads run side by side, so a scan waits for the slower one only.
    private func accountUsage(_ accounts: [AgentAccount], now: Date, soon: Bool) -> [UsageWindow] {
        let interval: TimeInterval = soon ? 60 : 600
        let defaults = UserDefaults.standard
        var reads: [() -> (windows: [UsageWindow], plan: PlanDetails?)?] = []
        var readAccounts: [AgentAccount] = []
        for account in accounts where defaults.bool(forKey: account.provider == .codex ? "codexAccountUsage" : "claudeAccountUsage") {
            guard now.timeIntervalSince(usageReads[account.id] ?? .distantPast) > interval else { continue }
            usageReads[account.id] = now
            readAccounts.append(account)
            reads.append { account.provider == .codex ? AccountUsage.codex(account: account) : AccountUsage.claude(account: account) }
        }
        let lock = NSLock()
        var windows: [UsageWindow] = []
        DispatchQueue.concurrentPerform(iterations: reads.count) { index in
            guard let result = reads[index]() else { return }
            lock.lock()
            windows += result.windows
            if let plan = result.plan { plans[readAccounts[index].id] = plan }
            lock.unlock()
        }
        return windows
    }

    /// Latest value per window, kept across restarts so a weekly window stays visible between sessions.
    private func mergeWindows(_ fresh: [UsageWindow], accounts: [AgentAccount], now: Date) -> [UsageWindow] {
        if storedWindows == nil {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let saved = (try? Data(contentsOf: WardenPaths.usageFile))
                .flatMap { try? decoder.decode([UsageWindow].self, from: $0) } ?? []
            storedWindows = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let followed = (storedWindows ?? [:]).filter { Accounts.follows($0.value.provider, account: $0.value.account, in: accounts) }
        let fresh = fresh.filter { Accounts.follows($0.provider, account: $0.account, in: accounts) }
        let merged = UsageWindow.latest(followed, adding: fresh, now: now)
        let changed = merged != storedWindows
        storedWindows = merged
        if changed {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(Array(merged.values)) {
                try? manager.createDirectory(at: WardenPaths.support, withIntermediateDirectories: true)
                try? data.write(to: WardenPaths.usageFile, options: .atomic)
            }
        }
        // Each account's limits stay together, as in History and `WardenBridge status`.
        return merged.values.sorted {
            ($0.provider.rawValue, $0.account ?? "", $0.durationMinutes ?? 0, $0.scope ?? "")
                < ($1.provider.rawValue, $1.account ?? "", $1.durationMinutes ?? 0, $1.scope ?? "")
        }
    }

    private func codexTitles(_ url: URL) -> [String: String] {
        guard let attrs = try? manager.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return [:] }
        if let index = codexIndexes[url.path], index.modified == modified, index.size == size { return index.titles }
        let titles = readEdges(url, size: size, tailLimit: 262_144).map { TelemetryParser.codexTitles($0.1) } ?? [:]
        codexIndexes[url.path] = (modified, size, titles)
        return titles
    }

    /// Session logs changed since `date`, and per Claude session its subagent transcripts written in the last half hour.
    private func recentFiles(at root: URL, since date: Date, now: Date) -> ([(URL, Date)], [String: [URL]]) {
        guard manager.fileExists(atPath: root.path),
              let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return ([], [:]) }
        var files: [(URL, Date)] = []
        var subagents: [String: [URL]] = [:]
        for case let file as URL in enumerator {
            // A Claude subagent's transcript carries its parent's session id. The parent's own transcript holds
            // the session's state, and many parallel subagents would otherwise crowd sessions out of the limit.
            if file.lastPathComponent == "subagents" {
                enumerator.skipDescendants()
                let session = file.deletingLastPathComponent().lastPathComponent
                let agents = (try? manager.contentsOfDirectory(at: file, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                let recent = agents.filter { agent in
                    guard agent.pathExtension == "jsonl",
                          let modified = (try? agent.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    else { return false }
                    return modified > now.addingTimeInterval(-1800)
                }
                if !recent.isEmpty { subagents[session] = recent }
                continue
            }
            guard file.pathExtension == "jsonl",
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= date else { continue }
            files.append((file, modified))
        }
        return (files, subagents)
    }

    private func readEdges(_ url: URL, size: Int, tailLimit: Int) -> (Data, Data)? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let head = (try? file.read(upToCount: min(size, 65_536))) ?? Data()
        let offset = UInt64(max(0, size - tailLimit))
        try? file.seek(toOffset: offset)
        let tail = (try? file.read(upToCount: min(size, tailLimit))) ?? Data()
        return (head, tail)
    }

    private func readBridge(now: Date) -> (status: [String: BridgeStatus], events: [String: BridgeEvent]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var statuses: [String: BridgeStatus] = [:]
        var events: [String: BridgeEvent] = [:]
        if let files = try? manager.contentsOfDirectory(at: WardenPaths.statusDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let status = try? decoder.decode(BridgeStatus.self, from: data) {
                    statuses[status.sessionID] = status
                }
            }
        }
        if let files = try? manager.contentsOfDirectory(at: WardenPaths.eventDirectory,
                                                        includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.pathExtension == "json" {
                guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date > now.addingTimeInterval(-6 * 3600),
                      let data = try? Data(contentsOf: file),
                      let event = try? decoder.decode(BridgeEvent.self, from: data) else { continue }
                if let old = events[event.sessionID], old.at >= event.at { continue }
                events[event.sessionID] = event
            }
        }
        return (statuses, events)
    }

    private func prune(_ directory: URL, olderThan date: Date) {
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "json" {
            if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified < date {
                try? manager.removeItem(at: file)
            }
        }
    }

    private func processSnapshot() -> ([AgentProcess], [String]) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([], []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return ([], []) }
        var parents: [Int32: Int32] = [:]
        var candidates: [(pid: Int32, provider: AgentProvider, surface: String)] = []
        var apps = Set<String>()
        for line in output.split(separator: "\n") {
            let pieces = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard pieces.count == 3, let pid = Int32(pieces[0]), let parent = Int32(pieces[1]) else { continue }
            let path = String(pieces[2])
            parents[pid] = parent
            if path.contains("/ChatGPT.app/Contents/MacOS/ChatGPT") { apps.insert("ChatGPT") }
            if path.contains("/Claude.app/Contents/MacOS/Claude") { apps.insert("Claude") }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            let provider: AgentProvider
            if name == "codex" { provider = .codex }
            else if name == "claude" { provider = .claude }
            else { continue }
            // App servers also run beneath Codex's tools on the TUI's own TTY and cwd. Counting one as
            // another agent makes the editor's exact terminal match ambiguous.
            if provider == .codex, let arguments = ProcessDetails.arguments(of: pid), Self.isCodexService(arguments) {
                continue
            }
            let surface: String
            if path.contains(".vscode/extensions") { surface = "VS Code" }
            else if path.contains("ChatGPT.app") { surface = "ChatGPT" }
            else if path.contains("Claude.app") { surface = "Claude Desktop" }
            else { surface = "Terminal" }
            candidates.append((pid, provider, surface))
        }
        var hosts: [Int32: String] = [:]
        func hostApp(of pid: Int32) -> String? {
            var current = parents[pid] ?? 0
            for _ in 0..<12 where current > 1 {
                if let cached = hosts[current] { return cached }
                if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular,
                   let bundleID = app.bundleIdentifier {
                    hosts[current] = bundleID
                    return bundleID
                }
                current = parents[current] ?? 0
            }
            return nil
        }
        let agents = candidates.map { candidate in
            AgentProcess(id: Int(candidate.pid), provider: candidate.provider, surface: candidate.surface,
                         cwd: ProcessDetails.cwd(of: candidate.pid), tty: ProcessDetails.tty(of: candidate.pid),
                         hostBundleID: hostApp(of: candidate.pid))
        }
        if let list = ProcessInfo.processInfo.environment["WARDEN_TEST_APPS"] {
            return (agents, list.split(separator: ",").map(String.init))
        }
        return (agents, apps.sorted())
    }

    static func isCodexService(_ arguments: [String]) -> Bool {
        arguments.contains("--managed-daemon") || arguments.contains("pid-update-loop")
            || ["app-server", "sandbox"].contains(arguments.dropFirst().first ?? "")
    }
}
