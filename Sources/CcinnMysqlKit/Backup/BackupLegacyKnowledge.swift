import CryptoKit
import Foundation

/// Converts the knowledge of a CcinnMysql 1.5 backup (one `KnowledgeBase` per connection and database) into today's
/// knowledge base (`DatabaseKnowledge` per server and database, plus the index of projects and links).
///
/// What carries over:
/// - table notes and column notes (with their value meanings) → `Note`s of kind `description`;
/// - glossary terms → `Term`s (the term's SQL is kept in the definition: a term maps to tables, not to a statement);
/// - relationships the user or an AI added, and verdicts on any relationship → `Relationship`s with `user`, `ai` and
///   `code` evidence (a user's verdict confirms or rejects, as in the app);
/// - linked code folders → projects (`~/…` under the exporting user's home) linked to the database.
///
/// What does not: table structure, computed relationships, code references and build information. They are facts the
/// next refresh recomputes from the server. Items the new model cannot hold are reported with a warning.
///
/// Ids are derived from the database and the item, so importing the same 1.5 backup twice merges rather than duplicates.
enum BackupLegacyKnowledge {
    static let aiAuthor = "ai:unknown"
    static let userAuthor = "user"
    /// As `KnowledgeMCP`'s limits for what an AI may write.
    static let maximumColumnsPerEnd = 8
    static let maximumMappings = 20

