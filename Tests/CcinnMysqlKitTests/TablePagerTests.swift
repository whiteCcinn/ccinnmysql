import Foundation
import MySQLKit
import MySQLWire
import Testing
@testable import CcinnMysqlKit

/// The Data tab's pages: server-side sort, forward and back, by key where exact (add-data-paging-and-sort).
@Suite("Table pager")
struct TablePagerTests {
    static let table = "`shop`.`orders`"
    static func column(_ name: String, _ type: ColumnType, notNull: Bool = true, flags: UInt16 = 0, binary: Bool = false) -> ColumnDefinition {
        ColumnDefinition(name: name, type: type, table: "orders", schema: "shop",
                         flags: flags | (notNull ? ColumnDefinition.notNullFlag : 0), characterSet: binary ? 63 : 33)
    }
    static let columns = [column("id", .longLong), column("created_at", .datetime), column("city", .varString, notNull: false),
                          column("total", .double), column("status", .string, flags: ColumnDefinition.enumFlag)]

    /// `count` rows with ids from `firstID`, newest first by created_at.
    static func rows(_ count: Int, firstID: Int = 1, descending: Bool = false) -> [[String?]] {
        (0..<count).map { offset in
            let id = descending ? firstID - offset : firstID + offset
            return [String(id), "2026-11-\(String(format: "%02d", 1 + id % 28)) 10:00:00", id % 3 == 0 ? nil : "KL", "1.5", "paid"]
        }
    }

    @Test func theFirstPageIsInKeyOrderWithOneExtraRow() {
        let pager = TablePager(table: Self.table, keyColumns: ["id"])
        #expect(pager.first(sortedBy: nil).sql == "SELECT * FROM `shop`.`orders` ORDER BY `id` ASC LIMIT 201")
    }

