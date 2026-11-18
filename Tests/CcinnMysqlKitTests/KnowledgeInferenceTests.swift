import Foundation
import Testing
@testable import CcinnMysqlKit

/// Shorthand for test schemas: `col("user_id", "bigint")`.
func col(_ name: String, _ type: String = "bigint", nullable: Bool = false, comment: String? = nil) -> KnowledgeColumn {
    KnowledgeColumn(name: name, type: type, dataType: String(type.prefix { $0.isLetter }), nullable: nullable, comment: comment)
}

func table(_ name: String, _ columns: [KnowledgeColumn], pk: [String] = ["id"], unique: [[String]] = [], indexes: [[String]] = [],
           kind: KnowledgeTable.Kind = .table, comment: String? = nil, foreignKeys: [DeclaredForeignKey] = []) -> KnowledgeTable {
    KnowledgeTable(name: name, kind: kind, comment: comment, columns: columns, primaryKey: pk, uniqueKeys: unique, indexes: indexes,
                   foreignKeys: foreignKeys)
}

private func edges(_ relationships: [KnowledgeRelationship]) -> Set<String> {
    Set(relationships.map(\.id))
}

@Suite("Knowledge naming inference")
struct NamingInferenceTests {
    @Test func snakeCaseIdColumnsReferenceTheirTable() throws {
        let found = NamingInference.relationships(in: [
            table("users", [col("id")]),
            table("orders", [col("id"), col("user_id")], indexes: [["user_id"]]),
        ])
        let edge = try #require(found.first)
        #expect(found.count == 1)
        #expect(edge.id == "orders(user_id)->users(id)")
        #expect(edge.sources == [.naming] && edge.cardinality == .manyToOne)
        #expect(edge.confidence > 0.5 && edge.confidence <= 0.85)
        #expect(edge.evidence.first?.kind == .naming)
    }

    @Test func camelCasePrefixesPluralsAndKnownPrefixes() {
        let found = edges(NamingInference.relationships(in: [
            table("users", [col("id")]),
            table("orders", [col("id"), col("userId"), col("categoryID")]),
            table("categories", [col("id")]),
            table("shop_customers", [col("id")]),
            table("shop_invoices", [col("id"), col("customer_id")]),
            table("t_user", [col("id")]),
            table("t_order", [col("id"), col("user_id")]),
            table("boxes", [col("id")]),
            table("parcels", [col("id"), col("box_id")]),
        ]))
        #expect(found.contains("orders(userId)->users(id)"))
        #expect(found.contains("orders(categoryID)->categories(id)"))
        #expect(found.contains("shop_invoices(customer_id)->shop_customers(id)"))
        #expect(found.contains("t_order(user_id)->t_user(id)"))
        #expect(found.contains("parcels(box_id)->boxes(id)"))
    }

    @Test func targetKeyNamedLikeTheColumn() {
        let found = edges(NamingInference.relationships(in: [
            table("campaign", [col("campaign_id"), col("name", "varchar(64)")], pk: ["campaign_id"]),
            table("report_hour", [col("id"), col("campaign_id"), col("dsp_id", "int")]),
            table("dsp", [col("dsp_id", "int")], pk: ["dsp_id"]),
            table("placement", [col("code", "varchar(32)"), col("title", "varchar(64)")], pk: ["code"]),
            table("ad", [col("id"), col("placement_code", "varchar(32)")]),
        ]))
        #expect(found.contains("report_hour(campaign_id)->campaign(campaign_id)"))
        #expect(found.contains("report_hour(dsp_id)->dsp(dsp_id)"))
        #expect(!found.contains { $0.hasPrefix("ad(") }, "placement_code is not an id column and placement's key is not named like it")
    }