    static func convert(_ bases: [Base], profiles: [ConnectionProfile], sourceHome: String, warnings: inout [BackupWarning]) -> BackupKnowledge? {
        guard !bases.isEmpty else { return nil }
        var profilesByID: [UUID: ConnectionProfile] = [:]
        for profile in profiles where profilesByID[profile.id] == nil { profilesByID[profile.id] = profile }
        var builder = IndexBuilder()
        var databases: [DatabaseKey: DatabaseKnowledge] = [:]
        var order: [DatabaseKey] = []
        var droppedFacts = false
        for base in bases {
            guard base.formatVersion <= 1 else {
                warnings.append(.legacyKnowledgeNotConverted("the knowledge of “\(label(base.database))” was written by a newer CcinnMysql."))
                continue
            }
            guard let profile = profilesByID[base.connectionID] else {
                warnings.append(.legacyKnowledgeNotConverted("the knowledge of “\(label(base.database))” belongs to a connection not in the backup."))
                continue
            }
            guard isUsableName(base.database) else {
                warnings.append(.legacyKnowledgeNotConverted("knowledge of a database with an unusable name."))
                continue
            }
            if base.hasFacts { droppedFacts = true }
            let key = DatabaseKey(cluster: ClusterKey(profile: profile), catalog: "def", database: base.database)
            let projects = builder.link(base.projects, to: key, sourceHome: sourceHome, warnings: &warnings)
            var converter = Converter(key: key, projectsByName: projects)
            let converted = converter.convert(base)
            warnings += converter.warnings
            let isEmpty: Bool = converted.notes.isEmpty && converted.terms.isEmpty && converted.relationships.isEmpty
            if !isEmpty || !projects.isEmpty { builder.addDatabase(key) }
            // Without notes, terms or relationships there is no file to write: the index entry carries the links.
            guard !isEmpty else { continue }
            if let existing = databases[key] {
                // Two connections (other users of the same server) both had knowledge of this database.
                databases[key] = BackupKnowledgeMerge.merge(local: existing, imported: converted).merged
            } else {
                databases[key] = converted
                order.append(key)
            }
        }
        if droppedFacts {
            warnings.append(.legacyKnowledgeNotConverted("table structure, computed relationships and code references; refresh each database's knowledge to rebuild them."))
        }
        guard !builder.index.databases.isEmpty else { return nil }
        return BackupKnowledge(index: builder.index, databases: order.compactMap { databases[$0] })
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

    // MARK: Index

    /// Projects by stored path (one per folder, however many databases it was linked to) and their links.
    struct IndexBuilder {
        private(set) var index = KnowledgeIndex()
        private var projectIDs = Set<String>()
        private var links = Set<String>()
        private var clusters = Set<ClusterKey>()
        private var databases = Set<String>()

        mutating func addDatabase(_ key: DatabaseKey) {
            if databases.insert(key.fileID).inserted { index.databases.append(KnowledgeIndex.DatabaseEntry(key: key)) }
            if clusters.insert(key.cluster).inserted { index.clusters.append(KnowledgeIndex.ClusterEntry(key: key.cluster)) }
        }

        /// Adds the base's projects and links them to `key`; returns project name → project id, for code evidence.
        mutating func link(_ projects: [Project], to key: DatabaseKey, sourceHome: String, warnings: inout [BackupWarning]) -> [String: String] {
            var byName: [String: String] = [:]
            for project in projects {
                // 1.5 stored absolute, standardized paths; anything else is not resolved against this process's folder.
                let isAbsolute: Bool = project.path.hasPrefix("/") && BackupPaths.isAcceptable(project.path)
                let stored = BackupPaths.collapsingHome(project.path, home: sourceHome)
                guard isAbsolute, BackupPaths.isAcceptable(stored) else {
                    warnings.append(.legacyKnowledgeNotConverted("the linked folder “\(label(project.path))”, whose path cannot be used."))
                    continue
                }
                let id = KnowledgeMCP.projectID(path: stored)
                if projectIDs.insert(id).inserted {
                    var name = KnowledgeMCP.clean(project.name, limit: 200).replacingOccurrences(of: "\n", with: " ")
                    if name.isEmpty { name = (stored as NSString).lastPathComponent }
                    index.projects.append(KnowledgeIndex.Project(id: id, path: stored, name: name, gitRemote: nil, addedAt: project.addedAt,
                                                                 addedBy: userAuthor))
                }
                if links.insert(id + "\u{1F}" + key.fileID).inserted {
                    index.links.append(KnowledgeIndex.Link(project: id, database: key.fileID, addedAt: project.addedAt, addedBy: userAuthor))
                }
                if byName[project.name] == nil { byName[project.name] = id }
            }
            return byName
        }
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

        mutating func convert(_ base: Base) -> DatabaseKnowledge {
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

        private mutating func relationships(_ base: Base) -> [Relationship] {
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

    struct Base: Decodable {
        var formatVersion: Int
        var connectionID: UUID
        var database: String
        var projects: [Project] = []
        var computed: [LegacyRelationship] = []
        var notes = Notes()
        /// Structure, computed relationships or code references that the conversion drops.
        var hasFacts = false

        enum CodingKeys: String, CodingKey {
            case formatVersion, connectionID, database, projects, snapshot, computed, references, build, notes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try container.decode(Int.self, forKey: .formatVersion)
            connectionID = try container.decode(UUID.self, forKey: .connectionID)
            database = try container.decode(String.self, forKey: .database)
            // A newer knowledge format may have changed shape: it is skipped, so nothing else is read from it.
            guard formatVersion <= 1 else { return }
            projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
            // Computed relationships only orient verdicts; one that does not decode orients nothing.
            computed = (try? container.decodeIfPresent([LegacyRelationship].self, forKey: .computed)) ?? []
            notes = try container.decodeIfPresent(Notes.self, forKey: .notes) ?? Notes()
            let hasSnapshot: Bool = (try? container.decodeNil(forKey: .snapshot)) == false
            let references = (try? container.decodeIfPresent([String: Ignored].self, forKey: .references)) ?? nil
            let hasReferences: Bool = references?.isEmpty == false
            hasFacts = hasSnapshot || !computed.isEmpty || hasReferences
        }
    }

    /// Any JSON value, not read.
    struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    struct Project: Decodable {
        var name: String
        var path: String
        var addedAt: Date
    }

    struct Notes: Decodable {
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

    struct TableNote: Decodable {
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

    struct ColumnNote: Decodable {
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

    struct GlossaryTerm: Decodable {
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

    struct Verdict: Decodable {
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

    struct AnnotatedRelationship: Decodable {
        var relationship: LegacyRelationship
        var note: String?
        var author: String
        var updatedAt: Date
    }

    struct LegacyRelationship: Decodable {
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

    struct End: Decodable {
        var table: String
        var columns: [String]

        /// 1.5's `RelationshipEnd.label`.
        var label: String { "\(table)(\(columns.joined(separator: ", ")))" }
    }

    struct LegacyEvidence: Decodable {
        /// `schema`, `naming`, `definition`, `code`, `query` or `note`.
        var kind: String
        var project: String?
        var path: String?
        var line: Int?
        var detail: String?
    }
}
