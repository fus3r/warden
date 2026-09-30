import XCTest
@testable import WardenCore

final class WebSocketTests: XCTestCase {
    /// A server frame: unmasked, with a 7 or 16-bit length.
    private func serverFrame(_ opcode: UInt8, _ payload: Data, final: Bool = true) -> Data {
        var frame = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        }
        return frame + payload
    }

    func testClientFramesAreMaskedText() {
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let short = Data(#"{"method":"initialized","params":{}}"#.utf8)
        let frame = WebSocket.frame(.text, short, mask: mask)
        XCTAssertEqual(Array(frame.prefix(2)), [0x81, 0x80 | UInt8(short.count)])
        XCTAssertEqual(Array(frame.dropFirst(2).prefix(4)), mask)
        XCTAssertEqual(Data(frame.dropFirst(6).enumerated().map { $0.element ^ mask[$0.offset % 4] }), short)
        // A longer message announces a 16-bit length.
        let long = Data(repeating: 0x61, count: 300)
        XCTAssertEqual(Array(WebSocket.frame(.text, long, mask: mask).prefix(4)), [0x81, 0xFE, 0x01, 0x2C])
    }

    func testServerMessagesArriveInPiecesFragmentsAndPings() throws {
        let request = Data(#"{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"01a0ddd9-a0d4","command":"/bin/zsh -lc 'touch approved.txt'","padding":"\#(String(repeating: "x", count: 200))"}}"#.utf8)
        let whole = serverFrame(0x1, request)
        var decoder = WebSocket.Decoder()
        decoder.append(whole.prefix(3))
        XCTAssertNil(try decoder.next())
        decoder.append(whole.dropFirst(3).prefix(100))
        XCTAssertNil(try decoder.next())
        decoder.append(whole.dropFirst(103))
        XCTAssertEqual(try decoder.next(), .text(request))
        XCTAssertNil(try decoder.next())

        // A message in two fragments, with a ping between them, then a pong to skip and a close.
        decoder.append(serverFrame(0x1, Data(#"{"method":"serverRequest/resolved","#.utf8), final: false))
        decoder.append(serverFrame(0x9, Data("hi".utf8)))
        decoder.append(serverFrame(0x0, Data(#""params":{"threadId":"01a0ddd9-a0d4","requestId":0}}"#.utf8)))
        decoder.append(serverFrame(0xA, Data()))
        decoder.append(serverFrame(0x8, Data([0x03, 0xE8])))
        XCTAssertEqual(try decoder.next(), .ping(Data("hi".utf8)))
        XCTAssertEqual(try decoder.next(), .text(Data(#"{"method":"serverRequest/resolved","params":{"threadId":"01a0ddd9-a0d4","requestId":0}}"#.utf8)))
        XCTAssertEqual(try decoder.next(), .close)
    }

    func testUpgradeAnswer() {
        let accepted = Data("HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\nsec-websocket-accept: 4//0mhQ6t/U+1KRRsA4fTAG65Cw=\r\nx-codex-websocket-max-unfragmented-message-bytes: 16777216\r\n\r\n".utf8)
        XCTAssertEqual(WebSocket.handshake(accepted.prefix(40)), .incomplete)
        XCTAssertEqual(WebSocket.handshake(accepted + Data([0x81, 0x00])), .accepted(rest: Data([0x81, 0x00])))
        XCTAssertEqual(WebSocket.handshake(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)), .refused("HTTP/1.1 400 Bad Request"))
    }
}
