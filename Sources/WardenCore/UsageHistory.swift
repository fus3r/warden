import Foundation

/// Token use per day from the providers' session logs. Each update reads only what a log gained since the last
/// one, so the first update reads the last five weeks of logs once and later ones read a few new lines.
/// Records stay after a provider deletes old logs, and are dropped after 90 days.
///
/// Logs still being written keep a cursor in a small file saved at most every five minutes. A log left alone for
/// three days is settled: its usage joins the archive and only its read offset is kept, in case it resumes.
/// The archive file changes only when logs settle, so the disk sees a few small writes an hour.
public final class UsageHistory: @unchecked Sendable {
    private let directory: URL
    private var activeFile: URL { directory.appendingPathComponent("usage-active.json") }
    private var archiveFile: URL { directory.appendingPathComponent("usage-archive.json") }
    private static let backfillDays = 35
    private static let keptDays = 90
    private static let settleAfter: TimeInterval = 3 * 86_400
    private static let saveInterval: TimeInterval = 300

    private struct Active: Codable {
        var version = 1
        var cursors: [String: LedgerCursor] = [:]
    }

    private struct Archive: Codable {
        var version = 1
        /// Read offset of each settled log, with the day it settled.
        var settled: [String: Settled] = [:]
        var records: [UsageRecord] = []
    }

    private struct Settled: Codable {
        var offset: UInt64
        var day: String
        /// Parsing state without the usage already merged into the archive.
        var checkpoint: LedgerCursor?
    }

    /// Which log counted each Claude reply, by hash, with the day it did. Branched and forked sessions copy earlier
    /// replies into a log of their own; only the first log to count a reply keeps it. Kept for 40 days.
    private struct Claims: Codable {
        var version = 1
        /// "hash:owner:day", in base 36.
        var entries: [String] = []
        /// The logs read before claims existed have been replayed to register their replies. Optional, as files from
        /// before it must still decode.
        var seeded: Bool?
    }

    private var active = Active()
    private var archive = Archive()
    private var claims: [UInt64: (owner: UInt32, day: Int32)] = [:]
    private var claimsChanged = false
    private var claimsSeeded = false
    private var claimsFile: URL { directory.appendingPathComponent("usage-replies.json") }
    private var loaded = false
    private var activeChanged = false
    private var savedAt = Date.distantPast
    /// Size and date of each log when last checked, so an unchanged log is not opened.
    private var seen: [String: (size: Int, modified: Date)] = [:]
    private let manager = FileManager.default

    public init(directory: URL = WardenPaths.support) { self.directory = directory }

    public struct Update {
        /// Every kept record.
        public var records: [UsageRecord]
        /// The records of each session still being written, by session id.
        public var sessions: [String: [UsageRecord]]
        /// Each use read in this update with its time, when asked for.
        public var events: [UsageEvent] = []
    }

