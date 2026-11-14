import CryptoKit
import Foundation
import Security
import Testing
@testable import MySQLWire

@Suite("TLS request and capabilities")
struct TLSRequestTests {
    @Test func sslRequestIs32BytesWithSSLFlag() {
        let request = SSLRequest(capabilities: [.protocol41, .secureConnection, .pluginAuth])
        let bytes = request.encode()
        #expect(bytes.count == 32)
        var reader = PayloadReader(bytes)
        let capabilities = Capabilities(rawValue: (try? reader.readUInt32()) ?? 0)
        #expect(capabilities.contains(.ssl))
        #expect(capabilities.contains(.protocol41))
        #expect((try? reader.readUInt32()) == 16 * 1024 * 1024)
        #expect((try? reader.readUInt8()) == 45)
        #expect(bytes[9...].allSatisfy { $0 == 0 })
    }

    @Test func handshakeResponseAfterTLSKeepsSSLFlag() {
        let response = HandshakeResponse41(capabilities: [.protocol41, .secureConnection, .pluginAuth, .ssl, .pluginAuthLenencData],
                                           username: "u", authResponse: [1, 2, 3], database: nil, authPluginName: "caching_sha2_password")
        var reader = PayloadReader(response.encode())
        let capabilities = Capabilities(rawValue: (try? reader.readUInt32()) ?? 0)
        #expect(capabilities.contains(.ssl))
    }

    /// MariaDB greeting: "5.5.5-" version prefix, CLIENT_MYSQL (bit 0) cleared and extended capabilities in the
    /// last four reserved bytes.
    @Test func parsesMariaDBGreeting() throws {
        var writer = PayloadWriter()
        writer.writeUInt8(10)
        writer.writeNullTerminated("5.5.5-10.11.6-MariaDB-1:10.11.6+maria~ubu2204")
        writer.writeUInt32(99)
        writer.writeBytes(Array(1...8))
        writer.writeUInt8(0)
        let capabilities: UInt32 = (Capabilities.client.rawValue | Capabilities.ssl.rawValue) & ~Capabilities.longPassword.rawValue
        writer.writeUInt16(UInt16(truncatingIfNeeded: capabilities))
        writer.writeUInt8(45)
        writer.writeUInt16(2)
        writer.writeUInt16(UInt16(truncatingIfNeeded: capabilities >> 16))
        writer.writeUInt8(21)
        writer.writeBytes([UInt8](repeating: 0, count: 6))
        writer.writeUInt32(0x0000_001D) // MariaDB extended capabilities
        writer.writeBytes(Array(9...20) + [0])
        writer.writeNullTerminated("mysql_native_password")
        let greeting = try HandshakeV10(payload: writer.bytes)
        #expect(greeting.serverVersion.hasPrefix("5.5.5-10.11.6-MariaDB"))
        #expect(greeting.isMariaDB)
        #expect(greeting.mariaDBExtendedCapabilities == 0x1D)
        #expect(greeting.capabilities.contains(.ssl))
        #expect(greeting.scramble == Array(1...20))
        #expect(greeting.connectionID == 99)
    }

    @Test func serverStatusFlags() {
        let status = ServerStatus(rawValue: 0x0203)
        #expect(status.contains(.inTransaction))
        #expect(status.contains(.autocommit))
        #expect(status.contains(.noBackslashEscapes))
        #expect(!status.contains(.moreResultsExist))
    }

    @Test func resetConnectionCommand() {
        #expect(Command.resetConnection == [0x1F])
        #expect(Command.query("SELECT 1") == [0x03] + Array("SELECT 1".utf8))
    }
}

@Suite("Authentication plugins")
struct AuthPluginTests {
    /// Reference value computed independently: SHA256(p) XOR SHA256(SHA256(SHA256(p)) || nonce).
    @Test func cachingSHA2ScrambleMatchesDefinition() {
        let password = "secret"
        let nonce = Array<UInt8>(repeating: 7, count: 20)
        let stage1 = Array(SHA256.hash(data: Array(password.utf8)))
        let stage2 = Array(SHA256.hash(data: stage1))
        let stage3 = Array(SHA256.hash(data: stage2 + nonce))
        let expected = zip(stage1, stage3).map { $0 ^ $1 }
        #expect(AuthPlugin.cachingSHA2Scramble(password: password, nonce: nonce) == expected)
        #expect(AuthPlugin.cachingSHA2Scramble(password: "", nonce: nonce).isEmpty)
    }

