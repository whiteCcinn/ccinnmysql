import Darwin
import Foundation

/// The one-time carry-over of the knowledge CcinnMysql 1.5 left on disk into today's store.
///
/// 1.5 kept one file per database of a saved connection, `Knowledge/<connection id>/<database>.json`, in the same folder
/// today's store uses (`index.json`, `databases/`), so both live side by side. What carries over is what
/// `LegacyKnowledgeConverter` converts (notes, glossary terms, the relationships and verdicts people and AIs wrote, linked
/// folders), merged as a 1.5 backup's knowledge is merged; structure is rebuilt by the next refresh.
///
/// It runs once: a record of the run (`.imported-from-1.5.json`) keeps it from running again, so knowledge deleted
/// afterwards is not brought back. The 1.5 files stay where they are, so 1.5 still reads them. A run that fails before its
/// record is written runs again at the next launch; ids derived from the 1.5 items make that merge change nothing twice.
public enum LegacyKnowledgeImport {
    /// What one run carried over, kept for the app to show once.
    public struct Record: Codable, Sendable, Equatable {
        public var importedAt: Date
        /// 1.5 files found, and those among them that could not be read.
        public var files: Int
        public var unreadableFiles: Int
        /// Databases whose knowledge was written, and what they received.
        public var databases: Int
        public var notes: Int
        public var terms: Int
        public var relationships: Int
        public var projects: Int
        /// What did not carry over, one line each.
        public var warnings: [String]

        public init(importedAt: Date, files: Int, unreadableFiles: Int = 0, databases: Int = 0, notes: Int = 0, terms: Int = 0,
                    relationships: Int = 0, projects: Int = 0, warnings: [String] = []) {
            self.importedAt = importedAt
            self.files = files
            self.unreadableFiles = unreadableFiles
            self.databases = databases
            self.notes = notes
            self.terms = terms
            self.relationships = relationships
            self.projects = projects
            self.warnings = warnings
        }

        /// Whether there is anything to tell: knowledge carried over, or something that did not.
        public var isWorthShowing: Bool { databases > 0 || projects > 0 || !warnings.isEmpty }

        /// One sentence: what carried over, by kind.
        public var summary: String {
            var kinds: [String] = []
            if notes > 0 { kinds.append(Self.counted(notes, "note")) }
            if terms > 0 { kinds.append(Self.counted(terms, "glossary term")) }
            if relationships > 0 { kinds.append(Self.counted(relationships, "relationship")) }
            var parts: [String] = []
            if !kinds.isEmpty { parts.append(Self.list(kinds) + " of " + Self.counted(databases, "database")) }
            if projects > 0 { parts.append(Self.counted(projects, "linked folder")) }
            guard !parts.isEmpty else { return "Nothing could be carried over from CcinnMysql 1.5." }
            return "Carried over from CcinnMysql 1.5: " + parts.joined(separator: ", and ") + "."
        }

        private static func counted(_ value: Int, _ singular: String) -> String {
            "\(value.formatted(.number)) \(Plural.noun(value, singular))"
        }

