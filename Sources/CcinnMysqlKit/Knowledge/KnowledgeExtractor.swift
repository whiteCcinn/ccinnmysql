import CryptoKit
import Foundation
import MySQLKit

/// A database's structure in five metadata queries, whatever its size: objects, columns, indexes, foreign keys and stored
/// definitions (views, routines, triggers, events). Metadata only; no rows.
public struct KnowledgeSchemaRows: Sendable {
    public var objects: [DatabaseObject]
    public var columns: [String: [ColumnInfo]]
    public var indexes: [String: [IndexInfo]]
    public var foreignKeys: [String: [ForeignKeyInfo]]
    public var definitions: [StoredDefinition]

    public init(objects: [DatabaseObject], columns: [String: [ColumnInfo]], indexes: [String: [IndexInfo]] = [:],
                foreignKeys: [String: [ForeignKeyInfo]] = [:], definitions: [StoredDefinition] = []) {
        self.objects = objects
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.definitions = definitions
    }
}

/// Where extraction reads a database's structure: `MySQLClient`, or a fake in tests.
public protocol KnowledgeSchemaSource: Sendable {
    var knowledgeServerVersion: String? { get }
    func knowledgeRows(_ database: String) async throws -> KnowledgeSchemaRows
    func knowledgeServerIdentifier() async -> String?
}

extension MySQLClient: KnowledgeSchemaSource {
    public var knowledgeServerVersion: String? { serverInfo.productDescription }

    public func knowledgeRows(_ database: String) async throws -> KnowledgeSchemaRows {
        async let objects = objects(schema: database)
        async let columns = columnsByTable(schema: database)
        async let indexes = indexesByTable(schema: database)
        async let foreignKeys = foreignKeysByTable(schema: database)
        async let stored = storedDefinitions(schema: database)
        return KnowledgeSchemaRows(objects: try await objects.objects, columns: try await columns, indexes: try await indexes,
                                   foreignKeys: try await foreignKeys, definitions: try await stored.definitions)
    }

    /// `@@server_uuid`; nil on MariaDB (no such variable) or when refused.
    public func knowledgeServerIdentifier() async -> String? {
        guard let results = try? await query("SELECT @@server_uuid AS identifier", limits: RowLimits(maxRows: 1, maxBytes: 4_096)) else { return nil }
        return results.last?.records.first?.text("identifier")
    }
}

/// One table or view as the server reports it, before it becomes `TableFacts`.
public struct ExtractedTable: Sendable {
    public var name: String
    public var kind: TableFacts.Kind
    public var comment: String?
    public var keys: TableFacts.Keys
    /// In column order.
    public var columns: [ColumnFacts]
    /// The query of a view: read for lineage, joins and the fingerprint, never stored.
    public var definition: String?

    public init(name: String, kind: TableFacts.Kind, comment: String? = nil, keys: TableFacts.Keys = TableFacts.Keys(), columns: [ColumnFacts] = [],
                definition: String? = nil) {
        self.name = name
        self.kind = kind
        self.comment = comment
        self.keys = keys
        self.columns = columns
        self.definition = definition
    }
}

/// A declared foreign key of a table in the extracted database.
public struct ExtractedForeignKey: Sendable, Equatable {
    public var table: String
    public var columns: [String]
    /// The referenced table's database; may be another database of the same server.
    public var referencedSchema: String
    public var referencedTable: String
    public var referencedColumns: [String]
    /// The server checks it for every row (InnoDB).
    public var isGuaranteed: Bool

    public init(table: String, columns: [String], referencedSchema: String, referencedTable: String, referencedColumns: [String], isGuaranteed: Bool) {
        self.table = table
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.isGuaranteed = isGuaranteed
    }
}

/// A stored routine, trigger or event body, mined for joins like a view and never stored.
public struct ExtractedRoutine: Sendable, Equatable {
    public var kind: String
    public var name: String
    public var sql: String

    public init(kind: String, name: String, sql: String) {
        self.kind = kind
        self.name = name
        self.sql = sql
    }
}

/// One database's structure at one moment.
public struct ExtractedSchema: Sendable {
    public var database: String
    public var serverVersion: String?
    public var serverIdentifier: String?
    public var tables: [ExtractedTable]
    public var foreignKeys: [ExtractedForeignKey]
    public var routines: [ExtractedRoutine]

    public init(database: String, serverVersion: String?, serverIdentifier: String?, tables: [ExtractedTable], foreignKeys: [ExtractedForeignKey] = [],
                routines: [ExtractedRoutine] = []) {
        self.database = database
        self.serverVersion = serverVersion
        self.serverIdentifier = serverIdentifier
        self.tables = tables
        self.foreignKeys = foreignKeys
        self.routines = routines
    }
}

public enum KnowledgeExtractor {
    public enum Failure: Error, LocalizedError, Equatable {
        case systemDatabase(String)

        public var errorDescription: String? {
            switch self {
            case let .systemDatabase(name): "“\(name)” is the server's own database; knowledge covers your databases."
            }
        }
    }

