import Foundation
import Testing
@testable import CcinnMysqlKit

private typealias L = Legacy15
private typealias F = BackupFixtures

/// The one-time carry-over of the knowledge CcinnMysql 1.5 left on disk, next to today's store.
@Suite("Knowledge from CcinnMysql 1.5 on disk")
struct LegacyKnowledgeImportTests {
    private let profile = F.profile(name: "prod", host: "db.prod")
    private let home = "/Users/me"
    private var key: DatabaseKey { DatabaseKey(cluster: ClusterKey(profile: profile), catalog: "def", database: "adx") }

    private func store() -> KnowledgeStore {
        KnowledgeStore(directory: F.temporaryDirectory().appendingPathComponent("Knowledge", isDirectory: true))
    }

    /// Writes `base` where 1.5 kept it: `Knowledge/<connection id>/<database>.json`, encoded as 1.5 encoded it.
    @discardableResult
    private func write(_ base: L.KnowledgeBase, in store: KnowledgeStore, fileName: String? = nil) throws -> URL {
        let folder = store.directory.appendingPathComponent(base.connectionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName ?? base.database + ".json")
        try JSONEncoder().encode(base).write(to: url)
        return url
    }

    private func noted(_ database: String = "adx", _ table: String = "report", _ text: String = "revenue in USD") -> L.KnowledgeBase {
        var base = L.KnowledgeBase(connectionID: profile.id, database: database)
        base.notes.tables[table] = L.TableNote(summary: text, author: "user", updatedAt: F.date(5))
        return base
    }

    private func run(_ store: KnowledgeStore, profiles: [ConnectionProfile]? = nil) throws -> LegacyKnowledgeImport.Record? {
        try LegacyKnowledgeImport.runIfNeeded(store: store, profiles: profiles ?? [profile], home: home, now: F.date(100), fileExists: { _ in true })
    }

