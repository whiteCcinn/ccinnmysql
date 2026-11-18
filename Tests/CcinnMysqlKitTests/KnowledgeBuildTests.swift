import Foundation
import Testing
@testable import CcinnMysqlKit
import MySQLKit

/// Schema facts served from memory; `beforeReturning` runs while the build is in flight.
struct FakeSchemaSource: KnowledgeSchemaSource {
    var schema: SchemaFacts
    var beforeReturning: (@Sendable () async throws -> Void)?

    func facts(database: String) async throws -> SchemaFacts {
        try await beforeReturning?()
        return schema
    }
}

/// An AdTech-flavoured demo: declared keys, naming conventions, a view and code joins.
enum KnowledgeFixture {
    static let database = "ads"

    static func tables(dropping: Set<String> = [], extra: [KnowledgeTable] = []) -> [KnowledgeTable] {
        let all = [
            table("advertisers", [col("id"), col("name", "varchar(64)", comment: "广告主名称")], comment: "Advertiser accounts"),
            table("campaigns", [col("id"), col("advertiser_id"), col("status", "tinyint", comment: "1=active 2=paused")], indexes: [["advertiser_id"]]),
            table("impressions", [col("id"), col("campaign_id"), col("dsp_id", "int"), col("cost", "decimal(18,6)")]),
            table("dsp", [col("dsp_id", "int"), col("name", "varchar(64)", comment: "DSP 名称")], pk: ["dsp_id"]),
            table("customers", [col("id"), col("email", "varchar(128)")]),
            table("orders", [col("id"), col("customer_id")], indexes: [["customer_id"]],
                  foreignKeys: [DeclaredForeignKey(name: "fk_orders_customer", columns: ["customer_id"], referencedDatabase: database,
                                                   referencedTable: "customers", referencedColumns: ["id"])]),
            table("campaign_spend", [col("campaign_id"), col("spend", "decimal(18,6)")], pk: [], kind: .view),
        ]
        return all.filter { !dropping.contains($0.name) } + extra
    }

    static let viewSQL = "select `i`.`campaign_id` AS `campaign_id`,sum(`i`.`cost`) AS `spend` from (`ads`.`impressions` `i` join `ads`.`campaigns` `c` on((`c`.`id` = `i`.`campaign_id`))) group by `i`.`campaign_id`"

    static func facts(dropping: Set<String> = [], extra: [KnowledgeTable] = []) -> SchemaFacts {
        SchemaFacts(tables: tables(dropping: dropping, extra: extra), definitions: [StoredDefinition(kind: .view, name: "campaign_spend", sql: viewSQL)],
                    serverVersion: "8.4.3")
    }

    static let goSource = """
        package report

        const q = `SELECT d.name, SUM(i.cost) FROM impressions i
            JOIN dsp d ON d.dsp_id = i.dsp_id GROUP BY d.name`
        """

    /// Owns the temporary folders for as long as a test holds it.
    final class Testbed: @unchecked Sendable {
        let data = TemporaryDirectory()
        let code = TemporaryDirectory()
        let store: KnowledgeStore
        let key: KnowledgeKey

        init(connectionID: UUID = UUID()) {
            store = KnowledgeStore(root: data.url)
            key = KnowledgeKey(connectionID: connectionID, database: KnowledgeFixture.database)
        }
    }

    /// A store with a linked project containing `goSource`.
    static func prepared() async throws -> Testbed {
        let bed = Testbed()
        try bed.code.write("report/dsp.go", goSource)
        let path = bed.code.url.path
        try await bed.store.update(bed.key) { kb in kb.projects = [LinkedProject(name: "report-svc", path: path)] }
        return bed
    }
}

