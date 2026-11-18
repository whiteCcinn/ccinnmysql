import Foundation

// The knowledge base of one database of one saved connection (design D1–D4). It holds metadata and annotations,
// never row data. Field ownership (D3): `projects` is written by the user in the app, `snapshot`/`computed`/
// `references`/`build` by builds, `notes` by annotations; each writer changes only its own fields under the file lock.

/// Identifies a knowledge base: one database of one saved connection.
public struct KnowledgeKey: Hashable, Sendable, CustomStringConvertible {
    public let connectionID: UUID
    public let database: String

    public init(connectionID: UUID, database: String) {
        self.connectionID = connectionID
        self.database = database
    }

    public var description: String { "\(connectionID.uuidString)/\(database)" }
}

/// Who wrote an annotation.
public enum KnowledgeAuthor: String, Codable, Sendable, Hashable {
    case ai
    case user
}

/// Where a relationship comes from. Facts (`declared` … `naming`) are computed by builds; `ai` and `user` are annotations.
public enum RelationshipSource: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case declared
    case view
    case routine
    case code
    case naming
    case ai
    case user

    /// Ordered from strongest to weakest provenance.
    public static func < (lhs: RelationshipSource, rhs: RelationshipSource) -> Bool { lhs.rank < rhs.rank }

    private var rank: Int {
        switch self {
        case .declared: 0
        case .user: 1
        case .view: 2
        case .routine: 3
        case .code: 4
        case .ai: 5
        case .naming: 6
        }
    }

    /// Facts recomputed by every build (as opposed to annotations, which survive rebuilds as they are).
    public var isComputed: Bool { self != .ai && self != .user }
}

public enum RelationshipCardinality: String, Codable, Sendable, Hashable {
    /// Many rows of `from` reference one row of `to` (the usual foreign key).
    case manyToOne
    case oneToOne
    /// Neither side is a single-column key: the direction is as written.
    case unknown
}

/// Why a relationship, note or term is believed.
public struct KnowledgeEvidence: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A declared foreign key.
        case schema
        /// A naming convention match.
        case naming
        /// A view, routine, trigger or event definition.
        case definition
        /// A file of a linked project.
        case code
        /// A query the AI ran to verify the claim.
        case query
        /// Anything else, described in `detail`.
        case note
    }

    public var kind: Kind
    /// Name of the linked project (`kind == .code`).
    public var project: String?
    /// Path relative to the project root.
    public var path: String?
    public var line: Int?
    public var detail: String?

    public init(kind: Kind, project: String? = nil, path: String? = nil, line: Int? = nil, detail: String? = nil) {
        self.kind = kind
        self.project = project
        self.path = path
        self.line = line
        self.detail = detail
    }

    /// `project:path:line` for code evidence, otherwise the detail.
    public var label: String {
        if let path {
            let location = [project, path].compactMap { $0 }.joined(separator: ":")
            return line.map { "\(location):\($0)" } ?? location
        }
        return detail ?? kind.rawValue
    }
}

/// One side of a relationship.
public struct RelationshipEnd: Codable, Sendable, Hashable {
    public var table: String
    public var columns: [String]

    public init(table: String, columns: [String]) {
        self.table = table
        self.columns = columns
    }

    public var label: String { "\(table)(\(columns.joined(separator: ", ")))" }
}

/// A relationship between two tables of the same database.
public struct KnowledgeRelationship: Codable, Sendable, Hashable, Identifiable {
    public static let maxEvidence = 5

    public var from: RelationshipEnd
    public var to: RelationshipEnd
    /// Sorted strongest first, without duplicates.
    public var sources: [RelationshipSource]
    public var confidence: Double
    public var cardinality: RelationshipCardinality
    /// At most `maxEvidence`, strongest first.
    public var evidence: [KnowledgeEvidence]
    /// How often the join was seen in code and definitions.
    public var occurrences: Int
    /// The declared foreign key's name.
    public var constraintName: String?

