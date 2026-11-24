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
              score DOUBLE NOT NULL, body TEXT NOT NULL, KEY (grp), KEY (name))
            """)
        // body: 1,100 equal characters, then the part that orders the rows; the server sorts by the first 1,024 bytes.
        let rows = (1...Self.rowCount).map { id in
            "(\(id), \(id % 7), 'n\(id % 13)', \(id % 5 == 0 ? "NULL" : "'c\(id % 3)'"), \(Double(id % 11) / 3), "
                + "CONCAT(REPEAT('x', 1100), '\(id % 17)'))"
        }
        for batch in stride(from: 0, to: rows.count, by: 200) {
            _ = try await client.query("INSERT INTO \(Self.table) VALUES " + rows[batch..<min(batch + 200, rows.count)].joined(separator: ","))
        }
        // The same rows without a key: a copy, and a view (every view is keyless).
        // Not CREATE TABLE … SELECT: servers that enforce GTID consistency refuse it.
        _ = try await client.query("""
            CREATE TABLE `\(Self.database)`.`k` (id INT NOT NULL, grp INT NOT NULL, name VARCHAR(20) NOT NULL, city VARCHAR(20) NULL,
              score DOUBLE NOT NULL)
            """)
        _ = try await client.query("INSERT INTO `\(Self.database)`.`k` SELECT id, grp, name, city, score FROM \(Self.table)")
        _ = try await client.query("CREATE VIEW `\(Self.database)`.`v` AS SELECT id, grp, name FROM \(Self.table)")
    }

    /// Reads every page forward, then back to the first; returns the ids forward, the pages, and the pages read back.
    private func walk(_ client: MySQLClient, _ pager: inout TablePager, sort: TablePager.Sort?, maxBytes: Int = 64 * 1024 * 1024)
        async throws -> (forward: [String], pages: [[String]], backward: [[String]]) {
        var forward: [String] = []
        var pages: [[String]] = []
        var request: TablePager.Request? = pager.first(sortedBy: sort)
        while let current = request {
            let result = try await client.previewPage(current.sql, maxRows: pager.pageSize + 1, maxBytes: maxBytes)
            let page = pager.apply(current, columns: result.columns, rows: result.rows, truncated: result.isTruncated).compactMap { $0.first ?? nil }
            pages.append(page)
            forward += page
            request = pager.next()
        }
        var backward: [[String]] = []
        request = pager.previous()
        while let current = request {
            let result = try await client.previewPage(current.sql, maxRows: pager.pageSize + 1, maxBytes: maxBytes)
            backward.insert(pager.apply(current, columns: result.columns, rows: result.rows, truncated: result.isTruncated)
                .compactMap { $0.first ?? nil }, at: 0)
            request = pager.previous()
        }
        return (forward, pages, backward)
    }

    private func truth(_ client: MySQLClient, _ table: String, order: [String], ascending: Bool) async throws -> [String] {
        let orderBy = order.isEmpty ? "" : " ORDER BY " + order.map { SQLText.quoteIdentifier($0) + (ascending ? " ASC" : " DESC") }.joined(separator: ", ")
        return ids(try await client.previewPage("SELECT * FROM \(table)\(orderBy)", maxRows: 10_000))
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

    // Review #3, #5, #2: a TEXT sort tied past max_sort_length, keyless tables and views sorted by a tied column, and
    // pages cut short by the byte limit still read every row exactly once.
    @Test(arguments: IntegrationEnvironment.targets)
    func hardOrdersReadEveryRowOnce(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { _ = try? await client.query("DROP DATABASE IF EXISTS \(Self.database)"); await client.close() } }
        try await prepare(client)

        var text = TablePager(table: Self.table, keyColumns: ["id"], pageSize: 100)
        let textSort = TablePager.Sort(column: "body", ascending: true)
        let textWalk = try await walk(client, &text, sort: textSort)
        #expect(!text.seeksByKey)
        #expect(textWalk.forward == (try await truth(client, Self.table, order: ["body", "id"], ascending: true)), "TEXT sort")
        #expect(Set(textWalk.forward).count == Self.rowCount)

        for name in ["k", "v"] {
            let table = "`\(Self.database)`.`\(name)`"
            let columns = try await client.columns(schema: Self.database, table: name)
            let tieBreakers = columns.filter { TablePager.breaksTies(dataType: $0.dataType) }.map(\.name)
            var pager = TablePager(table: table, keyColumns: [], tieBreakers: tieBreakers, pageSize: 200)
            let sort = TablePager.Sort(column: "grp", ascending: false)
            let walked = try await walk(client, &pager, sort: sort)
            let expected = try await truth(client, table, order: TablePager.orderColumns(sort: sort, key: [], tieBreakers: tieBreakers),
                                           ascending: false)
            #expect(walked.forward == expected, "\(name) by grp")
            #expect(Set(walked.forward).count == Self.rowCount, "\(name): every row once")
            #expect(walked.backward == Array(walked.pages.dropLast()), "\(name): back")
        }

        // About 1.1 KB a row, a 40 KB limit: every page stops after some 35 rows.
        var cut = TablePager(table: Self.table, keyColumns: ["id"], pageSize: 100)
        let cutWalk = try await walk(client, &cut, sort: nil, maxBytes: 40 * 1024)
        #expect(cutWalk.pages.count > 20)
        #expect(cutWalk.forward == (try await truth(client, Self.table, order: ["id"], ascending: true)), "pages cut by the byte limit")
        #expect(cut.firstRow == 1)
    }

    // Review #4: snowflake-sized DECIMAL ids, 19 digits apart by 1. MySQL compares a quoted number with a DECIMAL as
    // a double, so a quoted seek would skip the ids that round alike.
    @Test(arguments: IntegrationEnvironment.targets)
    func longDecimalKeysPageExactly(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { _ = try? await client.query("DROP DATABASE IF EXISTS \(Self.database)"); await client.close() } }
        _ = try await client.query("DROP DATABASE IF EXISTS \(Self.database)")
        _ = try await client.query("CREATE DATABASE \(Self.database)")
        let table = "`\(Self.database)`.`d`"
        _ = try await client.query("CREATE TABLE \(table) (id DECIMAL(20,0) PRIMARY KEY, note VARCHAR(10) NOT NULL)")
        let values = (0..<500).map { "(\(1_500_000_000_000_000_000 as Int64 + Int64($0)), 'n')" }.joined(separator: ",")
        _ = try await client.query("INSERT INTO \(table) VALUES \(values)")
        var pager = TablePager(table: table, keyColumns: ["id"], pageSize: 100)
        let walked = try await walk(client, &pager, sort: nil)
        #expect(pager.seeksByKey)
        #expect(walked.forward == (try await truth(client, table, order: ["id"], ascending: true)))
        #expect(walked.backward == Array(walked.pages.dropLast()))
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func aFilteredWalkReadsEveryMatchingRowOnce(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { _ = try? await client.query("DROP DATABASE IF EXISTS \(Self.database)"); await client.close() } }
        try await prepare(client)
        let filter = try #require(try TableFilter.parse("WHERE grp IN (1, 3) OR name = 'n4' -- a few groups").get())
        var pager = TablePager(table: Self.table, keyColumns: ["id"], filter: filter, pageSize: 50)
        let sort = TablePager.Sort(column: "name", ascending: false)
        let walked = try await walk(client, &pager, sort: sort)
        #expect(pager.seeksByKey)
        let expected = ids(try await client.previewPage("SELECT * FROM \(Self.table) WHERE \(filter.sql) ORDER BY `name` DESC, `id` DESC",
                                                       maxRows: 10_000))
        #expect(!expected.isEmpty && expected.count < Self.rowCount)
        #expect(walked.forward == expected)
        #expect(walked.backward == Array(walked.pages.dropLast()))
    }
}
