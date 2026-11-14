import Foundation
import MySQLWire

/// Everything needed to stop a statement on the right server (design D6).
public struct KillTarget: Sendable, Hashable {
    /// `CONNECTION_ID()` on the server (the thread to kill).
    public let threadID: UInt64
    /// Connection id from the greeting: the proxy's session id behind ProxySQL.
    public let proxySessionID: UInt32?
    /// The server the thread lives on; `nil` when it could not be determined.
    public let identity: ServerIdentity?

    public init(threadID: UInt64, proxySessionID: UInt32? = nil, identity: ServerIdentity?) {
        self.threadID = threadID
        self.proxySessionID = proxySessionID
        self.identity = identity
    }
}

/// Entry point for one server (or proxy): a bounded connection pool, server facts, kill pinning, and the
/// metadata / operations APIs (see the `MySQLClient+*.swift` extensions).
public final class MySQLClient: Sendable {
    public let configuration: ConnectionConfiguration
    public let serverInfo: ServerInfo
    let pool: ConnectionPool
    /// Configuration actually dialled (points at the tunnel's local port when tunnelled).
    private let effectiveConfiguration: ConnectionConfiguration
    private let transportFactory: TransportFactory
    private let tunnel: SSHTunnel?

    /// Default per-statement budget for metadata queries issued by the app itself.
    public static let metadataTimeout: Double = 30
    /// Attempts to reach the right server through a load balancer before giving up on a kill.
    static let killAttempts = 8

    private init(configuration: ConnectionConfiguration, effectiveConfiguration: ConnectionConfiguration, serverInfo: ServerInfo,
                 pool: ConnectionPool, transportFactory: @escaping TransportFactory, tunnel: SSHTunnel?) {
        self.configuration = configuration
        self.effectiveConfiguration = effectiveConfiguration
        self.serverInfo = serverInfo
        self.pool = pool
        self.transportFactory = transportFactory
        self.tunnel = tunnel
    }

    /// Opens the pool and validates the credentials with a first connection.
    /// The client takes ownership of `tunnel` and closes it in `close()`.
    public static func connect(_ configuration: ConnectionConfiguration, poolSize: Int = 4, tunnel: SSHTunnel? = nil,
                               transportFactory: @escaping TransportFactory = Transports.network) async throws -> MySQLClient {
        let effective = tunnel.map { configuration.with(endpoint: $0.localAddress) } ?? configuration
        // Pool connections have no current schema: app-issued statements always qualify names, and a later
        // DROP DATABASE must not break new pool connections.
        var poolConfiguration = effective
        poolConfiguration.database = nil
        let factory: ConnectionPool.Factory = { [poolConfiguration] in
            let connection = try await openConnection(poolConfiguration, transportFactory: transportFactory)
            // Literals built by the app use backslash escapes; keep pool sessions in that mode.
            if await connection.status.contains(.noBackslashEscapes) {
                _ = try await connection.execute("SET SESSION sql_mode = REPLACE(@@sql_mode, 'NO_BACKSLASH_ESCAPES', '')")
            }
            return connection
        }
        let pool = ConnectionPool(maxSize: poolSize, factory: factory)
        do {
            let info = try await pool.withConnection { connection in
                try await ServerInfo.load(from: connection)
            }
            return MySQLClient(configuration: configuration, effectiveConfiguration: effective, serverInfo: info, pool: pool,
                               transportFactory: transportFactory, tunnel: tunnel)
        } catch {
            await pool.close()
            tunnel?.close()
            throw error
        }
    }

    public func close() async {
        await pool.close()
        tunnel?.close()
    }

    public var isTunnelled: Bool { tunnel != nil }

    // MARK: Statements

    /// Runs `sql` on a pooled connection. On cancellation, timeout or an abandoned oversized result
    /// the connection is dropped and the server-side statement is killed (design D5).
    public func query(_ sql: String, limits: RowLimits = RowLimits(), timeout: Double? = nil) async throws -> [ResultSet] {
        try await pool.withConnection { connection in
            do {
                let results: [ResultSet]
                if let timeout {
                    results = try await Deadline.run(seconds: timeout, timeoutError: {
                        MySQLError(.timeout, "The statement did not finish within \(Int(timeout))s")
                    }) {
                        try await connection.query(sql, limits: limits)
                    }
                } else {
                    results = try await connection.query(sql, limits: limits)
                }
                if await connection.isBroken { await killInBackground(connection) }
                return results
            } catch let error as MySQLError {
                // Only a statement that was actually sent and then abandoned leaves work on the server; a
                // connection that is still healthy goes back to the pool, so killing it would hit the
                // next caller's statement.
                if error.kind == .cancelled || error.kind == .timeout, await connection.isBroken {
                    await killInBackground(connection)
                }
                throw error
            }
        }
    }

    /// Runs `sql` and returns its last result; metadata default limits and timeout.
    public func execute(_ sql: String, timeout: Double? = MySQLClient.metadataTimeout) async throws -> ResultSet {
        guard let last = try await query(sql, limits: .metadata, timeout: timeout).last else {
            throw MySQLError(.protocolViolation, "The server returned no result for the statement")
        }
        return last
    }