        /// "a", "a and b", "a, b and c".
        private static func list(_ items: [String]) -> String {
            guard let last = items.last, items.count > 1 else { return items.first ?? "" }
            return items.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    static let recordName = ".imported-from-1.5.json"
    static let lockName = ".imported-from-1.5.lock"
    /// 1.5 wrote a few files per connection; a folder holding more than this was not written by it.
    public static let maximumFiles = 10_000
    static let maximumRecordBytes = 1 << 20

    // MARK: Finding

    /// The 1.5 knowledge files in today's knowledge folder: regular `*.json` files (not hidden, not the `.corrupt-…` copies
    /// 1.5 set aside) in subfolders named by a connection id. 1.5 wrote no symbolic links, so none is followed. Sorted, at
    /// most `limit`.
    public static func legacyFiles(in directory: URL, limit: Int = maximumFiles) -> [URL] {
        let fileManager = FileManager.default
        let folders = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { UUID(uuidString: $0) != nil }.sorted()
        var files: [URL] = []
        for folder in folders {
            let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
            guard fileType(folderURL) == S_IFDIR else { continue }
            let names = ((try? fileManager.contentsOfDirectory(atPath: folderURL.path)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            for name in names.sorted() {
                guard files.count < limit else { return files }
                let file = folderURL.appendingPathComponent(name, isDirectory: false)
                if fileType(file) == S_IFREG { files.append(file) }
            }
        }
        return files
    }

    /// The type of the item itself (a symbolic link is `S_IFLNK`, not what it points to); nil when it cannot be read.
    private static func fileType(_ url: URL) -> mode_t? {
        var status = stat()
        return lstat(url.path, &status) == 0 ? status.st_mode & S_IFMT : nil
    }

    // MARK: Running

    static func recordURL(in store: KnowledgeStore) -> URL { store.directory.appendingPathComponent(recordName, isDirectory: false) }

    /// The record of the run, or nil when none ran (or its record cannot be read).
    public static func record(in store: KnowledgeStore) -> Record? {
        let url = recordURL(in: store)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= maximumRecordBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Record.self, from: data)
    }

    /// Whether a run finished here: its record exists, readable or not.
    static func hasRun(in store: KnowledgeStore) -> Bool {
        var status = stat()
        return lstat(recordURL(in: store).path, &status) == 0
    }

    /// Carries the 1.5 files over when there are some and no run finished yet: the record of this run, or nil when there was
    /// nothing to do. `profiles` are today's saved connections (a file of a deleted connection is reported, not imported);
    /// without any, nothing runs and nothing is recorded, since connections that could not be read look the same and a
    /// later launch can still carry the knowledge over. `home` is the home folder that `~/…` project paths stand for. Takes its own lock, so the app and another copy of it do
    /// not both run it; the store's writes take the store's lock as usual.
    public static func runIfNeeded(store: KnowledgeStore, profiles: [ConnectionProfile], home: String, now: Date = Date(),
                                   fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> Record? {
        guard !profiles.isEmpty, !hasRun(in: store) else { return nil }
        var files = legacyFiles(in: store.directory, limit: maximumFiles + 1)
        guard !files.isEmpty else { return nil }
        return try FileLock.withLock(at: store.directory.appendingPathComponent(lockName, isDirectory: false), timeout: .seconds(30)) {
            // Another copy of the app may have finished while this one waited.
            guard !hasRun(in: store) else { return nil }
            var lines: [String] = []
            if files.count > maximumFiles {
                files.removeLast()
                lines.append("Only the first \(maximumFiles) of the CcinnMysql 1.5 knowledge files were read.")
            }
            var record = try carryOver(files, store: store, profiles: profiles, home: home, now: now, fileExists: fileExists, lines: &lines)
            record.warnings = lines
            try SecureFile.write(try encoder.encode(record), to: recordURL(in: store))
            return record
        }
    }

    private static func carryOver(_ files: [URL], store: KnowledgeStore, profiles: [ConnectionProfile], home: String, now: Date,
                                  fileExists: (String) -> Bool, lines: inout [String]) throws -> Record {
        var record = Record(importedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)), files: files.count)
        var bases: [LegacyKnowledgeBase] = []
        for file in files {
            do {
                bases.append(try LegacyKnowledgeConverter.read(contentsOf: file))
            } catch {
                record.unreadableFiles += 1
                lines.append("“\(LegacyKnowledgeConverter.label(file.lastPathComponent))” was not read. \(error.localizedDescription)")
            }
        }
        var warnings: [BackupWarning] = []
        let converted = BackupLegacyKnowledge.convert(bases, profiles: profiles, sourceHome: home, warnings: &warnings) { (database: String) -> String in
            "the knowledge of “\(database)” belongs to a connection that no longer exists."
        }
        if let section = converted {
            let written = try write(section.databases, to: store, record: &record, warnings: &warnings)
            try mergeIndex(section.index, written: written, into: store, home: home, fileExists: fileExists)
            record.projects = section.index.projects.count
        }
        lines += warnings.map(line)
        return record
    }

    /// Merges each database into the store's copy; one a newer app wrote is left alone and reported. The databases written.
    private static func write(_ databases: [DatabaseKnowledge], to store: KnowledgeStore, record: inout Record,
                              warnings: inout [BackupWarning]) throws -> [DatabaseKey: DatabaseKnowledge] {
        var written: [DatabaseKey: DatabaseKnowledge] = [:]
        for imported in databases {
            do {
                try store.updateDatabase(imported.key) { (database: inout DatabaseKnowledge) -> Void in
                    database = BackupKnowledgeMerge.merge(local: database, imported: imported).merged
                }
            } catch KnowledgeStore.Failure.newerFormat(_) {
                warnings.append(.localDatabaseNotWritable(imported.key))
                continue
            }
            written[imported.key] = imported
            record.databases += 1
            record.notes += imported.notes.count
            record.terms += imported.terms.count
            record.relationships += imported.relationships.count
        }
        return written
    }

    /// The clusters, databases, projects and links, merged into the store's index as a backup's are (projects matched to
    /// local ones by folder, deleted ones left deleted). Databases that were not written are not listed for their knowledge.
    private static func mergeIndex(_ imported: KnowledgeIndex, written: [DatabaseKey: DatabaseKnowledge], into store: KnowledgeStore, home: String,
                                   fileExists: (String) -> Bool) throws {
        try store.updateIndex { (index: inout KnowledgeIndex) -> Void in
            let deleted = Set(index.tombstones.map(\.id))
            let localProjects = index.projects
            let projects = imported.projects.filter { !deleted.contains($0.id) }.map { (project: KnowledgeIndex.Project) -> BackupProjectItem in
                BackupProjectItem(source: project, localProjects: localProjects, home: home, fileExists: fileExists)
            }
            let skipped = imported.databases.map(\.key).filter { (key: DatabaseKey) -> Bool in
                written[key] == nil && !imported.links.contains { $0.database == key.fileID }
            }
            let items = skipped.map { (key: DatabaseKey) -> BackupDatabaseItem in
                BackupDatabaseItem(key: key, status: .skipped, changes: BackupKnowledgeChanges(), hasMatchingConnection: true)
            }
            let plan = BackupKnowledgePlan(databases: items, projects: projects, indexChanges: true, importedIndex: imported, importedDatabases: written,
                                           localIndex: index)
            index = plan.mergedIndex(into: index)
        }
    }

    private static func line(_ warning: BackupWarning) -> String {
        if case let .legacyKnowledgeNotConverted(detail) = warning { return "Not carried over: " + detail }
        return warning.description
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
