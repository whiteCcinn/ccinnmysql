import Darwin
import Foundation

/// Judgements added by an AI or the user (design D9): notes, value meanings, glossary terms, relationships and
/// verdicts. Validated as a whole before anything is applied (all or nothing).
public struct KnowledgeAnnotation: Sendable {
    public struct EvidenceInput: Sendable {
        public enum Kind: String, Sendable {
            case code, query, note
        }

        public var kind: Kind?
        public var project: String?
        public var path: String?
        public var line: Int?
        public var detail: String?

        public init(kind: Kind? = nil, project: String? = nil, path: String? = nil, line: Int? = nil, detail: String? = nil) {
            self.kind = kind
            self.project = project
            self.path = path
            self.line = line
            self.detail = detail
        }
    }

    public struct TableNoteInput: Sendable {
        public var table: String
        /// Empty deletes the note.
        public var summary: String
        public var evidence: [EvidenceInput]

        public init(table: String, summary: String, evidence: [EvidenceInput] = []) {
            self.table = table
            self.summary = summary
            self.evidence = evidence
        }
    }

    public struct ColumnNoteInput: Sendable {
        public var table: String
        public var column: String
        /// No note and no values deletes the note.
        public var note: String?
        public var values: [String: String]
        public var evidence: [EvidenceInput]

        public init(table: String, column: String, note: String?, values: [String: String] = [:], evidence: [EvidenceInput] = []) {
            self.table = table
            self.column = column
            self.note = note
            self.values = values
            self.evidence = evidence
        }
    }

    public struct RelationshipInput: Sendable {
        public var fromTable: String
        public var fromColumns: [String]
        public var toTable: String
        public var toColumns: [String]
        public var confidence: Double?
        public var note: String?
        public var evidence: [EvidenceInput]
        /// Deletes the added relationship instead.
        public var remove: Bool

        public init(fromTable: String, fromColumns: [String], toTable: String, toColumns: [String], confidence: Double? = nil,
                    note: String? = nil, evidence: [EvidenceInput] = [], remove: Bool = false) {
            self.fromTable = fromTable
            self.fromColumns = fromColumns
            self.toTable = toTable
            self.toColumns = toColumns
            self.confidence = confidence
            self.note = note
            self.evidence = evidence
            self.remove = remove
        }
    }

    public struct VerdictInput: Sendable {
        public enum Status: String, Sendable {
            case confirmed, rejected, cleared
        }

        public var fromTable: String
        public var fromColumns: [String]
        public var toTable: String
        public var toColumns: [String]
        public var status: Status
        public var reason: String?

        public init(fromTable: String, fromColumns: [String], toTable: String, toColumns: [String], status: Status, reason: String?) {
            self.fromTable = fromTable
            self.fromColumns = fromColumns
            self.toTable = toTable
            self.toColumns = toColumns
            self.status = status
            self.reason = reason
        }
    }

    public struct GlossaryInput: Sendable {
        public var term: String
        /// Empty deletes the term.
        public var definition: String
        public var tables: [String]
        public var sql: String?

        public init(term: String, definition: String, tables: [String] = [], sql: String? = nil) {
            self.term = term
            self.definition = definition
            self.tables = tables
            self.sql = sql
        }
    }

    public var tableNotes: [TableNoteInput] = []
    public var columnNotes: [ColumnNoteInput] = []
    public var relationships: [RelationshipInput] = []
    public var verdicts: [VerdictInput] = []
    public var glossary: [GlossaryInput] = []

    public init() {}

    public var isEmpty: Bool {
        tableNotes.isEmpty && columnNotes.isEmpty && relationships.isEmpty && verdicts.isEmpty && glossary.isEmpty
    }
}

/// Validates and applies annotations.
public enum KnowledgeAnnotator {
    public static let maxItems = 100
    /// Text limits are UTF-8 bytes: a character count would let one grapheme carry megabytes of combining marks.
    public static let maxText = 8_000
    public static let maxTerm = 400
    public static let maxSQL = 16_000
    public static let maxValues = 200
    public static let maxColumns = 16
    /// All annotations of a knowledge base together, encoded.
    public static let maxNotesBytes = 4 * 1_048_576

