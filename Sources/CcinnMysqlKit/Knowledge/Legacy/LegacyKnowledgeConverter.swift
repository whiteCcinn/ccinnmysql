import CryptoKit
import Darwin
import Foundation

// CcinnMysql 1.5's knowledge base, read and converted into today's: from a 1.5 backup (`BackupLegacyFormat`) or, for a
// one-time import, from the files 1.5 left on disk.

/// One CcinnMysql 1.5 knowledge base (one database of one saved connection): a file `Knowledge/<connection id>/<database>.json`
/// under 1.5's data directory, or an item of a 1.5 backup's `knowledge` array. Both were written by a default
/// `JSONEncoder` (dates as seconds since 2001).
///
/// Only what the conversion uses is read. A file of a newer 1.5-era format (`formatVersion` above 1) keeps its identity
/// and nothing else, since its shape may have changed; `convert` reports it.
public struct LegacyKnowledgeBase: Decodable, Sendable {
    public let formatVersion: Int
    public let connectionID: UUID
    public let database: String
    var projects: [LegacyKnowledgeConverter.Project] = []
    var computed: [LegacyKnowledgeConverter.LegacyRelationship] = []
    var notes = LegacyKnowledgeConverter.Notes()
    /// Structure, computed relationships or code references that the conversion drops.
    var hasFacts = false

    /// Written by a later knowledge format than 1.5's: nothing but its identity was read.
    public var isNewerFormat: Bool { formatVersion > LegacyKnowledgeConverter.formatVersion }

    enum CodingKeys: String, CodingKey {
        case formatVersion, connectionID, database, projects, snapshot, computed, references, build, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        connectionID = try container.decode(UUID.self, forKey: .connectionID)
        database = try container.decode(String.self, forKey: .database)
        // A newer knowledge format may have changed shape: it is skipped, so nothing else is read from it.
        guard formatVersion <= LegacyKnowledgeConverter.formatVersion else { return }
        projects = try container.decodeIfPresent([LegacyKnowledgeConverter.Project].self, forKey: .projects) ?? []
        // Computed relationships only orient verdicts; one that does not decode orients nothing.
        computed = (try? container.decodeIfPresent([LegacyKnowledgeConverter.LegacyRelationship].self, forKey: .computed)) ?? []
        notes = try container.decodeIfPresent(LegacyKnowledgeConverter.Notes.self, forKey: .notes) ?? LegacyKnowledgeConverter.Notes()
        let hasSnapshot: Bool = (try? container.decodeNil(forKey: .snapshot)) == false
        let references = (try? container.decodeIfPresent([String: LegacyKnowledgeConverter.Ignored].self, forKey: .references)) ?? nil
        let hasReferences: Bool = references?.isEmpty == false
        hasFacts = hasSnapshot || !computed.isEmpty || hasReferences
    }
}