    @Test func xorPasswordRepeatsNonce() {
        let nonce: [UInt8] = [1, 2, 3]
        let result = AuthPlugin.xorPassword(password: "abcd", nonce: nonce)
        let plain = Array("abcd".utf8) + [0]
        #expect(result == plain.enumerated().map { $0.element ^ nonce[$0.offset % 3] })
        #expect(AuthPlugin.xorPassword(password: "abc", nonce: []) == Array("abc".utf8) + [0])
    }

    @Test func rsaOAEPRoundTripWithSPKIAndPKCS1PEM() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
        // Wrap PKCS#1 into SubjectPublicKeyInfo like MySQL's PEM files.
        let spki = RSAKeyTestSupport.subjectPublicKeyInfo(pkcs1: [UInt8](pkcs1))
        let nonce = Array<UInt8>(repeating: 0x5A, count: 20)
        for pem in [RSAKeyTestSupport.pem(spki, label: "PUBLIC KEY"), RSAKeyTestSupport.pem([UInt8](pkcs1), label: "RSA PUBLIC KEY")] {
            let cipher = try RSAPublicKey.encryptPassword("pässword", nonce: nonce, pem: pem)
            #expect(cipher.count == 256)
            let decrypted = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, Data(cipher) as CFData, &error) as Data?)
            #expect([UInt8](decrypted) == AuthPlugin.xorPassword(password: "pässword", nonce: nonce))
        }
    }

    @Test func rejectsGarbagePEM() {
        #expect(throws: MySQLWireError.self) { try RSAPublicKey.encryptPassword("x", nonce: [1], pem: "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----") }
        #expect(throws: MySQLWireError.self) { try RSAPublicKey.encryptPassword("x", nonce: [1], pem: "not a key") }
    }

    @Test func derParserNeverCrashesOnRandomInput() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3_000 {
            let count = Int.random(in: 0..<200, using: &generator)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if !bytes.isEmpty, Bool.random(using: &generator) { bytes[0] = 0x30 }
            _ = try? RSAPublicKey.pkcs1(fromDER: bytes)
        }
    }

    // RFC 8032 section 7.1, tests 1–3 (the 32-byte secret is used as MariaDB's "password").
    static let ed25519Vectors: [(secret: String, publicKey: String, message: String, signature: String)] = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]

    @Test(arguments: 0..<3)
    func ed25519MatchesRFC8032(index: Int) {
        let vector = Self.ed25519Vectors[index]
        let secret = Hex.bytes(vector.secret)
        #expect(Hex.string(Ed25519.publicKey(password: secret)) == vector.publicKey)
        #expect(Hex.string(Ed25519.sign(message: Hex.bytes(vector.message), password: secret)) == vector.signature)
    }

    /// Passwords of any length work (MariaDB hashes the whole password), and CryptoKit verifies the signature.
    @Test func ed25519SignatureVerifiesForArbitraryPasswords() throws {
        for password in ["", "a", "correct horse battery staple", String(repeating: "ü", count: 100)] {
            let bytes = Array(password.utf8)
            let message = Array<UInt8>(repeating: 0x42, count: 32)
            let signature = Ed25519.sign(message: message, password: bytes)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: Ed25519.publicKey(password: bytes))
            #expect(key.isValidSignature(Data(signature), for: Data(message)))
        }
    }
}

enum Hex {
    static func bytes(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex, let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
            bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    static func string(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

enum RSAKeyTestSupport {
    static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        if length < 0x100 { return [0x81, UInt8(length)] }
        return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
    }

    static func subjectPublicKeyInfo(pkcs1: [UInt8]) -> [UInt8] {
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString: [UInt8] = [0x03] + derLength(pkcs1.count + 1) + [0x00] + pkcs1
        let body = algorithm + bitString
        return [0x30] + derLength(body.count) + body
    }

    static func pem(_ der: [UInt8], label: String) -> String {
        let base64 = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}
