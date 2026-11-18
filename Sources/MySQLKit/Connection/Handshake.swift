import Foundation
import MySQLWire

/// What the connection phase negotiated (shown in connection details, used for decisions later).
public struct HandshakeOutcome: Sendable, Equatable {
    public let greeting: HandshakeV10
    public let capabilities: Capabilities
    public let isTLS: Bool
    /// The plugin that finally authenticated the session.
    public let authPlugin: String
    /// Status flags of the final OK packet.
    public let statusFlags: UInt16
}

/// Connection phase (design D2/D3): greeting → [SSLRequest + TLS] → HandshakeResponse41 → auth rounds → OK.
enum Handshake {
    static let maxAuthRounds = 8

    static func perform(transport: any ByteTransport, configuration: ConnectionConfiguration) async throws -> (PacketChannel, HandshakeOutcome) {
        var channel = PacketChannel(transport: transport)
        let greetingPayload = try await channel.read()
        if greetingPayload.first == 0xFF {
            // Refused before the handshake (host blocked, too many connections).
            throw MySQLError.server(try ServerPacket.parseError(greetingPayload))
        }
        let greeting = try HandshakeV10(payload: greetingPayload)
        guard greeting.capabilities.contains(.protocol41) else {
            throw MySQLError(.protocolViolation, "\(configuration.endpoint) does not speak MySQL protocol 4.1 (MySQL 4.1 or later is required)")
        }

        let database = configuration.database?.trimmingCharacters(in: .whitespaces)
        // A handshake string ends at NUL: refuse a name holding one before anything is sent, rather than send a different
        // name than the one given (and checked).
        let names = HandshakeResponse41(capabilities: [], username: configuration.username, authResponse: [], database: database,
                                        authPluginName: greeting.authPluginName)
        if let field = names.fieldWithNUL {
            throw MySQLError(.invalidArgument, "The \(field) contains a NUL character, which a MySQL handshake cannot carry; nothing was sent.")
        }
        var capabilities = Capabilities.client.intersection(greeting.capabilities).union(.protocol41)
        if database?.isEmpty != false { capabilities.remove(.connectWithDB) }

        let tlsMode = configuration.tls.mode
        let serverOffersTLS = greeting.capabilities.contains(.ssl)
        if tlsMode.requiresTLS, !serverOffersTLS {
            throw MySQLError(.tls, "\(configuration.endpoint) does not support TLS, but this connection requires it. Configure TLS on the server or change the TLS mode.")
        }
        let useTLS = tlsMode != .disabled && serverOffersTLS
        if useTLS {
            capabilities.insert(.ssl)
            try await channel.write(SSLRequest(capabilities: capabilities).encode())
            try transport.startTLS(configuration.tls)
        }

        var auth = AuthExchange(configuration: configuration, isSecure: useTLS, nonce: greeting.scramble)
        let initialPlugin = greeting.authPluginName ?? AuthPlugin.nativePasswordName
        let initialToken = try auth.start(plugin: initialPlugin, isSwitchRequest: false)
        let response = HandshakeResponse41(capabilities: capabilities, username: configuration.username, authResponse: initialToken,
                                           database: capabilities.contains(.connectWithDB) ? database : nil,
                                           authPluginName: auth.plugin, attributes: attributes(configuration))
        try await channel.write(response.encode())

        // Bounded: a hostile server cannot keep us switching plugins forever.
        for _ in 0..<maxAuthRounds {
            let reply = try await channel.read()
            switch try ServerPacket.parse(reply, capabilities: capabilities) {
            case let .ok(ok):
                return (channel, HandshakeOutcome(greeting: greeting, capabilities: capabilities, isTLS: useTLS, authPlugin: auth.plugin,
                                                  statusFlags: ok.statusFlags))
            case let .error(packet):
                throw MySQLError.server(packet)
            case let .authSwitch(newPlugin, data):
                let token = try auth.start(plugin: newPlugin, nonce: data.isEmpty ? greeting.scramble : data, isSwitchRequest: true)
                try await channel.write(token)
            case let .authMoreData(data):
                if let token = try auth.continueWith(data) {
                    try await channel.write(token)
                }
            case .eof, .other:
                throw MySQLError(.protocolViolation, "Unexpected packet during authentication")
            }
        }
        throw MySQLError(.protocolViolation, "Authentication did not complete after \(maxAuthRounds) rounds")
    }

    static func attributes(_ configuration: ConnectionConfiguration) -> [(String, String)] {
        [("_client_name", String(configuration.applicationName.prefix(64))), ("_client_version", "1.2.0"), ("_os", "macOS"),
         ("_pid", String(ProcessInfo.processInfo.processIdentifier)), ("program_name", String(configuration.applicationName.prefix(64)))]
    }
}

/// Authentication plugin logic (design D3) as a small state machine, independent of I/O.
struct AuthExchange {
    enum Step: Equatable {
        case idle
        /// caching_sha2_password: waiting for 0x03 (fast auth ok) or 0x04 (full auth needed).
        case cachingSHA2AwaitingStatus
        /// Requested the server's RSA public key; the next AuthMoreData carries the PEM.
        case awaitingPublicKey
        /// Sent the final secret; only OK/ERR may follow.
        case done
    }

