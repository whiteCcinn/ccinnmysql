import Foundation
import MySQLWire
import os
@testable import MySQLKit

/// A fake deployment: every connection is a `FakeMySQLServer` on one of `backends` servers (round-robin,
/// like a load balancer). `KILL [QUERY] <id>` interrupts thread `id` only on the backend that receives it.
/// In ProxySQL mode, kill ids are proxy session ids (greeting connection ids) and work from any backend.
final class FakeCluster: Sendable {
    private struct State {
        var nextID: UInt32 = 100
        var connections: [(backend: Int, server: FakeMySQLServer)] = []
        var handshakeDatabases: [String?] = []
        var kills: [(backend: Int, statement: String)] = []
        var nextBackend = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let reply: @Sendable (String) -> FakeMySQLServer.Reply
    let backends: Int
    let proxySQL: Bool
    let status: UInt16

    init(backends: Int = 1, proxySQL: Bool = false, status: UInt16 = 0x0002, reply: @escaping @Sendable (String) -> FakeMySQLServer.Reply) {
        self.backends = max(1, backends)
        self.proxySQL = proxySQL
        self.status = status
        self.reply = reply
    }

    /// Every statement received, grouped by connection in creation order.
    var statements: [String] { state.withLockUnchecked { $0.connections }.flatMap(\.server.queries) }
    var handshakeDatabases: [String?] { state.withLockUnchecked { $0.handshakeDatabases } }
    var kills: [(backend: Int, statement: String)] { state.withLockUnchecked { $0.kills } }
    var servers: [FakeMySQLServer] { state.withLockUnchecked { $0.connections.map(\.server) } }

    var transportFactory: TransportFactory {
        { [self] _, _ in
            let (id, backend) = state.withLockUnchecked { state -> (UInt32, Int) in
                state.nextID += 1
                let backend = state.nextBackend
                state.nextBackend = (state.nextBackend + 1) % backends
                return (state.nextID, backend)
            }
            let identity = FakeIdentity(uuid: "uuid-\(backend)", hostname: "db-\(backend)", port: 3306, serverID: Int64(backend + 1))
            // Behind ProxySQL the backend thread id differs from the proxy session id.
            let threadID = proxySQL ? id + 5_000 : id
            let server = FakeMySQLServer(connectionID: id, threadID: threadID, status: status, identity: identity) { [self] sql in
                if sql.hasPrefix("select @@version_comment limit 1") {
                    return .packets(FakeMySQLServer.resultSet([("@@version_comment", .varString)], [[proxySQL ? "(ProxySQL)" : "MySQL Community Server - GPL"]]))
                }
                if sql.hasPrefix("KILL") {
                    let target = UInt32(sql.split(separator: " ").last ?? "") ?? 0
                    state.withLockUnchecked { $0.kills.append((backend, sql)) }
                    let victim = state.withLockUnchecked { state in
                        state.connections.first { entry in
                            proxySQL ? entry.server.connectionID == target : (entry.backend == backend && entry.server.threadID == target)
                        }?.server
                    }
                    victim?.interrupt()
                    return .packets([FakeMySQLServer.ok()])
                }
                return reply(sql)
            }
            state.withLockUnchecked { $0.connections.append((backend, server)) }
            return HandshakeRecorder(server: server, cluster: self)
        }
    }

    fileprivate func record(database: String?) {
        state.withLockUnchecked { $0.handshakeDatabases.append(database) }
    }

    static func rows(_ value: String) -> [[UInt8]] {
        FakeMySQLServer.resultSet([("v", .varString)], [[value]])
    }
}

/// Records the database requested in each handshake.
private final class HandshakeRecorder: ByteTransport, @unchecked Sendable {
    let server: FakeMySQLServer
    let cluster: FakeCluster
    private let sawHandshake = OSAllocatedUnfairLock(initialState: false)

    init(server: FakeMySQLServer, cluster: FakeCluster) {
        self.server = server
        self.cluster = cluster
    }

    func send(_ bytes: [UInt8]) async throws {
        let first = sawHandshake.withLock { seen -> Bool in
            defer { seen = true }
            return !seen
        }
        if first {
            var framer = PacketFramer()
            framer.append(bytes)
            if let packet = try framer.nextPacket() { cluster.record(database: Self.database(in: packet.payload)) }
        }
        try await server.send(bytes)
    }

    func receive() async throws -> [UInt8] { try await server.receive() }
    func close() { server.close() }
    func startTLS(_ options: TLSOptions) throws { try server.startTLS(options) }

    static func database(in payload: [UInt8]) -> String? {
        var reader = PayloadReader(payload)
        guard let capabilities = try? Capabilities(rawValue: reader.readUInt32()), (try? reader.skip(4 + 1 + 23)) != nil else { return nil }
        _ = try? reader.readNullTerminatedString()
        _ = try? reader.readLengthEncodedBytes()
        guard capabilities.contains(.connectWithDB) else { return nil }
        return try? reader.readNullTerminatedString()
    }
}