    public init(from: RelationshipEnd, to: RelationshipEnd, sources: [RelationshipSource], confidence: Double,
                cardinality: RelationshipCardinality, evidence: [KnowledgeEvidence] = [], occurrences: Int = 0, constraintName: String? = nil) {
        // Edges without a key side have no direction: a canonical order lets the same join written either way merge.
        // One-to-one keys keep theirs (a declared key points from the extension table to the main one).
        if cardinality == .unknown, to.label < from.label {
            self.from = to
            self.to = from
        } else {
            self.from = from
            self.to = to
        }
        self.sources = Array(Set(sources)).sorted()
        self.confidence = min(max(confidence, 0), 1)
        self.cardinality = cardinality
        self.evidence = Array(evidence.prefix(Self.maxEvidence))
        self.occurrences = occurrences
        self.constraintName = constraintName
    }

    public var id: String { Self.id(from: from, to: to) }

    public static func id(from: RelationshipEnd, to: RelationshipEnd) -> String {
        "\(from.label)->\(to.label)"
    }

    /// The same for both directions: verdicts are keyed by it, so a relationship whose direction changes after a schema
    /// change (a new unique key) keeps its verdict.
    public var pairID: String { Self.pairID(from, to) }

    public static func pairID(_ first: RelationshipEnd, _ second: RelationshipEnd) -> String {
        [first.label, second.label].sorted().joined(separator: "<->")
    }

    public var isDeclared: Bool { sources.contains(.declared) }

    /// Combines two findings of the same edge: union of sources and evidence, the higher confidence.
    public func merged(with other: KnowledgeRelationship) -> KnowledgeRelationship {
        var evidence = self.evidence
        for item in other.evidence where !evidence.contains(item) { evidence.append(item) }
        let cardinality = self.cardinality == .unknown ? other.cardinality : self.cardinality
        return KnowledgeRelationship(from: from, to: to, sources: sources + other.sources, confidence: max(confidence, other.confidence),
                                     cardinality: cardinality, evidence: Self.diverse(evidence), occurrences: occurrences + other.occurrences,
                                     constraintName: constraintName ?? other.constraintName)
    }

    /// At most `maxEvidence`, strongest first, but one of each kind before a second of any: a code location must not be
    /// crowded out by several view and routine definitions.
    static func diverse(_ evidence: [KnowledgeEvidence]) -> [KnowledgeEvidence] {
        let ranked = evidence.enumerated().sorted { lhs, rhs in
            let left = evidenceRank(lhs.element.kind)
            let right = evidenceRank(rhs.element.kind)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        var chosen: [KnowledgeEvidence] = []
        var kinds = Set<KnowledgeEvidence.Kind>()
        for item in ranked where chosen.count < maxEvidence && kinds.insert(item.kind).inserted { chosen.append(item) }
        for item in ranked where chosen.count < maxEvidence && !chosen.contains(item) { chosen.append(item) }
        return chosen.sorted { evidenceRank($0.kind) < evidenceRank($1.kind) }
    }

    static func evidenceRank(_ kind: KnowledgeEvidence.Kind) -> Int {
        switch kind {
        case .schema: 0
        case .definition: 1
        case .code: 2
        case .query: 3
        case .note: 4
        case .naming: 5
        }
    }
}

// MARK: - Snapshot

public struct KnowledgeColumn: Codable, Sendable, Hashable {
    public var name: String
    /// Full type, e.g. `bigint unsigned`, `varchar(64)`.
    public var type: String
    /// Base type, e.g. `bigint`, `varchar`.
    public var dataType: String
    public var nullable: Bool
    public var comment: String?

    public init(name: String, type: String, dataType: String, nullable: Bool, comment: String? = nil) {
        self.name = name
        self.type = type
        self.dataType = dataType
        self.nullable = nullable
        self.comment = comment?.isEmpty == true ? nil : comment
    }
}

/// A declared foreign key of a table.
public struct DeclaredForeignKey: Codable, Sendable, Hashable {
    public var name: String
    public var columns: [String]
    public var referencedDatabase: String
    public var referencedTable: String
    public var referencedColumns: [String]

