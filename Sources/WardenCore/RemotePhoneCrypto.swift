import CryptoKit
import Foundation

/// The relay gets routing tokens and ciphertext, never this key. Each paired phone has a separate key.
public enum RemotePhoneCrypto {
    public enum Direction: String { case toMac = "warden.phone.toMac.v1", toPhone = "warden.phone.toPhone.v1" }
    public enum Failure: Error { case invalidKey, invalidPacket }

    public static func token() -> String { encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ text: String) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    private static func key(_ secret: String, room: String, direction: Direction) throws -> SymmetricKey {
        guard let bytes = decode(secret), bytes.count == 32 else { throw Failure.invalidKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(room.utf8),
                                      info: Data(direction.rawValue.utf8), outputByteCount: 32)
    }
    public static func seal(_ data: Data, secret: String, room: String, direction: Direction) throws -> String {
        let box = try AES.GCM.seal(data, using: key(secret, room: room, direction: direction))
        guard let combined = box.combined else { throw Failure.invalidPacket }
        return encode(combined)
    }
    public static func open(_ packet: String, secret: String, room: String, direction: Direction) throws -> Data {
        guard packet.count <= 1_000_000, let data = decode(packet), data.count >= 28 else { throw Failure.invalidPacket }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(secret, room: room, direction: direction))
    }
}