    @Test func onlyThe15FilesAreFoundNextToTodaysStore() throws {
        let store = store()
        let kept = try write(noted(), in: store)
        let folder = kept.deletingLastPathComponent()
        try Data("{}".utf8).write(to: folder.appendingPathComponent(".hidden.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("adx.json.corrupt-20261119-ab12"))
        let notAConnection = store.directory.appendingPathComponent("databases", isDirectory: true)
        try FileManager.default.createDirectory(at: notAConnection, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: notAConnection.appendingPathComponent("x.json"))
        try Data("{}".utf8).write(to: store.directory.appendingPathComponent("index.json"))

        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.json"), withDestinationURL: kept)
        #expect(LegacyKnowledgeImport.legacyFiles(in: store.directory).map(\.lastPathComponent) == ["adx.json"], "1.5 wrote no symbolic links")
        #expect(LegacyKnowledgeImport.legacyFiles(in: store.directory.appendingPathComponent("missing")).isEmpty)
    }

    @Test func notesTermsAndLinkedFoldersCarryOverOnceAndThe15FilesStay() throws {
        let store = store()
        var adx = noted()
        adx.notes.glossary["fill rate"] = L.GlossaryTerm(term: "Fill rate", definition: "Filled over requested.", tables: ["report"], author: "ai",
                                                         updatedAt: F.date(6))
        adx.projects = [L.LinkedProject(name: "adx-server", path: "/Users/me/code/adx-server")]
        let file = try write(adx, in: store)

        let record = try #require(try run(store))
        #expect(record.importedAt == F.date(100) && record.files == 1 && record.unreadableFiles == 0)
        #expect(record.databases == 1 && record.notes == 1 && record.terms == 1 && record.relationships == 0 && record.projects == 1)
        let knowledge = try #require(try store.database(key))
        #expect(knowledge.notes.map(\.text) == ["revenue in USD"] && knowledge.terms.map(\.term) == ["Fill rate"])
        let index = try store.index()
        #expect(index.databases.map(\.key) == [key])
        #expect(index.projects.map(\.path) == ["~/code/adx-server"] && index.projects.first?.addedBy == "user", "a folder the user linked")
        #expect(index.links.map(\.database) == [key.fileID])
        #expect(FileManager.default.fileExists(atPath: file.path), "1.5 still reads its files")
        #expect(LegacyKnowledgeImport.record(in: store) == record)

        let revision = try store.database(key)?.revision
        #expect(try run(store) == nil, "it runs once")
        #expect(try store.database(key)?.revision == revision)
    }

    @Test func knowledgeDeletedAfterTheImportStaysDeleted() throws {
        let store = store()
        try write(noted(), in: store)
        _ = try run(store)
        try store.updateDatabase(key) { (database: inout DatabaseKnowledge) -> Void in database.notes.removeAll() }

        #expect(try run(store) == nil)
        #expect(try store.database(key)?.notes.isEmpty == true)
    }

    @Test func knowledgeWrittenSince16IsMergedWithNotReplaced() throws {
        let store = store()
        let today = Note(id: "n-today", table: "orders", column: nil, kind: .description, text: "one row per order", evidence: [], by: "user",
                         at: F.date(50), fingerprint: nil)
        try store.updateDatabase(key) { (database: inout DatabaseKnowledge) -> Void in database.notes = [today] }
        try store.updateIndex { (index: inout KnowledgeIndex) -> Void in
            index.databases = [KnowledgeIndex.DatabaseEntry(key: key)]
            index.clusters = [KnowledgeIndex.ClusterEntry(key: key.cluster)]
        }
        try write(noted(), in: store)

        _ = try run(store)
        #expect(Set(try store.database(key)?.notes.map(\.text) ?? []) == ["one row per order", "revenue in USD"])
        #expect(try store.index().databases.count == 1 && store.index().clusters.count == 1)
    }

    @Test func damagedFilesAndDeletedConnectionsAreReportedAndTheRestCarriesOver() throws {
        let store = store()
        try write(noted(), in: store)
        let stranger = L.KnowledgeBase(connectionID: UUID(), database: "other")
        try write(stranger, in: store)
        let damaged = try write(noted("ssp"), in: store, fileName: "ssp.json")
        try Data("{\"formatVersion\": 1, \"connectionID\":".utf8).write(to: damaged)
        var facts = noted("dsp")
        facts.snapshot = L.Snapshot(tables: [["name": "report"]])
        try write(facts, in: store)

        let record = try #require(try run(store))
        #expect(record.files == 4 && record.unreadableFiles == 1 && record.databases == 2)
        #expect(record.warnings.contains { $0.contains("ssp.json") && $0.contains("damaged") }, "\(record.warnings)")
        #expect(record.warnings.contains { $0.contains("“other”") && $0.contains("connection that no longer exists") }, "\(record.warnings)")
        #expect(record.warnings.contains { $0.contains("table structure") }, "structure is rebuilt by a refresh: \(record.warnings)")
        #expect(!record.warnings.contains { $0.contains("backup") }, "this is no backup: \(record.warnings)")
        #expect(try store.database(key)?.notes.count == 1)
    }

    // Saved connections that could not be read look like none: nothing is recorded, so a later launch carries it over.
    @Test func withoutSavedConnectionsNothingIsRecorded() throws {
        let store = store()
        try write(noted(), in: store)
        #expect(try run(store, profiles: []) == nil)
        #expect(LegacyKnowledgeImport.record(in: store) == nil && !FileManager.default.fileExists(atPath: store.indexURL.path))
        #expect(try run(store)?.notes == 1)
    }

    @Test func nothingToCarryOverWritesNothing() throws {
        let store = store()
        #expect(try run(store) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "no store is created on a Mac that never ran 1.5")
        #expect(LegacyKnowledgeImport.record(in: store) == nil)
    }

    @Test func filesWhoseKnowledgeIsAllFactsAreRecordedAsDone() throws {
        let store = store()
        var facts = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        facts.snapshot = L.Snapshot(tables: [["name": "report"]])
        try write(facts, in: store)

        let record = try #require(try run(store))
        #expect(record.databases == 0 && record.notes == 0)
        #expect(try store.database(key) == nil)
        #expect(try run(store) == nil, "nothing is tried again on the next launch")
    }

    @Test func theRecordSaysWhatCarriedOverInOneSentence() {
        typealias Record = LegacyKnowledgeImport.Record
        let now = F.date(0)
        #expect(Record(importedAt: now, files: 3, databases: 2, notes: 3, terms: 1, relationships: 2, projects: 1).summary
                == "Carried over from CcinnMysql 1.5: 3 notes, 1 glossary term and 2 relationships of 2 databases, and 1 linked folder.")
        #expect(Record(importedAt: now, files: 1, databases: 1, notes: 1).summary == "Carried over from CcinnMysql 1.5: 1 note of 1 database.")
        #expect(Record(importedAt: now, files: 2, projects: 2).summary == "Carried over from CcinnMysql 1.5: 2 linked folders.")
        #expect(Record(importedAt: now, files: 1, warnings: ["x"]).summary == "Nothing could be carried over from CcinnMysql 1.5.")
        #expect(!Record(importedAt: now, files: 1).isWorthShowing && Record(importedAt: now, files: 1, warnings: ["x"]).isWorthShowing)
    }

    @Test func aDatabaseANewerAppWroteIsLeftAloneAndReported() throws {
        let store = store()
        try store.updateDatabase(key) { (database: inout DatabaseKnowledge) -> Void in database.notes = [] }
        let url = store.databaseURL(key)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = KnowledgeStore.schemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let before = try Data(contentsOf: url)
        try write(noted(), in: store)

        let record = try #require(try run(store))
        #expect(record.databases == 0 && record.warnings.contains { $0.contains("cannot be changed by this version") }, "\(record.warnings)")
        #expect(try Data(contentsOf: url) == before)
    }
}
