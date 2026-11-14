import Foundation
import MySQLWire
import Testing
@testable import MySQLKit

@Suite("Review regressions: kills and session edits")
struct ReviewKillAndEditTests {
    private func connect(_ cluster: FakeCluster) async throws -> MySQLClient {
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", connectTimeout: 3)
        return try await MySQLClient.connect(configuration, poolSize: 1, transportFactory: cluster.transportFactory)
    }

    /// Review #7: a KILL that is still connecting when its statement finishes must not hit the next statement.
    @Test func lateKillNeverInterruptsTheNextStatement() async throws {
        // Connections: #0 pool, #1 session, #2 the kill connection (slow to establish).
        let cluster = FakeCluster(connectDelays: [2: 0.6]) { sql in
            if sql.contains("first") { return .delayed(FakeCluster.rows("first"), seconds: 0.2) }
            if sql.contains("second") { return .delayed(FakeCluster.rows("second"), seconds: 0.8) }
            return .packets(FakeCluster.rows("ok"))
        }
        let client = try await connect(cluster)
        let session = client.openSession()
        let first = Task { try await session.run("SELECT 'first'") }
        try await Task.sleep(for: .milliseconds(50))
        let cancel = Task { await session.cancel(graceSeconds: 0.3) }
        #expect(try await first.value.last?.scalar == "first", "the statement finished before the kill arrived")
        let second = try await session.run("SELECT 'second'")
        #expect(second.last?.scalar == "second")
        await cancel.value
        await session.close()
        await client.close()
    }

    /// Review #11: without a server identity no KILL is sent through a possible load balancer; the socket is closed instead.
    @Test func unidentifiedServerGetsNoBlindKill() async throws {
        let cluster = FakeCluster(identityFails: true) { sql in sql.contains("long") ? .hang : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let session = client.openSession()
        let long = Task { try await session.run("SELECT 'long'") }
        try await Task.sleep(for: .milliseconds(150))
        await session.cancel(graceSeconds: 0.2)
        await #expect { _ = try await long.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        #expect(cluster.kills.isEmpty)
        await #expect { try await client.killQuery(KillTarget(threadID: 5, identity: nil)) } throws: { ($0 as? MySQLError)?.kind == .server }
        await session.close()
        await client.close()
    }

    /// Review #12: closing the client waits (bounded) for kills sent in the background.
    @Test func closeWaitsForBackgroundKills() async throws {
        let cluster = FakeCluster(connectDelays: [1: 0.4]) { _ in .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        client.killInBackground(KillTarget(threadID: 101, identity: FakeIdentity.cluster0))
        await client.close()
        #expect(cluster.kills.map(\.statement) == ["KILL QUERY 101"])
    }

    /// Review #6: inline edits run on the result's own session connection, inside a transaction.
    @Test func rowEditsRunOnTheSessionConnection() async throws {
        let cluster = FakeCluster { sql in
            if sql.hasPrefix("UPDATE") { return .packets([FakeMySQLServer.ok(affectedRows: 1, status: 0x0003, info: "Rows matched: 1  Changed: 1  Warnings: 0")]) }
            if sql.hasPrefix("START TRANSACTION") { return .packets([FakeMySQLServer.ok(status: 0x0003)]) }
            return .packets(FakeCluster.rows("ok"))
        }
        let client = try await connect(cluster)
        let session = client.openSession()
        _ = try await session.run("SET time_zone = '+08:00'")
        try await session.applyRowEdit("UPDATE `shop`.`t` SET `a` = 'x' WHERE `id` = '1' LIMIT 1")
        let sessionServer = try #require(cluster.servers.last)
        let tail = sessionServer.queries.suffix(4)
        #expect(Array(tail) == ["SET time_zone = '+08:00'", "START TRANSACTION", "UPDATE `shop`.`t` SET `a` = 'x' WHERE `id` = '1' LIMIT 1", "COMMIT"])
        await session.close()
        await client.close()
    }

    @Test func rowEditsRefuseAnOpenTransaction() async throws {
        let cluster = FakeCluster { sql in sql.hasPrefix("BEGIN") ? .packets([FakeMySQLServer.ok(status: 0x0003)]) : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let session = client.openSession()
        _ = try await session.run("BEGIN")
        await #expect { try await session.applyRowEdit("UPDATE t SET a = 1 WHERE id = 1 LIMIT 1") } throws: { ($0 as? MySQLError)?.kind == .invalidArgument }
        await session.close()
        await client.close()
    }
}

extension FakeIdentity {
    /// The identity FakeCluster gives backend 0.
    static let cluster0 = ServerIdentity(serverUUID: "uuid-0", hostname: "db-0", port: 3306, serverID: 1)
}
