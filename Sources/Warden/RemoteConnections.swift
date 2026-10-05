import Combine
import Darwin
import Foundation
import WardenCore

struct RemoteHostState {
    enum Phase: String { case connecting = "Connecting", connected = "Connected", reconnecting = "Reconnecting", paused = "Paused" }
    var phase: Phase = .connecting
    var message: String?
    var receivedAt: Date?
    var retryAt: Date?
    var snapshot: RemoteSnapshot?
}

/// One dedicated OpenSSH connection per configured host. Closing a user's terminal does not close this connection.
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
    private var generations: [String: UUID] = [:]
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
                guard hosts.allSatisfy({ RemoteSSHHost.validDestination($0.destination) }), Set(hosts.map(\.id)).count == hosts.count else {
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
        states[host.id] = RemoteHostState(phase: enabled ? .connecting : .paused)
        if enabled, started { connect(changed[index]) }
        onChange?()
    }

    func remove(_ host: RemoteSSHHost) {
        guard save(hosts.filter { $0.id != host.id }) else { return }
        stop(host.id)
        states.removeValue(forKey: host.id)
        onChange?()
    }

    func retry(_ host: RemoteSSHHost) {
        guard host.enabled else { return }
        stop(host.id)
        connect(host)
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
        session.detail = "SSH disconnected; last known state unavailable"
        session.activeSubagents = 0; session.resumesAt = nil; session.retry = nil
        return session
    }

    func shutdown() {
        started = false; timer?.invalidate(); timer = nil
        for id in Array(streams.keys) { stop(id) }
    }

    private func save(_ values: [RemoteSSHHost]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: storage, options: .atomic)
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
    }

    private func connect(_ host: RemoteSSHHost) {
        let generation = UUID()
        generations[host.id] = generation
        var state = states[host.id] ?? RemoteHostState()
        state.phase = state.snapshot == nil ? .connecting : .reconnecting
        state.retryAt = nil; state.message = nil
        states[host.id] = state
        let stream = RemoteSSHStream(host: host, collector: collector, configuration: configuration)
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
                state.phase = .reconnecting; state.message = message; state.retryAt = Date().addingTimeInterval(30)
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
            if let state = states[host.id], state.phase == .connected, let received = state.receivedAt,
               now.timeIntervalSince(received) > 45 {
                stop(host.id)
                var state = state
                state.phase = .reconnecting; state.message = "No SSH telemetry for 45 seconds."; state.retryAt = now
                states[host.id] = state
                onChange?()
            }
            if streams[host.id] == nil, let retry = states[host.id]?.retryAt, retry <= now { connect(host) }
        }
    }
}

/// Blocking reads run on background queues. Frames and diagnostics are bounded independently.
final class RemoteSSHStream: @unchecked Sendable {
    private let host: RemoteSSHHost
    private let collector: URL?
    private let configuration: URL?
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

    init(host: RemoteSSHHost, collector: URL?, configuration: URL? = nil) {
        self.host = host; self.collector = collector; self.configuration = configuration
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
                task.arguments = (configuration.map { ["-F", $0.path] } ?? []) + host.monitoringArguments
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
