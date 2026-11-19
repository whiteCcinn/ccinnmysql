import Foundation
import MySQLKit
import Testing
@testable import CcinnMysqlKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let later = Date(timeIntervalSince1970: 1_800_086_400)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "my://db:3306"), catalog: "def", database: "adx")

private func object(_ name: String, _ kind: ObjectKind = .table, comment: String? = nil) -> DatabaseObject {
    var object = DatabaseObject(schema: "adx", name: name, kind: kind)
    object.comment = comment
    return object
}

private func column(_ name: String, _ ordinal: Int, _ type: String, nullable: Bool = true, comment: String? = nil) -> ColumnInfo {
    ColumnInfo(name: name, ordinal: ordinal, dataType: String(type.prefix { $0 != "(" }), columnType: type, isNullable: nullable, comment: comment)
}

private func primaryKey(_ columns: String...) -> IndexInfo {
    IndexInfo(name: "PRIMARY", isUnique: true, type: "BTREE", columns: columns.map { IndexColumn(name: $0) })
}

private func rows(dspIDType: String = "bigint", reportComment: String = "hourly report", viewDefinition: String? = nil,
                  extra: [(DatabaseObject, [ColumnInfo], [IndexInfo])] = [], dropping: Set<String> = []) -> KnowledgeSchemaRows {
    var objects = [object("report_adx_hour", comment: reportComment), object("dsp"), object("v_dsp_report", .view)]
    var columns: [String: [ColumnInfo]] = [
        "report_adx_hour": [column("hour", 2, "tinyint", nullable: false), column("dt", 1, "date", nullable: false),
                            column("dsp_id", 3, dspIDType, nullable: false, comment: "DSP"), column("dsp_request", 4, "bigint")],
        "dsp": [column("id", 1, "bigint", nullable: false), column("name", 2, "varchar(64)")],
        "v_dsp_report": [column("dt", 1, "date"), column("dsp_name", 2, "varchar(64)")],
    ]
    var indexes: [String: [IndexInfo]] = ["report_adx_hour": [primaryKey("dt", "hour", "dsp_id")], "dsp": [primaryKey("id")]]
    let definition = viewDefinition ?? "select `r`.`dt` AS `dt`,`d`.`name` AS `dsp_name` from (`adx`.`report_adx_hour` `r` join `adx`.`dsp` `d` "
        + "on((`r`.`dsp_id` = `d`.`id`))) where (`r`.`dt` > '2026-01-01')"
    for (extraObject, extraColumns, extraIndexes) in extra {
        objects.append(extraObject)
        columns[extraObject.name] = extraColumns
        indexes[extraObject.name] = extraIndexes
    }
    objects.removeAll { dropping.contains($0.name) }
    return KnowledgeSchemaRows(objects: objects, columns: columns, indexes: indexes,
                               definitions: [StoredDefinition(kind: .view, name: "v_dsp_report", sql: definition)])
}

private func schema(dspIDType: String = "bigint", reportComment: String = "hourly report", viewDefinition: String? = nil,
                    extra: [(DatabaseObject, [ColumnInfo], [IndexInfo])] = [], dropping: Set<String> = []) -> ExtractedSchema {
    KnowledgeExtractor.build(database: "adx", rows: rows(dspIDType: dspIDType, reportComment: reportComment, viewDefinition: viewDefinition, extra: extra,
                                                     dropping: dropping),
                             serverVersion: "MySQL 8.4.3", serverIdentifier: nil)
}

@Suite("Schema fingerprints")
struct SchemaFingerprintTests {
    private func facts(_ schema: ExtractedSchema, _ name: String) throws -> TableFacts {
        let table = try #require(schema.tables.first { $0.name == name })
        return KnowledgeRefresher.tableFacts(table, database: "adx", previous: nil, now: now)
    }

