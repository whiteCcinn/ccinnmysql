import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// The knowledge base against real servers, on the demo `shop` schema (declared foreign keys, a view, a procedure, a
/// trigger and an event).
@Suite("Knowledge integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct KnowledgeIntegrationTests {
    typealias Target = IntegrationEnvironment.Target

    private func temporaryStore() -> KnowledgeStore {
        KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-kb-\(UUID().uuidString)", isDirectory: true))
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func extractionReadsKeysViewsAndRoutines(target: Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 4)
        defer { Task { await client.close() } }
        try await DemoSchema.load(into: client)
        let schema = try await KnowledgeExtractor.extract(database: "shop", from: client)
        let orders = try #require(schema.tables.first { $0.name == "orders" })
        #expect(orders.kind == .table && orders.keys.primary == ["id"])
        #expect(orders.columns.first { $0.name == "id" }?.isKey == true)
        #expect(schema.tables.first { $0.name == "v_paid_orders" }?.kind == .view)
        #expect(schema.tables.first { $0.name == "v_paid_orders" }?.definition?.lowercased().contains("join") == true)
        #expect(schema.tables.first { $0.name == "audit_no_pk" }?.keys.primary.isEmpty == true)
        #expect(Set(schema.routines.map(\.name)).isSuperset(of: ["sp_orders_by_city", "trg_orders_bi", "ev_purge_sessions"]))
        let keys = schema.foreignKeys.map { "\($0.table).\($0.columns.joined(separator: ","))->\($0.referencedTable)" }
        #expect(Set(keys) == ["orders.customer_id->customers", "order_items.order_id->orders"])
        if target.flavor == .mariadb {
            #expect(schema.serverIdentifier == nil, "MariaDB has no server_uuid")
        } else {
            #expect(schema.serverIdentifier?.count == 36)
        }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func refreshCombinesForeignKeysViewsAndRoutines(target: Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 4)
        defer { Task { await client.close() } }
        try await DemoSchema.load(into: client)
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let key = DatabaseKey(cluster: ClusterKey(rawValue: "my://127.0.0.1:\(target.port)"), catalog: "def", database: "shop")
        _ = try await KnowledgeService.refresh(key, source: client, store: store, history: [], infer: KnowledgeInference.machineRelationships, now: Date())
        let knowledge = try #require(try store.database(key))
        let toCustomers = try #require(knowledge.relationships.first { $0.from.table == "orders" && $0.to.table == "customers" })
        #expect(RelationshipConfidence.score(toCustomers) == 100, "InnoDB enforces it")
        let symbols = Set(toCustomers.evidence.compactMap(\.symbol))
        #expect(symbols.isSuperset(of: ["v_paid_orders", "sp_orders_by_city"]), "the view and the procedure join the same way: \(symbols)")
        let path = JoinPathFinder.find(from: "order_items", to: "customers", in: knowledge, confidence: { RelationshipConfidence.score($0) })
        #expect(path.paths.first?.sql == "FROM shop.order_items\nJOIN shop.orders ON order_items.order_id = orders.id\nJOIN shop.customers ON orders.customer_id = customers.id")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func visibilityFollowsTheAccountsPrivileges(target: Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { await admin.close() } }
        try await DemoSchema.load(into: admin)
        _ = try await admin.execute("DROP USER IF EXISTS 'kb_reader'@'%'")
        _ = try await admin.execute("CREATE USER 'kb_reader'@'%' IDENTIFIED BY 'kb-reader-pw'")
        _ = try await admin.execute("GRANT SELECT ON shop.orders TO 'kb_reader'@'%'")
        do {
            var configuration = IntegrationEnvironment.rootConfiguration(target)
            configuration.username = "kb_reader"
            configuration.password = "kb-reader-pw"
            let reader = try await MySQLClient.connect(configuration, poolSize: 1)
            #expect(try await KnowledgeMCP.liveVisibility(reader, "shop") == ["orders"])
            #expect(try await KnowledgeMCP.liveVisibility(reader, "mysql") == nil, "the server's own databases are never shown")
            #expect(try await KnowledgeMCP.liveVisibility(admin, "performance_schema") == nil)
            await reader.close()
        } catch {
            _ = try? await admin.execute("DROP USER IF EXISTS 'kb_reader'@'%'")
            throw error
        }
        _ = try await admin.execute("DROP USER IF EXISTS 'kb_reader'@'%'")
    }
}
