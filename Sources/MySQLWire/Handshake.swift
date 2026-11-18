import CryptoKit

/// Client/server capability flags (subset used by this client).
public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Also `CLIENT_MYSQL`: MariaDB servers clear it to announce extended capabilities.
    public static let longPassword = Capabilities(rawValue: 1 << 0)
    public static let foundRows = Capabilities(rawValue: 1 << 1)
    public static let longFlag = Capabilities(rawValue: 1 << 2)
    public static let connectWithDB = Capabilities(rawValue: 1 << 3)
    public static let localFiles = Capabilities(rawValue: 1 << 7)
    public static let protocol41 = Capabilities(rawValue: 1 << 9)
    public static let interactive = Capabilities(rawValue: 1 << 10)
    public static let ssl = Capabilities(rawValue: 1 << 11)
    public static let transactions = Capabilities(rawValue: 1 << 13)
    public static let secureConnection = Capabilities(rawValue: 1 << 15)
    public static let multiStatements = Capabilities(rawValue: 1 << 16)
    public static let multiResults = Capabilities(rawValue: 1 << 17)
    public static let psMultiResults = Capabilities(rawValue: 1 << 18)
    public static let pluginAuth = Capabilities(rawValue: 1 << 19)
    public static let connectAttrs = Capabilities(rawValue: 1 << 20)
    public static let pluginAuthLenencData = Capabilities(rawValue: 1 << 21)
    public static let canHandleExpiredPasswords = Capabilities(rawValue: 1 << 22)
    public static let sessionTrack = Capabilities(rawValue: 1 << 23)
    public static let deprecateEOF = Capabilities(rawValue: 1 << 24)

    /// What this client asks for (intersected with the server's flags at handshake time).
    /// Multi-statement mode is deliberately not requested: the app splits scripts itself, so a lexer
    /// disagreement with the server can never turn one statement into several. LOCAL INFILE is never
    /// requested either, so a hostile server cannot ask for local files.
    public static let client: Capabilities = [.longPassword, .longFlag, .protocol41, .transactions, .secureConnection,
                                              .multiResults, .pluginAuth, .pluginAuthLenencData,
                                              .connectWithDB, .connectAttrs, .canHandleExpiredPasswords]

    /// Assumed when parsing packets outside a negotiated session (tests, fuzzing).
    public static let standard: Capabilities = [.protocol41, .secureConnection, .pluginAuth]
}

/// Server status flags carried by OK and EOF packets.
public struct ServerStatus: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let inTransaction = ServerStatus(rawValue: 0x0001)
    public static let autocommit = ServerStatus(rawValue: 0x0002)
    public static let moreResultsExist = ServerStatus(rawValue: 0x0008)
    public static let noBackslashEscapes = ServerStatus(rawValue: 0x0200)
    public static let inReadOnlyTransaction = ServerStatus(rawValue: 0x2000)
    public static let sessionStateChanged = ServerStatus(rawValue: 0x4000)
}

/// Server greeting (protocol version 10).
public struct HandshakeV10: Sendable, Equatable {
    public let serverVersion: String
    public let connectionID: UInt32
    public let scramble: [UInt8]
    public let capabilities: Capabilities
    public let characterSet: UInt8
    public let statusFlags: UInt16
    public let authPluginName: String?
    /// MariaDB extended capabilities (reserved bytes 7–10), 0 for MySQL.
    public let mariaDBExtendedCapabilities: UInt32

    public init(payload: [UInt8]) throws {
        var reader = PayloadReader(payload)
        let protocolVersion = try reader.readUInt8()
        if protocolVersion == 0xFF {
            // Connection refused before the handshake (e.g. too many connections).
            _ = try? reader.readUInt16()
            throw MySQLWireError.malformed("server refused the connection: \(String(decoding: reader.readRest(), as: UTF8.self))")
        }
        guard protocolVersion == 10 else { throw MySQLWireError.malformed("unsupported protocol version \(protocolVersion)") }
        serverVersion = try reader.readNullTerminatedString()
        connectionID = try reader.readUInt32()
        var scramble = try reader.readBytes(8)
        try reader.skip(1)
        var capabilityBits = UInt32(try reader.readUInt16())
        var characterSet: UInt8 = 33
        var statusFlags: UInt16 = 0
        var pluginName: String?
        var extended: UInt32 = 0
        if !reader.isAtEnd {
            characterSet = try reader.readUInt8()
            statusFlags = try reader.readUInt16()
            capabilityBits |= UInt32(try reader.readUInt16()) << 16
            let authDataLength = Int(try reader.readUInt8())
            try reader.skip(6)
            let reservedTail = try reader.readUInt32()
            if capabilityBits & Capabilities.longPassword.rawValue == 0 { extended = reservedTail }
            let capabilities = Capabilities(rawValue: capabilityBits)
            if capabilities.contains(.secureConnection) {
                let part2Length = max(13, authDataLength - 8)
                let part2 = try reader.readBytes(min(part2Length, reader.remaining))
                // The second part is NUL-terminated; the scramble itself is 20 bytes in total.
                scramble += part2.prefix(12)
            }
            if capabilities.contains(.pluginAuth), !reader.isAtEnd {
                pluginName = try reader.readNullTerminatedString()
            }
        }
        self.scramble = scramble
        capabilities = Capabilities(rawValue: capabilityBits)
        self.characterSet = characterSet
        self.statusFlags = statusFlags
        authPluginName = pluginName
        mariaDBExtendedCapabilities = extended
    }

