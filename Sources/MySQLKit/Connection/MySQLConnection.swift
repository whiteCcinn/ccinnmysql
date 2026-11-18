import Foundation
import MySQLWire

/// Packet-level I/O over a transport. A value type so a single owner (the handshake, then the
/// connection actor) mutates it without locks.
struct PacketChannel: Sendable {
    let transport: any ByteTransport
    var framer = PacketFramer()
    /// Sequence id of the next packet to write.
    var sequence: UInt8 = 0
    /// Set when a result was abandoned mid-stream; the connection must then be dropped.
    var isAbandoned = false

    init(transport: any ByteTransport) {
        self.transport = transport
    }

    mutating func read() async throws -> [UInt8] {
        while true {
            if let packet = try framer.nextPacket() {
                sequence = packet.sequence &+ 1
                return packet.payload
            }
            framer.append(try await transport.receive())
        }
    }

    mutating func write(_ payload: [UInt8]) async throws {
        let bytes = PacketCodec.frame(payload, sequence: sequence)
        sequence &+= UInt8(truncatingIfNeeded: payload.count / PacketCodec.maxChunk + 1)
        try await transport.send(bytes)
    }

    /// Every client command starts a new sequence.
    mutating func sendCommand(_ payload: [UInt8]) async throws {
        sequence = 0
        try await write(payload)
    }
}