@Suite("Knowledge build")
struct KnowledgeBuilderTests {
    @Test func firstBuildCombinesEverySource() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        let summary = try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        let kb = try #require(try store.load(key))
        let byID = Dictionary(uniqueKeysWithValues: kb.computed.map { ($0.id, $0) })
        #expect(byID["orders(customer_id)->customers(id)"]?.sources == [.declared])
        #expect(byID["orders(customer_id)->customers(id)"]?.constraintName == "fk_orders_customer")
        #expect(byID["campaigns(advertiser_id)->advertisers(id)"]?.sources == [.naming])
        #expect(byID["impressions(campaign_id)->campaigns(id)"]?.sources == [.view, .naming])
        #expect(byID["impressions(campaign_id)->campaigns(id)"]?.confidence == 0.9)
        #expect(byID["impressions(dsp_id)->dsp(dsp_id)"]?.sources == [.code, .naming])
        #expect(byID["impressions(dsp_id)->dsp(dsp_id)"]?.evidence.contains(KnowledgeEvidence(kind: .code, project: "report-svc", path: "report/dsp.go", line: 4)) == true)
        #expect(kb.references["dsp"]?.first?.path == "report/dsp.go")
        #expect(kb.snapshot?.tables.count == 7 && kb.snapshot?.serverVersion == "8.4.3")
        #expect(kb.build?.changes == nil && kb.build?.codeScanned == true)
        #expect(kb.build?.projects.first?.files == 1)
        #expect(summary.tables == 6 && summary.views == 1)
        #expect(summary.relationships[.declared] == 1 && summary.relationships[.code] == 1)
    }

    @Test func rebuildsKeepNotesReportChangesAndOrphans() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        let builder = KnowledgeBuilder(store: store)
        _ = try await builder.build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        try await store.update(key) { kb in
            kb.notes.tables["customers"] = TableNote(summary: "Shop customers", author: .user)
            kb.notes.tables["dsp"] = TableNote(summary: "Demand-side platforms", author: .ai)
        }
        let changedCampaigns = table("campaigns", [col("id"), col("advertiser_id"), col("status", "tinyint"), col("budget", "decimal(18,2)")])
        let summary = try await builder.build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts(
            dropping: ["dsp", "campaigns"], extra: [changedCampaigns, table("publishers", [col("id")])])))
        #expect(summary.changes == SchemaChanges(added: ["publishers"], removed: ["dsp"], changed: ["campaigns"]))
        #expect(summary.orphanedNotes == ["table note: dsp"])
        let kb = try #require(try store.load(key))
        #expect(kb.notes.tables["customers"]?.summary == "Shop customers")
        #expect(kb.notes.tables["dsp"] != nil, "orphans are kept until someone deletes them")
    }

    @Test func schemaOnlyRebuildKeepsCodeFindings() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        let builder = KnowledgeBuilder(store: store)
        _ = try await builder.build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        _ = try await builder.build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()), scanCode: false)
        let kb = try #require(try store.load(key))
        #expect(kb.computed.first { $0.id == "impressions(dsp_id)->dsp(dsp_id)" }?.sources.contains(.code) == true)
        #expect(kb.references["dsp"]?.isEmpty == false)
        #expect(kb.build?.codeScanned == false && kb.build?.projects.first?.files == 1)
    }

    @Test func projectsUnlinkedDuringABuildLeaveNoTrace() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        let source = FakeSchemaSource(schema: KnowledgeFixture.facts()) {
            try await store.update(key) { kb in kb.projects.removeAll() }
        }
        _ = try await KnowledgeBuilder(store: store).build(key, source: source)
        let kb = try #require(try store.load(key))
        #expect(kb.references.isEmpty)
        #expect(kb.computed.allSatisfy { !$0.sources.contains(.code) })
        #expect(kb.build?.projects.isEmpty == true)
        #expect(kb.projects.isEmpty, "the build never writes the project list")
    }

    @Test func corruptKnowledgeIsNotRebuiltOver() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        try Data("garbage".utf8).write(to: store.fileURL(for: key))
        await #expect(throws: KnowledgeError.self) {
            try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        }
        #expect(try Data(contentsOf: store.fileURL(for: key)) == Data("garbage".utf8))
    }

    @Test func cancelledBuildsWriteNothing() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        let before = try store.load(key)
        let task = Task {
            try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()) {
                try await Task.sleep(for: .seconds(30))
            })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.load(key) == before)
    }

    @Test func declaredKeysToOtherDatabasesAreKeptOutOfTheGraph() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        let external = table("bills", [col("id"), col("account_id")], foreignKeys: [
            DeclaredForeignKey(name: "fk_acc", columns: ["account_id"], referencedDatabase: "billing", referencedTable: "accounts", referencedColumns: ["id"]),
        ])
        _ = try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts(extra: [external])))
        #expect(try store.load(key)?.computed.contains { $0.from.table == "bills" } == false)
    }
}

