import Darwin
import Foundation
import WardenCore

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? ""
let helper = URL(fileURLWithPath: CommandLine.arguments[0])
// A reader that goes away must make a write fail, not end the bridge.
signal(SIGPIPE, SIG_IGN)

switch mode {
case "install-claude", "uninstall-claude":
    do {
        if mode == "install-claude" { try ClaudeInstaller.install(helper: helper) }
        else { try ClaudeInstaller.uninstall() }
        print(mode == "install-claude" ? "Claude Code connected" : "Claude Code disconnected")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "status":
    // For scripts and status bars: counts and limits, as text or with --json.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = (try? Data(contentsOf: WardenPaths.stateFile)).flatMap { try? decoder.decode(WardenState.self, from: $0) }
    let windows = ((try? Data(contentsOf: WardenPaths.usageFile)).flatMap { try? decoder.decode([UsageWindow].self, from: $0) } ?? [])
        .sorted { ($0.provider.rawValue, $0.account ?? "", $0.durationMinutes ?? 0, $0.scope ?? "")
            < ($1.provider.rawValue, $1.account ?? "", $1.durationMinutes ?? 0, $1.scope ?? "") }
    if arguments.contains("--json") {
        let live = state.map { Date().timeIntervalSince($0.updatedAt) < 120 } ?? false
        let limits: [[String: Any]] = windows.map { window in
            var entry: [String: Any] = ["name": window.name, "usedPercent": window.usedPercent,
                                        "observedAt": ISO8601DateFormatter().string(from: window.observedAt)]
            if let reset = window.resetsAt { entry["resetsAt"] = ISO8601DateFormatter().string(from: reset) }
            return entry
        }
        var output: [String: Any] = ["limits": limits, "running": live]
        if let state, live {
            output["needsYou"] = state.needsYou
            output["working"] = state.working
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    } else {
        print(WardenState.line(state: state, windows: windows))
    }
    exit(0)
case "claude-status", "claude-event":
    break
default:
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
// Cursor and Devin also run the hooks in Claude Code's settings, for sessions of their own.
if object["cursor_version"] != nil || ProcessInfo.processInfo.environment["DEVIN_PROJECT_DIR"] != nil { exit(0) }
let rawID = (object["session_id"] as? String) ?? ""
let safeID = String(rawID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(128))
let now = Date()
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601

func agentHost() -> SessionHost {
    let pid = ProcessDetails.agentAncestor(of: getppid())
    let environment = ProcessInfo.processInfo.environment
    return SessionHost(pid: pid, processName: ProcessDetails.name(of: pid), tty: ProcessDetails.tty(of: pid),
                       bundleID: environment["__CFBundleIdentifier"], termProgram: environment["TERM_PROGRAM"])
}

func save<T: Encodable>(_ value: T, in directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? encoder.encode(value) {
        try? data.write(to: directory.appendingPathComponent("\(safeID).json"), options: .atomic)
    }
}

func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

if mode == "claude-status" {
    let workspace = object["workspace"] as? [String: Any] ?? [:]
    let model = object["model"] as? [String: Any] ?? [:]
    let context = object["context_window"] as? [String: Any] ?? [:]
    let limits = object["rate_limits"] as? [String: Any] ?? [:]
    let contextPercent = number(context["used_percentage"])
    // A second account runs with CLAUDE_CONFIG_DIR, and its limits are its own.
    let account = AgentAccount.claudeName(environment: ProcessInfo.processInfo.environment,
                                          home: FileManager.default.homeDirectoryForCurrentUser)
    var windows: [UsageWindow] = []
    for (field, label, minutes) in [("five_hour", "5h", 300), ("seven_day", "7d", 10_080)] {
        guard let value = limits[field] as? [String: Any], let percent = number(value["used_percentage"]) else { continue }
        windows.append(UsageWindow(id: UsageWindow.id(.claude, field, account: account), provider: .claude, label: label,
                                   usedPercent: percent, resetsAt: number(value["resets_at"]).map(Date.init(timeIntervalSince1970:)),
                                   observedAt: now, evidence: .provider, minutes: minutes, account: account))
    }
    if let spend = limits["spend_limit"] as? [String: Any], let percent = number(spend["used_percentage"]) {
        windows.append(TelemetryParser.extraUsage(percent, resetsAt: number(spend["resets_at"]).map(Date.init(timeIntervalSince1970:)),
                                                  observedAt: now, account: account))
    }
    if !safeID.isEmpty {
        save(BridgeStatus(sessionID: safeID,
                          cwd: (workspace["current_dir"] as? String) ?? (object["cwd"] as? String) ?? "",
                          projectDir: workspace["project_dir"] as? String,
                          sessionName: object["session_name"] as? String,
                          model: model["display_name"] as? String,
                          contextPercent: contextPercent,
                          totalTokens: (context["total_input_tokens"] as? NSNumber)?.intValue,
                          windows: windows, host: agentHost(), updatedAt: now, account: account,
                          modelID: model["id"] as? String,
                          cache: StatusCache(statusLine: object["prompt_cache"] as? [String: Any])),
             in: WardenPaths.statusDirectory)
    }

    if let index = arguments.firstIndex(of: "--chain"), index + 1 < arguments.count,
       let command = ClaudeInstaller.chainedCommand(arguments[index + 1]) {
        // Run the status line that was configured before Warden, with the same input, and show its output.
        let process = Process()
        let output = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = output
        if (try? process.run()) != nil {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            try? FileHandle.standardOutput.write(contentsOf: output.fileHandleForReading.readDataToEndOfFile())
            process.waitUntilExit()
        }
    } else {
        var parts: [String] = []
        if let name = model["display_name"] as? String { parts.append(name) }
        if let value = contextPercent { parts.append("context \(Int(value.rounded()))%") }
        for window in windows { parts.append("\(window.label) \(Int(window.usedPercent.rounded()))%") }
        print(parts.joined(separator: " · "))
    }
} else if mode == "claude-event", !safeID.isEmpty {
    let name = object["hook_event_name"] as? String ?? ""
    guard let kind = ClaudeHookEvent.kind(event: name, notification: object["notification_type"] as? String,
                                           lastMessage: object["last_assistant_message"] as? String) else { exit(0) }
    let detail: String?
    switch name {
    case "PermissionRequest": detail = (object["tool_name"] as? String).map { String($0.prefix(80)) }
    case "StopFailure": detail = ((object["error"] ?? object["error_type"]) as? String).map { String($0.prefix(40)) }
    case "Notification" where kind == "limit-wait": detail = object["notification_type"] as? String
    default: detail = nil
    }
    save(BridgeEvent(id: UUID().uuidString, sessionID: safeID, cwd: object["cwd"] as? String ?? "",
                     kind: kind, at: now, detail: detail, host: agentHost()),
         in: WardenPaths.eventDirectory)
    // Claude Code shows its prompt and runs this hook alongside it. Whichever answers first decides.
    if name == "PermissionRequest",
       let request = Approval.request(from: object, id: UUID().uuidString, sessionID: safeID),
       let answer = askWarden(request),
       let output = Approval.hookOutput(for: answer, hook: object),
       let data = try? JSONSerialization.data(withJSONObject: output) {
        FileHandle.standardOutput.write(data)
    }
}
exit(0)

/// Shows a permission request in a running Warden and waits for its answer. Returns nil at once when Warden is not
/// running, and nil later when Warden sees the prompt answered in the terminal or the user does not answer.
func askWarden(_ request: ApprovalRequest) -> ApprovalAnswer? {
    let path = Approval.socket.path
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
    }
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { return nil }
    defer { close(socket) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0, var line = try? JSONEncoder().encode(request) else { return nil }
    // Claude Code ends a hook after ten minutes; the bridge stops waiting a little earlier.
    var timeout = timeval(tv_sec: 590, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    line.append(10)
    guard line.withUnsafeBytes({ write(socket, $0.baseAddress, $0.count) }) == line.count else { return nil }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !reply.contains(10) {
        let count = read(socket, &buffer, buffer.count)
        guard count > 0 else { break }
        reply.append(buffer, count: count)
    }
    guard let end = reply.firstIndex(of: 10) else { return nil }
    return try? JSONDecoder().decode(ApprovalAnswer.self, from: reply[..<end])
}
