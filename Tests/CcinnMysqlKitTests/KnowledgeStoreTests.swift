import Foundation
import Testing
@testable import CcinnMysqlKit

/// A fresh directory per test, removed afterwards.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-knowledge-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ relativePath: String, _ text: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}

private func permissions(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

@Suite("Knowledge storage")
struct KnowledgeStoreTests {
    let key = KnowledgeKey(connectionID: UUID(), database: "shop")

    @Test func fileNamesAreReversibleAndCaseSafe() {
        #expect(KnowledgeLocation.fileName(for: "shop") == "shop.json")
        #expect(KnowledgeLocation.fileName(for: "Shop") == "%53hop.json")
        #expect(KnowledgeLocation.fileName(for: "Shop").lowercased() != KnowledgeLocation.fileName(for: "shop").lowercased(),
                "names that differ in case must not collide on case-insensitive APFS")
        for name in ["shop", "Shop", "a.b", "a/b", "广告_报表", "..", "x y", "%41", "e\u{301}", "\u{E9}"] {
            #expect(KnowledgeLocation.database(fromFileName: KnowledgeLocation.fileName(for: name)) == name)
        }
        #expect(KnowledgeLocation.fileName(for: "e\u{301}") != KnowledgeLocation.fileName(for: "\u{E9}"), "no Unicode normalization merge")
        let long = String(repeating: "报", count: 64)
        let hashed = KnowledgeLocation.fileName(for: long)
        #expect(hashed.utf8.count < 200 && hashed.hasPrefix("~"))
        #expect(KnowledgeLocation.database(fromFileName: hashed) == nil)
        #expect(KnowledgeLocation.fileName(for: String(repeating: "报", count: 63)) != KnowledgeLocation.fileName(for: long))
    }

    @Test func updateCreatesPrivateFilesAndLoadReadsThem() async throws {
        let directory = TemporaryDirectory()
        let store = KnowledgeStore(root: directory.url)
        #expect(try store.load(key) == nil)
        try await store.update(key) { kb in
            kb.notes.tables["orders"] = TableNote(summary: "One row per order", author: .ai)
        }
        let loaded = try #require(try store.load(key))
        #expect(loaded.notes.tables["orders"]?.summary == "One row per order")
        #expect(loaded.database == "shop" && loaded.connectionID == key.connectionID)
        let file = store.fileURL(for: key)
        #expect(permissions(file) == 0o600)
        #expect(permissions(file.deletingLastPathComponent()) == 0o700)
        #expect(permissions(directory.url) == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func updateWithoutCreateFailsForAMissingKnowledgeBase() async {
        let directory = TemporaryDirectory()
        let store = KnowledgeStore(root: directory.url)
        await #expect(throws: KnowledgeError.self) {
            try await store.update(key, create: false) { _ in }
        }
    }

    @Test func concurrentWritersFromSeparateStoresLoseNothing() async throws {
        let directory = TemporaryDirectory()
        // Two stores stand in for two processes: each update opens its own lock file description.
        let stores = [KnowledgeStore(root: directory.url), KnowledgeStore(root: directory.url)]
        let key = key
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await stores[index % 2].update(key) { kb in
                        kb.notes.tables["t\(index)"] = TableNote(summary: "note \(index)", author: .ai)
                    }
                }
            }
            try await group.waitForAll()
        }
        let loaded = try #require(try KnowledgeStore(root: directory.url).load(key))
        #expect(loaded.notes.tables.count == 40)
    }

    @Test func corruptFilesAreNeverOverwritten() async throws {
        let directory = TemporaryDirectory()
        let store = KnowledgeStore(root: directory.url)
        let file = store.fileURL(for: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        #expect(throws: KnowledgeError.self) { try store.load(key) }
        await #expect(throws: KnowledgeError.self) {
            try await store.update(key) { kb in kb.notes.tables["x"] = TableNote(summary: "x", author: .ai) }
        }
        #expect(try Data(contentsOf: file) == Data("{not json".utf8))
        // Reset moves the file aside and starts over.
        let moved = try await store.reset(key)
        #expect(moved.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(try store.load(key) == nil)
    }

    @Test func newerFormatsAreReadOnly() async throws {
        let directory = TemporaryDirectory()
        let store = KnowledgeStore(root: directory.url)
        try await store.update(key) { _ in }
        let file = store.fileURL(for: key)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["formatVersion"] = KnowledgeBase.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let before = try Data(contentsOf: file)
        await #expect(throws: KnowledgeError.self) {
            try await store.update(key) { kb in kb.notes.tables["x"] = TableNote(summary: "x", author: .ai) }
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func oversizedFilesAreRefused() throws {
        let directory = TemporaryDirectory()
        let store = KnowledgeStore(root: directory.url, maxFileBytes: 64)
        let file = store.fileURL(for: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 65).write(to: file)
        #expect(throws: KnowledgeError.self) { try store.load(key) }
    }

    @Test func cachedReadsSeeOtherWriters() async throws {
        let directory = TemporaryDirectory()
        let reader = KnowledgeStore(root: directory.url)
        let writer = KnowledgeStore(root: directory.url)
        try await writer.update(key) { kb in kb.notes.tables["a"] = TableNote(summary: "first", author: .ai) }
        #expect(try reader.load(key)?.notes.tables["a"]?.summary == "first")
        try await writer.update(key) { kb in kb.notes.tables["a"] = TableNote(summary: "second", author: .ai) }
        #expect(try reader.load(key)?.notes.tables["a"]?.summary == "second")
    }

    @Test func listsKnowledgeBasesOfAConnection() async throws {
        let directory = TemporaryDirectory()
        let store = KnowledgeStore(root: directory.url)
        let connection = UUID()
        for database in ["shop", "Shop", "ads"] {
            try await store.update(KnowledgeKey(connectionID: connection, database: database)) { _ in }
        }
        try await store.update(KnowledgeKey(connectionID: UUID(), database: "other")) { _ in }
        let listed = store.list(connectionID: connection)
        #expect(listed.compactMap(\.database).sorted() == ["Shop", "ads", "shop"])
        #expect(listed.allSatisfy { $0.error == nil })
    }

    @Test func modelsRoundTripAndToleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(KnowledgeBase.self, from: Data("""
            {"formatVersion":1,"connectionID":"\(key.connectionID.uuidString)","database":"shop"}
            """.utf8))
        #expect(decoded.projects.isEmpty && decoded.computed.isEmpty && decoded.notes.count == 0)
    }

    @Test func undirectedRelationshipsHaveOneCanonicalOrder() {
        let a = RelationshipEnd(table: "a", columns: ["x"])
        let b = RelationshipEnd(table: "b", columns: ["y"])
        let forward = KnowledgeRelationship(from: a, to: b, sources: [.code], confidence: 0.6, cardinality: .unknown)
        let backward = KnowledgeRelationship(from: b, to: a, sources: [.code], confidence: 0.6, cardinality: .unknown)
        #expect(forward.id == backward.id)
        let manyToOne = KnowledgeRelationship(from: b, to: a, sources: [.naming], confidence: 0.6, cardinality: .manyToOne)
        #expect(manyToOne.from == b, "many-to-one keeps its direction")
        let merged = forward.merged(with: KnowledgeRelationship(from: a, to: b, sources: [.naming, .code], confidence: 0.7, cardinality: .unknown,
                                                                evidence: [KnowledgeEvidence(kind: .naming)]))
        #expect(merged.sources == [.code, .naming])
        #expect(merged.confidence == 0.7)
        #expect(merged.evidence.count == 1)
    }

    @Test func mergedEvidenceKeepsOneOfEachKind() {
        let a = RelationshipEnd(table: "a", columns: ["x"])
        let b = RelationshipEnd(table: "b", columns: ["y"])
        let definitions = (0..<6).map { KnowledgeEvidence(kind: .definition, detail: "view v\($0)") }
        let declared = KnowledgeRelationship(from: a, to: b, sources: [.declared, .view], confidence: 1, cardinality: .manyToOne,
                                             evidence: [KnowledgeEvidence(kind: .schema, detail: "FOREIGN KEY fk")] + definitions.prefix(4))
        let code = KnowledgeRelationship(from: a, to: b, sources: [.code], confidence: 0.9, cardinality: .manyToOne,
                                         evidence: [KnowledgeEvidence(kind: .code, project: "p", path: "x.go", line: 3)])
        let merged = declared.merged(with: code)
        #expect(merged.evidence.count == KnowledgeRelationship.maxEvidence)
        #expect(merged.evidence.map(\.kind) == [.schema, .definition, .definition, .definition, .code])
    }

    @Test func fingerprintsIgnoreRowEstimatesButNotStructure() {
        let columns = [KnowledgeColumn(name: "id", type: "bigint", dataType: "bigint", nullable: false)]
        let base = KnowledgeTable(name: "t", rowsEstimate: 10, columns: columns, primaryKey: ["id"])
        #expect(base.fingerprint == KnowledgeTable(name: "t", rowsEstimate: 99_999, columns: columns, primaryKey: ["id"]).fingerprint)
        #expect(base.fingerprint != KnowledgeTable(name: "t", columns: columns, primaryKey: []).fingerprint)
        #expect(base.fingerprint != KnowledgeTable(name: "t", columns: [KnowledgeColumn(name: "id", type: "int", dataType: "int", nullable: false)],
                                                   primaryKey: ["id"]).fingerprint)
    }
}