    let configuration: ConnectionConfiguration
    let isSecure: Bool
    private(set) var nonce: [UInt8]
    private(set) var plugin = AuthPlugin.nativePasswordName
    private(set) var step = Step.idle

    init(configuration: ConnectionConfiguration, isSecure: Bool, nonce: [UInt8]) {
        self.configuration = configuration
        self.isSecure = isSecure
        self.nonce = Array(nonce.prefix(32))
    }

    private var password: String { configuration.password }

    /// First token for `plugin` (initial response or auth-switch reply).
    mutating func start(plugin requested: String, nonce newNonce: [UInt8]? = nil, isSwitchRequest: Bool) throws -> [UInt8] {
        if let newNonce { nonce = Array(newNonce.prefix(64)) }
        switch requested {
        case AuthPlugin.nativePasswordName:
            plugin = requested
            step = .done
            return AuthPlugin.nativePassword(password: password, scramble: nonce)
        case AuthPlugin.cachingSHA2Name:
            plugin = requested
            step = password.isEmpty ? .done : .cachingSHA2AwaitingStatus
            return AuthPlugin.cachingSHA2Scramble(password: password, nonce: nonce)
        case AuthPlugin.sha256Name:
            plugin = requested
            if password.isEmpty || isSecure {
                step = .done
                return password.isEmpty ? [0] : AuthPlugin.clearPassword(password: password)
            }
            if let pem = configuration.serverPublicKeyPEM?.nilIfBlank {
                step = .done
                return try encrypt(pem: pem)
            }
            guard configuration.allowPublicKeyRetrieval else { throw Self.plaintextFullAuthError(plugin: requested) }
            step = .awaitingPublicKey
            return [AuthPlugin.sha256RequestPublicKey]
        case AuthPlugin.clearPasswordName:
            guard configuration.allowCleartextPassword else {
                throw MySQLError(.authentication, "The server asked for the password in clear text (mysql_clear_password, used by LDAP/PAM accounts). Enable “Allow clear-text password” for this connection, preferably with TLS or an SSH tunnel.")
            }
            plugin = requested
            step = .done
            return AuthPlugin.clearPassword(password: password)
        case AuthPlugin.ed25519Name:
            plugin = requested
            step = .done
            // MariaDB signs exactly the 32-byte nonce (a trailing NUL, if any, is not part of it).
            return Ed25519.sign(message: Array(nonce.prefix(32)), password: Array(password.utf8))
        default:
            if isSwitchRequest {
                throw MySQLError(.authentication, "The server requires the authentication plugin “\(requested)”, which CcinnMysql does not support.")
            }
            // Offer native password first; servers using another default answer with an auth switch.
            plugin = AuthPlugin.nativePasswordName
            step = .done
            return AuthPlugin.nativePassword(password: password, scramble: nonce)
        }
    }

    /// Reaction to an AuthMoreData packet; `nil` when nothing must be sent (wait for OK).
    mutating func continueWith(_ data: [UInt8]) throws -> [UInt8]? {
        switch step {
        case .cachingSHA2AwaitingStatus:
            switch data.first {
            case AuthPlugin.cachingSHA2FastAuthSuccess where data.count == 1:
                step = .done
                return nil
            case AuthPlugin.cachingSHA2PerformFullAuth where data.count == 1:
                if isSecure {
                    step = .done
                    return AuthPlugin.clearPassword(password: password)
                }
                if let pem = configuration.serverPublicKeyPEM?.nilIfBlank {
                    step = .done
                    return try encrypt(pem: pem)
                }
                guard configuration.allowPublicKeyRetrieval else { throw Self.plaintextFullAuthError(plugin: plugin) }
                step = .awaitingPublicKey
                return [AuthPlugin.cachingSHA2RequestPublicKey]
            default:
                throw MySQLError(.protocolViolation, "Unexpected caching_sha2_password status from the server")
            }
        case .awaitingPublicKey:
            step = .done
            return try encrypt(pem: String(decoding: data, as: UTF8.self))
        case .idle, .done:
            // A redundant "fast auth succeeded" after an empty password is harmless.
            if plugin == AuthPlugin.cachingSHA2Name, data == [AuthPlugin.cachingSHA2FastAuthSuccess] { return nil }
            throw MySQLError(.protocolViolation, "Unexpected authentication data from the server (plugin \(plugin))")
        }
    }

    private func encrypt(pem: String) throws -> [UInt8] {
        do {
            return try RSAPublicKey.encryptPassword(password, nonce: Array(nonce.prefix(20)), pem: pem)
        } catch let error as MySQLWireError {
            throw MySQLError(.authentication, "Could not use the server's RSA public key: \(error.description)")
        }
    }

    static func plaintextFullAuthError(plugin: String) -> MySQLError {
        MySQLError(.authentication, "The server needs full \(plugin) authentication, which requires TLS or the server's RSA public key. Enable TLS (mode Preferred or stricter), pin the server's public key, or allow public key retrieval for this connection.")
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
