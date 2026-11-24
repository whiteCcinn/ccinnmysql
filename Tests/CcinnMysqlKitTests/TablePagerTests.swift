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
            + " OR (`created_at` = '2026-11-18 10:00:00' AND `id` < 801) ORDER BY `created_at` DESC, `id` DESC LIMIT 201")
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
        #expect(previous.sql == "SELECT * FROM `shop`.`orders` WHERE `id` < 401 ORDER BY `id` DESC LIMIT 201")
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

    @Test func theEditorGetsThePageAsAnOffsetQuery() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        #expect(pager.editorSQL == "SELECT * FROM `shop`.`orders` ORDER BY `id` ASC LIMIT 200")
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 401))
        _ = pager.apply(try #require(pager.previous()), columns: Self.columns, rows: Self.rows(201, firstID: 400, descending: true))
        #expect(pager.editorSQL == "SELECT * FROM `shop`.`orders` ORDER BY `id` ASC LIMIT 200 OFFSET 200",
                "the editor gets no values to escape: its session may read backslashes differently")
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

    // Review #2: a page cut short by the reader's 64 MiB limit is not the end of the table.
    @Test func aTruncatedPageIsNotTheLastPage() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(167), truncated: true)
        #expect(pager.hasNext)
        #expect(pager.position(rowsOnPage: 167, estimatedTotal: 300, locale: Locale(identifier: "en_US")) == "Rows 1–167 of ≈ 300")
        let next = try #require(pager.next())
        #expect(next.sql.contains("WHERE `id` > 167 "))
        _ = pager.apply(next, columns: Self.columns, rows: Self.rows(201, firstID: 168))
        #expect(pager.firstRow == 168)

        var offsetPager = TablePager(table: Self.table, keyColumns: [])
        _ = offsetPager.apply(offsetPager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(167), truncated: true)
        #expect(try #require(offsetPager.next()).sql.hasSuffix("LIMIT 201 OFFSET 167"), "the next page starts after the rows shown")
    }

    @Test func aTruncatedPreviousPageIsNotTheFirstPage() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 401))
        _ = pager.apply(try #require(pager.previous()), columns: Self.columns, rows: Self.rows(90, firstID: 400, descending: true), truncated: true)
        #expect(pager.firstRow == 311, "90 rows before row 401")
        #expect(pager.hasPrevious)
    }

    // Review #3, #6: sorts the server cannot compare exactly the way it orders them page by offset.
    @Test func textLongStringsAndTimestampsPageByOffset() throws {
        var title = ColumnDefinition(name: "title", type: .varString, table: "orders", schema: "shop", flags: ColumnDefinition.notNullFlag,
                                     characterSet: 45, length: 1_200)
        let stamp = Self.column("stamped_at", .timestamp)
        let body = ColumnDefinition(name: "body", type: .blob, table: "orders", schema: "shop", flags: ColumnDefinition.notNullFlag, characterSet: 45)
        let columns = [Self.column("id", .longLong), body, title, stamp]
        for sorted in ["body", "title", "stamped_at"] {
            var pager = TablePager(table: Self.table, keyColumns: ["id"])
            _ = pager.apply(pager.first(sortedBy: .init(column: sorted, ascending: true)), columns: columns,
                            rows: (0..<201).map { [String($0), "b", "t", "2026-11-01 01:30:00"] })
            #expect(!pager.seeksByKey, "\(sorted)")
            #expect(try #require(pager.next()).sql.hasSuffix("LIMIT 201 OFFSET 200"), "\(sorted)")
        }
        title = ColumnDefinition(name: "title", type: .varString, table: "orders", schema: "shop", flags: ColumnDefinition.notNullFlag,
                                 characterSet: 45, length: 1_020)
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: .init(column: "title", ascending: true)), columns: [Self.column("id", .longLong), title],
                        rows: (0..<201).map { [String($0), "t"] })
        #expect(pager.seeksByKey, "VARCHAR(255) in utf8mb4 is compared whole")
    }

    // Review #4: MySQL compares a quoted number with a DECIMAL as a double; numbers go unquoted.
    @Test func numbersAreComparedAsNumbers() throws {
        let columns = [Self.column("id", .newDecimal), Self.column("amount", .longLong)]
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: .init(column: "amount", ascending: true)), columns: columns,
                        rows: (0..<201).map { ["15000000000000002\($0 % 10)0", "-\($0)"] })
        let next = try #require(pager.next()).sql
        // The 200th row: amount -199, id 1500000000000000290 (19 digits: not exact as a double).
        #expect(next.contains("`amount` > -199 OR (`amount` = -199 AND `id` > 1500000000000000290)"), "\(next)")
    }

    // Review #5: without a key, ties in the sort column are broken by the other columns, so OFFSET pages are stable.
    @Test func aKeylessSortBreaksTiesWithTheOtherColumns() {
        let pager = TablePager(table: Self.table, keyColumns: [], tieBreakers: ["a", "b", "c"])
        #expect(pager.first(sortedBy: .init(column: "B", ascending: false)).sql
            == "SELECT * FROM `shop`.`orders` ORDER BY `B` DESC, `a` DESC, `c` DESC LIMIT 201")
        #expect(pager.first(sortedBy: nil).sql == "SELECT * FROM `shop`.`orders` LIMIT 201", "the table's own order needs no sort")
    }

    // Review #7: everything before the page was deleted; the empty answer is the start of the table.
    @Test func anEmptyPreviousPageIsTheStart() throws {
        var pager = TablePager(table: Self.table, keyColumns: ["id"])
        _ = pager.apply(pager.first(sortedBy: nil), columns: Self.columns, rows: Self.rows(201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 201))
        _ = pager.apply(try #require(pager.next()), columns: Self.columns, rows: Self.rows(201, firstID: 401))
        let previous = try #require(pager.previous())
        #expect(previous.readsBackward)
        #expect(pager.apply(previous, columns: Self.columns, rows: []).isEmpty)
        #expect(pager.firstRow == 1)
        #expect(!pager.hasPrevious)
    }

    @Test func aFilterNarrowsEveryPage() throws {
        let filter = try #require(try TableFilter.parse("city = 'KL' OR total > 1").get())
        var pager = TablePager(table: Self.table, keyColumns: ["id"], filter: filter)
        let first = pager.first(sortedBy: nil)
        #expect(first.sql == "SELECT * FROM `shop`.`orders` WHERE (city = 'KL' OR total > 1) ORDER BY `id` ASC LIMIT 201")
        _ = pager.apply(first, columns: Self.columns, rows: Self.rows(201))
        #expect(try #require(pager.next()).sql
            == "SELECT * FROM `shop`.`orders` WHERE (city = 'KL' OR total > 1) AND (`id` > 200) ORDER BY `id` ASC LIMIT 201")
        #expect(pager.editorSQL == "SELECT * FROM `shop`.`orders` WHERE (city = 'KL' OR total > 1) ORDER BY `id` ASC LIMIT 200")
        let commented = try #require(try TableFilter.parse("id > 5 -- recent").get())
        #expect(TablePager(table: Self.table, keyColumns: [], filter: commented).first(sortedBy: nil).sql
            == "SELECT * FROM `shop`.`orders` WHERE (id > 5 -- recent\n) LIMIT 201")
    }
}
