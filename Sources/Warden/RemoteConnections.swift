import Combine
import Darwin
import Foundation
import WardenCore

struct RemoteHostState {
    enum Phase: String {
        case connecting = "Connecting", connected = "Connected", reconnecting = "Reconnecting", paused = "Paused"
        case authenticationRequired = "Authentication required"
    }
    var phase: Phase = .connecting
    var message: String?
    var receivedAt: Date?
    var retryAt: Date?
    var snapshot: RemoteSnapshot?
}

/// Each host uses a dedicated SSH connection or an encrypted HTTPS feed independently of the user's terminal.
@MainActor
final class RemoteConnections: ObservableObject {
    @Published private(set) var hosts: [RemoteSSHHost] = []
    @Published private(set) var states: [String: RemoteHostState] = [:]
    @Published private(set) var storageError: String?
    var onChange: (() -> Void)?
    private let storage: URL
    private let collector: URL?
    private let configuration: URL?
    private var streams: [String: RemoteSSHStream] = [:]
    private var feeds: [String: RemoteFeedLink] = [:]
    private var generations: [String: UUID] = [:]
    private var attemptedSockets: [String: UInt64] = [:]
    private var timer: Timer?
    private var started = false
    private var usageProviders: [String] = []

    init(storage: URL = WardenPaths.support.appendingPathComponent("remote-hosts.json"),
         collector: URL? = Bundle.main.resourceURL?.appendingPathComponent("Remote/warden-remote.py"),
         configuration: URL? = nil) {
        self.storage = storage; self.collector = collector; self.configuration = configuration
        if FileManager.default.fileExists(atPath: storage.path) {
            do {
                hosts = try JSONDecoder().decode([RemoteSSHHost].self, from: Data(contentsOf: storage))
                guard hosts.allSatisfy({ RemoteSSHHost.validDestination($0.destination) && ($0.feed?.valid ?? true) }), Set(hosts.map(\.id)).count == hosts.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                hosts = []
                storageError = "Could not read the saved SSH hosts. The file has been left unchanged."
            }
        }
        for host in hosts { states[host.id] = RemoteHostState(phase: host.enabled ? .connecting : .paused) }
    }

