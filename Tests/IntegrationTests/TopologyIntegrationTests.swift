import Foundation
import Testing
@testable import MySQLKit

/// Replication, Group Replication, Galera and ProxySQL against the topology containers
/// (`scripts/it-up.sh m84 r84 gr84 galera proxysql`). Each test is skipped when its container is not listening.
@Suite("Topologies against real servers", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct TopologyIntegrationTests {
    static func configuration(port: Int, user: String = "root", password: String = IntegrationEnvironment.rootPassword) -> ConnectionConfiguration {
        ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: port), username: user, password: password, connectTimeout: 20,
                                tls: TLSOptions(mode: .preferred))
    }

    @Test(.enabled(if: IntegrationEnvironment.isListening(port: 13384) && IntegrationEnvironment.isListening(port: 13386)))
    func primaryAndReplica() async throws {
        let replica = try await MySQLClient.connect(Self.configuration(port: 13386), poolSize: 2)
        defer { Task { await replica.close() } }
        if try await replica.replicationOverview().channels.isEmpty {
            _ = try await replica.execute("""
                CHANGE REPLICATION SOURCE TO SOURCE_HOST = 'ccinnmysql-it-m84', SOURCE_PORT = 3306, SOURCE_USER = 'repl', \
                SOURCE_PASSWORD = 'Repl-pw-1', SOURCE_AUTO_POSITION = 1, GET_SOURCE_PUBLIC_KEY = 1
                """)
            _ = try await replica.execute("START REPLICA")
        }
        var channel: ReplicaChannel?
        for _ in 0..<40 {
            channel = try await replica.replicationOverview().channels.first
            if channel?.isHealthy == true { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let replicating = try #require(channel)
        #expect(replicating.isHealthy, "IO \(replicating.ioRunning ?? "?") SQL \(replicating.sqlRunning ?? "?") \(replicating.lastIOError ?? "")")
        #expect(replicating.sourceHost == "ccinnmysql-it-m84")
        #expect(replicating.secondsBehind != nil)
        #expect(try await replica.replicationOverview().role == .replica)
        #expect(replica.serverInfo.readOnly)

        let primary = try await MySQLClient.connect(Self.configuration(port: 13384), poolSize: 2)
        defer { Task { await primary.close() } }
        let source = try await primary.replicationOverview()
        #expect(source.binlogFile != nil)
        #expect(!source.connectedReplicas.isEmpty)
        #expect(source.role == .source)
    }

    @Test(.enabled(if: IntegrationEnvironment.isListening(port: 13387)))
    func groupReplicationMember() async throws {
        let client = try await MySQLClient.connect(Self.configuration(port: 13387), poolSize: 2)
        defer { Task { await client.close() } }
        if try await client.replicationOverview().groupMembers.first?.state != "ONLINE" {
            try await client.withConnection { connection in
                _ = try await connection.execute("SET GLOBAL group_replication_bootstrap_group = ON")
                _ = try await connection.execute("START GROUP_REPLICATION")
                _ = try await connection.execute("SET GLOBAL group_replication_bootstrap_group = OFF")
            }
        }
        var overview = try await client.replicationOverview()
        for _ in 0..<20 where overview.groupMembers.first?.state != "ONLINE" {
            try await Task.sleep(for: .milliseconds(500))
            overview = try await client.replicationOverview()
        }
        #expect(overview.role == .groupMember)
        let member = try #require(overview.groupMembers.first)
        #expect(member.state == "ONLINE")
        #expect(member.role == "PRIMARY")
        #expect(overview.groupName == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }

    @Test(.enabled(if: IntegrationEnvironment.isListening(port: 13340)))
    func galeraNode() async throws {
        let client = try await MySQLClient.connect(Self.configuration(port: 13340), poolSize: 2)
        defer { Task { await client.close() } }
        #expect(client.serverInfo.galeraEnabled)
        let overview = try await client.replicationOverview()
        #expect(overview.role == .galeraNode)
        #expect(overview.galera["wsrep_cluster_size"] == "1")
        #expect(overview.galera["wsrep_cluster_status"] == "Primary")
        #expect(overview.galera["wsrep_local_state_comment"] == "Synced")
    }

    @Test(.enabled(if: IntegrationEnvironment.isListening(port: 13360)))
    func throughProxySQL() async throws {
        let client = try await MySQLClient.connect(Self.configuration(port: 13360, user: "proxy_user", password: "Proxy-pw-1"), poolSize: 2)
        defer { Task { await client.close() } }
        #expect(client.serverInfo.isProxySQL)
        #expect(client.serverInfo.flavor == .mysql, "metadata comes from the MySQL backend")
        #expect(try await client.schemas().contains { $0.name == "shop" })
        #expect(try await client.objects(schema: "shop").objects.contains { $0.name == "orders" })

        // Cancelling a statement through the proxy uses the proxy's session id and stops the backend query.
        let session = client.openSession(database: "shop")
        let started = ContinuousClock.now
        let running = Task {
            try await session.run("SELECT COUNT(*) AS ccinn_proxy_cancel FROM orders a, orders b, orders c WHERE a.amount + b.amount + c.amount > a.id")
        }
        try await Task.sleep(for: .milliseconds(800))
        let target = try #require(await session.runningTarget)
        await session.cancel(graceSeconds: 5)
        await #expect { _ = try await running.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(target.proxySessionID != nil)
        let backend = try await MySQLClient.connect(Self.configuration(port: 13384), poolSize: 1)
        defer { Task { await backend.close() } }
        try await Task.sleep(for: .milliseconds(500))
        let stillRunning = try await backend.processList().processes.filter { $0.statement?.contains("ccinn_proxy_cancel") == true }
        #expect(stillRunning.isEmpty, "the backend statement was killed")
        await session.close()
    }
}
