import Foundation
import MySQLKit
import Testing
@testable import CcinnMysqlKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let later = Date(timeIntervalSince1970: 1_800_086_400)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "my://db:3306"), catalog: "def", database: "hr")

private func column(_ name: String, _ ordinal: Int, nullable: Bool = true, comment: String? = nil) -> ColumnInfo {
    ColumnInfo(name: name, ordinal: ordinal, dataType: "bigint", columnType: "bigint", isNullable: nullable, comment: comment)
}

private func primaryKey(_ columns: String...) -> IndexInfo {
    IndexInfo(name: "PRIMARY", isUnique: true, type: "BTREE", columns: columns.map { IndexColumn(name: $0) })
}

/// What an administrator sees, and what an account with SELECT on `employees(id, name)` and on nothing else sees.
private func rows(restricted: Bool) -> KnowledgeSchemaRows {
    let employees = restricted ? [column("id", 1, nullable: false), column("name", 2)]
        : [column("id", 1, nullable: false), column("name", 2), column("salary", 3, comment: "monthly, USD"), column("manager_id", 4)]
    var objects = [DatabaseObject(schema: "hr", name: "employees", kind: .table)]
    var columns: [String: [ColumnInfo]] = ["employees": employees]
    var definitions: [StoredDefinition] = []
    var keys: [String: [ForeignKeyInfo]] = [:]
    objects.append(DatabaseObject(schema: "hr", name: "v_staff", kind: .view))
    columns["v_staff"] = [column("id", 1), column("name", 2)]
    if !restricted {
        objects.append(DatabaseObject(schema: "hr", name: "payroll", kind: .table))
        columns["payroll"] = [column("id", 1, nullable: false), column("employee_id", 2)]
        keys["payroll"] = [ForeignKeyInfo(name: "fk_p", columns: ["employee_id"], referencedSchema: "hr", referencedTable: "employees", referencedColumns: ["id"])]
        definitions.append(StoredDefinition(kind: .view, name: "v_staff", sql: "select `e`.`id` AS `id`,`e`.`name` AS `name` from `hr`.`employees` `e`"))
    }
    return KnowledgeSchemaRows(objects: objects, columns: columns, indexes: ["employees": [primaryKey("id")], "payroll": restricted ? [] : [primaryKey("id")]],
                               foreignKeys: keys, definitions: definitions)
}

private func schema(restricted: Bool) -> ExtractedSchema {
    KnowledgeExtractor.build(database: "hr", rows: rows(restricted: restricted), serverVersion: "MySQL 8.4.3", serverIdentifier: nil)
}

private func adminKnowledge() -> DatabaseKnowledge {
    var knowledge = DatabaseKnowledge(key: key)
    let machine = KnowledgeInference.machineRelationships(KnowledgeInferenceInput(schema: schema(restricted: false), knowledge: {
        var preview = DatabaseKnowledge(key: key)
        var report = KnowledgeRefresher.Report()
        KnowledgeRefresher.updateTables(schema(restricted: false), in: &preview, now: now, report: &report)
        return preview
    }(), history: [], now: now))
    KnowledgeRefresher.apply(schema(restricted: false), machineRelationships: machine, to: &knowledge, now: now)
    let fingerprint = knowledge.table(named: "employees")?.fingerprint
    knowledge.notes = [Note(id: "n-salary", table: "employees", column: "salary", kind: .caveat, text: "includes bonus", evidence: [], by: "user", at: now,
                            fingerprint: fingerprint),
                       Note(id: "n-name", table: "employees", column: "name", kind: .description, text: "legal name", evidence: [], by: "user", at: now,
                            fingerprint: fingerprint)]
    knowledge.terms = [Term(id: "t1", term: "pay", synonyms: [], definition: "x", mapsTo: [.init(table: "employees", column: "salary")], by: "user", at: now)]
    knowledge.relationships.append(Relationship(from: .init(table: "employees", columns: ["manager_id"]), to: .init(table: "employees", columns: ["id"]),
                                                kind: .manyToOne, evidence: [Evidence(source: .user, by: "user", at: now)]))
    return knowledge
}

@Suite("Knowledge visibility: columns and partial refreshes")
struct KnowledgeVisibilityReviewTests {
    // Column grants: what the account cannot read disappears with everything that mentions it.
    @Test func hiddenColumnsTakeTheirCommentsKeysNotesTermsAndRelationshipsAlong() {
        let visibility = KnowledgeVisibility(columns: ["employees": ["id", "name"], "v_staff": nil])
        let filtered = KnowledgeMCP.filter(adminKnowledge(), visibility: visibility)
        #expect(filtered.tables.map(\.name).sorted() == ["employees", "v_staff"])
        #expect(filtered.table(named: "employees")?.columns.map(\.name) == ["id", "name"])
        #expect(filtered.table(named: "employees")?.keys.primary == ["id"])
        #expect(filtered.notes.map(\.id) == ["n-name"])
        #expect(filtered.terms.isEmpty, "a term about a hidden column would reveal it")
        #expect(!filtered.relationships.contains { $0.from.columns.contains("manager_id") })
        #expect(!filtered.relationships.contains { $0.from.table == "payroll" || $0.to.table == "payroll" })
        let encoded = String(decoding: (try? KnowledgeStore.encoder.encode(filtered)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains("salary") && !encoded.contains("USD") && !encoded.contains("payroll"))
    }

    // A refresh through an account that sees less never drops, changes or unlinks what it cannot see.
    @Test func aPartialRefreshLeavesWhatTheAccountCannotSeeUntouched() {
        var knowledge = adminKnowledge()
        let before = knowledge
        let report = KnowledgeRefresher.apply(schema(restricted: true), machineRelationships: [], to: &knowledge, now: later, partial: true)
        #expect(knowledge.table(named: "payroll")?.state == before.table(named: "payroll")?.state, "a table it cannot see is not dropped")
        #expect(knowledge.table(named: "employees") == before.table(named: "employees"), "seeing fewer columns is not a change")
        #expect(knowledge.table(named: "v_staff") == before.table(named: "v_staff"), "an unreadable view definition is not a change")
        #expect(knowledge.relationships.contains { $0.from.table == "payroll" && $0.evidence.contains { $0.source == .declared } })
        #expect(!knowledge.notes.contains { KnowledgeFreshness.isStale($0, in: knowledge) })
        #expect(report.tables.dropped == 0 && report.possibleRenames.isEmpty && report.relationships.removed == 0)
        #expect(report.tables.total == 2, "it counts only what the account sees")
    }

    // The app's refresh (the user's own) still marks tables that are gone.
    @Test func aFullRefreshStillDropsTables() {
        var knowledge = adminKnowledge()
        let report = KnowledgeRefresher.apply(schema(restricted: true), machineRelationships: [], to: &knowledge, now: later)
        #expect(knowledge.table(named: "payroll")?.state == .dropped)
        #expect(report.tables.dropped == 1)
    }
}