    func start() {
        guard !started else { return }
        started = true
        usageProviders = RemoteSSHStream.usageProviders
        for host in hosts where host.enabled { connect(host) }
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    func add(destination: String, name: String) -> Bool {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageError == nil, RemoteSSHHost.validDestination(destination), !hosts.contains(where: { $0.destination == destination }) else { return false }
        let host = RemoteSSHHost(destination: destination, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard save(hosts + [host]) else { return false }
        states[host.id] = RemoteHostState()
        if started { connect(host) }
        onChange?()
        return true
    }

    func setEnabled(_ enabled: Bool, host: RemoteSSHHost) {
        var changed = hosts
        guard let index = changed.firstIndex(where: { $0.id == host.id }) else { return }
        changed[index].enabled = enabled
        guard save(changed) else { return }
        stop(host.id)
        if !enabled, let feed = host.feed { Task { _ = try? await RemoteFeedLink.request(feed, method: "PATCH", paused: true) } }
        states[host.id] = RemoteHostState(phase: enabled ? .connecting : .paused)
        if enabled, started { connect(changed[index]) }
        onChange?()
    }

    func remove(_ host: RemoteSSHHost) {
        guard save(hosts.filter { $0.id != host.id }) else { return }
        stop(host.id)
        if let feed = host.feed { Task { _ = try? await RemoteFeedLink.request(feed, method: "DELETE") } }
        removeBootstrap(for: host)
        states.removeValue(forKey: host.id)
        onChange?()
    }

    func retry(_ host: RemoteSSHHost) {
        guard host.enabled else { return }
        stop(host.id)
        connect(host)
    }

    func authenticationCommand(for host: RemoteSSHHost) -> String? {
        let path = controlPath(for: host)
        do {
            try RemoteSSHAuthentication.prepare(path)
            return RemoteNavigation.authenticationCommand(host: host, controlPath: path.path, configuration: configuration?.path)
        } catch {
            var state = states[host.id] ?? RemoteHostState()
            state.message = "Could not prepare SSH sign-in: \(error.localizedDescription)"
            states[host.id] = state
            onChange?()
            return nil
        }
    }

    func controlPath(for host: RemoteSSHHost) -> URL {
        RemoteSSHAuthentication.controlPath(hostID: host.id, destination: host.destination, root: storage.deletingLastPathComponent())
    }

    /// The bootstrap is a private file on this Mac, delivered over SSH stdin, never installed on Linux.
    func feedCommand(for host: RemoteSSHHost, relay: String, publisherRelay: String? = nil) async throws -> String {
        var allowLocal = false
        #if DEBUG
        allowLocal = true
        #endif
        guard let url = RemoteFeed.url(relay, allowLocalHTTP: allowLocal), let collector,
              let index = hosts.firstIndex(where: { $0.id == host.id }) else { throw URLError(.badURL) }
        let feed = RemoteFeed(relay: url.absoluteString)
        _ = try await RemoteFeedLink.request(feed, method: "PUT", value: ["publisherToken": feed.publisherToken,
            "challenge": RemotePhoneCrypto.token(), "usageProviders": RemoteSSHStream.usageProviders])
        let helper = collector.deletingLastPathComponent().appendingPathComponent("warden-feed.py")
        let source = try String(contentsOf: collector, encoding: .utf8)
        guard let entry = source.range(of: "\nif __name__ == \"__main__\":", options: .backwards) else { throw CocoaError(.fileReadCorruptFile) }
        var config: [String: Any] = ["relay": feed.relay, "room": feed.room, "publisherToken": feed.publisherToken, "key": feed.key]
        #if DEBUG
        config["relay"] = publisherRelay ?? feed.relay
        config["localTest"] = allowLocal && url.scheme == "http"
        #endif
        let data = try JSONSerialization.data(withJSONObject: config)
        let encoded = data.base64EncodedString()
        let code = String(source[..<entry.lowerBound]) + "\n" + (try String(contentsOf: helper, encoding: .utf8))
            + "\nif __name__ == \"__main__\":\n    sys.exit(feed_main(json.loads(base64.b64decode(\"\(encoded)\"))))\n"
        let folder = storage.deletingLastPathComponent().appendingPathComponent("remote-bootstrap")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let bootstrap = folder.appendingPathComponent(controlPath(for: host).lastPathComponent + ".py")
        try code.write(to: bootstrap, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bootstrap.path)
        var changed = hosts
        changed[index].feed = feed; changed[index].enabled = true
        guard save(changed) else { throw CocoaError(.fileWriteUnknown) }
        stop(host.id)
        if let old = host.feed { Task { _ = try? await RemoteFeedLink.request(old, method: "DELETE") } }
        if started { connect(changed[index]) }
        let path = controlPath(for: host)
        try RemoteSSHAuthentication.prepare(path)
        let args = ["/usr/bin/ssh"] + (configuration.map { ["-F", $0.path] } ?? []) + ["-T", "-S", path.path,
            "-o", "ControlMaster=auto", "-o", "ControlPersist=5m", "-o", "BatchMode=no", "-o", "StrictHostKeyChecking=yes",
            "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "RemoteCommand=none", host.destination, "python3 -u -"]
        return args.map(SessionNavigation.shellQuote).joined(separator: " ") + " < " + SessionNavigation.shellQuote(bootstrap.path)
    }

    func useSSH(_ host: RemoteSSHHost) {
        var changed = hosts
        guard let index = changed.firstIndex(where: { $0.id == host.id }) else { return }
        changed[index].feed = nil
        guard save(changed) else { return }
        stop(host.id)
        if let feed = host.feed { Task { _ = try? await RemoteFeedLink.request(feed, method: "DELETE") } }
        removeBootstrap(for: host)
        if host.enabled, started { connect(changed[index]) }
    }

    private func removeBootstrap(for host: RemoteSSHHost) {
        let path = storage.deletingLastPathComponent().appendingPathComponent("remote-bootstrap")
            .appendingPathComponent(controlPath(for: host).lastPathComponent + ".py")
        try? FileManager.default.removeItem(at: path)
    }

    func refreshUsagePreferences() {
        let changed = RemoteSSHStream.usageProviders
        guard started, changed != usageProviders else { return }
        usageProviders = changed
        for host in hosts where host.enabled { retry(host) }
    }

    var sessions: [AgentSession] {
        hosts.filter(\.enabled).flatMap { host in
            guard let state = states[host.id], let snapshot = state.snapshot, let receivedAt = state.receivedAt else { return [AgentSession]() }
            let values = snapshot.sessions(host: host, receivedAt: receivedAt)
            return state.phase == .connected ? values : values.map(Self.unavailable)
        }
    }

    var windows: [UsageWindow] {
        hosts.filter(\.enabled).flatMap { host in
            guard let state = states[host.id], let snapshot = state.snapshot, let receivedAt = state.receivedAt else { return [UsageWindow]() }
            return snapshot.windows(host: host, receivedAt: receivedAt)
        }
    }

    var hasUncertainWork: Bool {
        hosts.filter(\.enabled).contains { host in
            guard let state = states[host.id], state.phase != .connected, let snapshot = state.snapshot else { return false }
            return snapshot.sessions(host: host, receivedAt: state.receivedAt ?? Date()).contains { $0.phase == .working || $0.phase == .needsAttention }
        }
    }

    static func unavailable(_ value: AgentSession) -> AgentSession {
        var session = value
        session.remote?.connected = false
        session.phase = .unknown; session.attention = nil; session.phaseEvidence = .inferred
        session.detail = "Remote monitoring disconnected; last known state unavailable"
        session.activeSubagents = 0; session.resumesAt = nil; session.retry = nil
        return session
    }

    func shutdown() {
        started = false; timer?.invalidate(); timer = nil
        for id in Set(streams.keys).union(feeds.keys) { stop(id) }
    }

    private func save(_ values: [RemoteSSHHost]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: storage, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.path)
            hosts = values; storageError = nil
            return true
        } catch {
            storageError = "Could not save the SSH hosts: \(error.localizedDescription)"
            return false
        }
    }

    private func stop(_ id: String) {
        generations.removeValue(forKey: id)
        streams.removeValue(forKey: id)?.stop()
        feeds.removeValue(forKey: id)?.stop()
    }

    private func connect(_ host: RemoteSSHHost) {
        let generation = UUID()
        generations[host.id] = generation
        var state = states[host.id] ?? RemoteHostState()
        state.phase = state.snapshot == nil ? .connecting : .reconnecting
        state.retryAt = nil; state.message = nil
        states[host.id] = state
        if let feed = host.feed {
            state.message = "Waiting for the temporary collector. Complete Start Temporary Collector in Terminal once."
            states[host.id] = state
            let link = RemoteFeedLink(feed: feed, usageProviders: RemoteSSHStream.usageProviders)
            feeds[host.id] = link
            link.start { [weak self] snapshot in
                guard let self, self.generations[host.id] == generation else { return }
                self.states[host.id] = RemoteHostState(phase: .connected, receivedAt: Date(), snapshot: snapshot)
                self.onChange?()
            } failed: { [weak self] message in
                guard let self, self.generations[host.id] == generation else { return }
                var state = self.states[host.id] ?? RemoteHostState()
                state.phase = .reconnecting; state.message = message
                self.states[host.id] = state; self.onChange?()
            }
            onChange?(); return
        }
        let path = controlPath(for: host)
        let socket = RemoteSSHAuthentication.socketIdentity(path)
        attemptedSockets[host.id] = socket
        let stream = RemoteSSHStream(host: host, collector: collector, configuration: configuration, controlPath: socket == nil ? nil : path)
        streams[host.id] = stream
        stream.start { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.generations[host.id] == generation else { return }
                self.states[host.id] = RemoteHostState(phase: .connected, receivedAt: Date(), snapshot: snapshot)
                self.onChange?()
            }
        } closed: { [weak self] message in
            Task { @MainActor in
                guard let self, self.generations[host.id] == generation else { return }
                self.streams.removeValue(forKey: host.id)
                var state = self.states[host.id] ?? RemoteHostState()
                let authentication = RemoteSSHAuthentication.required(message)
                state.phase = authentication ? .authenticationRequired : .reconnecting
                state.message = authentication ? "Sign in with Authenticate in Terminal, including your phone approval. Warden resumes when the shared connection is ready.\n\(message)" : message
                state.retryAt = authentication ? nil : Date().addingTimeInterval(30)
                self.states[host.id] = state
                self.onChange?()
            }
        }
        onChange?()
    }