    /// Applies `annotation` (validated first, all or nothing) and describes what changed.
    public static func apply(_ annotation: KnowledgeAnnotation, author: KnowledgeAuthor, to knowledge: inout KnowledgeBase,
                             now: Date = Date(), notesBudget: Int = maxNotesBytes) throws -> [String] {
        guard let snapshot = knowledge.snapshot else {
            throw KnowledgeError("The knowledge base of “\(knowledge.database)” has not been built yet; build it first (knowledge_build).")
        }
        guard !annotation.isEmpty else { throw KnowledgeError("Nothing to annotate.") }
        for (name, count) in [("table_notes", annotation.tableNotes.count), ("column_notes", annotation.columnNotes.count),
                              ("relationships", annotation.relationships.count), ("verdicts", annotation.verdicts.count),
                              ("glossary", annotation.glossary.count)] where count > maxItems {
            throw KnowledgeError("At most \(maxItems) \(name) per call (got \(count)).")
        }
        let context = Context(index: KnowledgeSchemaIndex(snapshot.tables), knowledge: knowledge, author: author)
        // Validate everything into a list of changes; apply only if all are valid.
        var changes: [(String, (inout KnowledgeBase) -> Void)] = []
        for input in annotation.tableNotes { changes.append(try context.tableNote(input, now: now)) }
        for input in annotation.columnNotes { changes.append(try context.columnNote(input, now: now)) }
        for input in annotation.relationships { changes.append(try context.relationship(input, now: now)) }
        for input in annotation.verdicts { changes.append(try context.verdict(input, now: now)) }
        for input in annotation.glossary { changes.append(try context.glossaryTerm(input, now: now)) }
        var updated = knowledge
        for (_, change) in changes { change(&updated) }
        let before = encodedSize(knowledge.notes)
        let after = encodedSize(updated.notes)
        if after > notesBudget, after > before {
            throw KnowledgeError("The notes of \(knowledge.database) would exceed \(notesBudget / 1_048_576) MB; delete outdated notes first.")
        }
        knowledge = updated
        return changes.map(\.0)
    }

    static func encodedSize(_ notes: KnowledgeNotes) -> Int {
        (try? JSONEncoder().encode(notes).count) ?? Int.max
    }

    struct Context {
        let index: KnowledgeSchemaIndex
        let knowledge: KnowledgeBase
        let author: KnowledgeAuthor

        // MARK: Names

        func table(_ name: String) throws -> KnowledgeTable {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let table = index.tables[trimmed] ?? index.table(lowercased: trimmed.lowercased()).flatMap({ index.tables[$0] }) { return table }
            let similar = index.tables.keys.filter { $0.lowercased().contains(trimmed.lowercased()) || trimmed.lowercased().contains($0.lowercased()) }
                .sorted().prefix(5)
            throw KnowledgeError("No table “\(name)” in \(knowledge.database).\(similar.isEmpty ? "" : " Similar: \(similar.joined(separator: ", ")).")")
        }

        func column(_ name: String, of table: KnowledgeTable) throws -> String {
            if let exact = index.column(lowercased: name.trimmingCharacters(in: .whitespaces).lowercased(), in: table.name) { return exact }
            throw KnowledgeError("No column “\(name)” in \(table.name). Columns: \(table.columns.prefix(40).map(\.name).joined(separator: ", ")).")
        }

        func end(_ tableName: String, _ columns: [String]) throws -> (RelationshipEnd, KnowledgeTable) {
            guard (1...maxColumns).contains(columns.count) else {
                throw KnowledgeError("A relationship side needs 1 to \(maxColumns) columns.")
            }
            let table = try table(tableName)
            return (RelationshipEnd(table: table.name, columns: try columns.map { try column($0, of: table) }), table)
        }

        // MARK: Text

