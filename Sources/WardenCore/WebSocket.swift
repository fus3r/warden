import Foundation

/// The client side of WebSocket framing (RFC 6455), which Codex's app-server daemon speaks on its Unix socket, one
/// JSON-RPC message per text frame. A client masks every frame it sends; the server's frames can arrive in pieces,
/// split into fragments, or with pings between them.
public enum WebSocket {
    public enum Opcode: UInt8 {
        case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
    }

    public enum Handshake: Equatable {
        case incomplete
        /// The server switched protocols. `rest` holds the bytes that followed its headers, the start of the first frame.
        case accepted(rest: Data)
        case refused(String)
    }

    public enum Message: Equatable {
        case text(Data)
        case ping(Data)
        case close
    }

    public enum FrameError: Error {
        case tooLarge
        case unknownOpcode
        case unexpectedFragment
    }

    /// The request that turns the connection into a WebSocket. `key` is 16 random bytes in base64.
    public static func upgradeRequest(key: String) -> Data {
        Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
    }

    /// Reads the server's answer to the upgrade request from what arrived so far.
    public static func handshake(_ received: Data) -> Handshake {
        guard let end = received.range(of: Data("\r\n\r\n".utf8)) else {
            return received.count > 16_384 ? .refused("no end to the headers") : .incomplete
        }
        let status = String(decoding: received[..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n").first ?? ""
        let parts = status.split(separator: " ")
        guard parts.count >= 2, parts[1] == "101" else { return .refused(status) }
        return .accepted(rest: Data(received[end.upperBound...]))
    }

    /// A whole frame from the client, masked with the four bytes of `mask`.
    public static func frame(_ opcode: Opcode, _ payload: Data, mask: [UInt8]) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        // The high bit of the length byte says the frame is masked; 126 and 127 announce a 16 or 64-bit length.
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(contentsOf: [UInt8(0x80 | 126), UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(UInt8(0x80 | 127))
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) })
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// Turns the server's bytes into messages as they arrive.
    public struct Decoder {
        private var buffer = Data()
        private var fragments: Data?
        private let limit: Int

        /// `limit` bounds one message; the daemon says it sends at most 16 MB unfragmented.
        public init(limit: Int = 64 << 20) {
            self.limit = limit
        }

        public mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// The next whole message, or nil until more bytes arrive. Pongs are skipped.
        public mutating func next() throws -> Message? {
            while true {
                let bytes = [UInt8](buffer.prefix(14))
                guard bytes.count >= 2 else { return nil }
                var length = Int(bytes[1] & 0x7F)
                var header = 2
                if length == 126 {
                    guard bytes.count >= 4 else { return nil }
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    header = 4
                } else if length == 127 {
                    guard bytes.count >= 10 else { return nil }
                    let value = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    guard value <= UInt64(limit) else { throw FrameError.tooLarge }
                    length = Int(value)
                    header = 10
                }
                guard length <= limit else { throw FrameError.tooLarge }
                let masked = bytes[1] & 0x80 != 0
                if masked { header += 4 }
                guard buffer.count >= header + length else { return nil }
                var payload = Data(buffer.dropFirst(header).prefix(length))
                if masked {
                    // Servers do not mask, but a masked frame still reads correctly.
                    let key = [UInt8](buffer.dropFirst(header - 4).prefix(4))
                    payload = Data(payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
                }
                buffer = Data(buffer.dropFirst(header + length))
                let final = bytes[0] & 0x80 != 0
                guard let opcode = Opcode(rawValue: bytes[0] & 0x0F) else { throw FrameError.unknownOpcode }
                switch opcode {
                case .ping:
                    return .ping(payload)
                case .pong:
                    continue
                case .close:
                    return .close
                case .text, .binary:
                    guard fragments == nil else { throw FrameError.unexpectedFragment }
                    if final { return .text(payload) }
                    fragments = payload
                case .continuation:
                    guard var message = fragments else { throw FrameError.unexpectedFragment }
                    message.append(payload)
                    guard message.count <= limit else { throw FrameError.tooLarge }
                    if final {
                        fragments = nil
                        return .text(message)
                    }
                    fragments = message
                }
            }
        }
    }
}
