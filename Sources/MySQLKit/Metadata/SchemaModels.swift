import Foundation

/// Kinds of schema objects shown in the browser.
public enum ObjectKind: String, Sendable, Codable, CaseIterable, Hashable {
    case table
    case view
    case systemView
    /// MariaDB 10.3+ sequences.
    case sequence
    case procedure
    case function
    case trigger
    case event

    public var displayName: String {
        switch self {
        case .table: "Table"
        case .view: "View"
        case .systemView: "System view"
        case .sequence: "Sequence"
        case .procedure: "Procedure"
        case .function: "Function"
        case .trigger: "Trigger"
        case .event: "Event"
        }
    }

    /// Objects that can be queried with SELECT.
    public var isRelation: Bool { self == .table || self == .view || self == .systemView || self == .sequence }
}

public struct SchemaInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let characterSet: String?
    public let collation: String?

    public init(name: String, characterSet: String? = nil, collation: String? = nil) {
        self.name = name
        self.characterSet = characterSet
        self.collation = collation
    }

    public var id: String { name }
    public var isSystem: Bool { SchemaInfo.systemSchemas.contains(name.lowercased()) }

    public static let systemSchemas: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]
}

/// One table, view, routine, trigger or event.
public struct DatabaseObject: Sendable, Hashable, Identifiable {
    public let schema: String
    public let name: String
    public let kind: ObjectKind
    public var engine: String?
    public var rowFormat: String?
    /// Estimated rows (InnoDB statistics are approximate).
    public var rowCount: Int64?
    public var dataLength: Int64?
    public var indexLength: Int64?
    public var dataFree: Int64?
    public var autoIncrement: UInt64?
    public var createTime: String?
    public var updateTime: String?
    public var collation: String?
    public var createOptions: String?
    public var comment: String?
    /// Routines: return type of a function; triggers: table; events: schedule.
    public var detail: String?
    public var definer: String?
    /// Triggers: `BEFORE INSERT`, events: `ENABLED`/`DISABLED`, routines: `DETERMINISTIC`/`SECURITY INVOKER`.
    public var status: String?

    public init(schema: String, name: String, kind: ObjectKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(schema)\u{1F}\(kind.rawValue)\u{1F}\(name)" }
    public var qualifiedName: String { SQLText.qualified(schema, name) }
    public var isPartitioned: Bool { createOptions?.lowercased().contains("partitioned") == true }
    public var totalLength: Int64? {
        guard dataLength != nil || indexLength != nil else { return nil }
        return (dataLength ?? 0).addingReportingOverflow(indexLength ?? 0).partialValue
    }
}

/// Objects of one schema plus the groups that could not be read (privileges, old versions).
public struct SchemaObjects: Sendable {
    public var objects: [DatabaseObject]
    /// Group name → reason (e.g. "Events" → "Access denied").
    public var unavailable: [String: String]

    public init(objects: [DatabaseObject] = [], unavailable: [String: String] = [:]) {
        self.objects = objects
        self.unavailable = unavailable
    }