        /// `max` is in UTF-8 bytes. Control characters (other than tab and line breaks), bidirectional overrides and
        /// isolates, and line or paragraph separators are refused: they can make text read differently than it is.
        func text(_ value: String, field: String, max: Int = maxText, allowEmpty: Bool = false) throws -> String {
            guard value.utf8.count <= max * 2 else { throw KnowledgeError("`\(field)` is longer than \(max) bytes.") }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !allowEmpty { throw KnowledgeError("`\(field)` is empty.") }
            guard trimmed.utf8.count <= max else { throw KnowledgeError("`\(field)` is longer than \(max) bytes.") }
            if let bad = trimmed.unicodeScalars.first(where: Self.isRefused) {
                throw KnowledgeError("`\(field)` contains the character U+\(String(bad.value, radix: 16, uppercase: true)), which is not allowed.")
            }
            return trimmed
        }

        static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.properties.generalCategory == .control { return !["\n", "\t", "\r"].contains(scalar) }
            switch scalar.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029: return true
            default: return false
            }
        }

        /// The current annotation was written by the user and the author is an AI: refused.
        func guardOwnership(_ existing: KnowledgeAuthor?, what: String) throws {
            if author == .ai, existing == .user {
                throw KnowledgeError("The \(what) was written by the user; an AI cannot change or delete it. Ask the user to edit it in CcinnMysql.")
            }
        }

        // MARK: Evidence

        func evidence(_ inputs: [KnowledgeAnnotation.EvidenceInput]) throws -> [KnowledgeEvidence] {
            guard inputs.count <= KnowledgeRelationship.maxEvidence else {
                throw KnowledgeError("At most \(KnowledgeRelationship.maxEvidence) pieces of evidence per item.")
            }
            return try inputs.map { input in
                let detail = try input.detail.map { try text($0, field: "evidence.detail") }
                if let line = input.line, !(1...10_000_000).contains(line) { throw KnowledgeError("`evidence.line` must be a positive line number.") }
                if let path = input.path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
                    let (project, relative) = try file(path, project: input.project)
                    return KnowledgeEvidence(kind: .code, project: project, path: relative, line: input.line, detail: detail)
                }
                guard let detail else { throw KnowledgeError("Evidence needs a `path` (a file in a linked project) or a `detail`.") }
                // A query is kept without its values: the knowledge base holds no row data.
                if input.kind == .query { return KnowledgeEvidence(kind: .query, detail: SQLRedactor.redactLiterals(detail)) }
                return KnowledgeEvidence(kind: .note, detail: detail)
            }
        }

        /// A regular file inside a linked project, after resolving symbolic links: (project name, relative path).
        func file(_ path: String, project: String?) throws -> (String, String) {
            let projects = knowledge.projects
            guard !projects.isEmpty else {
                throw KnowledgeError("No project is linked to \(knowledge.database); the user can link one in CcinnMysql. Use `detail` evidence instead.")
            }
            let candidates: [LinkedProject]
            if let project, !project.trimmingCharacters(in: .whitespaces).isEmpty {
                candidates = projects.filter { $0.name.caseInsensitiveCompare(project) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(project) == .orderedSame }
                guard !candidates.isEmpty else {
                    throw KnowledgeError("No linked project “\(project)”. Linked projects: \(projects.map(\.name).joined(separator: ", ")).")
                }
            } else {
                candidates = projects
            }
            guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw KnowledgeError("`evidence.path` contains a control character.")
            }
            for candidate in candidates {
                guard let root = Self.realPath(candidate.path) else { continue }
                let target = path.hasPrefix("/") ? path : root + "/" + path
                guard let resolved = Self.realPath(target), resolved.hasPrefix(root + "/") else { continue }
                var info = stat()
                guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                return (candidate.name, String(resolved.dropFirst(root.count + 1)))
            }
            throw KnowledgeError("Evidence path “\(path)” is not a file inside a linked project (\(candidates.map(\.name).joined(separator: ", "))).")
        }

        static func realPath(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        // MARK: Items

        func tableNote(_ input: KnowledgeAnnotation.TableNoteInput, now: Date) throws -> (String, (inout KnowledgeBase) -> Void) {
            let table = try table(input.table)
            let summary = try text(input.summary, field: "table_notes.summary", allowEmpty: true)
            try guardOwnership(knowledge.notes.tables[table.name]?.author, what: "note on \(table.name)")
            if summary.isEmpty {
                return ("deleted the note on \(table.name)", { $0.notes.tables[table.name] = nil })
            }
            let note = TableNote(summary: summary, author: author, updatedAt: now, evidence: try evidence(input.evidence))
            return ("noted \(table.name)", { $0.notes.tables[table.name] = note })
        }

        func columnNote(_ input: KnowledgeAnnotation.ColumnNoteInput, now: Date) throws -> (String, (inout KnowledgeBase) -> Void) {
            let table = try table(input.table)
            let column = try column(input.column, of: table)
            let note = try input.note.map { try text($0, field: "column_notes.note", allowEmpty: true) }.flatMap { $0.isEmpty ? nil : $0 }
            guard input.values.count <= maxValues else { throw KnowledgeError("At most \(maxValues) values per column.") }
            var values: [String: String] = [:]
            for (value, meaning) in input.values {
                values[try text(value, field: "column_notes.values key", max: 200)] = try text(meaning, field: "column_notes.values", max: 1_000)
            }
            try guardOwnership(knowledge.notes.columns[table.name]?[column]?.author, what: "note on \(table.name).\(column)")
            if note == nil, values.isEmpty {
                return ("deleted the note on \(table.name).\(column)", { kb in
                    kb.notes.columns[table.name]?[column] = nil
                    if kb.notes.columns[table.name]?.isEmpty == true { kb.notes.columns[table.name] = nil }
                })
            }
            let entry = ColumnNote(note: note, values: values, author: author, updatedAt: now, evidence: try evidence(input.evidence))
            return ("noted \(table.name).\(column)", { $0.notes.columns[table.name, default: [:]][column] = entry })
        }

        /// The relationship's cardinality from the keys of both sides; reversed when only `from` is a key.
        func oriented(_ from: (RelationshipEnd, KnowledgeTable), _ to: (RelationshipEnd, KnowledgeTable))
            -> (from: RelationshipEnd, to: RelationshipEnd, cardinality: RelationshipCardinality) {
            func isKey(_ end: RelationshipEnd, _ table: KnowledgeTable) -> Bool {
                let columns = Set(end.columns.map { $0.lowercased() })
                let keys = [table.primaryKey] + table.uniqueKeys
                return keys.contains { !$0.isEmpty && Set($0.map { $0.lowercased() }) == columns }
            }
            switch (isKey(from.0, from.1), isKey(to.0, to.1)) {
            case (_, true) where isKey(from.0, from.1): return (from.0, to.0, .oneToOne)
            case (_, true): return (from.0, to.0, .manyToOne)
            case (true, false): return (to.0, from.0, .manyToOne)
            case (false, false): return (from.0, to.0, .unknown)
            }
        }

        func relationship(_ input: KnowledgeAnnotation.RelationshipInput, now: Date) throws -> (String, (inout KnowledgeBase) -> Void) {
            let from = try end(input.fromTable, input.fromColumns)
            let to = try end(input.toTable, input.toColumns)
            guard from.0.columns.count == to.0.columns.count else { throw KnowledgeError("Both sides of a relationship need the same number of columns.") }
            let oriented = oriented(from, to)
            let probe = KnowledgeRelationship(from: oriented.from, to: oriented.to, sources: [], confidence: 0, cardinality: oriented.cardinality)
            let id = probe.id
            try guardOwnership(knowledge.notes.relationships[id]?.author, what: "relationship \(id)")
            try guardOwnership(knowledge.notes.verdicts[probe.pairID]?.author, what: "verdict on \(id)")
            if input.remove {
                guard knowledge.notes.relationships[id] != nil else { throw KnowledgeError("No added relationship \(id) to remove.") }
                return ("removed \(id)", { $0.notes.relationships[id] = nil })
            }
            let evidence = try evidence(input.evidence)
            guard !evidence.isEmpty else {
                throw KnowledgeError("An added relationship needs evidence: a file in a linked project (`path`, `line`) or a query that verified it (`detail`).")
            }
            let note = try input.note.map { try text($0, field: "relationships.note", allowEmpty: true) }.flatMap { $0.isEmpty ? nil : $0 }
            let ceiling = author == .user ? 1.0 : 0.95
            let confidence = min(ceiling, max(0.1, input.confidence.flatMap { $0.isFinite ? $0 : nil } ?? (author == .user ? 1 : 0.8)))
            let relationship = KnowledgeRelationship(from: oriented.from, to: oriented.to, sources: [author == .user ? .user : .ai],
                                                     confidence: confidence, cardinality: oriented.cardinality, evidence: evidence)
            let added = AnnotatedRelationship(relationship: relationship, note: note, author: author, updatedAt: now)
            return ("added \(id)", { $0.notes.relationships[id] = added })
        }

        func verdict(_ input: KnowledgeAnnotation.VerdictInput, now: Date) throws -> (String, (inout KnowledgeBase) -> Void) {
            let from = try end(input.fromTable, input.fromColumns)
            let to = try end(input.toTable, input.toColumns)
            let id = KnowledgeRelationship.pairID(from.0, to.0)
            // Every record of this relationship, in either direction.
            let recorded = knowledge.computed.filter { $0.pairID == id }
            let added = knowledge.notes.relationships.values.filter { $0.relationship.pairID == id }
            guard let relationship = recorded.first ?? added.first?.relationship else {
                throw KnowledgeError("No relationship between \(from.0.label) and \(to.0.label) is recorded; add it under `relationships` with evidence instead.")
            }
            if recorded.contains(where: \.isDeclared) {
                throw KnowledgeError("\(relationship.id) is a declared foreign key; it needs no verdict and cannot be rejected.")
            }
            if author == .ai, added.contains(where: { $0.author == .user }) || recorded.contains(where: { $0.sources.contains(.user) }) {
                throw KnowledgeError("\(relationship.id) was added by the user; an AI cannot give it a verdict. Ask the user to review it in CcinnMysql.")
            }
            try guardOwnership(knowledge.notes.verdicts[id]?.author, what: "verdict on \(relationship.id)")
            if input.status == .cleared {
                return ("cleared the verdict on \(relationship.id)", { $0.notes.verdicts[id] = nil })
            }
            let reason = try input.reason.map { try text($0, field: "verdicts.reason", allowEmpty: true) }.flatMap { $0.isEmpty ? nil : $0 }
            if input.status == .rejected, reason == nil { throw KnowledgeError("Say why \(id) is wrong (`reason`).") }
            let verdict = RelationshipVerdict(status: input.status == .confirmed ? .confirmed : .rejected, reason: reason, author: author, updatedAt: now,
                                              ends: [relationship.from, relationship.to])
            return ("\(verdict.status.rawValue) \(relationship.id)", { $0.notes.verdicts[id] = verdict })
        }

        func glossaryTerm(_ input: KnowledgeAnnotation.GlossaryInput, now: Date) throws -> (String, (inout KnowledgeBase) -> Void) {
            let term = try text(input.term, field: "glossary.term", max: maxTerm)
            let key = term.lowercased()
            let definition = try text(input.definition, field: "glossary.definition", allowEmpty: true)
            try guardOwnership(knowledge.notes.glossary[key]?.author, what: "glossary term “\(term)”")
            if definition.isEmpty {
                return ("deleted the term \(term)", { $0.notes.glossary[key] = nil })
            }
            guard input.tables.count <= maxItems else { throw KnowledgeError("At most \(maxItems) tables per term.") }
            let tables = try input.tables.map { try table($0).name }
            var sql: String?
            if let text = input.sql?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                guard text.utf8.count <= maxSQL else { throw KnowledgeError("`glossary.sql` is longer than \(maxSQL) bytes.") }
                if let bad = text.unicodeScalars.first(where: Self.isRefused) {
                    throw KnowledgeError("`glossary.sql` contains the character U+\(String(bad.value, radix: 16, uppercase: true)), which is not allowed.")
                }
                // Later sessions may run a stored recipe: only single read-only statements are kept.
                if let reason = ReadOnlySQLGuard.check(text, defaultDatabase: knowledge.database) {
                    throw KnowledgeError("`glossary.sql` must be one read-only statement: \(reason)")
                }
                sql = text
            }
            let entry = GlossaryTerm(term: term, definition: definition, tables: tables, sql: sql, author: author, updatedAt: now)
            return ("defined \(term)", { $0.notes.glossary[key] = entry })
        }
    }
}
