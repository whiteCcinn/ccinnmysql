import Foundation
import MySQLWire
import os
import Testing
@testable import MySQLKit

@Suite("Session and cancellation regressions")
struct SessionRegressionTests {
    private func connect(_ cluster: FakeCluster, database: String? = nil, poolSize: Int = 1) async throws -> MySQLClient {
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", database: database, connectTimeout: 2)
        return try await MySQLClient.connect(configuration, poolSize: poolSize, transportFactory: cluster.transportFactory)
    }

    @Test func cancelledBeforeSendingDoesNotKillTheNextQuery() async throws {
        let cluster = FakeCluster { sql in sql.contains("slow") ? .delayed(FakeCluster.rows("slow"), seconds: 0.4) : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.query("SELECT 'cancelled'")
        }
        _ = try? await cancelled.value
        // The pool's only connection is reused by an unrelated query; it must not be killed.
        let result = try await client.query("SELECT 'slow'")
        #expect(result.last?.scalar == "slow")
        #expect(!cluster.statements.contains { $0.hasPrefix("KILL") })
        await client.close()
    }

    @Test func lateCancelDoesNotCloseTheNextRun() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("first") { return .hang }
            if sql.contains("second") { return .delayed(FakeCluster.rows("second"), seconds: 0.8) }
            return .packets(FakeCluster.rows("ok"))
        }
        let client = try await connect(cluster)
        let session = client.openSession()
        let first = Task { try await session.run("SELECT 'first'") }
        try await Task.sleep(for: .milliseconds(100))
        let cancel = Task { await session.cancel(graceSeconds: 0.3) }
        await #expect { _ = try await first.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        // Re-run immediately on the same connection; the pending cancel's grace period expires meanwhile.
        let second = try await session.run("SELECT 'second'")
        #expect(second.last?.scalar == "second")
        await cancel.value
        #expect(try await session.run("SELECT 3").last?.scalar == "ok")
        await session.close()
        await client.close()
    }

    @Test func reconnectKeepsSchemaAndSessionSettings() async throws {
        let cluster = FakeCluster { _ in .packets([FakeMySQLServer.ok()]) }
        let client = try await connect(cluster, database: "sales")
        let session = client.openSession()
        _ = try await session.run("USE `crm`")
        _ = try await session.run("SET sql_mode = 'ANSI'")
        _ = try await session.run("SET GLOBAL max_connections = 10")
        #expect(await session.database == "crm")
        await session.close()
        _ = try await session.run("SELECT 1")
        #expect(cluster.handshakeDatabases.last == "crm")
        let replay = cluster.statements.suffix(3)
        #expect(replay.contains("SET sql_mode = 'ANSI'"))
        #expect(!replay.contains("SET GLOBAL max_connections = 10"))
        await client.close()
    }

    @Test func rejectedConcurrentRunKeepsStopWorking() async throws {
        let cluster = FakeCluster { sql in sql.contains("long") ? .hang : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let session = client.openSession()
        let long = Task { try await session.run("SELECT 'long'") }
        try await Task.sleep(for: .milliseconds(100))
        await #expect { _ = try await session.run("SELECT 2") } throws: { ($0 as? MySQLError)?.kind == .busy }
        #expect(await session.runningTarget != nil, "the rejected run must not clear the running statement")
        await session.cancel(graceSeconds: 1)
        await #expect { _ = try await long.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        await session.close()
        await client.close()
    }

    @Test func classifiesSessionStatements() {
        #expect(SessionContextChange.parse("SET sql_mode = ''") == .sessionVariable("SET sql_mode = ''"))
        #expect(SessionContextChange.parse("set role all") == .sessionVariable("set role all"))
        #expect(SessionContextChange.parse("SET NAMES utf8mb4") == .sessionVariable("SET NAMES utf8mb4"))
        #expect(SessionContextChange.parse("SET GLOBAL max_connections = 10") == nil)
        #expect(SessionContextChange.parse("SET PERSIST max_connections = 10") == nil)
        #expect(SessionContextChange.parse("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE") == nil)
        #expect(SessionContextChange.parse("USE `my``db`") == .use(database: "my`db"))
        #expect(SessionContextChange.parse("USE a.b") == nil)
        #expect(SessionContextChange.parse("SET PASSWORD = PASSWORD('x')") == nil)
        #expect(SessionContextChange.parse("set @@global.x = 1") == nil)
    }
}

@Suite("Cancelled connects")
struct CancelledConnectTests {
    @Test func preCancelledNetworkConnectFailsFast() async throws {
        let started = ContinuousClock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Transports.network(Endpoint(host: "127.0.0.1", port: 9), TransportOptions(connectTimeout: 6))
        }
        await #expect { _ = try await task.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test func cancelledCheckoutReservesNoSlot() async throws {
        let cluster = FakeCluster { _ in .packets(FakeCluster.rows("ok")) }
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", connectTimeout: 2)
        let pool = ConnectionPool(maxSize: 1) { try await MySQLConnection.connect(configuration, transportFactory: cluster.transportFactory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pool.checkout()
        }
        await #expect { _ = try await task.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        #expect(await pool.statistics.open == 0)
    }
}