@Suite("Knowledge annotations")
struct KnowledgeAnnotationTests {
    private func built() async throws -> KnowledgeFixture.Testbed {
        let bed = try await KnowledgeFixture.prepared()
        _ = try await KnowledgeBuilder(store: bed.store).build(bed.key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        return bed
    }

    private func apply(_ annotation: KnowledgeAnnotation, author: KnowledgeAuthor = .ai, store: KnowledgeStore, key: KnowledgeKey) async throws -> [String] {
        try await store.update(key, create: false) { kb in try KnowledgeAnnotator.apply(annotation, author: author, to: &kb) }
    }

    @Test func notesResolveNamesAndRejectUnknownOnes() async throws {
        let bed = try await built()
        let (store, key) = (bed.store, bed.key)
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = [.init(table: "IMPRESSIONS", summary: "One row per served impression")]
        annotation.columnNotes = [.init(table: "campaigns", column: "STATUS", note: "Delivery state", values: ["1": "active", "2": "paused"])]
        let applied = try await apply(annotation, store: store, key: key)
        #expect(applied.count == 2)
        let kb = try #require(try store.load(key))
        #expect(kb.notes.tables["impressions"]?.summary == "One row per served impression")
        #expect(kb.notes.tables["impressions"]?.author == .ai)
        #expect(kb.notes.columns["campaigns"]?["status"]?.values["2"] == "paused")
        var unknown = KnowledgeAnnotation()
        unknown.columnNotes = [.init(table: "campaigns", column: "nope", note: "x")]
        await #expect(throws: KnowledgeError.self) { try await apply(unknown, store: store, key: key) }
        unknown = KnowledgeAnnotation()
        unknown.tableNotes = [.init(table: "campaign", summary: "x")]
        await #expect(throws: KnowledgeError.self) { try await apply(unknown, store: store, key: key) }
    }

    @Test func evidenceMustBeAFileInsideALinkedProject() async throws {
        let bed = try await built()
        let (code, store, key) = (bed.code, bed.store, bed.key)
        let outside = TemporaryDirectory()
        try outside.write("secret.go", "x")
        try FileManager.default.createSymbolicLink(at: code.url.appendingPathComponent("escape.go"),
                                                   withDestinationURL: outside.url.appendingPathComponent("secret.go"))
        func relationship(_ evidence: KnowledgeAnnotation.EvidenceInput) -> KnowledgeAnnotation {
            var annotation = KnowledgeAnnotation()
            annotation.relationships = [.init(fromTable: "impressions", fromColumns: ["dsp_id"], toTable: "dsp", toColumns: ["dsp_id"], evidence: [evidence])]
            return annotation
        }
        for path in ["../\(outside.url.lastPathComponent)/secret.go", outside.url.appendingPathComponent("secret.go").path, "escape.go", "missing.go", "report"] {
            await #expect(throws: KnowledgeError.self, "\(path)") {
                try await apply(relationship(.init(path: path, line: 1)), store: store, key: key)
            }
        }
        _ = try await apply(relationship(.init(path: code.url.appendingPathComponent("report/dsp.go").path, line: 4)), store: store, key: key)
        let added = try #require(try store.load(key)?.notes.relationships.values.first)
        #expect(added.relationship.evidence == [KnowledgeEvidence(kind: .code, project: "report-svc", path: "report/dsp.go", line: 4)])
    }

