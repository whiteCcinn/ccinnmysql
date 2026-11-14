import Foundation
import MySQLKit

/// How close an AUTO_INCREMENT column is to its type's maximum.
public struct AutoIncrementHeadroom: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case ok, warning, critical
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let column: String
    public let columnType: String
    /// Highest value already handed out (next value − 1).
    public let current: UInt64
    public let maximum: UInt64

    public var usedFraction: Double { maximum == 0 ? 1 : min(1, Double(current) / Double(maximum)) }
    public var remaining: UInt64 { maximum > current ? maximum - current : 0 }

    public var severity: Severity {
        switch usedFraction {
        case 0.9...: .critical
        case 0.75...: .warning
        default: .ok
        }
    }
}

public struct TableFinding: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case missingPrimaryKey, redundantIndex, duplicateIndex, autoIncrementHeadroom, largeFreeSpace, nonTransactionalEngine, invisibleIndex
    }

    public enum Severity: Int, Sendable, Comparable {
        case info, warning, critical
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let kind: Kind
    public let severity: Severity
    public let title: String
    public let detail: String

    public var id: String { "\(kind.rawValue):\(title)" }
}

/// Pure analysis of table metadata (unit-tested; no I/O).
public enum TableInsights {
    /// Maximum value of an integer column type (`tinyint`, `int unsigned`, …); `nil` for non-integer types.
    public static func maximumValue(dataType: String, unsigned: Bool) -> UInt64? {
        switch dataType.lowercased() {
        case "tinyint": unsigned ? 255 : 127
        case "smallint": unsigned ? 65_535 : 32_767
        case "mediumint": unsigned ? 16_777_215 : 8_388_607
        case "int", "integer": unsigned ? 4_294_967_295 : 2_147_483_647
        case "bigint": unsigned ? UInt64.max : UInt64(Int64.max)
        default: nil
        }
    }

    /// Headroom of the table's AUTO_INCREMENT column; `nextValue` is `information_schema.TABLES.AUTO_INCREMENT`.
    public static func autoIncrementHeadroom(columns: [ColumnInfo], nextValue: UInt64?) -> AutoIncrementHeadroom? {
        guard let column = columns.first(where: \.isAutoIncrement),
              let maximum = maximumValue(dataType: column.dataType, unsigned: column.isUnsigned) else { return nil }
        let next = nextValue ?? 1
        let current = next > 0 ? next - 1 : 0
        return AutoIncrementHeadroom(column: column.name, columnType: column.columnType, current: min(current, maximum), maximum: maximum)
    }

    /// Indexes whose columns are a left prefix of (or equal to) another index of the same type.
    /// A unique index is never redundant to a non-unique one (it enforces a constraint).
    public static func redundantIndexes(_ indexes: [IndexInfo]) -> [TableFinding] {
        var findings: [TableFinding] = []
        let candidates = indexes.filter { $0.columns.allSatisfy { $0.name != nil && $0.expression == nil } }
        for index in candidates where !index.isPrimary {
            let columns = index.columns.map(signature)
            for other in candidates where other.name != index.name && other.type.uppercased() == index.type.uppercased() {
                let otherColumns = other.columns.map(signature)
                guard columns.count <= otherColumns.count, Array(otherColumns.prefix(columns.count)) == columns else { continue }
                if index.isUnique, !other.isUnique { continue }
                if columns.count == otherColumns.count {
                    // Exact duplicates: report only one of the pair (keep PRIMARY/unique, else the first name).
                    if other.isPrimary || (other.isUnique && !index.isUnique) || (other.isUnique == index.isUnique && other.name < index.name) {
                        findings.append(TableFinding(kind: .duplicateIndex, severity: .warning, title: "Duplicate index \(index.name)",
                                                     detail: "\(index.name) has the same columns as \(other.name); drop one of them to save space and write time."))
                        break
                    }
                    continue
                }
                if index.isUnique, other.isUnique { continue }
                findings.append(TableFinding(kind: .redundantIndex, severity: .warning, title: "Redundant index \(index.name)",
                                             detail: "Its columns (\(index.columns.map(\.displayName).joined(separator: ", "))) are a left prefix of \(other.name); queries can use \(other.name) instead."))
                break
            }
        }
        return findings
    }

    private static func signature(_ column: IndexColumn) -> String {
        "\((column.name ?? "").lowercased())(\(column.subPart.map(String.init) ?? ""))"
    }

    /// Everything worth pointing out about a table, most severe first.
    public static func findings(for detail: TableDetail) -> [TableFinding] {
        var findings: [TableFinding] = []
        let object = detail.object
        let engine = object.engine?.lowercased() ?? ""
        if object.kind == .table {
            let hasPrimary = detail.indexes.contains(where: \.isPrimary)
            let columnsByName = Dictionary(detail.columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let hasNotNullUnique = detail.indexes.contains { index in
                index.isUnique && index.columns.allSatisfy { column in column.name.flatMap { columnsByName[$0.lowercased()] }.map { !$0.isNullable } ?? false }
            }
            if !hasPrimary, !detail.columns.isEmpty {
                findings.append(TableFinding(kind: .missingPrimaryKey, severity: engine == "innodb" && !hasNotNullUnique ? .critical : .warning,
                                             title: "No primary key",
                                             detail: "InnoDB clusters rows by the primary key; without one it uses a hidden 6-byte row id, row-based replication must scan for every changed row, and rows cannot be edited safely."))
            }
            if engine == "myisam" || engine == "memory" || engine == "archive" || engine == "csv" {
                findings.append(TableFinding(kind: .nonTransactionalEngine, severity: .info, title: "\(object.engine ?? engine) engine",
                                             detail: "This engine is not transactional and does not survive crashes like InnoDB; ROLLBACK cannot undo changes."))
            }
        }
        findings += redundantIndexes(detail.indexes)
        for index in detail.indexes where !index.isVisible {
            findings.append(TableFinding(kind: .invisibleIndex, severity: .info, title: "Invisible index \(index.name)",
                                         detail: "The optimizer ignores this index but it is still maintained on every write."))
        }
        if let headroom = autoIncrementHeadroom(columns: detail.columns, nextValue: object.autoIncrement), headroom.severity > .ok {
            let percent = Int((headroom.usedFraction * 100).rounded(.down))
            findings.append(TableFinding(kind: .autoIncrementHeadroom, severity: headroom.severity == .critical ? .critical : .warning,
                                         title: "AUTO_INCREMENT \(percent)% used",
                                         detail: "\(headroom.column) (\(headroom.columnType)) is at \(headroom.current) of \(headroom.maximum); \(headroom.remaining) values remain. Widen the column (e.g. BIGINT UNSIGNED) before inserts fail."))
        }
        if let free = object.dataFree, free > 64 * 1024 * 1024, let total = object.totalLength, total > 0, Double(free) / Double(total) > 0.2 {
            findings.append(TableFinding(kind: .largeFreeSpace, severity: .info, title: "\(ByteFormatter.string(free)) free inside the table",
                                         detail: "More than 20% of the table's space is unused (deleted rows). OPTIMIZE TABLE rebuilds it, but locks or copies the table."))
        }
        return findings.sorted { $0.severity > $1.severity }
    }
}

/// Compact byte counts (`1.5 GB`), never trapping on huge values.
public enum ByteFormatter {
    public static func string(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes)
        var unit = 0
        while abs(value) >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }
}
