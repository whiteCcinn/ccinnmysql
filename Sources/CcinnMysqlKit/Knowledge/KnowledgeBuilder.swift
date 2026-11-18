import Foundation
import MySQLKit

/// What a build reads from the server.
public struct SchemaFacts: Sendable {
    public var tables: [KnowledgeTable]
    public var definitions: [StoredDefinition]
    public var serverVersion: String?
    /// Parts that could not be read (missing privileges, …).
    public var warnings: [String]

    public init(tables: [KnowledgeTable], definitions: [StoredDefinition] = [], serverVersion: String? = nil, warnings: [String] = []) {
        self.tables = tables
        self.definitions = definitions
        self.serverVersion = serverVersion
        self.warnings = warnings
    }
}

/// Reads schema facts for a build (the server through `MySQLKnowledgeSource`, or a fake in tests).
public protocol KnowledgeSchemaSource: Sendable {
    func facts(database: String) async throws -> SchemaFacts
}

/// Builds the factual part of a knowledge base (design D6): snapshot, declared keys, naming candidates, joins in
/// definitions and linked code. The slow work runs without the file lock; the result is applied under it to the
/// latest saved version, so annotations and project changes made meanwhile are kept.
public struct KnowledgeBuilder: Sendable {
    public enum Phase: Sendable, Equatable {
        case schema
        case relationships
        case code(filesDone: Int, filesTotal: Int)
        case saving
    }

    public struct Summary: Sendable {
        public let tables: Int
        public let views: Int
        /// Relationships per source (one relationship counts for each of its sources).
        public let relationships: [RelationshipSource: Int]
        public let totalRelationships: Int
        public let changes: SchemaChanges?
        public let orphanedNotes: [String]
        public let projects: [ProjectScan]
        public let warnings: [String]
        public let durationSeconds: Double
    }

    public let store: KnowledgeStore
    public let scanner: CodeScanner

    public init(store: KnowledgeStore, scanner: CodeScanner = CodeScanner()) {
        self.store = store
        self.scanner = scanner
    }