    @Test func addedRelationshipsNeedEvidenceAndAreCapped() async throws {
        let bed = try await built()
        let (store, key) = (bed.store, bed.key)
        var annotation = KnowledgeAnnotation()
        annotation.relationships = [.init(fromTable: "orders", fromColumns: ["id"], toTable: "impressions", toColumns: ["id"], evidence: [])]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        annotation.relationships = [.init(fromTable: "impressions", fromColumns: ["campaign_id"], toTable: "advertisers", toColumns: ["id"],
                                          confidence: 1, note: "legacy rows",
                                          evidence: [.init(kind: .query, detail: "SELECT COUNT(*) FROM impressions i LEFT JOIN advertisers a ON a.id = i.campaign_id WHERE a.id IS NULL → 0")])]
        _ = try await apply(annotation, store: store, key: key)
        let graph = KnowledgeGraph(try #require(try store.load(key)))
        let edge = try #require(graph.edges.first { $0.id == "impressions(campaign_id)->advertisers(id)" })
        #expect(edge.relationship.sources == [.ai] && edge.confidence == 0.95 && edge.note == "legacy rows")
    }

    @Test func verdictsSteerPathsAndSurviveRebuilds() async throws {
        let bed = try await built()
        let (store, key) = (bed.store, bed.key)
        var annotation = KnowledgeAnnotation()
        annotation.verdicts = [.init(fromTable: "campaigns", fromColumns: ["advertiser_id"], toTable: "advertisers", toColumns: ["id"],
                                     status: .rejected, reason: "advertiser_id holds the agency id")]
        _ = try await apply(annotation, store: store, key: key)
        _ = try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        let graph = KnowledgeGraph(try #require(try store.load(key)))
        #expect(graph.rejected.map(\.id) == ["campaigns(advertiser_id)->advertisers(id)"])
        #expect(graph.joinPaths(from: "impressions", to: "advertisers").isEmpty)
        var declared = KnowledgeAnnotation()
        declared.verdicts = [.init(fromTable: "orders", fromColumns: ["customer_id"], toTable: "customers", toColumns: ["id"], status: .rejected, reason: "x")]
        await #expect(throws: KnowledgeError.self) { try await apply(declared, store: store, key: key) }
        var unknown = KnowledgeAnnotation()
        unknown.verdicts = [.init(fromTable: "orders", fromColumns: ["id"], toTable: "customers", toColumns: ["id"], status: .confirmed, reason: nil)]
        await #expect(throws: KnowledgeError.self) { try await apply(unknown, store: store, key: key) }
    }

    @Test func glossaryRecipesMustBeReadOnly() async throws {
        let bed = try await built()
        let (store, key) = (bed.store, bed.key)
        var annotation = KnowledgeAnnotation()
        annotation.glossary = [.init(term: "eCPM", definition: "Cost per thousand impressions", tables: ["impressions"],
                                     sql: "DELETE FROM impressions")]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        annotation.glossary = [.init(term: "eCPM", definition: "Cost per thousand impressions", tables: ["IMPRESSIONS"],
                                     sql: "SELECT SUM(cost) / COUNT(*) * 1000 AS ecpm FROM impressions")]
        _ = try await apply(annotation, store: store, key: key)
        let term = try #require(try store.load(key)?.notes.glossary["ecpm"])
        #expect(term.tables == ["impressions"] && term.term == "eCPM")
    }

    @Test func aiCannotOverwriteWhatTheUserWrote() async throws {
        let bed = try await built()
        let (store, key) = (bed.store, bed.key)
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = [.init(table: "orders", summary: "Paid and unpaid orders")]
        _ = try await apply(annotation, author: .user, store: store, key: key)
        annotation.tableNotes = [.init(table: "orders", summary: "")]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        #expect(try store.load(key)?.notes.tables["orders"]?.summary == "Paid and unpaid orders")
        _ = try await apply(annotation, author: .user, store: store, key: key)
        #expect(try store.load(key)?.notes.tables["orders"] == nil, "the user may delete it")
    }

    @Test func boundsAndAllOrNothing() async throws {
        let bed = try await built()
        let (store, key) = (bed.store, bed.key)
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = (0..<101).map { _ in .init(table: "orders", summary: "x") }
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        annotation.tableNotes = [.init(table: "orders", summary: String(repeating: "x", count: KnowledgeAnnotator.maxText + 1))]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        annotation.tableNotes = [.init(table: "orders", summary: "bell\u{07}")]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        annotation.tableNotes = [.init(table: "orders", summary: "fine"), .init(table: "nope", summary: "x")]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: key) }
        #expect(try store.load(key)?.notes.tables["orders"] == nil, "one invalid item applies nothing")
        let unbuilt = KnowledgeKey(connectionID: UUID(), database: "x")
        try await store.update(unbuilt) { _ in }
        annotation.tableNotes = [.init(table: "orders", summary: "x")]
        await #expect(throws: KnowledgeError.self) { try await apply(annotation, store: store, key: unbuilt) }
    }
}

