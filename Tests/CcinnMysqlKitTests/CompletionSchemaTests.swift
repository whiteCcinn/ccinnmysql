import Foundation
import Testing
@testable import CcinnMysqlKit

/// What the completion schema cache drops or reloads (fix-completion-accuracy).
@Suite("Completion schema cache")
struct CompletionSchemaTests {
    @Test func ddlNamesTheCurrentDatabaseAndItsTable() {
        let change = SchemaChange(sql: "ALTER TABLE orders ADD COLUMN paid_at DATETIME", currentDatabase: "shop")
        #expect(change.databases == ["shop"])
        #expect(change.tables.contains(TableKey(database: "shop", table: "orders")))
    }

    @Test func ddlNamesEveryQualifiedDatabase() {
        let create = SchemaChange(sql: "CREATE TABLE ads.clicks (id BIGINT PRIMARY KEY)", currentDatabase: "shop")
        #expect(create.databases == ["shop", "ads"])
        #expect(create.tables.contains(TableKey(database: "ads", table: "clicks")))
        let rename = SchemaChange(sql: "RENAME TABLE orders TO archive.orders_2025", currentDatabase: "shop")
        #expect(rename.databases == ["shop", "archive"])
        #expect(rename.tables.isSuperset(of: [TableKey(database: "shop", table: "orders"), TableKey(database: "archive", table: "orders_2025")]))
    }

    @Test func backQuotedNamesAreUnquoted() {
        let change = SchemaChange(sql: "DROP TABLE `my db`.`order`", currentDatabase: nil)
        #expect(change.databases == ["my db"])
        #expect(change.tables == [TableKey(database: "my db", table: "order")])
    }

    @Test func withoutACurrentDatabaseOnlyQualifiedNamesCount() {
        let change = SchemaChange(sql: "ALTER TABLE orders ADD INDEX (city)", currentDatabase: nil)
        #expect(change.databases.isEmpty)
        #expect(change.tables.isEmpty)
    }

    @Test func databaseDdlChangesTheDatabaseList() {
        for sql in ["CREATE DATABASE crm", "create schema if not exists crm", "DROP DATABASE crm", "DROP SCHEMA IF EXISTS `crm`",
                    "/* setup */ CREATE DATABASE crm"] {
            #expect(SchemaChange(sql: sql, currentDatabase: "shop").changesDatabaseList, "\(sql)")
        }
        for sql in ["CREATE TABLE crm (id INT)", "ALTER TABLE t ADD COLUMN database_name TEXT", "DROP TABLE schema_log"] {
            #expect(!SchemaChange(sql: sql, currentDatabase: "shop").changesDatabaseList, "\(sql)")
        }
    }

    @Test func cachedSchemaAgesAndFailedLoadsBackOff() {
        let now = Date()
        #expect(!SchemaCachePolicy.isStale(loadedAt: now.addingTimeInterval(-60), now: now))
        #expect(SchemaCachePolicy.isStale(loadedAt: now.addingTimeInterval(-SchemaCachePolicy.maxAge - 1), now: now))
        #expect(SchemaCachePolicy.mayRetry(failedAt: nil, now: now))
        #expect(!SchemaCachePolicy.mayRetry(failedAt: now.addingTimeInterval(-5), now: now))
        #expect(SchemaCachePolicy.mayRetry(failedAt: now.addingTimeInterval(-SchemaCachePolicy.failureBackoff - 1), now: now))
    }
}