    public init(name: String, columns: [String], referencedDatabase: String, referencedTable: String, referencedColumns: [String]) {
        self.name = name
        self.columns = columns
        self.referencedDatabase = referencedDatabase
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }
}

public struct KnowledgeTable: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case table
        case view
    }

    public var name: String
    public var kind: Kind
    public var engine: String?
    public var rowsEstimate: Int64?
    public var comment: String?
    public var columns: [KnowledgeColumn]
    public var primaryKey: [String]
    public var uniqueKeys: [[String]]
    /// Column lists of the other indexes.
    public var indexes: [[String]]
    public var foreignKeys: [DeclaredForeignKey]
    /// Hash of the structure (kind, engine, columns, keys, foreign keys, comments); row estimates excluded.
    public var fingerprint: String

    public init(name: String, kind: Kind = .table, engine: String? = nil, rowsEstimate: Int64? = nil, comment: String? = nil,
                columns: [KnowledgeColumn], primaryKey: [String] = [], uniqueKeys: [[String]] = [], indexes: [[String]] = [],
                foreignKeys: [DeclaredForeignKey] = []) {
        self.name = name
        self.kind = kind
        self.engine = engine
        self.rowsEstimate = rowsEstimate
        self.comment = comment?.isEmpty == true ? nil : comment
        self.columns = columns
        self.primaryKey = primaryKey
        self.uniqueKeys = uniqueKeys
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        fingerprint = ""
        fingerprint = Self.fingerprint(of: self)
    }

    public func column(named name: String) -> KnowledgeColumn? {
        columns.first { $0.name == name } ?? columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The column alone is the primary key or a unique key.
    public func isSingleColumnKey(_ column: String) -> Bool {
        let lowered = column.lowercased()
        if primaryKey.count == 1, primaryKey[0].lowercased() == lowered { return true }
        return uniqueKeys.contains { $0.count == 1 && $0[0].lowercased() == lowered }
    }

    /// The column leads some index (foreign key columns usually do).
    public func isIndexLeader(_ column: String) -> Bool {
        let lowered = column.lowercased()
        return ([primaryKey] + uniqueKeys + indexes).contains { $0.first?.lowercased() == lowered }
    }

    static func fingerprint(of table: KnowledgeTable) -> String {
        var hasher = StableHasher()
        hasher.add(table.kind.rawValue)
        hasher.add(table.engine ?? "")
        hasher.add(table.comment ?? "")
        for column in table.columns {
            hasher.add(column.name)
            hasher.add(column.type)
            hasher.add(column.nullable ? "1" : "0")
            hasher.add(column.comment ?? "")
        }
        hasher.add("pk:" + table.primaryKey.joined(separator: ","))
        for key in table.uniqueKeys { hasher.add("uk:" + key.joined(separator: ",")) }
        for key in table.indexes { hasher.add("ix:" + key.joined(separator: ",")) }
        for key in table.foreignKeys.sorted(by: { $0.name < $1.name }) {
            hasher.add("fk:\(key.name):\(key.columns.joined(separator: ",")):\(key.referencedDatabase).\(key.referencedTable):\(key.referencedColumns.joined(separator: ","))")
        }
        return hasher.hexDigest
    }
}