    @Test func genericKeyNamesAreNotReferences() {
        // Found on the demo schema: legacy_counters' key is `name`, which says nothing about customers.name.
        let found = edges(NamingInference.relationships(in: [
            table("legacy_counters", [col("name", "varchar(40)"), col("hits", "int")], pk: ["name"]),
            table("session_cache", [col("token", "char(32)")], pk: ["token"]),
            table("customers", [col("id"), col("name", "varchar(100)"), col("token", "char(32)")]),
            table("t_dsp_info", [col("dsp_id", "int")], pk: ["dsp_id"]),
            table("bids", [col("id"), col("dsp_id", "int")]),
        ]))
        #expect(found == ["bids(dsp_id)->t_dsp_info(dsp_id)"], "an id-like key name still finds its only owner")
    }

    @Test func selfReferenceAndPolymorphicPairs() {
        let found = edges(NamingInference.relationships(in: [
            table("categories", [col("id"), col("parent_id", nullable: true)]),
            table("targets", [col("id")]),
            table("comments", [col("id"), col("target_id"), col("target_type", "varchar(32)")]),
        ]))
        #expect(found == ["categories(parent_id)->categories(id)"])
    }

    @Test func typesMustBeCompatibleAndWidthMismatchCostsConfidence() throws {
        let found = NamingInference.relationships(in: [
            table("users", [col("id")]),
            table("accounts", [col("id", "int")]),
            table("orders", [col("id"), col("user_id", "varchar(20)"), col("account_id", "bigint")]),
            table("sessions", [col("id"), col("account_id", "int")]),
        ])
        #expect(!edges(found).contains("orders(user_id)->users(id)"), "varchar never references a bigint key")
        let wide = try #require(found.first { $0.id == "orders(account_id)->accounts(id)" })
        let exact = try #require(found.first { $0.id == "sessions(account_id)->accounts(id)" })
        #expect(wide.confidence < exact.confidence)
    }

    @Test func declaredKeysCompositeTargetsAndViewsAreSkipped() {
        let declared = DeclaredForeignKey(name: "fk", columns: ["user_id"], referencedDatabase: "shop", referencedTable: "users", referencedColumns: ["id"])
        let found = edges(NamingInference.relationships(in: [
            table("users", [col("id")]),
            table("orders", [col("id"), col("user_id")], foreignKeys: [declared]),
            table("line", [col("order_id"), col("seq", "int")], pk: ["order_id", "seq"]),
            table("notes", [col("id"), col("line_id")]),
            table("user_view", [col("user_id")], pk: [], kind: .view),
        ]))
        // Not orders(user_id) (declared), not notes(line_id) (composite target), nothing from the view; a column of a
        // composite key may still reference another table.
        #expect(found == ["line(order_id)->orders(id)"])
    }
}

@Suite("Knowledge SQL join extraction")
struct SQLJoinExtractorTests {
    static let index = KnowledgeSchemaIndex([
        table("customers", [col("id"), col("name", "varchar(64)"), col("city", "varchar(64)")]),
        table("orders", [col("id"), col("order_id"), col("customer_id"), col("created_at", "datetime")], unique: [["order_id"]]),
        table("shipments", [col("id"), col("order_id"), col("city", "varchar(64)")]),
        table("employees", [col("id"), col("manager_id", nullable: true)]),
    ])

    private func scan(_ text: String, database: String = "shop") -> SQLJoinExtractor.Findings {
        SQLJoinExtractor.scan(Array(text.utf8), index: Self.index, database: database)
    }

    private func ids(_ findings: SQLJoinExtractor.Findings) -> Set<String> {
        Set(findings.joins.map { KnowledgeRelationship(from: $0.from, to: $0.to, sources: [.code], confidence: 1, cardinality: $0.cardinality).id })
    }

    @Test func aliasedJoinInGoSourceWithLines() throws {
        let findings = scan("""
            package repo

            const q = `
            SELECT o.id, c.name
            FROM orders o
            JOIN customers AS c ON c.id = o.customer_id
            WHERE o.created_at > ?`
            """)
        let join = try #require(findings.joins.first)
        #expect(findings.joins.count == 1)
        #expect(join.from == RelationshipEnd(table: "orders", columns: ["customer_id"]))
        #expect(join.to == RelationshipEnd(table: "customers", columns: ["id"]))
        #expect(join.cardinality == .manyToOne)
        #expect(join.line == 6)
        #expect(findings.tables["orders"]?.firstLine == 5 && findings.tables["orders"]?.sql == true)
        #expect(findings.tables["customers"]?.firstLine == 6)
    }

