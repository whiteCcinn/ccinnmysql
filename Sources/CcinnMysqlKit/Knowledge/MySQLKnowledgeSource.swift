import Foundation
import MySQLKit

/// Reads schema facts for a knowledge build from a server: five metadata queries for the whole schema (objects,
/// columns, indexes, foreign keys, stored definitions), whatever the number of tables. Metadata only, no rows.
public struct MySQLKnowledgeSource: KnowledgeSchemaSource {
    public let client: MySQLClient

    public init(client: MySQLClient) {
        self.client = client
    }

    public func facts(database: String) async throws -> SchemaFacts {
        let schemas = try await client.schemas()
        guard schemas.contains(where: { $0.name == database }) else {
            let names = schemas.filter { !$0.isSystem }.prefix(30).map(\.name).joined(separator: ", ")
            throw KnowledgeError("No database “\(database)” on this server.\(names.isEmpty ? "" : " Databases: \(names).")")
        }
        async let objects = client.objects(schema: database)
        async let columns = client.columnsByTable(schema: database)
        async let indexes = client.indexesByTable(schema: database)
        async let foreignKeys = client.foreignKeysByTable(schema: database)
        async let stored = client.storedDefinitions(schema: database)
        let listing = try await objects
        let columnsByTable = try await columns
        let indexesByTable = try await indexes
        let keysByTable = try await foreignKeys
        let definitions = try await stored

        var warnings = listing.unavailable.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        warnings += definitions.unavailable.sorted { $0.key < $1.key }.map { "\($0.key) definitions: \($0.value)" }
        let tables = listing.objects.filter { $0.kind == .table || $0.kind == .view }.compactMap { object -> KnowledgeTable? in
            guard let columns = columnsByTable[object.name], !columns.isEmpty else { return nil }
            return Self.table(object, columns: columns, indexes: indexesByTable[object.name] ?? [], foreignKeys: keysByTable[object.name] ?? [])
        }
        let skipped = listing.objects.filter { ($0.kind == .table || $0.kind == .view) && columnsByTable[$0.name]?.isEmpty != false }.count
        if skipped > 0 { warnings.append("\(skipped) table(s) or view(s) without readable columns were skipped") }
        return SchemaFacts(tables: tables, definitions: definitions.definitions, serverVersion: client.serverInfo.productDescription,
                           warnings: warnings)
    }

    static func table(_ object: DatabaseObject, columns: [ColumnInfo], indexes: [IndexInfo], foreignKeys: [ForeignKeyInfo]) -> KnowledgeTable {
        /// Indexes on plain columns only (functional key parts have no column name).
        func names(_ index: IndexInfo) -> [String]? {
            let names = index.columns.compactMap(\.name)
            return names.count == index.columns.count && !names.isEmpty ? names : nil
        }
        let primary = indexes.first(where: \.isPrimary).flatMap(names) ?? []
        let unique = indexes.filter { $0.isUnique && !$0.isPrimary }.compactMap(names)
        let other = indexes.filter { !$0.isUnique }.compactMap(names)
        return KnowledgeTable(
            name: object.name, kind: object.kind == .view ? .view : .table, engine: object.engine, rowsEstimate: object.rowCount,
            comment: object.comment,
            columns: columns.map { KnowledgeColumn(name: $0.name, type: $0.columnType, dataType: $0.dataType, nullable: $0.isNullable, comment: $0.comment) },
            primaryKey: primary, uniqueKeys: unique, indexes: other,
            foreignKeys: foreignKeys.map { key in
                DeclaredForeignKey(name: key.name, columns: key.columns, referencedDatabase: key.referencedSchema, referencedTable: key.referencedTable,
                                   referencedColumns: key.referencedColumns)
            })
    }
}