    /// The server's own databases: never a subject of knowledge (they also hold credentials and other sessions' SQL).
    public static let systemDatabases: Set<String> = ["mysql", "information_schema", "performance_schema", "sys"]

    public static func isSystemDatabase(_ name: String) -> Bool {
        systemDatabases.contains(name.lowercased())
    }

    public static func extract(database: String, from source: some KnowledgeSchemaSource) async throws -> ExtractedSchema {
        guard !isSystemDatabase(database) else { throw Failure.systemDatabase(database) }
        async let rows = source.knowledgeRows(database)
        async let identifier = source.knowledgeServerIdentifier()
        return build(database: database, rows: try await rows, serverVersion: source.knowledgeServerVersion, serverIdentifier: await identifier)
    }

    /// Pure: the extracted database from metadata rows.
    public static func build(database: String, rows: KnowledgeSchemaRows, serverVersion: String?, serverIdentifier: String?) -> ExtractedSchema {
        var viewDefinitions: [String: String] = [:]
        var routines: [ExtractedRoutine] = []
        for definition in rows.definitions {
            switch definition.kind {
            case .view: viewDefinitions[definition.name] = definition.sql
            case .routine, .trigger, .event: routines.append(ExtractedRoutine(kind: definition.kind.rawValue, name: definition.name, sql: definition.sql))
            }
        }
        var tables: [ExtractedTable] = []
        var foreignKeys: [ExtractedForeignKey] = []
        for object in rows.objects where object.kind == .table || object.kind == .view {
            let indexes = rows.indexes[object.name] ?? []
            let primary = indexes.first(where: \.isPrimary).flatMap(plainColumns) ?? []
            let unique = indexes.filter { $0.isUnique && !$0.isPrimary }.compactMap(plainColumns)
            let keyColumns = Set(primary)
            let columns = (rows.columns[object.name] ?? []).sorted { $0.ordinal < $1.ordinal }.map { (column: ColumnInfo) -> ColumnFacts in
                ColumnFacts(name: column.name, type: column.columnType.isEmpty ? column.dataType : column.columnType, isKey: keyColumns.contains(column.name),
                            isNullable: column.isNullable, comment: column.comment?.nilIfEmpty)
            }
            tables.append(ExtractedTable(name: object.name, kind: object.kind == .view ? .view : .table, comment: object.comment?.nilIfEmpty,
                                         keys: TableFacts.Keys(primary: primary, unique: unique), columns: columns,
                                         definition: object.kind == .view ? viewDefinitions[object.name] : nil))
            for key in rows.foreignKeys[object.name] ?? [] where key.columns.count == key.referencedColumns.count && !key.columns.isEmpty {
                foreignKeys.append(ExtractedForeignKey(table: object.name, columns: key.columns, referencedSchema: key.referencedSchema,
                                                       referencedTable: key.referencedTable, referencedColumns: key.referencedColumns, isGuaranteed: true))
            }
        }
        return ExtractedSchema(database: database, serverVersion: serverVersion, serverIdentifier: serverIdentifier, tables: tables,
                               foreignKeys: foreignKeys, routines: routines)
    }

    /// An index's columns when every key part is a plain column (functional key parts have no name).
    static func plainColumns(_ index: IndexInfo) -> [String]? {
        let names = index.columns.compactMap(\.name)
        return names.count == index.columns.count && !names.isEmpty ? names : nil
    }
}

/// Fingerprints that say whether knowledge written against a table still describes it.
public enum SchemaFingerprint {
    /// Kind, keys and every column's name, type, nullability and key flag in column order, plus the digest of a view's
    /// query (literals replaced, so a changed date filter is not a new structure). Comments, sizes and row counts are not
    /// part of it.
    public static func structure(kind: TableFacts.Kind, model: String?, keys: TableFacts.Keys, columns: [ColumnFacts], definition: String?) -> String {
        var lines: [String] = ["v1", kind.rawValue, model ?? "-"]
        let uniqueKeys = keys.unique.map { $0.joined(separator: ",") }.joined(separator: ";")
        lines.append([keys.primary.joined(separator: ","), uniqueKeys, keys.partition.joined(separator: ",")].joined(separator: "|"))
        for column in columns {
            let nullability = column.isNullable ? "N" : "NN"
            let key = column.isKey ? "K" : "-"
            lines.append([column.name, column.type.lowercased(), nullability, key].joined(separator: "\t"))
        }
        if let definition { lines.append("q\t" + SQLDigest.digest(definition)) }
        return hash(lines.joined(separator: "\n"))
    }

    /// The table's and its columns' comments: a changed comment refreshes the stored text without making knowledge stale.
    public static func comments(table comment: String?, columns: [ColumnFacts]) -> String {
        let lines: [String] = [comment ?? ""] + columns.map { $0.name + "\t" + ($0.comment ?? "") }
        return hash(lines.joined(separator: "\n"))
    }

    /// 24 hex characters of SHA-256: plenty to detect change, small in every relationship and note that records it.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
