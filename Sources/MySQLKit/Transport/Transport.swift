import Foundation

/// Host and port of a MySQL-protocol server (or proxy).
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 3306) {
        self.host = host
        self.port = port
    }

    public var isIPv6: Bool { host.contains(":") }
    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// A bidirectional byte stream to one server. `close()` must be safe to call from any thread at any
/// time (it is used for cancellation) and must make pending calls fail promptly.
public protocol ByteTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Returns the next chunk of bytes (at least one byte) or throws when the stream ends.
    func receive() async throws -> [UInt8]
    func close()
    /// Upgrades the same stream to TLS (design D1). Bytes sent afterwards are encrypted; errors of the
    /// TLS handshake surface on the next `send`/`receive` as `MySQLError.Kind.tls`.
    func startTLS(_ options: TLSOptions) throws
    /// TLS was started on this stream and the handshake has not produced any data yet.
    var tlsHandshakePending: Bool { get }
}

extension ByteTransport {
    public var tlsHandshakePending: Bool { false }
}

public struct TransportOptions: Sendable, Equatable {
    /// Seconds to establish the TCP connection (enforced together with the greeting by the connection).
    public var connectTimeout: Double
    /// Allow TLS 1.0/1.1 if the connection is upgraded later (must be chosen before connecting).
    public var allowLegacyTLS: Bool

    public init(connectTimeout: Double = 10, allowLegacyTLS: Bool = false) {
        self.connectTimeout = connectTimeout
        self.allowLegacyTLS = allowLegacyTLS
    }
}

public typealias TransportFactory = @Sendable (Endpoint, TransportOptions) async throws -> any ByteTransport

public enum Transports {
    /// TCP via `URLSessionStreamTask`, upgradable to TLS in place.
    public static let network: TransportFactory = { endpoint, options in
        try StreamTaskTransport.connect(to: endpoint, options: options, legacyTLS: options.allowLegacyTLS)
    }
}
