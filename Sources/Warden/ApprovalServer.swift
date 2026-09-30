import Darwin
import Foundation
import WardenCore

/// Takes permission requests from the bridge over a Unix socket in a folder only the user can open, and sends back
/// the answer on the same connection. A request lives as long as its connection: when the hook ends, it is gone.
final class ApprovalServer: @unchecked Sendable {
    /// Called on the main queue with each new request, and with the id of a request whose hook ended.
    var onRequest: ((ApprovalRequest) -> Void)?
    var onGone: ((String) -> Void)?

    private let queue = DispatchQueue(label: "Warden.approvals")
    private var listener: DispatchSourceRead?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    /// The connection that holds each request, by request id.
    private var connections: [String: Int32] = [:]

    func start() {
        queue.async { self.listen() }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for fd in Array(clients.keys) { drop(fd) }
            unlink(Approval.socket.path)
        }
    }

    /// Answers a request. An undecided answer releases the hook, and the terminal's prompt decides.
    func answer(_ id: String, with answer: ApprovalAnswer) {
        queue.async {
            guard let fd = self.connections[id], var line = try? JSONEncoder().encode(answer) else { return }
            line.append(10)
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            self.drop(fd)
        }
    }

    private func listen() {
        let path = Approval.socket.path
        let folder = Approval.socket.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(folder.path, 0o700)
        unlink(path)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    private func accept(_ listening: Int32) {
        let fd = Darwin.accept(listening, nil, nil)
        guard fd >= 0 else { return }
        // Only processes of the same user may ask; the folder's permissions already keep others out.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive(fd) }
        // The descriptor closes once the source stops watching it.
        source.setCancelHandler { close(fd) }
        clients[fd] = source
        buffers[fd] = Data()
        source.resume()
    }

    private func receive(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            // The hook ended: answered in the terminal, timed out, or its session closed.
            if count == 0 || (errno != EAGAIN && errno != EINTR) { drop(fd) }
            return
        }
        buffers[fd, default: Data()].append(chunk, count: count)
        guard let buffer = buffers[fd], connections.values.contains(fd) == false else { return }
        guard buffer.count < 1 << 20 else { return drop(fd) }
        guard let end = buffer.firstIndex(of: 10) else { return }
        guard let request = try? JSONDecoder().decode(ApprovalRequest.self, from: buffer[..<end]) else { return drop(fd) }
        connections[request.id] = fd
        DispatchQueue.main.async { self.onRequest?(request) }
    }

    private func drop(_ fd: Int32) {
        guard let source = clients.removeValue(forKey: fd) else { return }
        source.cancel()
        buffers.removeValue(forKey: fd)
        for (id, connection) in connections where connection == fd {
            connections.removeValue(forKey: id)
            DispatchQueue.main.async { self.onGone?(id) }
        }
    }
}
