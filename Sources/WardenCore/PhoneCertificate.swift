import CryptoKit
import Foundation
import Security

/// The certificates that let a phone reach Warden over HTTPS on the local network. The phone trusts Warden's own root
/// once, through a configuration profile. That root can vouch only for this Mac's `.local` name, and its private key
/// is thrown away as soon as it has signed the server certificate, so it can never sign anything else.
public struct PhoneCertificate: Codable, Equatable {
    /// The root the phone trusts, in DER.
    public var root: Data
    /// The certificate Warden's server presents, in DER, for `host`.
    public var server: Data
    /// The server certificate's P-256 private key, raw.
    public var serverKey: Data
    /// The name both certificates are for, such as "Studio-MacBook-Pro.local".
    public var host: String

    /// Apple rejects server certificates valid for more than 825 days, even under a root the user installed.
    public static let lifetimeDays = 825

    /// Issues a root limited to `host` and a server certificate for `host` under it.
    public static func issue(host: String, macName: String, now: Date = Date()) throws -> PhoneCertificate {
        let rootKey = P256.Signing.PrivateKey()
        let serverKey = P256.Signing.PrivateKey()
        // An hour of margin for a phone whose clock runs slightly behind.
        let validity = DER.sequence(DER.utcTime(now.addingTimeInterval(-3600)),
                                    DER.utcTime(now.addingTimeInterval(Double(lifetimeDays) * 86_400 - 7200)))
        let version = DER.explicit(0, DER.integer(Data([2])))
        let signature = DER.sequence(DER.oid("1.2.840.10045.4.3.2"))
        // iOS lists a root in Certificate Trust Settings only when it has a common name.
        let rootName = name("Warden on \(macName)")
        let rootExtensions = DER.explicit(3, DER.sequence(
            // A CA that may sign end certificates only.
            field("2.5.29.19", critical: true, DER.sequence(DER.boolean(true), DER.integer(Data([0])))),
            // keyCertSign and cRLSign.
            field("2.5.29.15", critical: true, DER.bitString(Data([0x06]), unusedBits: 1)),
            // Name constraints: permitted subtrees [0] holding one subtree, this Mac's name, so the root cannot vouch
            // for any other site.
            field("2.5.29.30", critical: true, DER.sequence(DER.explicit(0, DER.sequence(DER.dnsName(host))))),
            field("2.5.29.14", critical: false, DER.octetString(keyID(rootKey.publicKey)))
        ))
        let rootBody = DER.sequence(version, DER.integer(serial()), signature, rootName, validity, rootName,
                                    publicKeyInfo(rootKey.publicKey), rootExtensions)
        let root = try signed(rootBody, by: rootKey, algorithm: signature)

        let serverExtensions = DER.explicit(3, DER.sequence(
            field("2.5.29.19", critical: true, DER.sequence()),
            // digitalSignature.
            field("2.5.29.15", critical: true, DER.bitString(Data([0x80]), unusedBits: 7)),
            // TLS server authentication.
            field("2.5.29.37", critical: false, DER.sequence(DER.oid("1.3.6.1.5.5.7.3.1"))),
            field("2.5.29.17", critical: false, DER.sequence(DER.dnsName(host))),
            field("2.5.29.35", critical: false, DER.sequence(DER.implicitPrimitive(0, keyID(rootKey.publicKey))))
        ))
        let serverBody = DER.sequence(version, DER.integer(serial()), signature, rootName, validity, name(host),
                                      publicKeyInfo(serverKey.publicKey), serverExtensions)
        let server = try signed(serverBody, by: rootKey, algorithm: signature)
        return PhoneCertificate(root: root, server: server, serverKey: serverKey.rawRepresentation, host: host)
    }

    /// The SHA-256 fingerprint as iOS shows it in the root's details, "3F A2 …", on two lines of 16 bytes, for a check
    /// by eye.
    public static func fingerprint(_ der: Data) -> String {
        let bytes = SHA256.hash(data: der).map { String(format: "%02X", $0) }
        return bytes.prefix(16).joined(separator: " ") + "\n" + bytes.suffix(16).joined(separator: " ")
    }