    @Test func viewDefinitionsWithBackQuotesAndSchemaQualifiers() {
        let definition = "select `o`.`id` AS `id`,`c`.`name` AS `name` from (`shop`.`orders` `o` join `shop`.`customers` `c` on((`c`.`id` = `o`.`customer_id`))) where (`o`.`id` > 0)"
        #expect(ids(scan(definition)) == ["orders(customer_id)->customers(id)"])
        #expect(ids(scan(definition, database: "other")).isEmpty, "tables of another database are not ours")
        #expect(ids(scan("SELECT * FROM shop.orders JOIN shop.customers ON shop.customers.id = shop.orders.customer_id"))
                == ["orders(customer_id)->customers(id)"])
        #expect(ids(scan("SELECT * FROM a.orders JOIN a.customers ON a.customers.id = a.orders.customer_id")).isEmpty)
    }

    @Test func codeComparisonsAreNotJoins() {
        let code = """
            if a.id == b.customer_id { }
            if (o.id === c.customer_id) {}
            ok := o.id != c.customer_id
            x := orders.id
            y >= orders.customer_id
            """
        #expect(scan(code).joins.isEmpty)
        #expect(scan("FROM orders o JOIN customers c ON c.id == o.customer_id").joins.isEmpty)
    }

    @Test func usingCommaJoinsAndPlainTableQualifiers() {
        #expect(ids(scan("SELECT * FROM orders JOIN shipments USING (order_id)")) == ["shipments(order_id)->orders(order_id)"])
        #expect(ids(scan("SELECT * FROM orders o, customers c WHERE c.id = o.customer_id")) == ["orders(customer_id)->customers(id)"])
        #expect(ids(scan("select * from ORDERS join Customers on Customers.ID = Orders.Customer_Id")) == ["orders(customer_id)->customers(id)"])
    }

    @Test func statementBoundariesUnknownColumnsAndSelfJoins() {
        #expect(scan("SELECT * FROM orders o; SELECT * FROM customers c WHERE c.id = o.customer_id").joins.isEmpty)
        #expect(scan("FROM orders o JOIN customers c ON c.id = o.missing").joins.isEmpty)
        #expect(ids(scan("FROM employees e JOIN employees m ON e.manager_id = m.id")) == ["employees(manager_id)->employees(id)"])
    }

    @Test func nonKeyEqualitiesHaveUnknownCardinality() throws {
        let join = try #require(scan("FROM customers c JOIN shipments s ON s.city = c.city").joins.first)
        #expect(join.cardinality == .unknown)
    }

    @Test func templateLiteralsAndStringReferences() {
        let javascript = "const q = `SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id`;\nconst t = db.table(\"orders\"); const u = 'customers'; const v = \"orders_archive\""
        let findings = scan(javascript)
        #expect(ids(findings) == ["orders(customer_id)->customers(id)"])
        #expect(findings.tables["orders"]?.count == 2)
        #expect(findings.tables["customers"]?.count == 2)
        let stringOnly = scan("@Table(name = \"shipments\")")
        #expect(stringOnly.tables["shipments"]?.sql == false)
        #expect(scan("shipments are late").tables["shipments"] == nil, "a bare word is not a reference")
    }

    @Test func survivesHostileInput() {
        let noise = (0..<20_000).map { _ in UInt8.random(in: 0...255) }
        _ = SQLJoinExtractor.scan(noise, index: Self.index, database: "shop")
        _ = scan(String(repeating: "`", count: 10_000) + String(repeating: "a.b = ", count: 5_000))
        _ = scan("FROM")
        _ = scan("JOIN orders AS")
        _ = scan("x.y =")
    }
}
