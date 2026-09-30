import Darwin
import Foundation
import WardenCore

/// A connection to one Codex account's shared app-server daemon, where the `codex` terminal app runs its threads since
/// 0.157. The daemon tells every client when a thread starts waiting for approval or an answer, which Codex's logs
/// never record. Warden then joins that thread, which replays its open prompts, and leaves it once it stops waiting.
/// The daemon takes the first answer from any client, so the terminal keeps its own prompt. Commands, paths, and
/// questions stay in memory.
final class CodexDaemonClient: @unchecked Sendable {
    let account: AgentAccount
    /// Called on the main queue: a prompt to show, the id of a prompt that was answered or went away, and what each
    /// waiting session waits for, by session id.
    var onRequest: ((ApprovalRequest) -> Void)?
    var onGone: ((String) -> Void)?
    var onWaits: (([String: CodexApprovals.Wait]) -> Void)?
    /// A line for each step, for the debug harness.
    var log: ((String) -> Void)?

    private struct ThreadState {
        var cwd: String?
        /// The session Warden lists: the thread itself, or the one that spawned it.
        var session: String
        var wait: AttentionKind?
        var joined = false
    }

    private struct Prompt {
        var rpcID: Any
        var method: String
        var params: [String: Any]
        var thread: String
        var request: ApprovalRequest
    }

    private let queue = DispatchQueue(label: "Warden.codex-daemon")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// What arrived of the answer to the upgrade request, until the connection is a WebSocket.
    private var upgrade: Data?
    private var decoder = WebSocket.Decoder()
    private var nextID = 1
    private var replies: [Int: ([String: Any]?) -> Void] = [:]
    private var threads: [String: ThreadState] = [:]
    private var prompts: [String: Prompt] = [:]
    /// The files of pending file changes, by item id.
    private var edits: [String: [String]] = [:]
    private var connection = 0
    private var retryAt = Date.distantPast
    private var publishedWaits: [String: CodexApprovals.Wait] = [:]

    init(account: AgentAccount) {
        self.account = account
    }

    /// Connects when the daemon's socket exists and no connection is open. Called on each scan, which also reconnects
    /// after the daemon restarts.
    func connectIfNeeded() {
        queue.async { self.connect() }
    }

    func disconnect() {
        queue.sync { self.close(retryAfter: 0) }
    }

    /// Sends an answer you chose. False when the prompt went away or does not offer that answer.
    func answer(_ id: String, with answer: ApprovalAnswer) -> Bool {
        queue.sync {
            guard fd >= 0, let prompt = prompts[id],
                  let result = CodexApprovals.result(for: answer, method: prompt.method, params: prompt.params) else { return false }
            send(["id": prompt.rpcID, "result": result])
            prompts[id] = nil
            log?("answered \(id): \(result)")
            return true
        }
    }

    // MARK: Connection