/// Converts a CcinnMysql 1.5 knowledge base into today's knowledge base: a `DatabaseKnowledge` keyed by the server and
/// database, and the projects and links of the index.
///
/// What carries over:
/// - table notes and column notes (with their value meanings) → `Note`s of kind `description`;
/// - glossary terms → `Term`s (the term's SQL is kept in the definition: a term maps to tables, not to a statement);
/// - relationships the user or an AI added, and verdicts on any relationship → `Relationship`s with `user`, `ai` and
///   `code` evidence (a user's verdict confirms or rejects, as in the app; a code location in a linked folder keeps
///   its project, path and line);
/// - linked code folders → projects (`~/…` under `home`) linked to the database.
///
/// What does not: table structure, computed relationships, code references and build information. They are facts the
/// next refresh recomputes from the server. Items the new model cannot hold are reported as warnings.
///
/// Ids are derived from the database and the item, so converting the same 1.5 knowledge again (from a backup or from
/// disk) merges into what the first conversion made rather than duplicating it.
public enum LegacyKnowledgeConverter {
    /// The knowledge format 1.5 wrote.
    public static let formatVersion = 1
    /// As 1.5's knowledge store: larger files were refused.
    public static let maximumFileBytes = 64 << 20
    static let aiAuthor = "ai:unknown"
    static let userAuthor = "user"
    /// As `KnowledgeMCP`'s limits for what an AI may write.
    static let maximumColumnsPerEnd = 8
    static let maximumMappings = 20
    static let factsNotConverted = BackupWarning.legacyKnowledgeNotConverted(
        "table structure, computed relationships and code references; refresh each database's knowledge to rebuild them.")

    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge
        case unreadable(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The CcinnMysql 1.5 knowledge file is larger than 64 MB."
            case let .unreadable(detail): "The CcinnMysql 1.5 knowledge file cannot be read: \(detail)"
            case let .malformed(detail): "The CcinnMysql 1.5 knowledge file is damaged: \(detail)"
            }
        }
    }

    // MARK: Reading

    /// Reads one 1.5 knowledge file: a regular file (symbolic links resolved) of at most 64 MB, opened without blocking
    /// and checked through its descriptor, so a device or a pipe in its place is refused rather than read.
    public static func read(contentsOf url: URL) throws -> LegacyKnowledgeBase {
        let path = url.resolvingSymlinksInPath().path
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable(SecureFile.posixError().localizedDescription) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable("not a regular file") }
        guard status.st_size <= off_t(maximumFileBytes) else { throw Failure.tooLarge }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    /// Decodes one 1.5 knowledge file's contents.
    public static func decode(_ data: Data) throws -> LegacyKnowledgeBase {
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge }
        do {
            return try JSONDecoder().decode(LegacyKnowledgeBase.self, from: data)
        } catch {
            throw Failure.malformed(BackupFormat.describe(error))
        }
    }

    // MARK: Converting

    /// Converts `base`, which belongs to `profile` (the saved connection whose id is `base.connectionID`): the database's
    /// knowledge (empty when there is nothing to keep), the linked folders as projects under `home` (the home folder of the
    /// Mac that linked them), their links to the database, and what could not be converted. Pure: nothing is read or
    /// written; merge the results into the knowledge store, or into a backup's knowledge section.
    public static func convert(_ base: LegacyKnowledgeBase, profile: ConnectionProfile, home: String)
        -> (knowledge: DatabaseKnowledge, projects: [KnowledgeIndex.Project], links: [KnowledgeIndex.Link], warnings: [BackupWarning]) {
        let key = DatabaseKey(cluster: ClusterKey(profile: profile), catalog: "def", database: base.database)
        guard !base.isNewerFormat else {
            let warning = BackupWarning.legacyKnowledgeNotConverted("the knowledge of “\(label(base.database))” was written by a newer CcinnMysql.")
            return (DatabaseKnowledge(key: key), [], [], [warning])
        }
        guard isUsableName(base.database) else {
            return (DatabaseKnowledge(key: key), [], [], [.legacyKnowledgeNotConverted("knowledge of a database with an unusable name.")])
        }
        var warnings: [BackupWarning] = []
        let linked = projects(base.projects, linkedTo: key, home: home, warnings: &warnings)
        var converter = Converter(key: key, projectsByName: linked.byName)
        let knowledge = converter.convert(base)
        warnings += converter.warnings
        if base.hasFacts { warnings.append(factsNotConverted) }
        return (knowledge, linked.projects, linked.links, warnings)
    }

    /// Whether converted knowledge holds nothing to write (no notes, terms or relationships).
    public static func isEmpty(_ knowledge: DatabaseKnowledge) -> Bool {
        knowledge.notes.isEmpty && knowledge.terms.isEmpty && knowledge.relationships.isEmpty
    }

    /// One line, at most 200 characters, for warnings.
    static func label(_ text: String) -> String {
        KnowledgeMCP.clean(text, limit: 200).replacingOccurrences(of: "\n", with: " ")
    }

    /// Table, column and database names: not empty, one line, no control or text-direction characters.
    static func isUsableName(_ name: String) -> Bool {
        let isShort: Bool = !name.isEmpty && name.utf8.count <= BackupValidation.maximumIdentifierLength
        return isShort && !BackupValidation.containsControlCharacter(name) && !BackupValidation.containsBidiControl(name)
    }

    static func author(_ raw: String) -> String {
        raw == "user" ? userAuthor : aiAuthor
    }

    /// `prefix` and 16 hex characters of the SHA-256 of the parts: the shape `KnowledgeMCP` gives ids.
    static func stableID(_ prefix: String, _ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(("ccinnmysql-1.5\u{1F}" + parts.joined(separator: "\u{1F}")).utf8))
        return prefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Projects

    /// The base's folders as projects (one per folder) linked to `key`, and project name → project id for code evidence.
    private static func projects(_ folders: [Project], linkedTo key: DatabaseKey, home: String, warnings: inout [BackupWarning])
        -> (projects: [KnowledgeIndex.Project], links: [KnowledgeIndex.Link], byName: [String: String]) {
        var projects: [KnowledgeIndex.Project] = []
        var links: [KnowledgeIndex.Link] = []
        var byName: [String: String] = [:]
        var seen = Set<String>()
        for folder in folders {
            // 1.5 stored absolute, standardized paths; anything else is not resolved against this process's folder. As
            // when linking a folder today, neither `/` nor the home folder itself is a project.
            let isAbsolute: Bool = folder.path.hasPrefix("/") && BackupPaths.isAcceptable(folder.path)
            let stored = BackupPaths.collapsingHome(folder.path, home: home)
            let isFolder: Bool = stored != "/" && stored != "~"
            guard isAbsolute, isFolder, BackupPaths.isAcceptable(stored) else {
                warnings.append(.legacyKnowledgeNotConverted("the linked folder “\(label(folder.path))”, whose path cannot be used."))
                continue
            }
            let id = KnowledgeMCP.projectID(path: stored)
            if byName[folder.name] == nil { byName[folder.name] = id }
            guard seen.insert(id).inserted else { continue }
            var name = KnowledgeMCP.clean(folder.name, limit: 200).replacingOccurrences(of: "\n", with: " ")
            if name.isEmpty { name = (stored as NSString).lastPathComponent }
            projects.append(KnowledgeIndex.Project(id: id, path: stored, name: name, gitRemote: nil, addedAt: folder.addedAt, addedBy: userAuthor))
            links.append(KnowledgeIndex.Link(project: id, database: key.fileID, addedAt: folder.addedAt, addedBy: userAuthor))
        }
        return (projects, links, byName)
    }

    // MARK: One database

    struct Converter {
        let key: DatabaseKey
        let projectsByName: [String: String]
        private(set) var warnings: [BackupWarning] = []
        private var unconverted: [String] = []

        init(key: DatabaseKey, projectsByName: [String: String]) {
            self.key = key
            self.projectsByName = projectsByName
        }

        mutating func convert(_ base: LegacyKnowledgeBase) -> DatabaseKnowledge {
            var knowledge = DatabaseKnowledge(key: key)
            knowledge.notes = tableNotes(base.notes.tables) + columnNotes(base.notes.columns)
            knowledge.terms = terms(base.notes.glossary)
            knowledge.relationships = relationships(base)
            if !unconverted.isEmpty {
                let shown = unconverted.prefix(5).joined(separator: ", ")
                let more = unconverted.count > 5 ? " and \(unconverted.count - 5) more" : ""
                warnings.append(.legacyKnowledgeNotConverted("in \(label(key.database)): \(shown)\(more)."))
            }
            return knowledge
        }

        private mutating func tableNotes(_ notes: [String: TableNote]) -> [Note] {
            var result: [Note] = []
            for (table, note) in notes.sorted(by: { $0.key < $1.key }) {
                guard isUsableName(table) else {
                    unconverted.append("a note on a table with an unusable name")
                    continue
                }
                let text = KnowledgeMCP.clean(note.summary, limit: KnowledgeMCP.maxNoteLength)
                guard !text.isEmpty else { continue }
                let by = author(note.author)
                result.append(Note(id: stableID("n", [key.fileID, "table", table]), table: table, column: nil, kind: .description, text: text,
                                   evidence: evidence(note.evidence, by: by, at: note.updatedAt), by: by, at: note.updatedAt, fingerprint: nil))
            }
            return result
        }

        private mutating func columnNotes(_ notes: [String: [String: ColumnNote]]) -> [Note] {
            var result: [Note] = []
            for (table, columns) in notes.sorted(by: { $0.key < $1.key }) {
                for (column, note) in columns.sorted(by: { $0.key < $1.key }) {
                    guard isUsableName(table), isUsableName(column) else {
                        unconverted.append("a note on a column with an unusable name")
                        continue
                    }
                    var lines: [String] = []
                    if let text = note.note { lines.append(text) }
                    if !note.values.isEmpty {
                        let meanings = note.values.sorted { $0.key < $1.key }.map { (entry: (key: String, value: String)) -> String in
                            entry.key + " = " + entry.value
                        }
                        lines.append("Values: " + meanings.joined(separator: ", "))
                    }
                    let text = KnowledgeMCP.clean(lines.joined(separator: "\n"), limit: KnowledgeMCP.maxNoteLength)
                    guard !text.isEmpty else { continue }
                    let by = author(note.author)
                    result.append(Note(id: stableID("n", [key.fileID, "column", table, column]), table: table, column: column, kind: .description,
                                       text: text, evidence: evidence(note.evidence, by: by, at: note.updatedAt), by: by, at: note.updatedAt,
                                       fingerprint: nil))
                }
            }
            return result
        }

        private mutating func terms(_ glossary: [String: GlossaryTerm]) -> [Term] {
            var result: [Term] = []
            var seen = Set<String>()
            for (_, entry) in glossary.sorted(by: { $0.key < $1.key }) {
                let name = KnowledgeMCP.clean(entry.term, limit: 200).replacingOccurrences(of: "\n", with: " ")
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                var definition = entry.definition
                if let sql = entry.sql?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty { definition += "\n\nSQL: " + sql }
                let mappings = entry.tables.filter(isUsableName).prefix(maximumMappings).map { (table: String) -> Term.Mapping in Term.Mapping(table: table) }
                result.append(Term(id: stableID("g", [key.fileID, "term", name.lowercased()]), term: name, synonyms: [],
                                   definition: KnowledgeMCP.clean(definition, limit: KnowledgeMCP.maxNoteLength), mapsTo: Array(mappings),
                                   by: author(entry.author), at: entry.updatedAt))
            }
            return result
        }

        // MARK: Relationships

        private mutating func relationships(_ base: LegacyKnowledgeBase) -> [Relationship] {
            var byID: [String: Relationship] = [:]
            // Added relationships, by the pair of ends (either direction), for verdicts to find.
            var byPair: [String: String] = [:]
            for (_, added) in base.notes.relationships.sorted(by: { $0.key < $1.key }) {
                guard let ends = ends(added.relationship.from, added.relationship.to) else {
                    unconverted.append("an added relationship whose columns cannot be used")
                    continue
                }
                let by = author(added.author)
                let support = Evidence(source: by == userAuthor ? .user : .ai, rationale: rationale(added.note, added.relationship.evidence),
                                       by: by, at: added.updatedAt)
                let code = codeEvidence(added.relationship.evidence, by: by, at: added.updatedAt)
                let relationship = Relationship(from: ends.from, to: ends.to, kind: kind(added.relationship.cardinality),
                                                status: by == userAuthor ? .confirmed : .inferred, evidence: [support] + code)
                if byID[relationship.id] == nil {
                    byID[relationship.id] = relationship
                    byPair[pairKey(added.relationship.from, added.relationship.to)] = relationship.id
                }
            }
            // Computed relationships by pair, once: a lookup per verdict keeps a large file linear.
            var computedByPair: [String: LegacyRelationship] = [:]
            for relationship in base.computed {
                let pair = pairKey(relationship.from, relationship.to)
                if computedByPair[pair] == nil { computedByPair[pair] = relationship }
            }
            for (pair, verdict) in base.notes.verdicts.sorted(by: { $0.key < $1.key }) {
                let by = author(verdict.author)
                let isUser: Bool = by == userAuthor
                let decision = Evidence(source: isUser ? .user : .ai, verdict: verdict.status == "rejected" ? .reject : .assert,
                                        rationale: verdict.reason.map { KnowledgeMCP.clean($0, limit: KnowledgeMCP.maxRationaleLength) },
                                        by: by, at: verdict.updatedAt)
                let status: Relationship.Status = verdict.status == "rejected" ? .rejected : .confirmed
                var targetID = byPair[pair]
                if targetID == nil, verdict.ends.count == 2 { targetID = byPair[pairKey(verdict.ends[0], verdict.ends[1])] }
                if let id = targetID, var relationship = byID[id] {
                    if isUser {
                        relationship.evidence.removeAll { $0.source == .user }
                        relationship.status = status
                    }
                    relationship.evidence.append(decision)
                    byID[id] = relationship
                    continue
                }
                // A verdict on a computed relationship: the relationship itself is recomputed by the next refresh, which
                // keeps the verdict's evidence on the record of the same id.
                guard let computed = verdictTarget(verdict, pair: pair, computed: computedByPair), let ends = ends(computed.from, computed.to) else {
                    unconverted.append("a verdict on a relationship the backup does not describe")
                    continue
                }
                let relationship = Relationship(from: ends.from, to: ends.to, kind: kind(computed.cardinality), status: isUser ? status : .inferred,
                                                evidence: [decision])
                if byID[relationship.id] == nil { byID[relationship.id] = relationship }
            }
            return byID.values.sorted { $0.id < $1.id }
        }

        /// The relationship a verdict is about: the computed one of the same pair, else the ends the verdict recorded.
        private func verdictTarget(_ verdict: Verdict, pair: String, computed: [String: LegacyRelationship]) -> LegacyRelationship? {
            if let match = computed[pair] { return match }
            guard verdict.ends.count == 2 else { return nil }
            return LegacyRelationship(from: verdict.ends[0], to: verdict.ends[1], cardinality: "manyToOne", evidence: [])
        }

        /// Both ends in this database, with as many columns on each side (1 to 8) and usable names.
        private func ends(_ from: End, _ to: End) -> (from: Relationship.End, to: Relationship.End)? {
            let count = from.columns.count
            let sameWidth: Bool = count == to.columns.count && (1...maximumColumnsPerEnd).contains(count)
            let names = [from.table, to.table] + from.columns + to.columns
            guard sameWidth, names.allSatisfy(isUsableName) else { return nil }
            return (Relationship.End(table: from.table, columns: from.columns), Relationship.End(table: to.table, columns: to.columns))
        }

        private func kind(_ cardinality: String) -> Relationship.Kind {
            cardinality == "oneToOne" ? .oneToOne : .manyToOne
        }

        /// The note and every non-code piece of evidence, in one rationale.
        private func rationale(_ note: String?, _ evidence: [LegacyEvidence]) -> String? {
            var parts: [String] = []
            if let note, !note.isEmpty { parts.append(note) }
            for item in evidence where !isCode(item) {
                if let detail = item.detail, !detail.isEmpty { parts.append(item.kind + ": " + detail) }
            }
            let text = KnowledgeMCP.clean(parts.joined(separator: "; "), limit: KnowledgeMCP.maxRationaleLength)
            return text.isEmpty ? nil : text
        }

        /// Code locations as `code` evidence (project, path, line); the other kinds as the author's own evidence.
        private func evidence(_ items: [LegacyEvidence], by: String, at: Date) -> [Evidence] {
            var result = codeEvidence(items, by: by, at: at)
            for item in items.prefix(20) where !isCode(item) {
                guard let detail = item.detail.map({ (text: String) -> String in KnowledgeMCP.clean(text, limit: 300) }), !detail.isEmpty else { continue }
                result.append(Evidence(source: by == userAuthor ? .user : .ai, rationale: item.kind + ": " + detail, by: by, at: at))
            }
            return Array(result.prefix(20))
        }

        private func codeEvidence(_ items: [LegacyEvidence], by: String, at: Date) -> [Evidence] {
            items.prefix(20).compactMap { (item: LegacyEvidence) -> Evidence? in
                guard isCode(item), let path = item.path else { return nil }
                let project = item.project.flatMap { (name: String) -> String? in projectsByName[name] }
                let detail = item.detail.map { (text: String) -> String in KnowledgeMCP.clean(text, limit: 300) }
                return Evidence(source: .code, project: project, path: KnowledgeMCP.clean(path, limit: 500), line: item.line,
                                rationale: detail?.isEmpty == false ? detail : nil, by: by, at: at)
            }
        }

        private func isCode(_ item: LegacyEvidence) -> Bool {
            item.kind == "code" && item.path?.isEmpty == false
        }

        /// 1.5's `pairID`: both ends' labels, sorted.
        private func pairKey(_ first: End, _ second: End) -> String {
            [first.label, second.label].sorted().joined(separator: "<->")
        }
    }

    // MARK: 1.5 shapes (decoded leniently: fields 1.5 added over time fall back to their defaults)

    /// Any JSON value, not read.
    struct Ignored: Decodable, Sendable {
        init(from decoder: any Decoder) throws {}
    }

    struct Project: Decodable, Sendable {
        var name: String
        var path: String
        var addedAt: Date
    }

    struct Notes: Decodable, Sendable {
        var tables: [String: TableNote] = [:]
        var columns: [String: [String: ColumnNote]] = [:]
        var glossary: [String: GlossaryTerm] = [:]
        var relationships: [String: AnnotatedRelationship] = [:]
        var verdicts: [String: Verdict] = [:]

        init() {}

        enum CodingKeys: String, CodingKey {
            case tables, columns, glossary, relationships, verdicts
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tables = try container.decodeIfPresent([String: TableNote].self, forKey: .tables) ?? [:]
            columns = try container.decodeIfPresent([String: [String: ColumnNote]].self, forKey: .columns) ?? [:]
            glossary = try container.decodeIfPresent([String: GlossaryTerm].self, forKey: .glossary) ?? [:]
            relationships = try container.decodeIfPresent([String: AnnotatedRelationship].self, forKey: .relationships) ?? [:]
            verdicts = try container.decodeIfPresent([String: Verdict].self, forKey: .verdicts) ?? [:]
        }
    }

    struct TableNote: Decodable, Sendable {
        var summary: String
        var author: String
        var updatedAt: Date
        var evidence: [LegacyEvidence]

        enum CodingKeys: String, CodingKey {
            case summary, author, updatedAt, evidence
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            summary = try container.decode(String.self, forKey: .summary)
            author = try container.decode(String.self, forKey: .author)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            evidence = try container.decodeIfPresent([LegacyEvidence].self, forKey: .evidence) ?? []
        }
    }

    struct ColumnNote: Decodable, Sendable {
        var note: String?
        var values: [String: String]
        var author: String
        var updatedAt: Date
        var evidence: [LegacyEvidence]

        enum CodingKeys: String, CodingKey {
            case note, values, author, updatedAt, evidence
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            note = try container.decodeIfPresent(String.self, forKey: .note)
            values = try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
            author = try container.decode(String.self, forKey: .author)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            evidence = try container.decodeIfPresent([LegacyEvidence].self, forKey: .evidence) ?? []
        }
    }

    struct GlossaryTerm: Decodable, Sendable {
        var term: String
        var definition: String
        var tables: [String]
        var sql: String?
        var author: String
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case term, definition, tables, sql, author, updatedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            term = try container.decode(String.self, forKey: .term)
            definition = try container.decodeIfPresent(String.self, forKey: .definition) ?? ""
            tables = try container.decodeIfPresent([String].self, forKey: .tables) ?? []
            sql = try container.decodeIfPresent(String.self, forKey: .sql)
            author = try container.decode(String.self, forKey: .author)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
    }

    struct Verdict: Decodable, Sendable {
        /// `confirmed` or `rejected`.
        var status: String
        var reason: String?
        var author: String
        var updatedAt: Date
        var ends: [End]

        enum CodingKeys: String, CodingKey {
            case status, reason, author, updatedAt, ends
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            author = try container.decode(String.self, forKey: .author)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            ends = try container.decodeIfPresent([End].self, forKey: .ends) ?? []
        }
    }

    struct AnnotatedRelationship: Decodable, Sendable {
        var relationship: LegacyRelationship
        var note: String?
        var author: String
        var updatedAt: Date
    }

    struct LegacyRelationship: Decodable, Sendable {
        var from: End
        var to: End
        /// `manyToOne`, `oneToOne` or `unknown`.
        var cardinality: String
        var evidence: [LegacyEvidence]

        init(from: End, to: End, cardinality: String, evidence: [LegacyEvidence]) {
            self.from = from
            self.to = to
            self.cardinality = cardinality
            self.evidence = evidence
        }

        enum CodingKeys: String, CodingKey {
            case from, to, cardinality, evidence
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decode(End.self, forKey: .from)
            to = try container.decode(End.self, forKey: .to)
            cardinality = try container.decodeIfPresent(String.self, forKey: .cardinality) ?? "unknown"
            evidence = try container.decodeIfPresent([LegacyEvidence].self, forKey: .evidence) ?? []
        }
    }

    struct End: Decodable, Sendable {
        var table: String
        var columns: [String]

        /// 1.5's `RelationshipEnd.label`.
        var label: String { "\(table)(\(columns.joined(separator: ", ")))" }
    }

    struct LegacyEvidence: Decodable, Sendable {
        /// `schema`, `naming`, `definition`, `code`, `query` or `note`.
        var kind: String
        var project: String?
        var path: String?
        var line: Int?
        var detail: String?
    }
}
