import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// The Data tab's pages against a real server: forward to the end and back to the start, by key or by offset, give
/// exactly the rows of one full ORDER BY read (add-data-paging-and-sort).
@Suite("Table pager integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct TablePagerIntegrationTests {
    static let database = "ccinn_it_pager"
    static let table = "`ccinn_it_pager`.`t`"
    static let rowCount = 1_037

    private func prepare(_ client: MySQLClient) async throws {
        _ = try await client.query("DROP DATABASE IF EXISTS \(Self.database)")
        _ = try await client.query("CREATE DATABASE \(Self.database)")
        _ = try await client.query("""
            CREATE TABLE \(Self.table) (id INT PRIMARY KEY, grp INT NOT NULL, name VARCHAR(20) NOT NULL, city VARCHAR(20) NULL,
              score DOUBLE NOT NULL, KEY (grp), KEY (name))
            """)
        let rows = (1...Self.rowCount).map { id in
            "(\(id), \(id % 7), 'n\(id % 13)', \(id % 5 == 0 ? "NULL" : "'c\(id % 3)'"), \(Double(id % 11) / 3))"
        }
        for batch in stride(from: 0, to: rows.count, by: 200) {
            _ = try await client.query("INSERT INTO \(Self.table) VALUES " + rows[batch..<min(batch + 200, rows.count)].joined(separator: ","))
        }
    }

    private func ids(_ result: ResultSet) -> [String] { result.rows.compactMap { $0.first ?? nil } }

    @Test(arguments: IntegrationEnvironment.targets)
    func pagesForwardAndBackMatchOneFullRead(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { _ = try? await client.query("DROP DATABASE IF EXISTS \(Self.database)"); await client.close() } }
        try await prepare(client)
        let key = try await client.identifyingKeys(schema: Self.database, table: "t").first ?? []
        #expect(key == ["id"])
        let sorts: [(TablePager.Sort?, Bool)] = [
            (nil, true), (.init(column: "grp", ascending: true), true), (.init(column: "grp", ascending: false), true),
            (.init(column: "name", ascending: false), true), (.init(column: "city", ascending: true), false),
            (.init(column: "score", ascending: false), false),
        ]
        for (sort, seeksByKey) in sorts {
            let label = sort.map { "\($0.column) \($0.ascending ? "ASC" : "DESC")" } ?? "table order"
            var pager = TablePager(table: Self.table, keyColumns: key, pageSize: 100)
            let order = TablePager.orderColumns(sort: sort, key: key)
                .map { SQLText.quoteIdentifier($0) + ((sort?.ascending ?? true) ? " ASC" : " DESC") }.joined(separator: ", ")
            let truth = ids(try await client.previewPage("SELECT * FROM \(Self.table) ORDER BY \(order)", maxRows: 10_000))
            #expect(truth.count == Self.rowCount)

            var forward: [String] = []
            var request: TablePager.Request? = pager.first(sortedBy: sort)
            var pages: [[String]] = []
            while let current = request {
                let result = try await client.previewPage(current.sql, maxRows: pager.pageSize + 1)
                let page = pager.apply(current, columns: result.columns, rows: result.rows).compactMap { $0.first ?? nil }
                pages.append(page)
                forward += page
                #expect(pager.seeksByKey == seeksByKey, "\(label)")
                request = pager.next()
            }
            #expect(forward == truth, "\(label): forward")
            #expect(pager.firstRow == (pages.count - 1) * 100 + 1)

            var backward: [[String]] = []
            request = pager.previous()
            while let current = request {
                let result = try await client.previewPage(current.sql, maxRows: pager.pageSize + 1)
                backward.insert(pager.apply(current, columns: result.columns, rows: result.rows).compactMap { $0.first ?? nil }, at: 0)
                request = pager.previous()
            }
            #expect(backward == Array(pages.dropLast()), "\(label): back to the first page")
            #expect(pager.firstRow == 1)
            #expect(pager.hasNext)
        }
    }
}
