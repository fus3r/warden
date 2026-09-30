import Foundation

/// train-guard, a supervisor that pauses long jobs while the Mac runs on battery and lowers their priority while the
/// battery is warm. Its Python package, from 0.5, keeps each job in `~/.train-guard` as JSON; the earlier shell script
/// keeps them in `~/.claude/tools/train-guard`. Each job records the agent session that started it, from the session id
/// Claude Code and Codex give the commands they run, and train-guard runs the jobs of the agents listed in
/// `ignored-agents` at full speed. Warden edits that list and reads what the guards do; it never touches a job.
public struct TrainGuard {
    /// A job train-guard supervises now.
    public struct Job: Equatable {
        public var name: String
        /// The session id of the agent that started it.
        public var agent: String
        /// What the guard does with it now: "full" or "run" at full speed, "gentle" or "ecore" at low priority, "stop"
        /// while paused, or "waiting" for its process to appear.
        public var decision: String?
    }

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Where the Python package keeps its jobs, logs, and policy.
    public var packageFolder: URL { home.appendingPathComponent(".train-guard", isDirectory: true) }
    /// Where the shell script lives with its jobs and logs.
    public var scriptFolder: URL { home.appendingPathComponent(".claude/tools/train-guard", isDirectory: true) }

    public var hasScript: Bool {
        FileManager.default.fileExists(atPath: scriptFolder.appendingPathComponent("train-guard.sh").path)
    }