    /// When the server certificate expires, read back from its DER.
    public var expiresAt: Date? {
        guard let certificate = SecCertificateCreateWithData(nil, server as CFData) else { return nil }
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, &error)
                as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = (entry[kSecPropertyKeyValue] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// The identity a TLS listener presents: the server certificate with its key, held in memory only, so no keychain
    /// is involved and a rebuilt app never asks for access.
    public func identity() -> SecIdentity? {
        guard let certificate = SecCertificateCreateWithData(nil, server as CFData),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: serverKey) else { return nil }
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes, nil) else { return nil }
        return SecIdentityCreate(nil, certificate, secKey)
    }

    /// A configuration profile that installs the root on an iPhone or iPad. iOS then asks to turn on full trust for it
    /// in Settings → General → About → Certificate Trust Settings. Its identifier follows the Mac's name, so a profile
    /// for new certificates replaces the old one instead of piling up.
    public func profile(macName: String) -> Data {
        let identifier = "com.fus3r.Warden.phone.\(host.lowercased())"
        let payload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier + ".root",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Warden on \(macName)",
            "PayloadCertificateFileName": "Warden.cer",
            "PayloadContent": root
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Warden on \(macName)",
            "PayloadDescription": "Lets this device open Warden on \(macName) over HTTPS on your local network. The certificate is valid only for \(host).",
            "PayloadOrganization": "Warden",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload]
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
    }

    private static func name(_ commonName: String) -> Data {
        DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8(commonName))))
    }

    private static func publicKeyInfo(_ key: P256.Signing.PublicKey) -> Data {
        DER.sequence(DER.sequence(DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")),
                     DER.bitString(key.x963Representation))
    }

    private static func keyID(_ key: P256.Signing.PublicKey) -> Data {
        Data(Insecure.SHA1.hash(data: key.x963Representation))
    }

    private static func field(_ oid: String, critical: Bool, _ value: Data) -> Data {
        critical ? DER.sequence(DER.oid(oid), DER.boolean(true), DER.octetString(value))
                 : DER.sequence(DER.oid(oid), DER.octetString(value))
    }

    /// A positive 128-bit serial number.
    private static func serial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = (bytes[0] & 0x7f) | 0x01
        return Data(bytes)
    }

    private static func signed(_ body: Data, by key: P256.Signing.PrivateKey, algorithm: Data) throws -> Data {
        DER.sequence(body, algorithm, DER.bitString(try key.signature(for: body).derRepresentation))
    }
}

/// Just enough DER to write two X.509 certificates.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xff), at: 0)
                length >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: Data...) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }
    static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data { tlv(0x03, Data([unusedBits]) + data) }
    static func utf8(_ string: String) -> Data { tlv(0x0c, Data(string.utf8)) }
    static func dnsName(_ name: String) -> Data { tlv(0x82, Data(name.utf8)) }
    static func boolean(_ value: Bool) -> Data { Data([0x01, 0x01, value ? 0xff : 0x00]) }
    /// A context-specific constructed tag, such as a certificate's version [0] or extensions [3].
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xa0 | number, content) }
    /// A context-specific primitive tag, such as the key identifier [0] of an authority key identifier.
    static func implicitPrimitive(_ number: UInt8, _ content: Data) -> Data { tlv(0x80 | number, content) }

    /// A non-negative INTEGER from big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop { $0 == 0 })
        if value.isEmpty { value = Data([0]) }
        if value[value.startIndex] & 0x80 != 0 { value.insert(0, at: value.startIndex) }
        return tlv(0x02, value)
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        var body = Data([UInt8(parts[0] * 40 + parts[1])])
        for var part in parts.dropFirst(2) {
            var chunk = [UInt8(part & 0x7f)]
            part >>= 7
            while part > 0 {
                chunk.insert(UInt8(part & 0x7f) | 0x80, at: 0)
                part >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime, which covers the years up to 2049.
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }
}
