import Foundation
import Security

/// RSA public keys as sent by MySQL servers (PEM, `PUBLIC KEY` = SubjectPublicKeyInfo or `RSA PUBLIC KEY` = PKCS#1)
/// and the OAEP encryption used by `caching_sha2_password` / `sha256_password` full authentication.
public enum RSAPublicKey {
    /// Largest PEM accepted from a server (a 16384-bit key is ~2.9 KB).
    static let maxPEMBytes = 16 * 1024

    /// RSA-OAEP(SHA-1) of `(password + NUL) XOR nonce`.
    public static func encryptPassword(_ password: String, nonce: [UInt8], pem: String) throws -> [UInt8] {
        let key = try secKey(fromPEM: pem)
        let plaintext = AuthPlugin.xorPassword(password: password, nonce: nonce)
        var error: Unmanaged<CFError>?
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA1),
              let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(plaintext) as CFData, &error) as Data? else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unsupported key"
            throw MySQLWireError.malformed("could not encrypt with the server's RSA key: \(reason)")
        }
        return [UInt8](cipher)
    }

    public static func secKey(fromPEM pem: String) throws -> SecKey {
        guard pem.utf8.count <= maxPEMBytes else { throw MySQLWireError.malformed("RSA public key is too large") }
        let der = try decodePEM(pem)
        let pkcs1 = try pkcs1(fromDER: der)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            throw MySQLWireError.malformed("the server's RSA public key is invalid")
        }
        return key
    }

    /// Base64 body between the first `-----BEGIN` and `-----END` lines.
    static func decodePEM(_ pem: String) throws -> [UInt8] {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN") }),
              let end = lines[(begin + 1)...].firstIndex(where: { $0.hasPrefix("-----END") }) else {
            throw MySQLWireError.malformed("the server did not send a PEM public key")
        }
        let body = lines[(begin + 1)..<end].joined()
        guard let data = Data(base64Encoded: body), !data.isEmpty else {
            throw MySQLWireError.malformed("the server's public key is not valid base64")
        }
        return [UInt8](data)
    }

    /// Accepts SubjectPublicKeyInfo (rsaEncryption) or a bare PKCS#1 RSAPublicKey and returns PKCS#1.
    static func pkcs1(fromDER der: [UInt8]) throws -> [UInt8] {
        var outer = DERReader(der)
        let sequence = try outer.read(tag: 0x30)
        guard outer.isAtEnd else { throw MySQLWireError.malformed("trailing bytes after the public key") }
        var inner = DERReader(sequence)
        guard let first = inner.peekTag else { throw MySQLWireError.malformed("empty public key") }
        if first == 0x02 {
            // PKCS#1: SEQUENCE { modulus INTEGER, publicExponent INTEGER }
            _ = try inner.read(tag: 0x02)
            _ = try inner.read(tag: 0x02)
            guard inner.isAtEnd else { throw MySQLWireError.malformed("unexpected fields in the RSA public key") }
            return der
        }
        // SubjectPublicKeyInfo: SEQUENCE { AlgorithmIdentifier, BIT STRING }
        var algorithm = DERReader(try inner.read(tag: 0x30))
        let oid = try algorithm.read(tag: 0x06)
        guard oid == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01] else {
            throw MySQLWireError.malformed("the server's public key is not an RSA key")
        }
        let bits = try inner.read(tag: 0x03)
        guard let unused = bits.first, unused == 0, bits.count > 1 else { throw MySQLWireError.malformed("invalid public key bit string") }
        let key = Array(bits.dropFirst())
        _ = try pkcs1(fromDER: key) // validate the embedded PKCS#1 structure
        return key
    }
}

/// Minimal bounds-checked DER reader (definite lengths up to 4 bytes).
struct DERReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { position >= bytes.count }
    var peekTag: UInt8? { position < bytes.count ? bytes[position] : nil }

    mutating func read(tag expected: UInt8) throws -> [UInt8] {
        guard position < bytes.count, bytes[position] == expected else { throw MySQLWireError.malformed("unexpected DER tag") }
        position += 1
        guard position < bytes.count else { throw MySQLWireError.truncated("DER length") }
        let first = bytes[position]
        position += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), bytes.count - position >= count else { throw MySQLWireError.malformed("invalid DER length") }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[position])
                position += 1
            }
        }
        guard length >= 0, length <= bytes.count - position else { throw MySQLWireError.truncated("DER value") }
        defer { position += length }
        return Array(bytes[position..<(position + length)])
    }
}