    /// Base tables grouped by engine (sorted engine names; tables sorted by name).
    public var tablesByEngine: [(engine: String, tables: [DatabaseObject])] {
        let tables = objects.filter { $0.kind == .table }
        let grouped = Dictionary(grouping: tables) { $0.engine?.nilIfBlank ?? "Unknown" }
        return grouped.keys.sorted { lhs, rhs in
            if lhs.caseInsensitiveCompare("InnoDB") == .orderedSame { return true }
            if rhs.caseInsensitiveCompare("InnoDB") == .orderedSame { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.map { ($0, (grouped[$0] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    public func objects(of kind: ObjectKind) -> [DatabaseObject] {
        objects.filter { $0.kind == kind }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct ColumnInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let ordinal: Int
    public let dataType: String
    public let columnType: String
    public let isNullable: Bool
    /// `PRI`, `UNI`, `MUL` or empty.
    public let columnKey: String
    public let defaultValue: String?
    public let extra: String
    public let characterSet: String?
    public let collation: String?
    public let comment: String?
    public let generationExpression: String?

    public init(name: String, ordinal: Int, dataType: String, columnType: String, isNullable: Bool, columnKey: String = "",
                defaultValue: String? = nil, extra: String = "", characterSet: String? = nil, collation: String? = nil,
                comment: String? = nil, generationExpression: String? = nil) {
        self.name = name
        self.ordinal = ordinal
        self.dataType = dataType
        self.columnType = columnType
        self.isNullable = isNullable
        self.columnKey = columnKey
        self.defaultValue = defaultValue
        self.extra = extra
        self.characterSet = characterSet
        self.collation = collation
        self.comment = comment
        self.generationExpression = generationExpression
    }

    public var id: String { name }
    public var isPrimaryKey: Bool { columnKey.uppercased() == "PRI" }
    public var isKey: Bool { !columnKey.isEmpty }
    public var isAutoIncrement: Bool { extra.lowercased().contains("auto_increment") }
    public var isUnsigned: Bool { columnType.lowercased().contains("unsigned") }
    public var isGenerated: Bool { extra.lowercased().contains("generated") || generationExpression?.isEmpty == false }
}

public struct IndexColumn: Sendable, Hashable {
    public let name: String?
    /// Functional key parts (MySQL 8.0.13+).
    public let expression: String?
    public let subPart: Int?
    public let cardinality: Int64?
    public let isDescending: Bool

    public init(name: String?, expression: String? = nil, subPart: Int? = nil, cardinality: Int64? = nil, isDescending: Bool = false) {
        self.name = name
        self.expression = expression
        self.subPart = subPart
        self.cardinality = cardinality
        self.isDescending = isDescending
    }

    public var displayName: String {
        var text = name ?? "(\(expression ?? "?"))"
        if let subPart { text += "(\(subPart))" }
        if isDescending { text += " DESC" }
        return text
    }
}

public struct IndexInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let isUnique: Bool
    /// BTREE, HASH, FULLTEXT, SPATIAL, …
    public let type: String
    public let columns: [IndexColumn]
    public let isVisible: Bool
    public let comment: String?

    public init(name: String, isUnique: Bool, type: String, columns: [IndexColumn], isVisible: Bool = true, comment: String? = nil) {
        self.name = name
        self.isUnique = isUnique
        self.type = type
        self.columns = columns
        self.isVisible = isVisible
        self.comment = comment
    }

    public var id: String { name }
    public var isPrimary: Bool { name == "PRIMARY" }
    /// Cardinality of the whole index (its last column's prefix cardinality).
    public var cardinality: Int64? { columns.last?.cardinality }
}

public struct ForeignKeyInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let columns: [String]
    public let referencedSchema: String
    public let referencedTable: String
    public let referencedColumns: [String]
    public let onUpdate: String
    public let onDelete: String

    public init(name: String, columns: [String], referencedSchema: String, referencedTable: String, referencedColumns: [String],
                onUpdate: String = "RESTRICT", onDelete: String = "RESTRICT") {
        self.name = name
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    public var id: String { name }
}

public struct PartitionInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let subpartition: String?
    public let ordinal: Int
    public let method: String?
    public let expression: String?
    /// `VALUES LESS THAN` / `VALUES IN` description.
    public let bound: String?
    public let rowCount: Int64?
    public let dataLength: Int64?
    public let indexLength: Int64?
    public let comment: String?

    public init(name: String, subpartition: String? = nil, ordinal: Int, method: String? = nil, expression: String? = nil, bound: String? = nil,
                rowCount: Int64? = nil, dataLength: Int64? = nil, indexLength: Int64? = nil, comment: String? = nil) {
        self.name = name
        self.subpartition = subpartition
        self.ordinal = ordinal
        self.method = method
        self.expression = expression
        self.bound = bound
        self.rowCount = rowCount
        self.dataLength = dataLength
        self.indexLength = indexLength
        self.comment = comment
    }

    public var id: String { subpartition.map { "\(name).\($0)" } ?? name }
}

/// Everything shown on a table's detail page.
public struct TableDetail: Sendable {
    public var object: DatabaseObject
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public var foreignKeys: [ForeignKeyInfo]
    /// Foreign keys of other tables that point at this one.
    public var referencedBy: [ForeignKeyInfo]
    public var partitions: [PartitionInfo]
    public var ddl: String?
    /// Section → reason it could not be loaded.
    public var unavailable: [String: String]

    public init(object: DatabaseObject, columns: [ColumnInfo] = [], indexes: [IndexInfo] = [], foreignKeys: [ForeignKeyInfo] = [],
                referencedBy: [ForeignKeyInfo] = [], partitions: [PartitionInfo] = [], ddl: String? = nil, unavailable: [String: String] = [:]) {
        self.object = object
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.referencedBy = referencedBy
        self.partitions = partitions
        self.ddl = ddl
        self.unavailable = unavailable
    }
}

/// SQL stored in the server: a view, routine, trigger or event body.
public struct StoredDefinition: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case view
        case routine
        case trigger
        case event
    }

    public let kind: Kind
    public let name: String
    public let sql: String

    public init(kind: Kind, name: String, sql: String) {
        self.kind = kind
        self.name = name
        self.sql = sql
    }
}