/// One authenticated MySQL-protocol session.
///
/// The actor owns the socket; a command takes the packet channel out of the actor for its duration,
/// so overlapping commands fail fast with `.busy` instead of interleaving bytes. Any I/O or framing
/// failure marks the connection broken for good; a server ERR packet does not (the protocol stays aligned).
public actor MySQLConnection {
    public nonisolated let endpoint: Endpoint
    /// Connection id from the greeting (the proxy's session id behind ProxySQL).
    public nonisolated let connectionID: UInt32
    /// Version string from the greeting (MariaDB adds a `5.5.5-` prefix; see `ServerInfo`).
    public nonisolated let protocolVersion: String
    public nonisolated let capabilities: Capabilities
    public nonisolated let isTLS: Bool
    public nonisolated let authPlugin: String
    private nonisolated let transport: any ByteTransport

    private var channel: PacketChannel?
    public private(set) var isBroken = false
    /// Status flags of the last OK/EOF (transaction state, NO_BACKSLASH_ESCAPES).
    public private(set) var status: ServerStatus
    public private(set) var lastActivity = ContinuousClock.now
    /// Where this connection's statements run (set right after connecting; design D6).
    public private(set) var killTarget: KillTarget?

    func setKillTarget(_ target: KillTarget) {
        killTarget = target
    }

    init(endpoint: Endpoint, outcome: HandshakeOutcome, channel: PacketChannel) {
        self.endpoint = endpoint
        connectionID = outcome.greeting.connectionID
        protocolVersion = outcome.greeting.serverVersion
        capabilities = outcome.capabilities
        isTLS = outcome.isTLS
        authPlugin = outcome.authPlugin
        status = ServerStatus(rawValue: outcome.statusFlags)
        transport = channel.transport
        self.channel = channel
    }

    // MARK: Connect

    /// Opens and authenticates a connection. In every TLS mode, once the TLS handshake has started a failure is
    /// final: CcinnMysql never retries in plaintext (design D2), because a network attacker could force that.
    public static func connect(_ configuration: ConnectionConfiguration,
                               transportFactory: TransportFactory = Transports.network) async throws -> MySQLConnection {
        try await connectOnce(configuration, transportFactory: transportFactory)
    }

    /// A TLS handshake that never completes (the system TLS stack rejected the server's protocol version, e.g. a
    /// TLS 1.0-only yaSSL build) surfaces as a stalled read; explain the likely cause and the ways out.
    static func tlsStallError(_ configuration: ConnectionConfiguration) -> MySQLError {
        // A stall cannot be told apart from a server that is alive but not answering, so say both.
        let endpoint = configuration.endpoint
        let seconds = Int(configuration.connectTimeout.rounded())
        let unresponsive = "If the server does support TLS 1.2, it is not responding (overloaded or out of memory) — try again later."
        if configuration.tls.allowLegacyProtocols {
            return MySQLError(.tls, "The TLS handshake with \(endpoint) did not complete within \(seconds) s. The server most likely offers no protocol or cipher this Mac accepts: use an SSH tunnel, or set TLS to Disabled for this connection. \(unresponsive)")
        }
        return MySQLError(.tls, "The TLS handshake with \(endpoint) did not complete within \(seconds) s. The usual cause is a server that only speaks TLS 1.0/1.1 (old MySQL 5.6/5.7 builds with yaSSL): enable “Allow TLS 1.0 / 1.1” for this connection, connect through an SSH tunnel, or set TLS to Disabled. \(unresponsive)")
    }

    private static func connectOnce(_ configuration: ConnectionConfiguration, transportFactory: TransportFactory) async throws -> MySQLConnection {
        let endpoint = configuration.endpoint
        let timeout = max(1, configuration.connectTimeout)
        if Task.isCancelled { throw MySQLError.cancelled() }
        let options = TransportOptions(connectTimeout: timeout, allowLegacyTLS: configuration.tls.allowLegacyProtocols)
        let transport = try await transportFactory(endpoint, options)
        // TCP connect, handshake and session setup share one deadline; on timeout or cancellation the socket is closed.
        do {
            return try await Deadline.run(seconds: timeout, timeoutError: {
                MySQLError(.timeout, "\(endpoint) did not complete the connection setup within \(Int(timeout))s")
            }) {
                try await withTaskCancellationHandler {
                    let (channel, outcome) = try await Handshake.perform(transport: transport, configuration: configuration)
                    let connection = MySQLConnection(endpoint: endpoint, outcome: outcome, channel: channel)
                    do {
                        try await connection.applyInitialContext(configuration)
                    } catch {
                        await connection.close()
                        throw error
                    }
                    return connection
                } onCancel: {
                    transport.close()
                }
            }
        } catch {
            let stalledInTLS = transport.tlsHandshakePending
            transport.close()
            if Task.isCancelled { throw MySQLError.cancelled() }
            let mapped = Self.mapError(error, endpoint: endpoint)
            if mapped.kind == .timeout, stalledInTLS { throw tlsStallError(configuration) }
            throw mapped
        }
    }

    private func applyInitialContext(_ configuration: ConnectionConfiguration) async throws {
        try await useUTF8MB4()
        for variable in configuration.sessionVariables {
            let name = variable.name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            do {
                _ = try await execute("SET SESSION \(name) = \(SQLText.literal(variable.value))")
            } catch let error as MySQLError where error.kind == .server {
                continue // unknown variable on this server version
            }
        }
    }

    // MARK: Commands

    /// Runs `sql` (COM_QUERY) and returns every result it produced.
    public func query(_ sql: String, limits: RowLimits = RowLimits()) async throws -> [ResultSet] {
        try await perform { channel in
            try await channel.sendCommand(Command.query(sql))
            return try await ResultReader.readResults(from: &channel, capabilities: self.capabilities, limits: limits)
        }
    }

    /// Runs `sql` and returns its last result.
    public func execute(_ sql: String, limits: RowLimits = .metadata) async throws -> ResultSet {
        guard let last = try await query(sql, limits: limits).last else {
            throw MySQLError(.protocolViolation, "The server returned no result for the statement")
        }
        return last
    }

    public func ping() async throws {
        try await simpleCommand(Command.ping, name: "COM_PING")
    }

    /// COM_RESET_CONNECTION: drops temporary tables, user variables and session settings, keeps the login.
    public func resetSession() async throws {
        try await simpleCommand(Command.resetConnection, name: "COM_RESET_CONNECTION")
        try await useUTF8MB4()
    }

    /// The app sends and reads UTF-8. The handshake asks for utf8mb4, but the server can switch a new connection to
    /// another character set afterwards (`init_connect='SET NAMES gbk'`, skip-character-set-client-handshake), and in GBK,
    /// Shift-JIS or Big5 the byte 0x5C can be part of a character, so a string would end somewhere else than the app sees.
    /// Every connection is switched back after the handshake (after init_connect) and after a reset. A server that refuses
    /// is left as it is: guarded statements check the character set themselves before they run.
    private func useUTF8MB4() async throws {
        do {
            _ = try await execute("SET NAMES utf8mb4")
        } catch let error as MySQLError where error.kind == .server {
            return
        }
    }

    private func simpleCommand(_ payload: [UInt8], name: String) async throws {
        let statusFlags: UInt16 = try await perform { channel in
            try await channel.sendCommand(payload)
            let reply = try await channel.read()
            switch try ServerPacket.parse(reply, capabilities: self.capabilities) {
            case let .ok(ok): return ok.statusFlags
            case let .error(packet): throw MySQLError.server(packet)
            default: throw MySQLError(.protocolViolation, "Unexpected reply to \(name)")
            }
        }
        status = ServerStatus(rawValue: statusFlags)
    }

    /// Sends COM_QUIT (best effort) and closes the socket.
    public func close() async {
        guard !isBroken else { return }
        isBroken = true
        if var channel = channel.take() {
            try? await channel.sendCommand(Command.quit)
        }
        transport.close()
    }

    /// Closes the socket from any context (cancellation, pool shutdown).
    public nonisolated func forceClose() {
        transport.close()
    }

    /// Seconds since the last completed command.
    public var idleSeconds: Double {
        let elapsed = ContinuousClock.now - lastActivity
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: Plumbing

    private func perform<T: Sendable>(_ operation: (inout PacketChannel) async throws -> T) async throws -> T {
        guard !isBroken else {
            throw MySQLError(.connectionClosed, "The connection to \(endpoint) is closed")
        }
        guard var channel = channel.take() else {
            throw MySQLError(.busy, "Connection \(connectionID) is already running a statement")
        }
        if Task.isCancelled {
            self.channel = channel
            throw MySQLError.cancelled()
        }
        let transport = self.transport
        defer { lastActivity = .now }
        do {
            let result = try await withTaskCancellationHandler {
                try await operation(&channel)
            } onCancel: {
                transport.close()
            }
            if let results = result as? [ResultSet], let last = results.last {
                status = last.status
            }
            if channel.isAbandoned {
                markBroken()
            } else {
                self.channel = channel
            }
            return result
        } catch {
            let mapped = Self.mapError(error, endpoint: endpoint)
            if Task.isCancelled || mapped.breaksConnection {
                markBroken()
                throw Task.isCancelled ? MySQLError.cancelled() : mapped
            }
            self.channel = channel
            throw mapped
        }
    }

    private func markBroken() {
        isBroken = true
        channel = nil
        transport.close()
    }

    static func mapError(_ error: any Error, endpoint: Endpoint) -> MySQLError {
        switch error {
        case let error as MySQLError: error
        case let wire as MySQLWireError: MySQLError(.protocolViolation, "\(endpoint): \(wire.description)")
        default: MySQLError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)")
        }
    }
}
