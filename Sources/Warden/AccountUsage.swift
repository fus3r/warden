import Foundation
import WardenCore

/// Current plan limits from each provider's own CLI, which answers with its own sign-in, as its usage screen does.
/// Warden reads no credentials, sends no prompt, and calls no other method.
enum AccountUsage {
    /// Codex: `account/rateLimits/read` in the `codex app-server` protocol.
    static func codex(account: AgentAccount, timeout: TimeInterval = 8) -> (windows: [UsageWindow], plan: PlanDetails?)? {
        guard let codex = executable("codex") else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let initialize: [String: Any] = ["id": 1, "method": "initialize",
                                         "params": ["clientInfo": ["name": "warden", "title": "Warden", "version": version]]]
        let result = exchange(codex, arguments: ["app-server"], environment: account.environment, first: initialize,
                              timeout: timeout) { message in
            switch message["id"] as? Int {
            case 1: return .send([["method": "initialized"],
                                  ["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": false]]])
            case 2: return .finish(message["result"] as? [String: Any])
            default: return .wait
            }
        }
        guard let result else { return nil }
        let windows = TelemetryParser.codexAccountWindows(result, observedAt: Date(), account: account.name)
        var plan = TelemetryParser.codexPlan(result)
        plan?.account = account.name
        return windows.isEmpty ? nil : (windows, plan)
    }

    /// Claude: `get_usage` in Claude Code's control protocol, the data behind `/usage`. Without a prompt no model
    /// request is made. Safe mode keeps hooks, MCP servers, and plugins off, and the session is not saved.
    /// Claude Code marks this request experimental, so an answer in another shape reads as unavailable.
    /// `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` must stay unset: with it, Claude Code only repeats its cached answer.
    static func claude(account: AgentAccount, timeout: TimeInterval = 8) -> (windows: [UsageWindow], plan: PlanDetails?)? {
        guard let claude = executable("claude") else { return nil }
        func control(_ id: String, _ request: [String: Any]) -> [String: Any] {
            ["type": "control_request", "request_id": id, "request": request]
        }
        let arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--safe-mode", "--no-session-persistence"]
        let result = exchange(claude, arguments: arguments, environment: account.environment,
                              first: control("1", ["subtype": "initialize"]), timeout: timeout) { message in
            guard message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any] else { return .wait }
            switch response["request_id"] as? String {
            case "1": return .send([control("2", ["subtype": "get_usage", "skip_behaviors": true])])
            case "2": return .finish(response["response"] as? [String: Any])
            default: return .wait
            }
        }
        guard let result else { return nil }
        let windows = TelemetryParser.claudeAccountWindows(result, observedAt: Date(), account: account.name)
        var plan = TelemetryParser.claudePlan(result)
        plan?.account = account.name
        return windows.isEmpty ? nil : (windows, plan)
    }

    /// Apps opened from Finder do not inherit the shell's PATH, so the usual install folders are checked.
    static func executable(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static let versionLock = NSLock()
    nonisolated(unsafe) private static var versionCache: (path: String, modified: Date, version: String?)?

    /// The installed Claude Code version. The native installer links `claude` to a folder named after its version;
    /// other installs answer `claude --version`, asked again only when the program changes.
    static func claudeVersion() -> String? {
        guard let link = executable("claude") else { return nil }
        let target = link.resolvingSymlinksInPath()
        let name = target.lastPathComponent
        if name.first?.isNumber == true, name.split(separator: ".").count == 3 { return name }
        let modified = (try? FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date) ?? .distantPast
        versionLock.lock()
        defer { versionLock.unlock() }
        if let cached = versionCache, cached.path == target.path, cached.modified == modified { return cached.version }
        let process = Process()
        let output = Pipe()
        process.executableURL = link
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var version: String?
        if (try? process.run()) != nil {
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            version = text.split(separator: " ").first.map(String.init)
        }
        versionCache = (target.path, modified, version)
        return version
    }

    /// Claude Code's own list of live and background sessions, the supported way to read their state.
    static func claudeAgents(account: AgentAccount, timeout: TimeInterval = 3) -> [AgentViewEntry]? {
        guard let claude = executable("claude"),
              let data = output(of: claude, arguments: ["agents", "--json"], environment: account.environment,
                                timeout: timeout) else { return nil }
        return ClaudeAgentView.entries(data)
    }

    /// Runs a command and returns what it printed, or nil when it fails or outlasts the timeout.
    private static func output(of executable: URL, arguments: [String], environment: [String: String],
                               timeout: TimeInterval) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.currentDirectoryURL = workingFolder
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let answer = Answer()
        process.terminationHandler = { _ in answer.finish([:]) }
        guard (try? process.run()) != nil else { return nil }
        var data = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard answer.wait(timeout: timeout) != nil else {
            process.terminate()
            return nil
        }
        done.wait()
        return process.terminationStatus == 0 ? data : nil
    }

    /// An empty folder the CLIs start in. Warden itself runs in `/`, and Claude Code started there reads folders
    /// such as ~/Movies/TV, which macOS then asks about in Warden's name as access to Apple Music and the media library.
    private static var workingFolder: URL {
        let folder = WardenPaths.support.appendingPathComponent("CLI", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private enum Step {
        case wait
        case send([[String: Any]])
        case finish([String: Any]?)
    }

    /// Exchanges JSON lines with a CLI until `next` finishes. Blocks up to `timeout`, then ends the process.
    /// `environment` points the CLI at another account.
    private static func exchange(_ executable: URL, arguments: [String], environment: [String: String],
                                 first: [String: Any], timeout: TimeInterval,
                                 next: @escaping ([String: Any]) -> Step) -> [String: Any]? {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.currentDirectoryURL = workingFolder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let answer = Answer()
        let writer = input.fileHandleForWriting
        func send(_ message: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(10)
            try? writer.write(contentsOf: data)
        }
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    switch next(message) {
                    case .wait: break
                    case .send(let messages): messages.forEach(send)
                    case .finish(let result):
                        answer.finish(result)
                        return
                    }
                }
            }
            answer.finish(nil)
        }
        send(first)
        let result = answer.wait(timeout: timeout)
        process.terminate()
        return result
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: [String: Any]?
        private var finished = false

        func finish(_ result: [String: Any]?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            value = result
            done.signal()
        }

        func wait(timeout: TimeInterval) -> [String: Any]? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