    private func tick() {
        refreshUsagePreferences()
        let now = Date()
        for host in hosts where host.enabled {
            if host.feed == nil, states[host.id]?.phase == .authenticationRequired,
               let socket = RemoteSSHAuthentication.socketIdentity(controlPath(for: host)), socket != attemptedSockets[host.id] {
                connect(host)
            }
            if let state = states[host.id], state.phase == .connected, let received = state.receivedAt,
               now.timeIntervalSince(received) > (host.feed == nil ? 45 : 90) {
                if host.feed == nil { stop(host.id) }
                var state = state
                state.phase = .reconnecting; state.message = host.feed == nil ? "No SSH telemetry for 45 seconds." : "No HTTPS telemetry for 90 seconds. Start the temporary collector again if the server stopped it."
                state.retryAt = host.feed == nil ? now : nil
                states[host.id] = state
                onChange?()
            }
            if host.feed == nil, streams[host.id] == nil, let retry = states[host.id]?.retryAt, retry <= now { connect(host) }
        }
    }
}

/// Blocking reads run on background queues. Frames and diagnostics are bounded independently.
final class RemoteSSHStream: @unchecked Sendable {
    private let host: RemoteSSHHost
    private let collector: URL?
    private let configuration: URL?
    private let controlPath: URL?
    private let task = Process()
    private let lock = NSLock()
    private var stopped = false
    private var diagnostic = Data()
    static let frameLimit = 2 * 1024 * 1024

