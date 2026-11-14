import Foundation
import MySQLKit
import MySQLWire

/// Safe inline row editing for single-table results (design D11).
public struct RowEditPlan: Sendable, Equatable {
    public let schema: String
    public let table: String
    /// Result column index → base column name, for every column that maps to the table.
    public let columnNames: [Int: String]
    /// Result column indices that identify a row (the primary key or a NOT NULL unique key).
    public let keyColumns: [Int]
    public let editableColumns: Set<Int>

    public var qualifiedTable: String { SQLText.qualified(schema, table) }
}

public enum RowEditEligibility: Sendable, Equatable {
    case editable(RowEditPlan)
    case readOnly(String)

    public var plan: RowEditPlan? {
        if case let .editable(plan) = self { return plan }
        return nil
    }
}

public enum RowEditor {
    /// Binary collation id: such values cannot round-trip through the text protocol as UTF-8.
    static let binaryCharacterSet: UInt16 = 63

    /// Decides whether a result can be edited. `keys` are the table's identifying keys from metadata, in
    /// preference order (primary key first, then NOT NULL unique keys); `isBaseTable` comes from the schema.
    public static func eligibility(columns: [ColumnDefinition], keys: [[String]], isBaseTable: Bool) -> RowEditEligibility {
        let mapped = columns.enumerated().filter { !$0.element.originalTable.isEmpty && !$0.element.originalName.isEmpty }
        guard let first = mapped.first?.element else { return .readOnly("The result has no columns from a table.") }
        let schema = first.schema
        let table = first.originalTable
        let alias = first.table
        guard mapped.allSatisfy({ $0.element.originalTable == table && $0.element.schema == schema }) else {
            return .readOnly("Cells are read-only: the result combines several tables.")
        }
        // A self-join reports the same base table under several aliases; a key from one alias must never
        // identify a row of another.
        guard mapped.allSatisfy({ $0.element.table == alias }) else {
            return .readOnly("Cells are read-only: the result uses \(table) more than once (a self-join).")
        }
        guard !schema.isEmpty else { return .readOnly("Cells are read-only: the server did not report the table's schema.") }
        guard isBaseTable else { return .readOnly("Cells are read-only: \(table) is not a base table.") }
        var names: [Int: String] = [:]
        for (index, column) in mapped { names[index] = column.originalName }
        guard Set(names.values.map { $0.lowercased() }).count == names.count else {
            return .readOnly("Cells are read-only: a column appears more than once.")
        }
        let byName = Dictionary(names.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { first, _ in first })
        for key in keys where !key.isEmpty {
            let indices = key.compactMap { byName[$0.lowercased()] }
            guard indices.count == key.count else { continue }
            if let bad = indices.first(where: { !isExactKeyType(columns[$0]) }) {
                return .readOnly("Cells are read-only: key column \(columns[bad].name) cannot be matched exactly (binary or floating point).")
            }
            let editable = Set(names.keys.filter { isEditableType(columns[$0]) })
            return .editable(RowEditPlan(schema: schema, table: table, columnNames: names, keyColumns: indices, editableColumns: editable))
        }
        if keys.isEmpty { return .readOnly("Cells are read-only: \(table) has no primary key or NOT NULL unique key.") }
        return .readOnly("Cells are read-only: include the primary key columns (\(keys.first?.joined(separator: ", ") ?? "")) in the result to edit rows.")
    }

    static func isBinary(_ column: ColumnDefinition) -> Bool {
        column.characterSet == binaryCharacterSet && (column.type.kind == .text || column.type.kind == .binary || column.type == .bit)
    }

    static func isExactKeyType(_ column: ColumnDefinition) -> Bool {
        !isBinary(column) && column.type.kind != .float && column.type.kind != .json && column.type != .bit
    }

    static func isEditableType(_ column: ColumnDefinition) -> Bool {
        !isBinary(column) && column.type != .geometry && column.type != .bit
    }

    /// `UPDATE … SET … WHERE <key = old values> LIMIT 1`. `changes` maps result column → new value (nil = NULL).
    public static func updateStatement(plan: RowEditPlan, row: [String?], changes: [Int: String?], noBackslashEscapes: Bool = false) throws -> String {
        let assignments = try changes.keys.sorted().map { index -> String in
            guard plan.editableColumns.contains(index), let name = plan.columnNames[index] else {
                throw MySQLError(.invalidArgument, "Column \(index + 1) cannot be edited")
            }
            let value = changes[index] ?? nil
            return "\(SQLText.quoteIdentifier(name)) = \(value.map { SQLText.literal($0, noBackslashEscapes: noBackslashEscapes) } ?? "NULL")"
        }
        guard !assignments.isEmpty else { throw MySQLError(.invalidArgument, "Nothing to update") }
        let conditions = try plan.keyColumns.map { index -> String in
            guard let name = plan.columnNames[index], index < row.count else { throw MySQLError(.invalidArgument, "Key column missing from the row") }
            guard let value = row[index] else { throw MySQLError(.invalidArgument, "Key column \(name) is NULL; the row cannot be identified") }
            return "\(SQLText.quoteIdentifier(name)) = \(SQLText.literal(value, noBackslashEscapes: noBackslashEscapes))"
        }
        return "UPDATE \(plan.qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(conditions.joined(separator: " AND ")) LIMIT 1"
    }

    /// Rows matched by an UPDATE, from its OK packet info (`Rows matched: 1  Changed: 0  Warnings: 0`).
    public static func matchedRows(info: String, affectedRows: UInt64) -> UInt64 {
        if let match = info.firstMatch(of: /Rows matched:\s*(\d+)/), let value = UInt64(match.output.1.prefix(19)) { return value }
        return affectedRows
    }
}

extension MySQLClient {
    /// Runs a generated row UPDATE in a transaction on one pooled connection and commits only when exactly one
    /// row matched; otherwise rolls back and throws.
    public func applyRowEdit(_ statement: String) async throws {
        try await withConnection { connection in
            _ = try await connection.execute("START TRANSACTION")
            do {
                let result = try await connection.execute(statement)
                let matched = RowEditor.matchedRows(info: result.info, affectedRows: result.affectedRows)
                guard matched == 1 else {
                    _ = try? await connection.execute("ROLLBACK")
                    throw MySQLError(.server, matched == 0
                        ? "No row matched: it was changed or deleted by someone else. Nothing was saved; reload the result."
                        : "\(matched) rows matched the key; nothing was saved.")
                }
                _ = try await connection.execute("COMMIT")
            } catch {
                _ = try? await connection.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// True for `BASE TABLE` (not a view) according to `information_schema.TABLES`.
    public func isBaseTable(schema: String, table: String) async throws -> Bool {
        let type = try await execute("SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(SQLText.literal(schema)) AND TABLE_NAME = \(SQLText.literal(table))").scalar
        return type?.uppercased() == "BASE TABLE"
    }

    /// Identifying keys of a table for row editing: the primary key, then NOT NULL unique keys.
    public func identifyingKeys(schema: String, table: String) async throws -> [[String]] {
        let indexes = try await indexes(schema: schema, table: table)
        let columns = try await columns(schema: schema, table: table)
        let nullable = Set(columns.filter(\.isNullable).map { $0.name.lowercased() })
        let usable = indexes.filter { index in
            index.isUnique && index.columns.allSatisfy { column in column.name.map { !nullable.contains($0.lowercased()) } ?? false }
        }
        return usable.sorted { $0.isPrimary && !$1.isPrimary }.map { $0.columns.compactMap(\.name) }
    }
}