    private func connect() {
        guard fd < 0, Date() >= retryAt else { return }
        let path = CodexApprovals.socket(in: account.folder).path
        guard FileManager.default.fileExists(atPath: path) else { return }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            retryAt = Date().addingTimeInterval(30)
            return
        }
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        fd = socket
        connection += 1
        upgrade = Data()
        decoder = WebSocket.Decoder()
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(socket) }
        source.resume()
        self.source = source
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        write(WebSocket.upgradeRequest(key: key))
        log?("connecting to \(path)")
    }

    /// Ends the connection and withdraws its prompts. The next scan connects again after `retryAfter` seconds.
    private func close(retryAfter: TimeInterval, reason: String? = nil) {
        guard fd >= 0 else { return }
        source?.cancel()
        source = nil
        fd = -1
        upgrade = nil
        replies = [:]
        threads = [:]
        edits = [:]
        retryAt = Date().addingTimeInterval(retryAfter)
        let gone = Array(prompts.keys)
        prompts = [:]
        if let reason { log?("disconnected: \(reason)") }
        DispatchQueue.main.async { gone.forEach { self.onGone?($0) } }
        publishWaits()
    }

    /// Reads everything the daemon sent, so it never waits on Warden: the daemon drops a client that falls behind.
    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while fd >= 0 {
            let count = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if count > 0 {
                receive(Data(chunk[0..<count]))
            } else {
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { close(retryAfter: 0, reason: "closed") }
                return
            }
        }
    }

    private func receive(_ data: Data) {
        if var answer = upgrade {
            answer.append(data)
            switch WebSocket.handshake(answer) {
            case .incomplete:
                upgrade = answer
                return
            case .refused(let status):
                close(retryAfter: 600, reason: "refused: \(status)")
                return
            case .accepted(let rest):
                upgrade = nil
                decoder.append(rest)
                initialize()
            }
        } else {
            decoder.append(data)
        }
        do {
            while fd >= 0, let message = try decoder.next() {
                switch message {
                case .text(let payload): handle(payload)
                case .ping(let payload): write(WebSocket.frame(.pong, payload, mask: mask()))
                case .close: close(retryAfter: 0, reason: "the daemon closed the connection")
                }
            }
        } catch {
            close(retryAfter: 30, reason: "unreadable frame")
        }
    }

    private func initialize() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        call("initialize", CodexApprovals.initializeParams(version: version)) { [weak self] result in
            guard let self else { return }
            let agent = result?["userAgent"] as? String ?? ""
            guard CodexApprovals.isSupported(userAgent: agent) else {
                // Before 0.157 the daemon did not host the terminal's threads; check again in ten minutes.
                self.close(retryAfter: 600, reason: "unsupported daemon \(agent)")
                return
            }
            self.log?("connected: \(agent)")
            self.send(["method": "initialized", "params": [String: Any]()])
            // Threads that already wait, such as one whose prompt opened before Warden started.
            self.call("thread/loaded/list", [:]) { result in
                for id in result?["data"] as? [String] ?? [] { self.read(id) }
            }
        }
    }

    // MARK: Messages

    private func handle(_ payload: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let method = message["method"] as? String {
            if let rpcID = message["id"] {
                request(method, rpcID: rpcID, params: params)
            } else {
                notification(method, params: params)
            }
        } else if let id = (message["id"] as? NSNumber)?.intValue, let reply = replies.removeValue(forKey: id) {
            if let error = message["error"] { log?("error: \(error)") }
            reply(message["result"] as? [String: Any])
        }
    }

    private func notification(_ method: String, params: [String: Any]) {
        guard let thread = params["threadId"] as? String else { return }
        switch method {
        case "thread/status/changed":
            let wait = CodexApprovals.waits(inStatus: params["status"] as? [String: Any])
            guard threads[thread] != nil else {
                // A thread Warden has not met yet: its folder and parent come with a read, only once it waits.
                if wait != nil { read(thread) }
                return
            }
            threads[thread]?.wait = wait
            follow(thread)
        case "serverRequest/resolved":
            // Answered in the terminal, by Warden, or withdrawn when the turn ended.
            guard let rpcID = params["requestId"] else { return }
            let key = promptID(thread: thread, rpcID: rpcID)
            guard prompts.removeValue(forKey: key) != nil else { return }
            log?("resolved \(key)")
            DispatchQueue.main.async { self.onGone?(key) }
            publishWaits()
        case "thread/closed":
            threads[thread] = nil
            let gone = prompts.filter { $0.value.thread == thread }.map(\.key)
            gone.forEach { prompts[$0] = nil }
            DispatchQueue.main.async { gone.forEach { self.onGone?($0) } }
            publishWaits()
        case "item/started":
            // A file change Warden sees start, while it follows the thread, before its request comes.
            if let item = params["item"] as? [String: Any], let change = CodexApprovals.fileChange(item) {
                edits[change.id] = change.paths
            }
        default:
            break
        }
    }

    private func request(_ method: String, rpcID: Any, params: [String: Any]) {
        guard let thread = params["threadId"] as? String else { return }
        let key = promptID(thread: thread, rpcID: rpcID)
        // Joining a thread again replays prompts Warden already shows.
        guard prompts[key] == nil else { return }
        let state = threads[thread]
        let rules = (account.folder.appendingPathComponent("rules/default.rules").path as NSString).abbreviatingWithTildeInPath
        guard var request = CodexApprovals.request(method: method, params: params, id: key, sessionID: state?.session ?? thread,
                                                   cwd: state?.cwd, paths: (params["itemId"] as? String).flatMap { edits[$0] } ?? [],
                                                   rules: rules) else {
            log?("left to the terminal: \(method)")
            return
        }
        request.account = account.name
        prompts[key] = Prompt(rpcID: rpcID, method: method, params: params, thread: thread, request: request)
        log?("prompt \(key): \(request.tool) \(request.summary ?? "")")
        DispatchQueue.main.async { self.onRequest?(request) }
        publishWaits()
    }

    // MARK: Threads

    private func read(_ thread: String) {
        call("thread/read", ["threadId": thread]) { [weak self] result in
            guard let self, let info = result?["thread"] as? [String: Any] else { return }
            var state = self.threads[thread] ?? ThreadState(session: thread)
            state.cwd = info["cwd"] as? String
            state.session = info["parentThreadId"] as? String ?? thread
            state.wait = CodexApprovals.waits(inStatus: info["status"] as? [String: Any])
            self.threads[thread] = state
            self.follow(thread)
        }
    }

    /// Joins a thread that waits, which replays its open prompts, and leaves one that stopped waiting, so the daemon
    /// can unload it once its terminal closes.
    private func follow(_ thread: String) {
        guard let state = threads[thread] else { return }
        if state.wait != nil, !state.joined {
            threads[thread]?.joined = true
            log?("joining \(thread)")
            let params: [String: Any] = ["threadId": thread, "excludeTurns": true,
                                         "initialTurnsPage": ["limit": 1, "itemsView": "full"]]
            call("thread/resume", params) { [weak self] result in
                guard let self else { return }
                guard let result else {
                    self.threads[thread]?.joined = false
                    return
                }
                // The current turn holds the edits of a pending file change; its request names only the item.
                for (item, paths) in CodexApprovals.fileChanges(inPage: result["initialTurnsPage"] as? [String: Any]) {
                    self.edits[item] = paths
                }
            }
        } else if state.wait == nil, state.joined {
            threads[thread]?.joined = false
            log?("leaving \(thread)")
            call("thread/unsubscribe", ["threadId": thread], then: nil)
        }
        publishWaits()
    }

    private func publishWaits() {
        var waits: [String: CodexApprovals.Wait] = [:]
        for (id, state) in threads {
            guard let kind = state.wait else { continue }
            let asked = prompts.values.first { $0.thread == id }?.request
            let detail = kind == .choice ? asked?.questions.first?.text : asked?.tool
            // A prompt of the session itself comes before one of a thread it spawned.
            if waits[state.session] == nil || id == state.session {
                waits[state.session] = CodexApprovals.Wait(kind: kind, detail: detail)
            }
        }
        guard waits != publishedWaits else { return }
        publishedWaits = waits
        DispatchQueue.main.async { self.onWaits?(waits) }
    }

    // MARK: Sending

    private func promptID(thread: String, rpcID: Any) -> String {
        "codex-\(connection)-\(thread)-\(rpcID)"
    }

    private func call(_ method: String, _ params: [String: Any], then reply: (([String: Any]?) -> Void)?) {
        let id = nextID
        nextID += 1
        if let reply { replies[id] = reply }
        send(["id": id, "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        write(WebSocket.frame(.text, data, mask: mask()))
    }

    private func write(_ data: Data) {
        guard fd >= 0 else { return }
        let failed = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return true
                }
            }
            return false
        }
        if failed { close(retryAfter: 0, reason: "write failed") }
    }

    private func mask() -> [UInt8] {
        (0..<4).map { _ in UInt8.random(in: 0...255) }
    }
}