    static var usageProviders: [String] {
        let defaults = UserDefaults.standard
        return [("Codex", "codexAccountUsage"), ("Claude", "claudeAccountUsage")].compactMap { provider, key in
            defaults.object(forKey: key) == nil || defaults.bool(forKey: key) ? provider : nil
        }
    }

    init(host: RemoteSSHHost, collector: URL?, configuration: URL? = nil, controlPath: URL? = nil) {
        self.host = host; self.collector = collector; self.configuration = configuration; self.controlPath = controlPath
    }

    func start(snapshot: @escaping @Sendable (RemoteSnapshot) -> Void, closed: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                guard RemoteSSHHost.validDestination(host.destination), let collector else {
                    throw NSError(domain: "WardenSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled remote collector is missing."])
                }
                let providers = try JSONSerialization.data(withJSONObject: Self.usageProviders)
                var code = Data("WARDEN_USAGE_PROVIDERS = ".utf8)
                code.append(providers); code.append(Data("\n".utf8)); code.append(try Data(contentsOf: collector))
                let input = Pipe(), output = Pipe(), error = Pipe()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                task.arguments = (configuration.map { ["-F", $0.path] } ?? []) + (controlPath.map { ["-S", $0.path] } ?? []) + host.monitoringArguments
                task.standardInput = input; task.standardOutput = output; task.standardError = error
                lock.lock()
                if stopped { lock.unlock(); return }
                do { try task.run() } catch { lock.unlock(); throw error }
                lock.unlock()
                let diagnosticsDone = DispatchGroup()
                diagnosticsDone.enter()
                DispatchQueue.global(qos: .utility).async { [self] in
                    defer { diagnosticsDone.leave() }
                    while let chunk = try? Self.readChunk(error.fileHandleForReading, count: 4096) {
                        lock.lock()
                        diagnostic.append(chunk.prefix(max(0, 8192 - diagnostic.count)))
                        lock.unlock()
                    }
                }
                try input.fileHandleForWriting.write(contentsOf: code)
                try input.fileHandleForWriting.close()
                var buffer = Data()
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                while let chunk = try Self.readChunk(output.fileHandleForReading, count: 65_536) {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        guard line.count <= Self.frameLimit else { throw Self.protocolError }
                        let value = try decoder.decode(RemoteSnapshot.self, from: line)
                        guard value.version == 1 else { throw Self.protocolError }
                        snapshot(value)
                    }
                    guard buffer.count <= Self.frameLimit else { throw Self.protocolError }
                }
                task.waitUntilExit()
                diagnosticsDone.wait()
                lock.lock(); let message = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines); lock.unlock()
                closed(message?.isEmpty == false ? message! : "SSH closed. Retrying in 30 seconds.")
            } catch {
                stop()
                closed("SSH monitoring failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if task.isRunning { task.terminate() }
    }

    private static var protocolError: NSError {
        NSError(domain: "WardenSSH", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or oversized remote telemetry."])
    }

    /// Foundation's read(upToCount:) can wait for the requested count on a pipe. A single read delivers each heartbeat.
    private static func readChunk(_ handle: FileHandle, count: Int) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let length = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if length < 0, errno == EINTR { continue }
            if length < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return length == 0 ? nil : Data(buffer.prefix(length))
        }
    }
}
