import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

@Suite("Knowledge builds against real servers", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct KnowledgeIntegrationTests {
    typealias Target = IntegrationEnvironment.Target

    @Test(arguments: IntegrationEnvironment.targets)
    func buildsTheDemoSchemaFromMetadataOnly(target: Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 4)
        defer { Task { await client.close() } }
        try await DemoSchema.load(into: client)

        let facts = try await MySQLKnowledgeSource(client: client).facts(database: "shop")
        let orders = try #require(facts.tables.first { $0.name == "orders" })
        #expect(orders.primaryKey == ["id"])
        #expect(orders.foreignKeys.map(\.referencedTable) == ["customers"])
        #expect(orders.indexes.contains(["customer_id", "created_at"]))
        #expect(orders.column(named: "customer_id")?.dataType.lowercased() == "int")
        #expect(facts.tables.contains { $0.name == "v_paid_orders" && $0.kind == .view })
        #expect(facts.tables.contains { $0.name == "audit_no_pk" && $0.primaryKey.isEmpty })
        #expect(facts.definitions.contains { $0.kind == .view && $0.name == "v_paid_orders" })
        #expect(facts.definitions.contains { $0.kind == .routine && $0.name == "sp_orders_by_city" })
        #expect(facts.warnings.isEmpty, "\(facts.warnings)")
        await #expect(throws: KnowledgeError.self) { try await MySQLKnowledgeSource(client: client).facts(database: "no_such_db") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-knowledge-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeStore(root: directory)
        let key = KnowledgeKey(connectionID: UUID(), database: "shop")
        let summary = try await KnowledgeBuilder(store: store).build(key, source: MySQLKnowledgeSource(client: client))
        #expect(summary.relationships[.declared] == 2)
        let knowledge = try #require(try store.load(key))
        let byID = Dictionary(uniqueKeysWithValues: knowledge.computed.map { ($0.id, $0) })
        let customer = try #require(byID["orders(customer_id)->customers(id)"])
        #expect(customer.sources == [.declared, .view, .routine], "the view and the procedure join the same way")
        #expect(byID["order_items(order_id)->orders(id)"]?.sources.contains(.declared) == true)
        let path = try #require(KnowledgeGraph(knowledge).joinPaths(from: "order_items", to: "customers").first)
        #expect(path.tables == ["order_items", "orders", "customers"])
        #expect(path.sql == "FROM order_items\nJOIN orders ON orders.id = order_items.order_id\nJOIN customers ON customers.id = orders.customer_id")
    }

    /// The real `CcinnMysql mcp` binary: build from the server and a linked project, then query and annotate offline.
    @Test(arguments: IntegrationEnvironment.targets.filter { ["MySQL 8.4", "MariaDB 10.11"].contains($0.label) })
    func mcpBuildsAndQueriesOverStdio(target: Target) async throws {
        guard MCPProcess.binaryExists else { return }
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        try await DemoSchema.load(into: admin)
        await admin.close()

        let process = try MCPProcess(target: target)
        defer { process.terminate() }
        let profile = try #require(try ProfileRepository(directory: process.directory, secrets: InMemorySecretStore()).load().first)
        let code = process.directory.appendingPathComponent("checkout-service", isDirectory: true)
        try FileManager.default.createDirectory(at: code.appendingPathComponent("internal/order"), withIntermediateDirectories: true)
        try Data("package order\n\nconst byCity = `SELECT c.city, SUM(o.amount)\nFROM orders o\nJOIN customers c ON c.id = o.customer_id\nGROUP BY c.city`\n".utf8)
            .write(to: code.appendingPathComponent("internal/order/report.go"))
        let store = KnowledgeStore(root: process.directory.appendingPathComponent("Knowledge", isDirectory: true))
        try await store.update(KnowledgeKey(connectionID: profile.id, database: "shop")) { kb in
            kb.projects = [LinkedProject(name: "checkout-service", path: code.path)]
        }

        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let tools = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("knowledge_build") && names.contains("run_query"))

        let built = try await process.call(id: 3, "knowledge_build", ["database": "shop"])
        #expect(built["relationships_by_source"]?["declared"] == .int(2))
        #expect(built["relationships_by_source"]?["code"] == .int(1))
        #expect(built["projects"]?[0]?["files"] == .int(1))

        let context = try await process.call(id: 4, "knowledge_context", ["database": "shop", "tables": ["orders"]])
        let toCustomers = context["tables"]?[0]?["relationships"]?.arrayValue?.first { $0["table"] == "customers" }
        #expect(toCustomers?["sources"] == ["declared", "view", "routine", "code"])
        #expect(toCustomers?["evidence"]?.arrayValue?.contains(.string("checkout-service:internal/order/report.go:5")) == true)
        #expect(context["tables"]?[0]?["code_references"]?[0]?["path"] == "internal/order/report.go")

        let path = try await process.call(id: 5, "knowledge_join_path", ["database": "shop", "from": "order_items", "to": "customers"])
        #expect(path["paths"]?[0]?["tables"] == ["order_items", "orders", "customers"])

        _ = try await process.call(id: 6, "knowledge_annotate", [
            "database": "shop",
            "column_notes": [["table": "orders", "column": "channel", "note": "Where the order was placed", "values": ["web": "website", "app": "mobile app"]]],
            "glossary": [["term": "GMV", "definition": "Gross merchandise value: sum of order amounts", "tables": ["orders"],
                          "sql": "SELECT SUM(amount) FROM orders WHERE status <> 'cancelled'"]],
        ])
        let search = try await process.call(id: 7, "knowledge_search", ["database": "shop", "query": "mobile gmv"])
        #expect(search["tables"]?[0]?["table"] == "orders")
        #expect(search["glossary"]?[0]?["term"] == "GMV")
        let erd = try await process.call(id: 8, "knowledge_erd", ["database": "shop"])
        #expect(erd["mermaid"]?.stringValue?.contains("customers ||--o{ orders : \"customer_id\"") == true)

        let saved = try #require(try store.load(KnowledgeKey(connectionID: profile.id, database: "shop")))
        #expect(saved.projects.count == 1, "builds never change the linked projects")
        #expect(saved.notes.glossary["gmv"]?.author == .ai)
    }
}