    @Test func factsFollowTheServerInOrdinalOrder() throws {
        let report = try facts(schema(), "report_adx_hour")
        #expect(report.columns.map(\.name) == ["dt", "hour", "dsp_id", "dsp_request"])
        #expect(report.kind == .table && report.model == nil)
        #expect(report.keys.primary == ["dt", "hour", "dsp_id"])
        #expect(report.columns.filter(\.isKey).map(\.name) == ["dt", "hour", "dsp_id"])
        #expect(report.columns.last?.isNullable == true && report.columns.first?.isNullable == false)
        #expect(report.state == .new && report.firstSeen == now)
        let view = try facts(schema(), "v_dsp_report")
        #expect(view.kind == .view)
        #expect(view.lineage == [TableReference(table: "dsp"), TableReference(table: "report_adx_hour")], "the view's own database is bare")
    }

    @Test func commentsDoNotChangeTheStructureFingerprint() throws {
        let original = try facts(schema(), "report_adx_hour")
        let recommented = try facts(schema(reportComment: "per hour"), "report_adx_hour")
        #expect(original.fingerprint == recommented.fingerprint)
        #expect(original.commentFingerprint != recommented.commentFingerprint)
        let retyped = try facts(schema(dspIDType: "varchar(32)"), "report_adx_hour")
        #expect(original.fingerprint != retyped.fingerprint)
    }

    @Test func literalOnlyChangesInAViewDefinitionKeepTheFingerprint() throws {
        let original = try facts(schema(), "v_dsp_report")
        let otherDate = try facts(schema(viewDefinition: "select `r`.`dt` AS `dt`,`d`.`name` AS `dsp_name` from (`adx`.`report_adx_hour` `r` join `adx`.`dsp` `d` "
                                         + "on((`r`.`dsp_id` = `d`.`id`))) where (`r`.`dt` > '2026-06-01')"), "v_dsp_report")
        #expect(original.fingerprint == otherDate.fingerprint)
        let otherJoin = try facts(schema(viewDefinition: "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.hour = d.id"), "v_dsp_report")
        #expect(original.fingerprint != otherJoin.fingerprint)
    }
}

@Suite("Knowledge refresh")
struct KnowledgeRefreshTests {
    private func refreshed(_ schemas: [ExtractedSchema], machine: [[Relationship]] = []) -> (DatabaseKnowledge, KnowledgeRefresher.Report) {
        var knowledge = DatabaseKnowledge(key: key)
        var report = KnowledgeRefresher.Report()
        for (index, schema) in schemas.enumerated() {
            report = KnowledgeRefresher.apply(schema, machineRelationships: index < machine.count ? machine[index] : [], to: &knowledge,
                                              now: index == 0 ? now : later)
        }
        return (knowledge, report)
    }

    @Test func tableStatesAcrossRefreshes() {
        let renamed = (object("dsp_v2"), [column("id", 1, "bigint", nullable: false), column("name", 2, "varchar(64)")], [primaryKey("id")])
        let (knowledge, report) = refreshed([schema(), schema(dspIDType: "varchar(32)", extra: [renamed], dropping: ["dsp"])])
        #expect(knowledge.table(named: "report_adx_hour")?.state == .changed)
        #expect(knowledge.table(named: "report_adx_hour")?.changedAt == later)
        #expect(knowledge.table(named: "dsp")?.state == .dropped, "kept until the user prunes it")
        #expect(knowledge.table(named: "dsp_v2")?.state == .new)
        #expect(knowledge.table(named: "v_dsp_report")?.state == .fresh)
        #expect(report.tables == .init(total: 3, new: 1, changed: 1, dropped: 1))
        #expect(report.possibleRenames == [["dsp", "dsp_v2"]], "same structure, never moved automatically")
        #expect(knowledge.serverVersion == "MySQL 8.4.3")
    }

    @Test func lineageBecomesRelationshipsThatNeverJoin() {
        let (knowledge, _) = refreshed([schema()])
        let lineage = knowledge.relationships.filter { $0.kind == .lineage }
        #expect(Set(lineage.map(\.to.table)) == ["dsp", "report_adx_hour"])
        #expect(lineage.allSatisfy { $0.from.table == "v_dsp_report" && $0.evidence.map(\.source) == [.lineage] })
    }

