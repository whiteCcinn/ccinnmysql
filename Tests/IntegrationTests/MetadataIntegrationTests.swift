import Foundation
import Testing
@testable import MySQLKit

@Suite("Metadata and operations against real servers", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct MetadataIntegrationTests {
    typealias Target = IntegrationEnvironment.Target

    private func client(_ target: Target) async throws -> MySQLClient {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 4)
        try await DemoSchema.load(into: client)
        return client
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func schemaBrowser(target: Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let schemas = try await client.schemas()
        #expect(schemas.first?.isSystem == false)
        #expect(schemas.contains { $0.name == "shop" })
        #expect(schemas.last?.isSystem == true)

        let objects = try await client.objects(schema: "shop")
        #expect(objects.unavailable.isEmpty, "\(objects.unavailable)")
        let engines = Dictionary(uniqueKeysWithValues: objects.tablesByEngine.map { ($0.engine.uppercased(), Set($0.tables.map(\.name))) })
        #expect(engines["INNODB"]?.isSuperset(of: ["customers", "orders", "order_items", "events_log"]) == true)
        #expect(engines["MYISAM"] == ["legacy_counters"])
        #expect(engines["MEMORY"] == ["session_cache"])
        #expect(objects.objects(of: .view).map(\.name) == ["v_paid_orders"])
        #expect(objects.objects(of: .procedure).map(\.name) == ["sp_orders_by_city"])
        #expect(objects.objects(of: .function).first?.detail?.lowercased().hasPrefix("decimal") == true)
        #expect(objects.objects(of: .trigger).first?.status == "BEFORE INSERT")
        #expect(objects.objects(of: .event).first?.detail?.hasPrefix("EVERY 1 HOUR") == true)
        let tiny = try #require(objects.objects.first { $0.name == "tiny_ids" })
        #expect(tiny.autoIncrement == 122)

        for object in objects.objects where !object.kind.isRelation || object.kind == .view {
            let ddl = try await client.ddl(of: object)
            #expect(ddl.uppercased().contains("CREATE"), "\(object.kind) \(object.name): \(ddl.prefix(80))")
        }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func tableDetails(target: Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let objects = try await client.objects(schema: "shop")
        let orders = try #require(objects.objects.first { $0.name == "orders" })
        let detail = try await client.tableDetail(orders)
        #expect(detail.unavailable.isEmpty, "\(detail.unavailable)")
        #expect(detail.columns.map(\.name) == ["id", "customer_id", "status", "channel", "amount", "created_at"])
        #expect(detail.columns.first?.isAutoIncrement == true)
        #expect(detail.columns.first?.isUnsigned == true)
        #expect(detail.indexes.first?.isPrimary == true)
        let composite = try #require(detail.indexes.first { $0.name == "idx_customer_created" })
        #expect(composite.columns.compactMap(\.name) == ["customer_id", "created_at"])
        #expect((composite.cardinality ?? 0) > 0)
        #expect(detail.foreignKeys.first?.referencedTable == "customers")
        #expect(detail.foreignKeys.first?.onDelete == "CASCADE")
        #expect(detail.referencedBy.contains { $0.name.hasPrefix("order_items.") })
        #expect(detail.ddl?.contains("CREATE TABLE") == true)

        let log = try #require(objects.objects.first { $0.name == "events_log" })
        #expect(log.isPartitioned)
        let partitions = try await client.tableDetail(log).partitions
        #expect(partitions.map(\.name) == ["p2024", "p2025", "p2026", "pmax"])
        #expect(partitions.first?.method == "RANGE")

        let preview = try await client.preview(orders, limit: 25)
        #expect(preview.rows.count == 25)
        #expect(preview.columns.first?.originalTable == "orders")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func processlistKillAndLockWaits(target: Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        // A sleeping statement in another session, killed from the processlist.
        let sleeper = client.openSession()
        let sleeping = Task { try await sleeper.run("SELECT SLEEP(20) AS ccinn_sleep") }
        try await Task.sleep(for: .milliseconds(600))
        let snapshot = try await client.processList()
        #expect(snapshot.identity != nil)
        let victim = try #require(snapshot.processes.first { $0.statement?.contains("ccinn_sleep") == true })
        try await client.kill(victim, in: snapshot, connection: false)
        _ = await sleeping.result
        await sleeper.close()

        // A lock wait: session A holds a row lock, session B waits for it.
        let holder = client.openSession(database: "shop")
        let waiter = client.openSession(database: "shop")
        _ = try await holder.run("START TRANSACTION")
        _ = try await holder.run("UPDATE customers SET name = 'locked' WHERE id = 1")
        _ = try await waiter.run("SET SESSION innodb_lock_wait_timeout = 20")
        let blocked = Task { try await waiter.run("UPDATE customers SET name = 'waiter' WHERE id = 1") }
        try await Task.sleep(for: .milliseconds(800))
        let activity = try await client.innoDBActivity()
        #expect(activity.unavailable["Transactions"] == nil && activity.unavailable["Lock waits"] == nil, "\(activity.unavailable)")
        #expect(activity.transactions.contains { $0.isWaiting })
        let wait = try #require(activity.lockWaits.first)
        #expect(wait.lockedTable?.contains("customers") == true)
        #expect(wait.blockingThread != nil && wait.waitingThread != nil)
        _ = try await holder.run("ROLLBACK")
        _ = try await blocked.value
        _ = try await waiter.run("ROLLBACK")
        await holder.close()
        await waiter.close()
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func statementsReplicationVariablesAccounts(target: Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        if client.serverInfo.performanceSchemaEnabled {
            _ = try await client.execute("SELECT COUNT(*) FROM shop.orders WHERE amount > 100")
            let digests = try await client.topStatements(order: .totalLatency, limit: 20)
            #expect(!digests.isEmpty)
            #expect(digests.allSatisfy { $0.totalSeconds >= 0 && $0.totalSeconds.isFinite })
        }
        let replication = try await client.replicationOverview()
        #expect([.standalone, .source, .galeraNode].contains(replication.role))
        let variables = try await client.variables()
        #expect(variables.contains { $0.name == "max_connections" })
        let status = try await client.status()
        #expect(status.contains { $0.name.lowercased() == "uptime" })
        let accounts = try await client.accounts()
        let root = try #require(accounts.first { $0.user == "root" })
        #expect(try await client.grants(for: root).first?.uppercased().hasPrefix("GRANT") == true)
    }
}