    /// Reads new log lines. With `events`, it also returns each use it read with its time; `eventsSince` adds, once,
    /// the use from that date that earlier updates read without keeping times. Runs on one background queue at a time.
    public func update(accounts: [AgentAccount], now: Date = Date(), events collecting: Bool = false,
                       eventsSince backfill: Date? = nil) -> Update {
        if !loaded { load() }
        var archiveChanged = false
        let since = now.addingTimeInterval(-Double(Self.backfillDays) * 86_400)
        if !claimsSeeded { seedClaims(accounts, since: since, now: now) }
        var modifiedAt: [String: Date] = [:]
        var events: [UsageEvent] = []
        let collect: ((UsageEvent) -> Void)? = collecting ? { events.append($0) } : nil
        let dayNumber = Int32(now.timeIntervalSince1970 / 86_400)
        for (provider, root, account) in roots(accounts) {
            for (file, size, modified) in logs(in: root, since: since) {
                // Keyed by file name, which holds the session id, so a log moved to Codex's archive is not read again.
                let key = "\(provider.rawValue)/\(file.lastPathComponent)"
                modifiedAt[key] = modified
                let claim: ((String) -> Bool)? = provider == .claude ? { [unowned self] in self.claim($0, log: key, day: dayNumber) } : nil
                if let backfill, modified >= backfill, let known = active.cursors[key]?.offset ?? archive.settled[key]?.offset, known > 0 {
                    // Read what earlier updates already counted, for its times only; its records are discarded. Replies
                    // copied into several logs count once, and the logs they belong to keep them from now on.
                    var replay = LedgerCursor(session: Self.session(of: file, provider: provider), account: account)
                    _ = read(file, provider: provider, cursor: &replay, through: known,
                             events: { if $0.at >= backfill { events.append($0) } }, claim: claim)
                }
                if let last = seen[file.path], last.size == size, last.modified == modified { continue }
                seen[file.path] = (size, modified)
                var cursor = active.cursors[key] ?? LedgerCursor(session: Self.session(of: file, provider: provider), account: account)
                if active.cursors[key] == nil, let settled = archive.settled[key] {
                    guard UInt64(size) > settled.offset else { continue }
                    if let checkpoint = settled.checkpoint {
                        cursor = checkpoint
                    } else {
                        // Older archives saved only an offset. Recover model and cumulative counters once when
                        // that particular log resumes, then discard usage already held in the archive.
                        guard read(file, provider: provider, cursor: &cursor, through: settled.offset) else { continue }
                        cursor = cursor.continuation
                    }
                }
                // A log that shrank was rewritten, and its content is read again. Keeping its earlier records would
                // count what the rewrite kept twice.
                if UInt64(size) < cursor.offset { cursor = LedgerCursor(session: cursor.session, account: account) }
                guard UInt64(size) > cursor.offset, read(file, provider: provider, cursor: &cursor, events: collect, claim: claim) else { continue }
                active.cursors[key] = cursor
                activeChanged = true
            }
        }

        // Settle logs left alone for three days, and those deleted or outside the backfill window.
        let today = UsageLedger.dayString(now)
        for (key, cursor) in active.cursors where modifiedAt[key].map({ now.timeIntervalSince($0) > Self.settleAfter }) ?? true {
            archive.records = merged(archive.records + cursor.records)
            archive.settled[key] = Settled(offset: cursor.offset, day: today, checkpoint: cursor.continuation)
            active.cursors.removeValue(forKey: key)
            archiveChanged = true
            activeChanged = true
        }

        let oldest = UsageLedger.dayString(now.addingTimeInterval(-Double(Self.keptDays) * 86_400))
        if archive.records.contains(where: { $0.day < oldest }) || archive.settled.values.contains(where: { $0.day < oldest }) {
            archive.records.removeAll { $0.day < oldest }
            archive.settled = archive.settled.filter { $0.value.day >= oldest }
            archiveChanged = true
        }

        // The archive is written first: a log in both files counts once, from the archive.
        if archiveChanged { write(archive, to: archiveFile) }
        if archiveChanged || (activeChanged && now.timeIntervalSince(savedAt) >= Self.saveInterval) { flush(now: now) }
        var sessions: [String: [UsageRecord]] = [:]
        for cursor in active.cursors.values {
            // Spawned threads and reviews count toward the session that started them, as in the Limits report.
            if let session = cursor.parent ?? cursor.session { sessions[session, default: []] += cursor.records }
        }
        return Update(records: archive.records + active.cursors.values.flatMap(\.records).filter { $0.day >= oldest },
                      sessions: sessions, events: events)
    }