    /// Runs `body` with one pooled connection (several statements that must see the same server).
    public func withConnection<T: Sendable>(_ body: (MySQLConnection) async throws -> T) async throws -> T {
        try await pool.withConnection(body)
    }

    /// Opens a dedicated session (keeps `USE`/`SET` state) for an editor tab.
    public func openSession(database: String? = nil) -> SQLSession {
        SQLSession(client: self, database: database ?? configuration.database?.nilIfBlank)
    }

    /// Connection ids owned by the pool (to hide the app's own metadata queries from activity views).
    public func ownConnectionIDs() async -> Set<UInt32> {
        await pool.connectionIDs
    }

    // MARK: Kill (design D6)

    /// `KILL QUERY`: stops the statement running on that thread; the connection survives.
    public func killQuery(_ target: KillTarget) async throws {
        try await kill(target, verb: "KILL QUERY")
    }

    /// `KILL`: terminates the whole connection.
    public func killConnection(_ target: KillTarget) async throws {
        try await kill(target, verb: "KILL")
    }

    func killInBackground(_ connection: MySQLConnection) async {
        guard let target = await connection.killTarget else { return }
        Task.detached { [self] in try? await killQuery(target) }
    }

    /// Kills must not wait behind a saturated pool, so they use short-lived connections, verified to reach
    /// the server that runs the thread (load balancers may route each new connection elsewhere).
    private func kill(_ target: KillTarget, verb: String) async throws {
        var configuration = effectiveConfiguration
        configuration.database = nil
        configuration.connectTimeout = min(configuration.connectTimeout, 10)
        let transportFactory = transportFactory
        let viaProxy = serverInfo.isProxySQL
        try await Deadline.run(seconds: 30, timeoutError: { MySQLError(.timeout, "The server did not answer \(verb) in time") }) { [configuration] in
            if viaProxy, let proxySessionID = target.proxySessionID {
                // ProxySQL maps its own session ids to the backend connection.
                let connection = try await MySQLConnection.connect(configuration, transportFactory: transportFactory)
                defer { connection.forceClose() }
                _ = try await connection.execute("\(verb) \(proxySessionID)")
                await connection.close()
                return
            }
            let attempts = target.identity == nil ? 1 : Self.killAttempts
            for _ in 0..<attempts {
                let connection = try await MySQLConnection.connect(configuration, transportFactory: transportFactory)
                do {
                    if let expected = target.identity {
                        let reached = try await Self.identify(connection).identity
                        guard reached.matches(expected) else {
                            await connection.close()
                            continue
                        }
                    }
                    _ = try await connection.execute("\(verb) \(target.threadID)")
                    await connection.close()
                    return
                } catch {
                    await connection.close()
                    throw error
                }
            }
            throw MySQLError(.server, "Could not reach \(target.identity?.description ?? "the server") through \(configuration.endpoint) (it looks like a load balancer). Connect to that server directly to stop this session.")
        }
    }

    // MARK: Connections

    /// Connects and records where the connection landed, so its statements can be killed later.
    static func openConnection(_ configuration: ConnectionConfiguration, transportFactory: @escaping TransportFactory) async throws -> MySQLConnection {
        let connection = try await MySQLConnection.connect(configuration, transportFactory: transportFactory)
        do {
            let (threadID, identity) = try await identify(connection)
            await connection.setKillTarget(KillTarget(threadID: threadID, proxySessionID: connection.connectionID, identity: identity))
        } catch let error as MySQLError where error.kind == .server {
            // Identity is best effort (e.g. exotic proxies); fall back to the greeting's connection id.
            await connection.setKillTarget(KillTarget(threadID: UInt64(connection.connectionID), proxySessionID: connection.connectionID, identity: nil))
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    /// `CONNECTION_ID()` and server identity of the server a connection reached.
    static func identify(_ connection: MySQLConnection) async throws -> (threadID: UInt64, identity: ServerIdentity) {
        let version = connection.protocolVersion
        let parsed = ServerVersion(version)
        let hasUUID = version.range(of: "MariaDB", options: .caseInsensitive) == nil && (parsed?.atLeast(5, 6) ?? false)
        let base = "CONNECTION_ID() AS thread_id, @@hostname AS hostname, @@port AS port, @@server_id AS server_id"
        var row: Record?
        if hasUUID {
            do {
                row = try await connection.execute("SELECT \(base), @@server_uuid AS server_uuid").first
            } catch let error as MySQLError where error.kind == .server {
                row = nil // e.g. a proxy in front of MariaDB
            }
        }
        if row == nil { row = try await connection.execute("SELECT \(base)").first }
        guard let row else { throw MySQLError(.protocolViolation, "The server returned no identity row") }
        let threadID = row.int("thread_id").flatMap { UInt64(exactly: $0) } ?? UInt64(connection.connectionID)
        let identity = ServerIdentity(serverUUID: row.text("server_uuid"), hostname: row.text("hostname"),
                                      port: row.int("port").map { Int(clamping: $0) }, serverID: row.int("server_id"))
        return (threadID, identity)
    }

    /// A connection for a SQL session, with exactly the session's schema.
    func makeSessionConnection(database: String?) async throws -> MySQLConnection {
        var sessionConfiguration = effectiveConfiguration
        sessionConfiguration.database = database
        return try await Self.openConnection(sessionConfiguration, transportFactory: transportFactory)
    }
}