    /// The `train-guard` command where installers put it: `~/.local/bin` for Warden, pipx, and uv, or Homebrew's folder.
    public var command: URL? {
        ([home.appendingPathComponent(".local/bin/train-guard")]
         + ["/opt/homebrew/bin/train-guard", "/usr/local/bin/train-guard"].map { URL(fileURLWithPath: $0) })
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var isInstalled: Bool { hasScript || command != nil }

    /// Do not offer an ineffective override for the published 0.4 package or an unmodified old script.
    public var supportsSessionControl: Bool {
        if let command,
           let version = TrainGuardPackage.installedVersion(in: command.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()),
           !TrainGuardPackage.isOlder(version) { return true }
        if hasScript,
           let script = try? String(contentsOf: scriptFolder.appendingPathComponent("train-guard.sh"), encoding: .utf8),
           script.contains("ignored-agents"), script.contains("AGENT=") { return true }
        return false
    }

    /// The lists that apply: the package's, and the script's when it is installed.
    private var listFiles: [URL] {
        ([packageFolder] + (hasScript ? [scriptFolder] : [])).map { $0.appendingPathComponent("ignored-agents") }
    }

    /// Session ids of the agents whose jobs run at full speed.
    public func ignoredAgents() -> Set<String> {
        listFiles.reduce(into: Set<String>()) { ids, file in
            ids.formUnion(Self.agents(inList: (try? String(contentsOf: file, encoding: .utf8)) ?? ""))
        }
    }

    /// Adds an agent to each list or removes it, keeping the lists' other lines. The label, such as "Claude · warden",
    /// follows the id as a comment for whoever reads the file.
    public func setIgnored(_ ignored: Bool, agent: String, label: String) throws {
        for file in listFiles {
            let text: String
            do { text = try String(contentsOf: file, encoding: .utf8) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { text = Self.listHeader }
            // Never replace an unreadable owner list with an empty one.
            catch { throw error }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.list(text, agent: agent, ignored: ignored, label: label).write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// The running jobs whose guard recorded an agent, by name.
    public func jobs() -> [Job] {
        (packageJobs() + (hasScript ? scriptJobs() : [])).sorted { $0.name < $1.name }
    }

    /// Active work, including jobs launched outside an agent. Paused or waiting guards do not need wake protection.
    public func workingJobs() -> [String] {
        let active = packageNames().filter { name in
            guard packageSupervisorRuns(name), let runtime = Self.object(packageRun.appendingPathComponent(name + ".runtime.json")),
                  let state = runtime["state"] as? String, ["full", "gentle"].contains(state),
                  let pids = runtime["pids"] as? [Int], !pids.isEmpty else { return false }
            return true
        }
        let legacy = hasScript ? runningScriptGuards().filter { name in
            let state = Self.decision(inLog: Self.tail(of: scriptFolder.appendingPathComponent("logs/\(name).guard.log")))
            return ["run", "ecore", "gentle"].contains(state ?? "")
        } : []
        return (active + legacy).sorted()
    }

    /// The package's guards whose supervisor still runs, by name, whether or not they recorded an agent.
    public func runningPackageGuards() -> [String] {
        packageNames().filter(packageSupervisorRuns).sorted()
    }

    /// Legacy guards are also checked before replacing their command during migration.
    public func runningScriptGuards() -> [String] {
        let run = scriptFolder.appendingPathComponent("run")
        return ((try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "meta" && scriptSupervisorRuns($0) }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    private func scriptSupervisorRuns(_ meta: URL) -> Bool {
        let name = meta.deletingPathExtension().lastPathComponent
        guard let gpid = try? String(contentsOf: meta.deletingLastPathComponent().appendingPathComponent(name + ".gpid"), encoding: .utf8),
              let pid = pid_t(gpid.trimmingCharacters(in: .whitespacesAndNewlines)),
              let arguments = ProcessDetails.arguments(of: pid), arguments.contains("__supervise"),
              arguments.last.map({ URL(fileURLWithPath: $0).lastPathComponent }) == meta.lastPathComponent else { return false }
        return true
    }

    private var packageRun: URL { packageFolder.appendingPathComponent("run", isDirectory: true) }

    private func packageNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: packageRun.path)) ?? [])
            .filter { $0.hasSuffix(".meta.json") }.map { String($0.dropLast(".meta.json".count)) }
    }

    /// `<name>.guard.json` names the supervisor by process id and start time, so a process that later got the same id
    /// is not taken for it.
    private func packageSupervisorRuns(_ name: String) -> Bool {
        guard let supervisor = Self.object(packageRun.appendingPathComponent(name + ".guard.json")),
              let pid = (supervisor["pid"] as? NSNumber)?.int32Value,
              let started = (supervisor["create_time"] as? NSNumber)?.doubleValue,
              let actual = ProcessDetails.startTime(of: pid) else { return false }
        return abs(actual - started) < 0.01
    }

    /// The package's jobs: `<name>.meta.json` names the agent and `.runtime.json` what the guard last decided.
    private func packageJobs() -> [Job] {
        packageNames().compactMap { name -> Job? in
            guard let agent = Self.object(packageRun.appendingPathComponent(name + ".meta.json"))?["agent"] as? String,
                  !agent.isEmpty, packageSupervisorRuns(name) else { return nil }
            let runtime = Self.object(packageRun.appendingPathComponent(name + ".runtime.json"))
            return Job(name: name, agent: agent, decision: runtime?["state"] as? String)
        }
    }

    /// The shell script's jobs. Its records are shell assignments, and a guard that died, as at a restart, leaves its
    /// record behind while its process id may now be another's.
    private func scriptJobs() -> [Job] {
        let run = scriptFolder.appendingPathComponent("run", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "meta" }.compactMap { meta -> Job? in
            let name = meta.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: meta, encoding: .utf8),
                  let agent = Self.agent(inMeta: text), scriptSupervisorRuns(meta) else { return nil }
            let log = scriptFolder.appendingPathComponent("logs/\(name).guard.log")
            return Job(name: name, agent: agent, decision: Self.decision(inLog: Self.tail(of: log)))
        }
    }

    static let listHeader = "# Agent sessions whose jobs train-guard runs at full speed, one id per line. Warden's menu edits this list.\n"

    static func agents(inList text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let id = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        })
    }

    static func list(_ text: String, agent: String, ignored: Bool, label: String) -> String {
        guard !agent.isEmpty, agent.allSatisfy({ !$0.isWhitespace && $0 != "#" }) else { return text }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        lines.removeAll { $0.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces) == agent }
        if ignored { lines.append("\(agent)  # \(label.components(separatedBy: .newlines).joined(separator: " "))") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func object(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The agent a shell guard's record names. The script writes it shell-quoted, so no agent reads ''.
    static func agent(inMeta text: String) -> String? {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("AGENT=") }) else { return nil }
        let value = line.dropFirst("AGENT=".count)
        return value.isEmpty || value == "''" ? nil : String(value)
    }

    /// The decision on a shell guard's last line such as "[guard] 2026-09-27 13:42:16 -> ecore   (power=AC …)".
    static func decision(inLog text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            guard let range = line.range(of: " -> "),
                  let word = line[range.upperBound...].split(separator: " ").first,
                  ["run", "ecore", "gentle", "stop"].contains(word) else { continue }
            return String(word)
        }
        return nil
    }

    /// The end of a shell guard's log, which gains a line each time the guard's decision or readings change.
    private static func tail(of url: URL, bytes: UInt64 = 2048) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