@Suite("Knowledge queries")
struct KnowledgeQueryTests {
    private func graph(_ adjust: (inout KnowledgeBase) -> Void = { _ in }) async throws -> KnowledgeGraph {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        _ = try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        var kb = try #require(try store.load(key))
        adjust(&kb)
        return KnowledgeGraph(kb)
    }

    @Test func joinPathAcrossTwoHopsWithReadySQL() async throws {
        let paths = try await graph().joinPaths(from: "impressions", to: "advertisers")
        let best = try #require(paths.first)
        #expect(best.tables == ["impressions", "campaigns", "advertisers"])
        #expect(best.sql == "FROM impressions\nJOIN campaigns ON campaigns.id = impressions.campaign_id\nJOIN advertisers ON advertisers.id = campaigns.advertiser_id")
        #expect(try await graph().joinPaths(from: "impressions", to: "customers").isEmpty)
        #expect(try await graph().joinPaths(from: "impressions", to: "nope").isEmpty)
    }

    @Test func confidentDetoursBeatDoubtfulShortcuts() async throws {
        let shortcut = KnowledgeRelationship(from: RelationshipEnd(table: "impressions", columns: ["id"]),
                                             to: RelationshipEnd(table: "advertisers", columns: ["id"]),
                                             sources: [.naming], confidence: 0.3, cardinality: .manyToOne)
        let paths = try await graph { kb in kb.computed.append(shortcut) }.joinPaths(from: "impressions", to: "advertisers")
        #expect(paths.first?.tables == ["impressions", "campaigns", "advertisers"])
        #expect(paths.dropFirst().contains { $0.tables == ["impressions", "advertisers"] }, "the shortcut is offered as an alternative")
    }

    @Test func searchCoversNamesCommentsNotesGlossaryAndCJK() async throws {
        let graph = try await graph { kb in
            kb.notes.glossary["spend"] = GlossaryTerm(term: "spend", definition: "Money paid to DSPs", tables: ["impressions"], author: .ai)
            kb.notes.tables["campaigns"] = TableNote(summary: "投放计划", author: .user)
        }
        #expect(graph.search("dsp", limit: 5).tables.first?.table == "dsp")
        #expect(graph.search("spend", limit: 5).tables.map(\.table).prefix(2).contains("impressions"))
        #expect(graph.search("spend", limit: 5).glossary.map(\.term) == ["spend"])
        #expect(graph.search("名称", limit: 5).tables.map(\.table).sorted() == ["advertisers", "dsp"])
        #expect(graph.search("广告主收入", limit: 5).tables.first?.table == "advertisers", "two-character pieces of CJK words match")
        #expect(graph.search("投放", limit: 5).tables.first?.reasons.contains("note") == true)
        #expect(graph.search("   ", limit: 5).tables.isEmpty)
    }

    @Test func neighbourhoodIsBoundedByDepthAndLimit() async throws {
        let graph = try await graph()
        #expect(graph.neighbourhood(of: ["advertisers"], depth: 1, limit: 10) == ["advertisers", "campaigns"])
        #expect(Set(graph.neighbourhood(of: ["advertisers"], depth: 2, limit: 10)) == ["advertisers", "campaigns", "impressions"])
        #expect(graph.neighbourhood(of: ["advertisers"], depth: 5, limit: 2).count == 2)
    }
}

