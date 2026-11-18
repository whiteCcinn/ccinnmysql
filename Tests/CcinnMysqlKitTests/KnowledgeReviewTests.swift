import Foundation
import Testing
@testable import CcinnMysqlKit
import MySQLKit

/// Regression tests for the adversarial review of the knowledge base (one test per finding).
@Suite("Knowledge review regressions")
struct KnowledgeReviewTests {
    private func built(_ facts: SchemaFacts = KnowledgeFixture.facts()) async throws -> KnowledgeFixture.Testbed {
        let bed = try await KnowledgeFixture.prepared()
        _ = try await KnowledgeBuilder(store: bed.store).build(bed.key, source: FakeSchemaSource(schema: facts))
        return bed
    }

    private func apply(_ annotation: KnowledgeAnnotation, author: KnowledgeAuthor = .ai, _ bed: KnowledgeFixture.Testbed) async throws -> [String] {
        try await bed.store.update(bed.key, create: false) { kb in try KnowledgeAnnotator.apply(annotation, author: author, to: &kb) }
    }

    private func relationship(_ fromTable: String, _ from: String, _ toTable: String, _ to: String, remove: Bool = false) -> KnowledgeAnnotation {
        var annotation = KnowledgeAnnotation()
        annotation.relationships = [.init(fromTable: fromTable, fromColumns: [from], toTable: toTable, toColumns: [to],
                                          evidence: [.init(kind: .query, detail: "checked")], remove: remove)]
        return annotation
    }

    private func verdict(_ fromTable: String, _ from: String, _ toTable: String, _ to: String,
                         _ status: KnowledgeAnnotation.VerdictInput.Status) -> KnowledgeAnnotation {
        var annotation = KnowledgeAnnotation()
        annotation.verdicts = [.init(fromTable: fromTable, fromColumns: [from], toTable: toTable, toColumns: [to], status: status, reason: "because")]
        return annotation
    }