    // Machine evidence is recomputed on every refresh; what the user and the AI added stays.
    @Test func machineEvidenceIsReplacedCuratedEvidenceKept() throws {
        let from = Relationship.End(table: "report_adx_hour", columns: ["dsp_id"])
        let to = Relationship.End(table: "dsp", columns: ["id"])
        let naming = Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 55, at: now)])
        let gone = Relationship(from: .init(table: "report_adx_hour", columns: ["hour"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                evidence: [Evidence(source: .naming, score: 30, at: now)])
        var (knowledge, _) = refreshed([schema()], machine: [[naming, gone]])
        let id = naming.id
        let index = try #require(knowledge.relationships.firstIndex { $0.id == id })
        knowledge.relationships[index].evidence.append(Evidence(source: .code, path: "dao.go", line: 12, by: "ai:claude-code", at: now))
        let rerun = Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 60, at: later)])
        let report = KnowledgeRefresher.apply(schema(), machineRelationships: [rerun], to: &knowledge, now: later)
        let kept = try #require(knowledge.relationships.first { $0.id == id })
        #expect(kept.evidence.map(\.source).sorted { $0.rawValue < $1.rawValue } == [.code, .naming])
        #expect(kept.evidence.first { $0.source == .naming }?.score == 60)
        #expect(!knowledge.relationships.contains { $0.id == gone.id }, "machine-only evidence that is gone takes the relationship with it")
        #expect(report.relationships.removed == 1)
    }

    @Test func tombstonedRelationshipsAreNotInferredAgain() {
        let naming = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                  evidence: [Evidence(source: .naming, score: 55, at: now)])
        var knowledge = DatabaseKnowledge(key: key)
        knowledge.tombstones = [Tombstone(id: naming.id, deletedAt: now, by: "user")]
        _ = KnowledgeRefresher.apply(schema(), machineRelationships: [naming], to: &knowledge, now: now)
        #expect(!knowledge.relationships.contains { $0.id == naming.id })
    }

    @Test func notesAndRelationshipsGoStaleWhenTheirTableChanges() throws {
        var (knowledge, _) = refreshed([schema()])
        let report = try #require(knowledge.table(named: "report_adx_hour"))
        knowledge.notes.append(Note(id: "n1", table: "report_adx_hour", column: "dsp_id", kind: .caveat, text: "0 means house ads", evidence: [],
                                    by: "ai:codex", at: now, fingerprint: report.fingerprint))
        let curated = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                   evidence: [Evidence(source: .ai, by: "ai:codex", at: now)],
                                   fingerprints: ["report_adx_hour": report.fingerprint, "dsp": knowledge.table(named: "dsp")?.fingerprint ?? ""])
        knowledge.relationships.append(curated)
        #expect(!KnowledgeFreshness.isStale(knowledge.notes[0], in: knowledge))
        #expect(!KnowledgeFreshness.isStale(curated, in: knowledge))

        let refresh = KnowledgeRefresher.apply(schema(dspIDType: "varchar(32)"), machineRelationships: [], to: &knowledge, now: later)
        #expect(KnowledgeFreshness.isStale(knowledge.notes[0], in: knowledge))
        #expect(KnowledgeFreshness.isStale(try #require(knowledge.relationships.first { $0.id == curated.id }), in: knowledge))
        #expect(refresh.notesStale == 1)
        #expect(refresh.relationships.nowStale == 1)
    }

    @Test func relationshipsToMissingColumnsAreBroken() {
        let (knowledge, _) = refreshed([schema()])
        let broken = Relationship(from: .init(table: "report_adx_hour", columns: ["app_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                  evidence: [Evidence(source: .ai, at: now)])
        #expect(KnowledgeFreshness.isBroken(broken, in: knowledge))
        let fine = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                evidence: [Evidence(source: .ai, at: now)])
        #expect(!KnowledgeFreshness.isBroken(fine, in: knowledge))
        let otherDatabase = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(database: "admin", table: "dsp", columns: ["id"]),
                                         kind: .manyToOne, evidence: [Evidence(source: .ai, at: now)])
        #expect(!KnowledgeFreshness.isBroken(otherDatabase, in: knowledge), "another database's columns are checked against its own knowledge")
    }
}