@Suite("Knowledge rendering")
struct KnowledgeRenderingTests {
    @Test func mermaidDiagramOfAFocusSet() throws {
        let kb = KnowledgeBase(key: KnowledgeKey(connectionID: UUID(), database: "shop"),
                               snapshot: KnowledgeSnapshot(tables: [
                                   table("customers", [col("id"), col("name", "varchar(64)", comment: "Full \"legal\" name")]),
                                   table("orders", [col("id"), col("customer_id", nullable: true), col("note", "text")]),
                               ]),
                               computed: [
                                   KnowledgeRelationship(from: RelationshipEnd(table: "orders", columns: ["customer_id"]),
                                                         to: RelationshipEnd(table: "customers", columns: ["id"]),
                                                         sources: [.naming], confidence: 0.7, cardinality: .manyToOne),
                               ])
        let diagram = KnowledgeERD.mermaid(KnowledgeGraph(kb), focus: [], columns: .keys)
        #expect(diagram.text == """
            erDiagram
                customers {
                    bigint id PK
                }
                orders {
                    bigint id PK
                    bigint customer_id FK
                }
                customers |o..o{ orders : "customer_id"
            """)
        #expect(diagram.entities == 2 && !diagram.truncated)
        let all = KnowledgeERD.mermaid(KnowledgeGraph(kb), focus: ["customers"], columns: .all)
        #expect(all.text.contains("varchar name \"Full legal name\""))
        #expect(all.text.contains("text note"))
    }

    @Test func namesAreSanitizedUniqueAndBounded() {
        let tables = [table("order-items", [col("id")]), table("order items", [col("id")]), table("2024_report", [col("id")]),
                      table("报表", [col("id")])]
        let kb = KnowledgeBase(key: KnowledgeKey(connectionID: UUID(), database: "x"), snapshot: KnowledgeSnapshot(tables: tables))
        let diagram = KnowledgeERD.mermaid(KnowledgeGraph(kb), focus: [], columns: .keys)
        let entities = diagram.text.split(separator: "\n").filter { $0.hasSuffix("{") }.map { $0.trimmingCharacters(in: .whitespaces).dropLast(2) }
        #expect(Set(entities).count == 4)
        #expect(entities.allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && !($0.first?.isNumber ?? true) })
        let many = (0..<80).map { table("t\($0)", [col("id")]) }
        let big = KnowledgeERD.mermaid(KnowledgeGraph(KnowledgeBase(key: KnowledgeKey(connectionID: UUID(), database: "x"),
                                                                    snapshot: KnowledgeSnapshot(tables: many))), focus: [], columns: .keys)
        #expect(big.entities == KnowledgeERD.maxEntities && big.truncated)
    }

    @Test func markdownExportHasEverySectionAndNoConnectionDetails() async throws {
        let bed = try await KnowledgeFixture.prepared()
        let (store, key) = (bed.store, bed.key)
        _ = try await KnowledgeBuilder(store: store).build(key, source: FakeSchemaSource(schema: KnowledgeFixture.facts()))
        try await store.update(key) { kb in
            kb.notes.glossary["ecpm"] = GlossaryTerm(term: "eCPM", definition: "Cost per mille", tables: ["impressions"], sql: "SELECT 1", author: .ai)
            kb.notes.columns["campaigns"] = ["status": ColumnNote(note: "Delivery", values: ["1": "active"], author: .user)]
        }
        let kb = try #require(try store.load(key))
        let markdown = KnowledgeMarkdown.render(kb, graph: KnowledgeGraph(kb))
        for expected in ["# ads", "## Tables", "### impressions", "## Relationships", "## Glossary", "```mermaid", "erDiagram", "eCPM",
                         "1 = active", "orders(customer_id) → customers(id)"] {
            #expect(markdown.contains(expected), "\(expected)")
        }
        #expect(!markdown.contains(key.connectionID.uuidString))
        #expect(!markdown.contains("/private/") && !markdown.contains("/var/folders"), "no local paths")
    }
}