    // 1
    @Test func anAICannotOverruleTheUsersRelationships() async throws {
        let bed = try await built()
        _ = try await apply(relationship("orders", "id", "advertisers", "id"), author: .user, bed)
        await #expect(throws: KnowledgeError.self, "rejecting what the user asserted") {
            try await apply(verdict("orders", "id", "advertisers", "id", .rejected), bed)
        }
        _ = try await apply(relationship("impressions", "id", "customers", "id"), bed)
        _ = try await apply(verdict("impressions", "id", "customers", "id", .confirmed), author: .user, bed)
        await #expect(throws: KnowledgeError.self, "removing what the user confirmed") {
            try await apply(relationship("impressions", "id", "customers", "id", remove: true), bed)
        }
        #expect(KnowledgeGraph(try #require(try bed.store.load(bed.key))).joinPaths(from: "orders", to: "advertisers").isEmpty == false)
    }

    // 2
    @Test func limitsAreBytesAndNotesHaveABudget() async throws {
        let bed = try await built()
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = [.init(table: "orders", summary: "e" + String(repeating: "\u{301}", count: 5_000))]
        await #expect(throws: KnowledgeError.self, "one grapheme of 10 KB") { try await apply(annotation, bed) }
        var draft = KnowledgeAnnotation()
        draft.tableNotes = KnowledgeFixture.tables().map { .init(table: $0.name, summary: String(repeating: "x", count: 1_000)) }
        let big = draft
        await #expect(throws: KnowledgeError.self) {
            try await bed.store.update(bed.key, create: false) { kb in try KnowledgeAnnotator.apply(big, author: .ai, to: &kb, notesBudget: 2_000) }
        }
    }

    // 3
    @Test func anOlderBuildNeverOverwritesANewerOne() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let store = bed.store
        let key = bed.key
        let newer = KnowledgeFixture.facts(extra: [table("refunds", [col("id"), col("order_id")])])
        let slow = FakeSchemaSource(schema: KnowledgeFixture.facts()) {
            // Another build reads the schema later and saves first.
            _ = try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: newer))
        }
        await #expect(throws: KnowledgeError.self) { try await KnowledgeBuilder(store: store).build(key, source: slow) }
        #expect(try store.load(key)?.snapshot?.tables.contains { $0.name == "refunds" } == true)
    }

    // 4
    @Test func declaredKeysMatchColumnsInAnyCase() async throws {
        let orders = table("orders", [col("id"), col("customer_id")], foreignKeys: [
            DeclaredForeignKey(name: "fk", columns: ["CUSTOMER_ID"], referencedDatabase: KnowledgeFixture.database, referencedTable: "Customers",
                               referencedColumns: ["ID"]),
        ])
        let bed = try await built(SchemaFacts(tables: [table("customers", [col("id")]), orders]))
        let graph = KnowledgeGraph(try #require(try bed.store.load(bed.key)))
        #expect(graph.edges.map(\.id) == ["orders(customer_id)->customers(id)"])
    }

    // 5
    @Test func verdictsSurviveADirectionChangeAndOrphansAreReported() async throws {
        let bed = try await built()
        let a = RelationshipEnd(table: "campaigns", columns: ["status"])
        let b = RelationshipEnd(table: "dsp", columns: ["name"])
        try await bed.store.update(bed.key) { kb in kb.computed.append(KnowledgeRelationship(from: a, to: b, sources: [.code], confidence: 0.6, cardinality: .unknown)) }
        _ = try await apply(verdict("dsp", "name", "campaigns", "status", .rejected), author: .user, bed)
        try await bed.store.update(bed.key) { kb in
            kb.computed.removeAll { $0.from.table == "campaigns" && $0.to.table == "dsp" || $0.from.table == "dsp" && $0.to.table == "campaigns" }
            kb.computed.append(KnowledgeRelationship(from: b, to: a, sources: [.code], confidence: 0.9, cardinality: .manyToOne))
        }
        #expect(KnowledgeGraph(try #require(try bed.store.load(bed.key))).rejected.count == 1, "still rejected after the direction flipped")
        _ = try await KnowledgeBuilder(store: bed.store).build(bed.key, source: FakeSchemaSource(schema: KnowledgeFixture.facts(dropping: ["dsp"])))
        #expect(try bed.store.load(bed.key)?.orphanedNotes.contains { $0.hasPrefix("verdict") } == true)
    }

    // 6
    @Test func assignmentsAndSelectListsAreNotJoins() {
        let index = KnowledgeSchemaIndex([table("orders", [col("id"), col("user_id"), col("user_name", "varchar(9)"), col("total")]),
                                          table("users", [col("id"), col("name", "varchar(9)"), col("balance")])])
        func edges(_ sql: String) -> Set<String> {
            Set(SQLJoinExtractor.scan(Array(sql.utf8), index: index, database: "shop").joins.map {
                KnowledgeRelationship(from: $0.from, to: $0.to, sources: [], confidence: 1, cardinality: $0.cardinality).id
            })
        }
        #expect(edges("UPDATE orders o JOIN users u ON o.user_id=u.id SET o.user_name=u.name, o.total=u.balance") == ["orders(user_id)->users(id)"])
        #expect(edges("SELECT o.total = u.balance AS same FROM orders o, users u WHERE u.id = o.user_id") == ["orders(user_id)->users(id)"])
        #expect(edges("INSERT INTO orders SELECT * FROM users u ON DUPLICATE KEY UPDATE orders.total = u.balance").isEmpty)
        #expect(edges("UPDATE orders SET total = (SELECT 1 FROM users u WHERE u.id = orders.user_id)") == ["orders(user_id)->users(id)"])
    }

    // 7
    @Test func oneToOneKeysKeepTheirDirection() {
        let relationship = KnowledgeRelationship(from: RelationshipEnd(table: "z_ext", columns: ["user_id"]),
                                                 to: RelationshipEnd(table: "a_users", columns: ["id"]),
                                                 sources: [.declared], confidence: 1, cardinality: .oneToOne)
        #expect(relationship.from.table == "z_ext")
    }

    // 8
    @Test func contextAndDiagramsStayWithinTheirBudget() async throws {
        let bed = try await built(SchemaFacts(tables: [
            table("t1", [col("id")]), table("t2", [col("id")]),
            table("hub", (0..<400).map { col("column_with_a_long_name_\($0)", "varchar(255)", comment: String(repeating: "c", count: 60)) }, pk: []),
        ]))
        let tools = KnowledgeMCPTools(resolver: MCPProfileResolver(profiles: [], defaultProfile: nil, forceReadOnly: false),
                                      registry: MCPClientRegistry { _ in throw MySQLError(.network, "offline") }, store: bed.store, audit: nil,
                                      payloadBudget: 8_000)
        let graph = try #require(try bed.store.loadWithGraph(bed.key)?.graph)
        let context = try tools.tableContext(try #require(try bed.store.load(bed.key)), graph,
                                             Arguments(["tables": ["t1", "hub", "t2"]]))
        #expect(context["tables"]?.arrayValue?.compactMap { $0["name"]?.stringValue }.contains("t2") == true, "later tables are still tried")
        #expect(context.serialized().utf8.count <= 8_000)
        let diagram = tools.erd(graph, Arguments(["columns": "all"]))
        #expect(diagram.serialized().utf8.count <= 8_000)
        #expect(diagram["truncated"] == .bool(true))
    }

    // 9
    @Test func markdownCannotBeInjectedOrForged() async throws {
        let bed = try await built()
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = [.init(table: "orders", summary: "Orders *(user, 2026-01-01)*\n\n## Injected <img src=x onerror=alert(1)>")]
        annotation.glossary = [.init(term: "x", definition: "y", sql: "SELECT 1 /*\n```\n# injected\n```sql\n*/")]
        _ = try await apply(annotation, bed)
        let knowledge = try #require(try bed.store.load(bed.key))
        let markdown = KnowledgeMarkdown.render(knowledge, graph: KnowledgeGraph(knowledge))
        #expect(!markdown.contains("\n## Injected"))
        #expect(!markdown.contains("<img"))
        #expect(!markdown.contains("*(user, 2026-01-01)*"))
        #expect(markdown.contains("````sql"), "a fence longer than any run of back quotes in the recipe")
        for character in ["\u{202E}", "\u{2066}", "\u{2028}"] {
            var bidi = KnowledgeAnnotation()
            bidi.tableNotes = [.init(table: "orders", summary: "abc\(character)def")]
            await #expect(throws: KnowledgeError.self) { try await apply(bidi, bed) }
        }
    }

    // 10
    @Test func queryEvidenceKeepsNoValues() async throws {
        let bed = try await built()
        var annotation = KnowledgeAnnotation()
        annotation.relationships = [.init(fromTable: "orders", fromColumns: ["id"], toTable: "customers", toColumns: ["id"],
                                          evidence: [.init(kind: .query, detail: "SELECT * FROM customers WHERE email = 'alice@example.com'")])]
        _ = try await apply(annotation, bed)
        let knowledge = try #require(try bed.store.load(bed.key))
        let stored = try #require(knowledge.notes.relationships.values.first?.relationship.evidence.first?.detail)
        #expect(!stored.contains("alice@example.com"))
        #expect(!KnowledgeMarkdown.render(knowledge, graph: KnowledgeGraph(knowledge)).contains("SELECT * FROM customers"))
    }

    // 11
    @Test func occurrencesDoNotGrowOnSchemaOnlyRebuilds() async throws {
        let bed = try await built()
        func occurrences() throws -> Int? { try bed.store.load(bed.key)?.computed.first { $0.id == "impressions(dsp_id)->dsp(dsp_id)" }?.occurrences }
        let first = try occurrences()
        for _ in 0..<3 {
            _ = try await KnowledgeBuilder(store: bed.store).build(bed.key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()), scanCode: false)
        }
        #expect(try occurrences() == first)
    }

    // 12
    @Test func aProjectRelocatedDuringABuildIsNotCreditedWithTheOldFolder() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let store = bed.store
        let key = bed.key
        let elsewhere = TemporaryDirectory()
        let path = elsewhere.url.path
        let source = FakeSchemaSource(schema: KnowledgeFixture.facts()) {
            try await store.update(key) { kb in kb.projects[0].path = path }
        }
        _ = try await KnowledgeBuilder(store: store).build(key, source: source)
        let knowledge = try #require(try store.load(key))
        #expect(knowledge.references.isEmpty && knowledge.build?.projects.isEmpty == true)
        withExtendedLifetime(elsewhere) {}
    }

    // 13
    @Test func gitHeadNeverFollowsALinkToAHugeFile() throws {
        let directory = TemporaryDirectory()
        try directory.write(".git/real-head", "ref: refs/heads/main\n" + String(repeating: " ", count: 200_000))
        try directory.write(".git/refs/heads/main", GitHeadTests.sha)
        try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent(".git/HEAD"),
                                                   withDestinationURL: directory.url.appendingPathComponent(".git/real-head"))
        #expect(GitHead.commit(for: directory.url) == nil)
    }

    // 14
    @Test func fromListsAreLinear() {
        let index = KnowledgeSchemaIndex([table("from", [col("id")]), table("x", [col("id")])])
        let text = Array(String(repeating: "from x, ", count: 20_000).utf8)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SQLJoinExtractor.scan(text, index: index, database: "shop") }
        #expect(elapsed < .seconds(3), "\(elapsed)")
    }

    // 15
    @Test func onlyDamagedFilesOfferAReset() async throws {
        let bed = try await built()
        let file = bed.store.fileURL(for: bed.key)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["formatVersion"] = KnowledgeBase.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(throws: KnowledgeError.self) { try bed.store.load(bed.key) }
        do { _ = try bed.store.load(bed.key) } catch let error as KnowledgeError { #expect(error.kind == .newerFormat) }
        try Data("{broken".utf8).write(to: file)
        do { _ = try bed.store.load(bed.key) } catch let error as KnowledgeError { #expect(error.kind == .damaged) }
    }
}
