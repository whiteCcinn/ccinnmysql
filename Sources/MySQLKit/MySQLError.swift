import Foundation
import MySQLWire

/// Every failure surfaced by MySQLKit. Messages are user-facing and never contain secrets.
public struct MySQLError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidArgument
        case network
        case timeout
        case dns
        case sshTunnel
        /// TLS could not be negotiated, or the server certificate was rejected.
        case tls
        case authentication
        /// The server rejected a statement (ERR packet). The connection stays usable.
        case server
        case protocolViolation
        case cancelled
        case connectionClosed
        case busy
        /// The connection broke while the server had an open transaction; it was rolled back.
        case transactionLost
    }

    public let kind: Kind
    public let message: String
    /// MySQL error code from an ERR packet.
    public let code: Int?
    public let sqlState: String?

    public init(_ kind: Kind, _ message: String, code: Int? = nil, sqlState: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
        self.sqlState = sqlState
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public static func cancelled() -> MySQLError { MySQLError(.cancelled, "The operation was cancelled") }

    static func server(_ packet: ErrorPacket) -> MySQLError {
        let message = packet.message.isEmpty ? "Server error \(packet.code)" : packet.message
        let kind: Kind = Self.authenticationCodes.contains(Int(packet.code)) ? .authentication : .server
        return MySQLError(kind, message, code: Int(packet.code), sqlState: packet.sqlState)
    }

    /// Access denied / bad handshake / password expired / account locked / plugin errors.
    static let authenticationCodes: Set<Int> = [1043, 1044, 1045, 1251, 1698, 1820, 1862, 3118, 2061, 1524, 4150, 3159]

    /// The statement was killed by `KILL QUERY`, or exceeded MAX_EXECUTION_TIME / max_statement_time.
    public var isQueryInterrupted: Bool {
        guard kind == .server else { return false }
        return [1317, 3024, 1969, 1927].contains(code ?? 0)
    }

    /// Errors after which the connection must not be reused.
    public var breaksConnection: Bool {
        switch kind {
        case .server, .authentication, .invalidArgument, .busy: false
        default: true
        }
    }
}
