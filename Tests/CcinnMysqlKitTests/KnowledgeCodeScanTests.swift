import Foundation
import Testing
@testable import CcinnMysqlKit

/// A scratch folder for the scanner's projects, removed when the test ends.
private final class ScanFolder: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-scan-\(UUID().uuidString)", isDirectory: true)

    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func table(_ name: String, _ columns: [String], primary: [String] = ["id"]) -> TableFacts {
    TableFacts(name: name, kind: .table, keys: TableFacts.Keys(primary: primary),
               columns: columns.map { ColumnFacts(name: $0, type: "bigint", isKey: primary.contains($0)) }, fingerprint: "fp-" + name, state: .fresh,
               firstSeen: now)
}

private let tables = [table("customers", ["id", "name"]), table("orders", ["id", "customer_id"])]
private let joinSQL = "SELECT o.id FROM orders o JOIN customers c ON c.id = o.customer_id"

@Suite("Code scanner")
struct KnowledgeCodeScanTests {
    @Test func joinsInCodeBecomeScanEvidenceWithPathAndLineOnly() async throws {
        let folder = ScanFolder()
        try folder.write("internal/repo/order.go", "package repo\n\nconst q = `\n\(joinSQL) WHERE o.secret = 'Hunter2'`\n")
        try folder.write("mapper/OrderMapper.xml", "<select id=\"x\">\nSELECT * FROM orders o, customers c WHERE o.customer_id = c.id\n</select>\n")
        let result = try await CodeScanner().scan(projects: [CodeScanner.Project(id: "p1", root: folder.url)], tables: tables, database: "shop", now: now)
        #expect(result.files == 2 && !result.truncated)
        let relationship = try #require(result.relationships.first)
        #expect(result.relationships.count == 1)
        #expect(relationship.from.table == "orders" && relationship.from.columns == ["customer_id"] && relationship.to.table == "customers")
        #expect(relationship.kind == .manyToOne)
        #expect(relationship.evidence.map(\.path) == ["internal/repo/order.go", "mapper/OrderMapper.xml"])
        #expect(relationship.evidence.first?.line == 4 && relationship.evidence.allSatisfy { $0.source == .scan && $0.project == "p1" })
        let stored = String(decoding: try KnowledgeStore.encoder.encode(relationship), as: UTF8.self)
        #expect(!stored.contains("Hunter2") && !stored.contains("SELECT"), "never code text")
        #expect(RelationshipConfidence.score(relationship) == 60, "pattern-matched code is moderate evidence")
    }

    @Test func dependenciesHiddenFoldersLinksBinariesAndUnknownNamesAreSkipped() async throws {
        let folder = ScanFolder()
        let outside = ScanFolder()
        try outside.write("secret.go", joinSQL)
        for path in ["node_modules/x/q.js", "vendor/lib/q.go", ".git/hooks/q.sh", ".hidden/q.go", "build/q.java", "notes.txt"] {
            try folder.write(path, joinSQL)
        }
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("link.go"), withDestinationURL: outside.url.appendingPathComponent("secret.go"))
        try Data([0x53, 0x45, 0x4C, 0x00] + Array(joinSQL.utf8)).write(to: folder.url.appendingPathComponent("blob.go"))
        try folder.write("other.go", "SELECT * FROM invoices i JOIN payments p ON p.invoice_id = i.id")
        let result = try await CodeScanner().scan(projects: [CodeScanner.Project(id: "p1", root: folder.url)], tables: tables, database: "shop", now: now)
        #expect(result.relationships.isEmpty)
    }

    @Test func limitsStopTheScanAndSaySo() async throws {
        let folder = ScanFolder()
        for index in 0..<8 { try folder.write("q\(index).go", joinSQL) }
        let result = try await CodeScanner(limits: CodeScanner.Limits(maxFiles: 2)).scan(projects: [CodeScanner.Project(id: "p1", root: folder.url)],
                                                                                          tables: tables, database: "shop", now: now)
        #expect(result.files == 2 && result.truncated)
        let many = try await CodeScanner().scan(projects: [CodeScanner.Project(id: "p1", root: folder.url)], tables: tables, database: "shop", now: now)
        #expect(many.relationships.first?.evidence.count == CodeScanner.maxEvidence, "a few files are cited, not every one")
        let missing = try await CodeScanner().scan(projects: [CodeScanner.Project(id: "gone", root: folder.url.appendingPathComponent("nope"))],
                                                   tables: tables, database: "shop", now: now)
        #expect(missing.relationships.isEmpty && missing.files == 0)
    }

    @Test func cancellationStopsTheScan() async throws {
        let folder = ScanFolder()
        for index in 0..<200 { try folder.write("q\(index).go", joinSQL) }
        let task = Task {
            try await CodeScanner(limits: CodeScanner.Limits(concurrency: 1)).scan(projects: [CodeScanner.Project(id: "p1", root: folder.url)],
                                                                                  tables: tables, database: "shop", now: now)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // The service scans the projects linked to the database on every refresh: removing the code removes the evidence.
    @Test func refreshScansLinkedProjectsAndRecomputesTheEvidence() async throws {
        struct Source: KnowledgeSchemaSource {
            let knowledgeServerVersion: String? = "MySQL 8.4.3"
            func knowledgeRows(_ database: String) async throws -> KnowledgeSchemaRows {
                KnowledgeSchemaRows(objects: [.init(schema: database, name: "orders", kind: .table), .init(schema: database, name: "customers", kind: .table)],
                                    columns: ["orders": [.init(name: "id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false),
                                                         .init(name: "customer_id", ordinal: 2, dataType: "bigint", columnType: "bigint", isNullable: true)],
                                              "customers": [.init(name: "id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false)]],
                                    indexes: ["orders": [.init(name: "PRIMARY", isUnique: true, type: "BTREE", columns: [.init(name: "id")])],
                                              "customers": [.init(name: "PRIMARY", isUnique: true, type: "BTREE", columns: [.init(name: "id")])]])
            }
            func knowledgeServerIdentifier() async -> String? { nil }
        }
        let folder = ScanFolder()
        try folder.write("repo.go", joinSQL)
        let store = KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-kb-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let key = DatabaseKey(cluster: ClusterKey(rawValue: "my://db:3306"), catalog: "def", database: "shop")
        try KnowledgeService.linkProject(path: folder.url.path, to: key, store: store, home: FileManager.default.homeDirectoryForCurrentUser, now: now)
        let noInference: KnowledgeToolSettings.Inference = { (_: KnowledgeInferenceInput) -> [Relationship] in [] }
        _ = try await KnowledgeService.refresh(key, source: Source(), store: store, history: [], infer: noInference, now: now)
        let scanned = try #require(try store.database(key)?.relationships.first { $0.evidence.contains { $0.source == .scan } })
        #expect(scanned.from.table == "orders" && scanned.evidence.first?.path == "repo.go")
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("repo.go"))
        _ = try await KnowledgeService.refresh(key, source: Source(), store: store, history: [], infer: noInference, now: now)
        #expect(try store.database(key)?.relationships.contains { $0.evidence.contains { $0.source == .scan } } == false)
    }
}