    public func build(_ key: KnowledgeKey, source: any KnowledgeSchemaSource, scanCode: Bool = true,
                      progress: (@Sendable (Phase) -> Void)? = nil) async throws -> Summary {
        let clock = ContinuousClock()
        let started = clock.now
        // An unreadable file stops the build here: it would not be saved anyway.
        let projects = try store.load(key)?.projects ?? []

        progress?(.schema)
        // When the schema was read: a build that read it later and saved first must not be overwritten.
        let readAt = Date()
        let facts = try await source.facts(database: key.database)
        try Task.checkCancellation()
        let snapshot = KnowledgeSnapshot(tables: facts.tables, takenAt: readAt, serverVersion: facts.serverVersion)
        let index = KnowledgeSchemaIndex(snapshot.tables)

        progress?(.relationships)
        var base = RelationshipSet()
        for relationship in Self.declaredRelationships(snapshot.tables, database: key.database, index: index) { base.add(relationship) }
        for relationship in NamingInference.relationships(in: snapshot.tables) { base.add(relationship) }
        for definition in facts.definitions {
            try Task.checkCancellation()
            let findings = SQLJoinExtractor.scan(Array(definition.sql.utf8), index: index, database: key.database)
            let source: RelationshipSource = definition.kind == .view ? .view : .routine
            for join in findings.joins {
                let evidence = KnowledgeEvidence(kind: .definition, detail: "\(definition.kind.rawValue) \(definition.name)")
                base.add(CodeScanner.relationship(join, source: source, evidence: evidence))
            }
        }

        var scanResult: CodeScanner.Result?
        if scanCode, !projects.isEmpty {
            scanResult = try await scanner.scan(projects: projects, index: index, database: key.database) { step in
                progress?(.code(filesDone: step.filesDone, filesTotal: step.filesTotal))
            }
        }
        try Task.checkCancellation()

        progress?(.saving)
        let warnings = facts.warnings
        let scanned = scanResult
        let baseRelationships = base.all
        return try await store.update(key) { knowledge in
            if let saved = knowledge.snapshot, saved.takenAt > readAt {
                throw KnowledgeError("Another build of \(key.database) read the schema later and finished first; its newer result was kept.")
            }
            // Only projects still linked, under the name and at the folder they have now, contribute code findings.
            let linked = Dictionary(knowledge.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            func isCurrent(_ scan: ProjectScan) -> Bool {
                guard let project = linked[scan.projectID] else { return false }
                return project.name == scan.project && (scan.path == nil || scan.path == project.path)
            }
            var relationships = RelationshipSet()
            baseRelationships.forEach { relationships.add($0) }
            let codeRelationships: [KnowledgeRelationship]
            let references: [String: [CodeReference]]
            let projectScans: [ProjectScan]
            if let scanned {
                let kept = Set(scanned.projects.filter(isCurrent).map(\.project))
                codeRelationships = scanned.joins.compactMap { Self.restricted($0, toProjects: kept) }
                references = scanned.references.compactMapValues { list in
                    let filtered = list.filter { kept.contains($0.project) }
                    return filtered.isEmpty ? nil : filtered
                }
                projectScans = scanned.projects.filter(isCurrent)
            } else if !scanCode {
                // Schema-only rebuild: the previous code findings stay (revalidated against the new snapshot by the graph).
                let kept = Set((knowledge.build?.projects ?? []).filter(isCurrent).map(\.project))
                codeRelationships = knowledge.computed.compactMap { Self.codePart(of: $0) }.compactMap { Self.restricted($0, toProjects: kept) }
                references = knowledge.references.filter { index.tables[$0.key] != nil }
                projectScans = (knowledge.build?.projects ?? []).filter(isCurrent)
            } else {
                codeRelationships = []
                references = [:]
                projectScans = []
            }
            codeRelationships.forEach { relationships.add($0) }
            let changes = SchemaChanges.between(knowledge.snapshot, snapshot)
            knowledge.snapshot = snapshot
            knowledge.computed = relationships.all
            knowledge.references = references
            let duration = clock.now - started
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            knowledge.build = BuildInfo(builtAt: Date(), durationSeconds: seconds, codeScanned: scanned != nil || (scanCode && projects.isEmpty),
                                        projects: projectScans, changes: changes, warnings: warnings)
            var counts: [RelationshipSource: Int] = [:]
            for relationship in knowledge.computed {
                for source in relationship.sources { counts[source, default: 0] += 1 }
            }
            return Summary(tables: snapshot.tables.filter { $0.kind == .table }.count, views: snapshot.tables.filter { $0.kind == .view }.count,
                           relationships: counts, totalRelationships: knowledge.computed.count, changes: changes,
                           orphanedNotes: knowledge.orphanedNotes, projects: projectScans, warnings: warnings, durationSeconds: seconds)
        }
    }

    /// Declared foreign keys between tables of this database.
    static func declaredRelationships(_ tables: [KnowledgeTable], database: String, index: KnowledgeSchemaIndex) -> [KnowledgeRelationship] {
        var found: [KnowledgeRelationship] = []
        for table in tables {
            for key in table.foreignKeys where key.referencedDatabase == database && !key.columns.isEmpty
                && key.columns.count == key.referencedColumns.count {
                guard let target = index.tables[key.referencedTable] ?? index.table(lowercased: key.referencedTable.lowercased()).flatMap({ index.tables[$0] })
                else { continue }
                // Servers report key columns as written in the DDL (`REFERENCES t(ID)` for a column `id`).
                let columns = key.columns.compactMap { index.column(lowercased: $0.lowercased(), in: table.name) }
                let referenced = key.referencedColumns.compactMap { index.column(lowercased: $0.lowercased(), in: target.name) }
                guard columns.count == key.columns.count, referenced.count == key.referencedColumns.count else { continue }
                let oneToOne = columns.count == 1 && table.isSingleColumnKey(columns[0])
                    || Set(columns.map { $0.lowercased() }) == Set(table.primaryKey.map { $0.lowercased() })
                found.append(KnowledgeRelationship(
                    from: RelationshipEnd(table: table.name, columns: columns),
                    to: RelationshipEnd(table: target.name, columns: referenced),
                    sources: [.declared], confidence: 1, cardinality: oneToOne ? .oneToOne : .manyToOne,
                    evidence: [KnowledgeEvidence(kind: .schema, detail: "FOREIGN KEY \(key.name)")], constraintName: key.name))
            }
        }
        return found
    }

    /// The code-derived part of a computed relationship (sources other than `code` are recomputed by every build).
    static func codePart(of relationship: KnowledgeRelationship) -> KnowledgeRelationship? {
        guard relationship.sources.contains(.code) else { return nil }
        let evidence = relationship.evidence.filter { $0.kind == .code }
        return KnowledgeRelationship(from: relationship.from, to: relationship.to, sources: [.code],
                                     confidence: relationship.cardinality == .unknown ? 0.6 : 0.9, cardinality: relationship.cardinality,
                                     evidence: evidence, occurrences: max(1, evidence.count))
    }

    /// A code relationship with only the evidence of `projects`; `nil` when none is left.
    static func restricted(_ relationship: KnowledgeRelationship, toProjects projects: Set<String>) -> KnowledgeRelationship? {
        let evidence = relationship.evidence.filter { $0.kind != .code || $0.project.map(projects.contains) == true }
        guard evidence.contains(where: { $0.kind == .code }) else { return nil }
        return KnowledgeRelationship(from: relationship.from, to: relationship.to, sources: relationship.sources, confidence: relationship.confidence,
                                     cardinality: relationship.cardinality, evidence: evidence, occurrences: relationship.occurrences)
    }
}

/// Relationships merged by id, in first-seen order.
struct RelationshipSet {
    private var byID: [String: KnowledgeRelationship] = [:]
    private var order: [String] = []

    mutating func add(_ relationship: KnowledgeRelationship) {
        let id = relationship.id
        if let existing = byID[id] {
            byID[id] = existing.merged(with: relationship)
        } else {
            byID[id] = relationship
            order.append(id)
        }
    }

    var all: [KnowledgeRelationship] { order.compactMap { byID[$0] }.sorted { $0.id < $1.id } }
}