@Suite("Knowledge extraction")
struct KnowledgeExtractionTests {
    private struct FakeSource: KnowledgeSchemaSource {
        let knowledgeServerVersion: String? = "MySQL 8.4.3"
        func knowledgeRows(_ database: String) async throws -> KnowledgeSchemaRows {
            KnowledgeSchemaRows(
                objects: [object("orders"), object("customers"), object("v_x", .view), object("sp_x", .procedure), object("trg_x", .trigger)],
                columns: ["orders": [column("id", 1, "bigint", nullable: false), column("customer_id", 2, "bigint")],
                          "customers": [column("id", 1, "bigint", nullable: false), column("tenant", 2, "varchar(16)", nullable: false),
                                        column("code", 3, "varchar(16)", nullable: false)]],
                indexes: ["orders": [primaryKey("id")],
                          "customers": [primaryKey("id"), IndexInfo(name: "uk_code", isUnique: true, type: "BTREE", columns: [IndexColumn(name: "tenant"), IndexColumn(name: "code")]),
                                        IndexInfo(name: "fx", isUnique: true, type: "BTREE", columns: [IndexColumn(name: nil, expression: "lower(code)")])]],
                foreignKeys: ["orders": [ForeignKeyInfo(name: "fk_c", columns: ["customer_id"], referencedSchema: "crm", referencedTable: "customers",
                                                        referencedColumns: ["id"])]],
                definitions: [StoredDefinition(kind: .view, name: "v_x", sql: "select `id` AS `id` from `orders`"),
                              StoredDefinition(kind: .routine, name: "sp_x", sql: "BEGIN DECLARE n INT; SELECT COUNT(*) INTO n FROM orders o JOIN customers c ON o.customer_id = c.id; END"),
                              StoredDefinition(kind: .trigger, name: "trg_x", sql: "BEGIN INSERT INTO audit SELECT 1; END")])
        }
        func knowledgeServerIdentifier() async -> String? { "3e11fa47-71ca-11e1-9e33-c80aa9429562" }
    }

    @Test func oneDatabaseInFiveMetadataQueries() async throws {
        let schema = try await KnowledgeExtractor.extract(database: "shop", from: FakeSource())
        #expect(schema.tables.map(\.name) == ["orders", "customers", "v_x"], "routines and triggers are not tables")
        #expect(schema.tables.map(\.kind) == [.table, .table, .view])
        #expect(schema.tables.first { $0.name == "customers" }?.keys.unique == [["tenant", "code"]], "a functional key part is no column key")
        #expect(schema.tables.first { $0.name == "v_x" }?.definition == "select `id` AS `id` from `orders`")
        #expect(schema.routines.map(\.name) == ["sp_x", "trg_x"])
        #expect(schema.foreignKeys.map(\.referencedSchema) == ["crm"] && schema.foreignKeys.allSatisfy(\.isGuaranteed), "InnoDB enforces foreign keys")
        #expect(schema.serverIdentifier == "3e11fa47-71ca-11e1-9e33-c80aa9429562")
    }

    @Test func theServersOwnDatabasesAreRefused() async {
        for database in ["mysql", "information_schema", "PERFORMANCE_SCHEMA", "sys"] {
            await #expect(throws: KnowledgeExtractor.Failure.self) { try await KnowledgeExtractor.extract(database: database, from: FakeSource()) }
        }
    }

    @Test func routineBodiesAreMinedForTheirQueries() {
        let body = """
        BEGIN
          DECLARE done INT DEFAULT 0;
          DECLARE cur CURSOR FOR SELECT o.id FROM orders o JOIN customers c ON o.customer_id = c.id;
          IF done = 0 THEN INSERT INTO log SELECT 1 FROM dual; END IF;
          SET done = 1;
        END
        """
        #expect(KnowledgeInference.routineQueries(body) == ["SELECT o.id FROM orders o JOIN customers c ON o.customer_id = c.id",
                                                           "INSERT INTO log SELECT 1 FROM dual"])
    }
}