    @Test func aSortColumnIsTiedBrokenByTheKeyInTheSameDirection() {
        let pager = TablePager(table: Self.table, keyColumns: ["id"])
        #expect(pager.first(sortedBy: .init(column: "created_at", ascending: false)).sql
            == "SELECT * FROM `shop`.`orders` ORDER BY `created_at` DESC, `id` DESC LIMIT 201")
        #expect(pager.first(sortedBy: .init(column: "ID", ascending: false)).sql == "SELECT * FROM `shop`.`orders` ORDER BY `ID` DESC LIMIT 201",
                "the key itself is not repeated")
    }

    @Test func theNextPageSeeksPastTheLastRowByKey() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        let sort = TablePager.Sort(column: "created_at", ascending: false)
        let first = pager.first(sortedBy: sort)
        let page = pager.apply(first, columns: Self.columns, rows: Self.rows(201, firstID: 1_000, descending: true))
        #expect(page.count == 200)
        #expect(pager.hasNext)
        #expect(!pager.hasPrevious)
        #expect(pager.firstRow == 1)
        let next = try #require(pager.next())
        // The 200th row has id 801: created_at 2026-11-18.
        #expect(next.sql == "SELECT * FROM `shop`.`orders` WHERE `created_at` < '2026-11-18 10:00:00'"
            + " OR (`created_at` = '2026-11-18 10:00:00' AND `id` < '801') ORDER BY `created_at` DESC, `id` DESC LIMIT 201")
        _ = pager.apply(next, columns: Self.columns, rows: Self.rows(201, firstID: 800, descending: true))
        #expect(pager.firstRow == 201)
        #expect(pager.hasPrevious)
    }

    @Test func thePreviousPageSeeksBackAndReadsInReverse() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201, firstID: 1))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 401))
        #expect(pager.firstRow == 401)
        let previous = try #require(pager.previous())
        #expect(previous.sql == "SELECT * FROM `shop`.`orders` WHERE `id` < '401' ORDER BY `id` DESC LIMIT 201")
        // The server answers nearest first: ids 400 down to 200.
        let page = pager.apply(previous, columns: Self.columns, rows: Self.rows(201, firstID: 400, descending: true))
        #expect(page.first?.first == "201")
        #expect(page.last?.first == "400")
        #expect(pager.firstRow == 201)
        #expect(pager.hasNext)
        let toFirst = try #require(pager.previous())
        #expect(toFirst.sql == "SELECT * FROM `shop`.`orders` ORDER BY `id` ASC LIMIT 201", "back to the first page reads it from the start")
    }

    @Test func columnsThatCannotBeComparedExactlyPageByOffset() throws {
        for sorted in ["city", "total", "status"] { // nullable, floating point, ENUM (sorted by its index)
            var pager = TablePager(table: Self.table, keyColumns: ["id"])
            _ = pager.apply(pager.first(sortedBy: .init(column: sorted, ascending: true)), columns: Self.columns, rows: Self.rows(201))
            #expect(try #require(pager.next()).sql == "SELECT * FROM `shop`.`orders` ORDER BY `\(sorted)` ASC, `id` ASC LIMIT 201 OFFSET 200",
                    "\(sorted)")
        }
        let binaryKey = [Self.column("uuid", .string, binary: true), Self.column("created_at", .datetime)]
        var pager = TablePager(table: Self.table, keyColumns: ["uuid"])
        _ = pager.apply(pager.first(sortedBy: nil), columns: binaryKey, rows: (0..<201).map { [String($0), "2026-11-01 10:00:00"] })
        #expect(try #require(pager.next()).sql.hasSuffix("LIMIT 201 OFFSET 200"))
    }

    @Test func aTableWithoutAKeyIsReadInItsOwnOrderByOffset() throws {
        var pager = TablePager(table: Self.table, keyColumns: [])
        #expect(pager.first(sortedBy: nil).sql == "SELECT * FROM `shop`.`orders` LIMIT 201")
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201))
        #expect(try #require(pager.next()).sql == "SELECT * FROM `shop`.`orders` LIMIT 201 OFFSET 400")
        #expect(try #require(pager.previous()).sql == "SELECT * FROM `shop`.`orders` LIMIT 201", "back to the first page reads it from the start")
    }

    @Test func theLastPageHasNoNext() {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        let page = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(37))
        #expect(page.count == 37)
        #expect(!pager.hasNext)
        #expect(pager.next() == nil)
        #expect(pager.previous() == nil)
    }

    @Test func valuesAndNamesAreQuoted() throws {
        let columns = [Self.column("na`me", .varString), Self.column("id", .longLong)]
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        let first = pager.first(sortedBy: .init(column: "na`me", ascending: true))
        _ = pager.apply(first, columns: columns, rows: (0..<201).map { ["O'Brien \\ ' --", String($0)] })
        let next = try #require(pager.next()).sql
        #expect(next.contains("`na``me` > " + SQLText.literal("O'Brien \\ ' --")), "\(next)")
        #expect(next.contains("ORDER BY `na``me` ASC, `id` ASC"))
    }

    @Test func reloadReadsThePageOnScreenAgain() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        let next = try #require(pager.next())
        _ = pager.apply(next, columns: Self.columns, rows: Self.rows(201, firstID: 201))
        #expect(pager.reload() == next)
    }

    @Test func theEditorGetsThePageInReadingOrder() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        #expect(pager.editorSQL == "SELECT * FROM `shop`.`orders` ORDER BY `id` ASC LIMIT 200")
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 401))
        _ = pager.apply(try #require(pager.previous()), columns: Self.columns, rows: Self.rows(201, firstID: 400, descending: true))
        #expect(pager.editorSQL == "SELECT * FROM (SELECT * FROM `shop`.`orders` WHERE `id` < '401' ORDER BY `id` DESC LIMIT 200) AS page"
            + " ORDER BY `id` ASC")
    }

    @Test func thePositionNamesTheRowsOnScreenAndTheTablesSize() throws {
        let english = Locale(identifier: "en_US")
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        #expect(pager.position(rowsOnPage: 0, estimatedTotal: nil, locale: english) == "No rows")
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        #expect(pager.position(rowsOnPage: 200, estimatedTotal: 2_812_331, locale: english) == "Rows 1–200 of ≈ 2.8M")
        #expect(pager.position(rowsOnPage: 200, estimatedTotal: nil, locale: english) == "Rows 1–200")
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(37, firstID: 201))
        #expect(pager.position(rowsOnPage: 37, estimatedTotal: 2_812_331, locale: english) == "Rows 201–237 of 237",
                "the last page knows the count")
    }
}