    /// Claude names a log after its session and keeps a subagent's log in its session's folder. Codex names a log
    /// `rollout-<time>-<thread id>.jsonl`, adding `_<page id>` when a thread spans several logs; the thread id is
    /// the session id.
    private static func session(of file: URL, provider: AgentProvider) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        if provider == .claude {
            let folder = file.deletingLastPathComponent()
            return folder.lastPathComponent == "subagents" ? folder.deletingLastPathComponent().lastPathComponent : name
        }
        let uuid = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        return name.range(of: uuid, options: .regularExpression).map { String(name[$0]) } ?? name
    }

    /// Saves the cursors of logs still being written, as when Warden quits.
    public func flush(now: Date = Date()) {
        if claimsChanged {
            let oldest = Int32(now.timeIntervalSince1970 / 86_400) - 40
            claims = claims.filter { $0.value.day >= oldest }
            let entries = claims.map { "\(String($0.key, radix: 36)):\(String($0.value.owner, radix: 36)):\(String($0.value.day, radix: 36))" }
            write(Claims(entries: entries, seeded: claimsSeeded ? true : nil), to: claimsFile)
            claimsChanged = false
        }
        guard activeChanged else { return }
        write(active, to: activeFile)
        activeChanged = false
        savedAt = now
    }

    /// True when this log may count a reply: no other log counted it first. `settled` gives the reply to this log,
    /// whose count is already in the archive, whatever claimed it before.
    private func claim(_ reply: String, log: String, day: Int32, settled: Bool = false) -> Bool {
        let key = Self.hash(reply), owner = UInt32(truncatingIfNeeded: Self.hash(log))
        if !settled, let existing = claims[key] { return existing.owner == owner }
        claims[key] = (owner, day)
        claimsChanged = true
        return true
    }

    /// Once: logs read before Warden kept claims counted the replies a branch or fork copies into its own log. Their
    /// read parts are replayed to register which log counted each reply, archived logs first since their counts stay,
    /// and the Claude logs still being written are read again from their start or their archived part, so each
    /// copied reply counts once from now on. Takes about as long as the first read, on the history's queue.
    private func seedClaims(_ accounts: [AgentAccount], since: Date, now: Date) {
        let day = Int32(now.timeIntervalSince1970 / 86_400)
        let files = roots(accounts).filter { $0.0 == .claude }.flatMap { root in
            logs(in: root.1, since: since).map { (file: $0.0, account: root.2) }
        }
        for settledFirst in [true, false] {
            for (file, account) in files {
                let key = "\(AgentProvider.claude.rawValue)/\(file.lastPathComponent)"
                let settled = archive.settled[key]?.offset
                let known = settledFirst ? settled : active.cursors[key]?.offset
                guard let known, known > 0 else { continue }
                var replay = LedgerCursor(session: Self.session(of: file, provider: .claude), account: account)
                _ = read(file, provider: .claude, cursor: &replay, through: known,
                         claim: { [unowned self] in self.claim($0, log: key, day: day, settled: settledFirst) })
            }
        }
        for key in active.cursors.keys where key.hasPrefix("\(AgentProvider.claude.rawValue)/") {
            active.cursors.removeValue(forKey: key)
        }
        seen = [:]
        claimsSeeded = true
        claimsChanged = true
        activeChanged = true
    }

    /// FNV-1a, stable across launches, unlike Swift's own hashing.
    private static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    /// Records with the same day, agent, model, and project added together.
    private func merged(_ records: [UsageRecord]) -> [UsageRecord] {
        var positions: [String: Int] = [:]
        var result: [UsageRecord] = []
        for record in records {
            let key = "\(record.day)\t\(record.provider.rawValue)\t\(record.model)\t\(record.project)\t\(record.account ?? "")"
            if let position = positions[key] {
                result[position].usage = result[position].usage + record.usage
            } else {
                positions[key] = result.count
                result.append(record)
            }
        }
        return result
    }

    /// Each account's session logs, and Codex's archived ones. Claude subagent transcripts are included: their use
    /// counts toward the plan like the session's own.
    private func roots(_ accounts: [AgentAccount]) -> [(AgentProvider, URL, String?)] {
        accounts.flatMap { account -> [(AgentProvider, URL, String?)] in
            var roots = [(account.provider, account.sessions, account.name)]
            if account.provider == .codex {
                roots.append((.codex, account.folder.appendingPathComponent("archived_sessions"), account.name))
            }
            return roots
        }
    }

    private func logs(in root: URL, since: Date) -> [(URL, Int, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [(URL, Int, Date)] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since,
                  let size = values.fileSize else { continue }
            files.append((file, size, modified))
        }
        // A session's own log comes before its subagents' logs, which may repeat its replies: the first log to count a
        // reply keeps it, and the session's own log holds the complete one.
        return files.sorted { !$0.0.path.contains("/subagents/") && $1.0.path.contains("/subagents/") }
    }

    /// Reads from the cursor's offset to the end in 8 MB chunks. A line cut by a chunk is read again with the next.
    /// Returns true when the cursor moved.
    private func read(_ file: URL, provider: AgentProvider, cursor: inout LedgerCursor, through limit: UInt64? = nil,
                      events: ((UsageEvent) -> Void)? = nil, claim: ((String) -> Bool)? = nil) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let chunkSize = 8 << 20
        let initial = cursor
        var more = true
        while more {
            // Chunks and parsed lines are autoreleased. Draining each keeps memory flat through a large first read.
            more = autoreleasepool {
                let start = cursor.offset
                if let limit, start >= limit { return false }
                let count = limit.map { Int(min(UInt64(chunkSize), $0 - start)) } ?? chunkSize
                guard (try? handle.seek(toOffset: start)) != nil,
                      let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { return false }
                UsageLedger.read(chunk, provider: provider, cursor: &cursor, events: events, claim: claim)
                guard chunk.count == chunkSize else { return false }
                // A single line longer than a chunk holds output, not usage, and is skipped.
                if cursor.offset == start { cursor.offset += UInt64(chunkSize) }
                return true
            }
        }
        return cursor != initial
    }

    private func load() {
        loaded = true
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: claimsFile), let stored = try? decoder.decode(Claims.self, from: data), stored.version == 1 {
            claimsSeeded = stored.seeded == true
            for entry in stored.entries {
                let parts = entry.split(separator: ":")
                guard parts.count == 3, let key = UInt64(parts[0], radix: 36), let owner = UInt32(parts[1], radix: 36),
                      let day = Int32(parts[2], radix: 36) else { continue }
                claims[key] = (owner, day)
            }
        }
        if let data = try? Data(contentsOf: archiveFile), let stored = try? decoder.decode(Archive.self, from: data),
           stored.version == 1 {
            archive = stored
        }
        if let data = try? Data(contentsOf: activeFile), let stored = try? decoder.decode(Active.self, from: data),
           stored.version == 1 {
            active = stored
            // Discard a cursor only if all its bytes were settled. A resumed cursor contains new usage beyond
            // that offset. Keeping the settled checkpoint also makes a relaunch before the next flush safe.
            active.cursors = active.cursors.filter { key, cursor in
                archive.settled[key].map { cursor.offset > $0.offset } ?? true
            }
        }
    }

    private func write<T: Encodable>(_ value: T, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
