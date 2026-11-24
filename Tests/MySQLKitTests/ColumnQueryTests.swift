import Foundation
import Testing
@testable import MySQLKit

/// `columnsByTable` asked for more tables than one IN list holds (fix-completion-accuracy, review #6).
@Suite("Column queries")
struct ColumnQueryTests {
    @Test func everyTableAskedForIsQueriedInBatches() {
        let tables = (0..<450).map { "t\($0)" }
        let queries = MySQLClient.columnQueries(schema: "shop", tables: tables)
        #expect(queries.count == 3)
        for query in queries { #expect(query.components(separatedBy: "'t").count - 1 <= MySQLClient.columnQueryBatch) }
        let named = queries.flatMap { query in tables.filter { query.contains("'\($0)'") } }
        #expect(Set(named) == Set(tables), "no table is left out")
    }

    @Test func aWholeSchemaIsOneQueryAndNoTablesNone() {
        #expect(MySQLClient.columnQueries(schema: "shop", tables: nil).count == 1)
        #expect(MySQLClient.columnQueries(schema: "shop", tables: []).isEmpty)
    }
}