    /// MariaDB announces itself in the version string (and by clearing CLIENT_MYSQL).
    public var isMariaDB: Bool { serverVersion.range(of: "MariaDB", options: .caseInsensitive) != nil }
}

/// The short packet that asks the server to switch to TLS before the handshake response.
public struct SSLRequest: Sendable, Equatable {
    public var capabilities: Capabilities
    public var maxPacketSize: UInt32 = 16 * 1024 * 1024
    public var characterSet: UInt8 = 45 // utf8mb4_general_ci

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities.union(.ssl)
    }

    public func encode() -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt32(capabilities.rawValue)
        writer.writeUInt32(maxPacketSize)
        writer.writeUInt8(characterSet)
        writer.writeBytes([UInt8](repeating: 0, count: 23))
        return writer.bytes
    }
}

/// Client reply to the greeting.
public struct HandshakeResponse41: Sendable {
    public var capabilities: Capabilities
    public var maxPacketSize: UInt32 = 16 * 1024 * 1024
    public var characterSet: UInt8 = 45 // utf8mb4_general_ci
    public var username: String
    public var authResponse: [UInt8]
    public var database: String?
    public var authPluginName: String?
    public var attributes: [(String, String)] = []

    /// The first field a NUL would end early ("user name", "database name", "authentication plugin name"), `nil` when none
    /// holds one. The encoder cannot carry NUL in them: callers refuse such a response instead of sending a different name.
    public var fieldWithNUL: String? {
        if username.utf8.contains(0) { return "user name" }
        if database?.utf8.contains(0) == true { return "database name" }
        if authPluginName?.utf8.contains(0) == true { return "authentication plugin name" }
        return nil
    }

    public init(capabilities: Capabilities, username: String, authResponse: [UInt8], database: String?, authPluginName: String?,
                attributes: [(String, String)] = []) {
        self.capabilities = capabilities
        self.username = username
        self.authResponse = authResponse
        self.database = database
        self.authPluginName = authPluginName
        self.attributes = attributes
    }

    public func encode() -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt32(capabilities.rawValue)
        writer.writeUInt32(maxPacketSize)
        writer.writeUInt8(characterSet)
        writer.writeBytes([UInt8](repeating: 0, count: 23))
        writer.writeNullTerminated(username)
        if capabilities.contains(.pluginAuthLenencData) {
            writer.writeLengthEncodedBytes(authResponse)
        } else if capabilities.contains(.secureConnection) {
            writer.writeUInt8(UInt8(clamping: authResponse.count))
            writer.writeBytes(authResponse.prefix(255))
        } else {
            writer.writeBytes(authResponse)
            writer.writeUInt8(0)
        }
        if capabilities.contains(.connectWithDB) { writer.writeNullTerminated(database ?? "") }
        if capabilities.contains(.pluginAuth) { writer.writeNullTerminated(authPluginName ?? "") }
        if capabilities.contains(.connectAttrs) {
            var attributesWriter = PayloadWriter()
            for (key, value) in attributes {
                attributesWriter.writeLengthEncodedString(key)
                attributesWriter.writeLengthEncodedString(value)
            }
            writer.writeLengthEncodedBytes(attributesWriter.bytes)
        }
        return writer.bytes
    }
}

public enum AuthPlugin {
    public static let nativePasswordName = "mysql_native_password"
    public static let cachingSHA2Name = "caching_sha2_password"
    public static let sha256Name = "sha256_password"
    public static let clearPasswordName = "mysql_clear_password"
    public static let ed25519Name = "client_ed25519"

    /// `caching_sha2_password` AuthMoreData status bytes.
    public static let cachingSHA2FastAuthSuccess: UInt8 = 0x03
    public static let cachingSHA2PerformFullAuth: UInt8 = 0x04
    /// Client requests for the server's RSA public key.
    public static let cachingSHA2RequestPublicKey: UInt8 = 0x02
    public static let sha256RequestPublicKey: UInt8 = 0x01

    /// `SHA1(password) XOR SHA1(scramble + SHA1(SHA1(password)))`; empty for an empty password.
    public static func nativePassword(password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(Insecure.SHA1.hash(data: Array(password.utf8)))
        let stage2 = Array(Insecure.SHA1.hash(data: stage1))
        let stage3 = Array(Insecure.SHA1.hash(data: Array(scramble.prefix(20)) + stage2))
        return zip(stage1, stage3).map { $0 ^ $1 }
    }

    /// `SHA256(p) XOR SHA256(SHA256(SHA256(p)) + nonce)`; empty for an empty password.
    public static func cachingSHA2Scramble(password: String, nonce: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(SHA256.hash(data: Array(password.utf8)))
        let stage2 = Array(SHA256.hash(data: stage1))
        let stage3 = Array(SHA256.hash(data: stage2 + Array(nonce.prefix(20))))
        return zip(stage1, stage3).map { $0 ^ $1 }
    }

    /// `(password + NUL) XOR nonce` (nonce repeated), the plaintext of RSA-encrypted full authentication.
    public static func xorPassword(password: String, nonce: [UInt8]) -> [UInt8] {
        let plain = Array(password.utf8) + [0]
        guard !nonce.isEmpty else { return plain }
        return plain.enumerated().map { $0.element ^ nonce[$0.offset % nonce.count] }
    }

    /// Cleartext password; only safe inside TLS or an SSH tunnel.
    public static func clearPassword(password: String) -> [UInt8] {
        Array(password.utf8) + [0]
    }
}