/// 64-bit FNV-1a over length-prefixed fields: stable across processes and versions (unlike `Hasher`).
struct StableHasher {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ text: String) {
        let bytes = Array(text.utf8)
        var length = UInt64(bytes.count)
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: length))
            length >>= 8
        }
        for byte in bytes { mix(byte) }
    }

    private mutating func mix(_ byte: UInt8) {
        state ^= UInt64(byte)
        state = state &* 0x0000_0100_0000_01B3
    }

    var hexDigest: String {
        let hex = String(state, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

public struct KnowledgeSnapshot: Codable, Sendable, Equatable {
    /// Sorted by name.
    public var tables: [KnowledgeTable]
    public var takenAt: Date
    public var serverVersion: String?

    public init(tables: [KnowledgeTable], takenAt: Date = Date(), serverVersion: String? = nil) {
        self.tables = tables.sorted { $0.name < $1.name }
        self.takenAt = takenAt
        self.serverVersion = serverVersion
    }
}

/// What changed in the schema since the previous build.
public struct SchemaChanges: Codable, Sendable, Equatable {
    public var added: [String]
    public var removed: [String]
    public var changed: [String]

    public init(added: [String] = [], removed: [String] = [], changed: [String] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    public static func between(_ old: KnowledgeSnapshot?, _ new: KnowledgeSnapshot) -> SchemaChanges? {
        guard let old else { return nil }
        let before = Dictionary(old.tables.map { ($0.name, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.tables.map { ($0.name, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        return SchemaChanges(added: after.keys.filter { before[$0] == nil }.sorted(),
                             removed: before.keys.filter { after[$0] == nil }.sorted(),
                             changed: after.compactMap { name, print in before[name].map { $0 == print ? nil : name } ?? nil }.sorted())
    }
}

// MARK: - Projects and code

/// A local directory linked to the database by the user.
public struct LinkedProject: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Unique within the knowledge base; used in evidence.
    public var name: String
    /// Absolute, standardized path.
    public var path: String
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, path: String, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
    }
}

/// Where a table is used in a linked project.
public struct CodeReference: Codable, Sendable, Hashable {
    public var project: String
    public var path: String
    /// First line that mentions the table.
    public var line: Int
    public var count: Int
    /// Seen after FROM/JOIN/INTO/UPDATE/TABLE (rather than only as a string that equals the table name).
    public var sql: Bool

    public init(project: String, path: String, line: Int, count: Int, sql: Bool) {
        self.project = project
        self.path = path
        self.line = line
        self.count = count
        self.sql = sql
    }
}

/// Outcome of scanning one linked project.
public struct ProjectScan: Codable, Sendable, Hashable {
    public var projectID: UUID
    public var project: String
    /// The folder that was scanned (a project relocated meanwhile is not credited with the old folder's findings).
    public var path: String?
    /// Git `HEAD` commit when scanned.
    public var commit: String?
    public var files: Int
    public var bytes: Int64
    /// A file or byte limit stopped the scan early.
    public var truncated: Bool
    public var error: String?

    public init(projectID: UUID, project: String, path: String? = nil, commit: String? = nil, files: Int = 0, bytes: Int64 = 0,
                truncated: Bool = false, error: String? = nil) {
        self.projectID = projectID
        self.project = project
        self.path = path
        self.commit = commit
        self.files = files
        self.bytes = bytes
        self.truncated = truncated
        self.error = error
    }
}

public struct BuildInfo: Codable, Sendable, Equatable {
    public var builtAt: Date
    public var durationSeconds: Double
    public var codeScanned: Bool
    public var projects: [ProjectScan]
    /// `nil` on the first build.
    public var changes: SchemaChanges?
    public var warnings: [String]

    public init(builtAt: Date, durationSeconds: Double, codeScanned: Bool, projects: [ProjectScan], changes: SchemaChanges?, warnings: [String]) {
        self.builtAt = builtAt
        self.durationSeconds = durationSeconds
        self.codeScanned = codeScanned
        self.projects = projects
        self.changes = changes
        self.warnings = warnings
    }
}

// MARK: - Annotations

public struct TableNote: Codable, Sendable, Hashable {
    public var summary: String
    public var author: KnowledgeAuthor
    public var updatedAt: Date
    public var evidence: [KnowledgeEvidence]

    public init(summary: String, author: KnowledgeAuthor, updatedAt: Date = Date(), evidence: [KnowledgeEvidence] = []) {
        self.summary = summary
        self.author = author
        self.updatedAt = updatedAt
        self.evidence = evidence
    }
}

public struct ColumnNote: Codable, Sendable, Hashable {
    public var note: String?
    /// Meaning of stored values, e.g. `"3": "paused"`.
    public var values: [String: String]
    public var author: KnowledgeAuthor
    public var updatedAt: Date
    public var evidence: [KnowledgeEvidence]

    public init(note: String?, values: [String: String] = [:], author: KnowledgeAuthor, updatedAt: Date = Date(), evidence: [KnowledgeEvidence] = []) {
        self.note = note
        self.values = values
        self.author = author
        self.updatedAt = updatedAt
        self.evidence = evidence
    }
}

public struct GlossaryTerm: Codable, Sendable, Hashable {
    public var term: String
    public var definition: String
    public var tables: [String]
    /// A read-only statement computing the term (checked by `ReadOnlySQLGuard` when stored).
    public var sql: String?
    public var author: KnowledgeAuthor
    public var updatedAt: Date

    public init(term: String, definition: String, tables: [String] = [], sql: String? = nil, author: KnowledgeAuthor, updatedAt: Date = Date()) {
        self.term = term
        self.definition = definition
        self.tables = tables
        self.sql = sql
        self.author = author
        self.updatedAt = updatedAt
    }
}

public struct RelationshipVerdict: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case confirmed
        case rejected
    }

    public var status: Status
    public var reason: String?
    public var author: KnowledgeAuthor
    public var updatedAt: Date
    /// Both sides of the relationship (to find verdicts whose tables or columns disappeared).
    public var ends: [RelationshipEnd]

    public init(status: Status, reason: String?, author: KnowledgeAuthor, updatedAt: Date = Date(), ends: [RelationshipEnd] = []) {
        self.status = status
        self.reason = reason
        self.author = author
        self.updatedAt = updatedAt
        self.ends = ends
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        author = try container.decode(KnowledgeAuthor.self, forKey: .author)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        ends = try container.decodeIfPresent([RelationshipEnd].self, forKey: .ends) ?? []
    }
}

/// A relationship added by an AI or the user.
public struct AnnotatedRelationship: Codable, Sendable, Hashable {
    public var relationship: KnowledgeRelationship
    public var note: String?
    public var author: KnowledgeAuthor
    public var updatedAt: Date

    public init(relationship: KnowledgeRelationship, note: String?, author: KnowledgeAuthor, updatedAt: Date = Date()) {
        self.relationship = relationship
        self.note = note
        self.author = author
        self.updatedAt = updatedAt
    }
}

public struct KnowledgeNotes: Codable, Sendable, Equatable {
    /// Keyed by table name.
    public var tables: [String: TableNote]
    /// Keyed by table name, then column name.
    public var columns: [String: [String: ColumnNote]]
    /// Keyed by the lower-cased term.
    public var glossary: [String: GlossaryTerm]
    /// Keyed by relationship id.
    public var relationships: [String: AnnotatedRelationship]
    /// Keyed by relationship id.
    public var verdicts: [String: RelationshipVerdict]

    public init(tables: [String: TableNote] = [:], columns: [String: [String: ColumnNote]] = [:], glossary: [String: GlossaryTerm] = [:],
                relationships: [String: AnnotatedRelationship] = [:], verdicts: [String: RelationshipVerdict] = [:]) {
        self.tables = tables
        self.columns = columns
        self.glossary = glossary
        self.relationships = relationships
        self.verdicts = verdicts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tables = try container.decodeIfPresent([String: TableNote].self, forKey: .tables) ?? [:]
        columns = try container.decodeIfPresent([String: [String: ColumnNote]].self, forKey: .columns) ?? [:]
        glossary = try container.decodeIfPresent([String: GlossaryTerm].self, forKey: .glossary) ?? [:]
        relationships = try container.decodeIfPresent([String: AnnotatedRelationship].self, forKey: .relationships) ?? [:]
        verdicts = try container.decodeIfPresent([String: RelationshipVerdict].self, forKey: .verdicts) ?? [:]
    }

    public var count: Int {
        tables.count + columns.values.reduce(0) { $0 + $1.count } + glossary.count + relationships.count + verdicts.count
    }
}

// MARK: - Knowledge base

public struct KnowledgeBase: Codable, Sendable, Equatable {
    /// Bump for every change to what is stored. Older versions refuse to write newer files, so they never drop what
    /// they do not know (tolerant decoding below only fills in fields missing from older files).
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var connectionID: UUID
    public var database: String
    public var projects: [LinkedProject]
    public var snapshot: KnowledgeSnapshot?
    /// Relationships found by the last build (declared, definitions, code, naming).
    public var computed: [KnowledgeRelationship]
    /// Table name → files that use it.
    public var references: [String: [CodeReference]]
    public var build: BuildInfo?
    public var notes: KnowledgeNotes
    public var updatedAt: Date

    public init(key: KnowledgeKey, projects: [LinkedProject] = [], snapshot: KnowledgeSnapshot? = nil, computed: [KnowledgeRelationship] = [],
                references: [String: [CodeReference]] = [:], build: BuildInfo? = nil, notes: KnowledgeNotes = KnowledgeNotes(),
                updatedAt: Date = Date()) {
        formatVersion = Self.currentFormatVersion
        connectionID = key.connectionID
        database = key.database
        self.projects = projects
        self.snapshot = snapshot
        self.computed = computed
        self.references = references
        self.build = build
        self.notes = notes
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding: fields added by later versions of the same format fall back to their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        connectionID = try container.decode(UUID.self, forKey: .connectionID)
        database = try container.decode(String.self, forKey: .database)
        projects = try container.decodeIfPresent([LinkedProject].self, forKey: .projects) ?? []
        snapshot = try container.decodeIfPresent(KnowledgeSnapshot.self, forKey: .snapshot)
        computed = try container.decodeIfPresent([KnowledgeRelationship].self, forKey: .computed) ?? []
        references = try container.decodeIfPresent([String: [CodeReference]].self, forKey: .references) ?? [:]
        build = try container.decodeIfPresent(BuildInfo.self, forKey: .build)
        notes = try container.decodeIfPresent(KnowledgeNotes.self, forKey: .notes) ?? KnowledgeNotes()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public var key: KnowledgeKey { KnowledgeKey(connectionID: connectionID, database: database) }

    /// Annotations whose table or column no longer exists in the snapshot (kept until the user deletes them).
    public var orphanedNotes: [String] {
        guard let snapshot else { return [] }
        let tables = Dictionary(snapshot.tables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var orphans: [String] = []
        for name in notes.tables.keys where tables[name] == nil { orphans.append("table note: \(name)") }
        for (table, columns) in notes.columns {
            for column in columns.keys where tables[table]?.columns.contains(where: { $0.name == column }) != true {
                orphans.append("column note: \(table).\(column)")
            }
        }
        func exists(_ end: RelationshipEnd) -> Bool {
            guard let table = tables[end.table] else { return false }
            return end.columns.allSatisfy { column in table.columns.contains { $0.name == column } }
        }
        for (id, added) in notes.relationships where !(exists(added.relationship.from) && exists(added.relationship.to)) {
            orphans.append("relationship: \(id)")
        }
        for (id, verdict) in notes.verdicts where !verdict.ends.isEmpty && !verdict.ends.allSatisfy(exists) {
            orphans.append("verdict: \(id)")
        }
        return orphans.sorted()
    }
}

/// A failure explained in plain language (unreadable file, unknown table, invalid annotation, …).
public struct KnowledgeError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public enum Kind: Sendable, Equatable {
        /// The file cannot be decoded: the only case where the app offers to reset it.
        case damaged
        /// Written by a newer version: read-only here, never reset.
        case newerFormat
        /// I/O, size or lock problems that may pass.
        case unavailable
        case other
    }

    public let message: String
    public let kind: Kind

    public init(_ message: String, kind: Kind = .other) {
        self.message = message
        self.kind = kind
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
