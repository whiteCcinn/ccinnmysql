import Foundation
import MySQLKit
import MySQLWire

/// The Data tab's pages of a table: sorted by the server, read forward and back. Pages are left by key where that is
/// exact (`WHERE (sort, key) > (last row)`: page 5,000 costs what page 1 does) and by offset otherwise. Pure: the
/// caller runs `Request.sql` and hands the rows to `apply`.
public struct TablePager: Sendable, Equatable {
    public struct Sort: Sendable, Equatable {
        public var column: String
        public var ascending: Bool

        public init(column: String, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }
    }

    /// One page's query: one row more than a page, so the answer tells whether another page follows.
    public struct Request: Sendable, Equatable {
        public let sql: String
        /// The same page, exactly one page long and in reading order, for the SQL editor.
        public let editorSQL: String
        let sort: Sort?
        let pageIndex: Int
        /// A previous page read by key comes back last row first.
        let reversed: Bool
    }

    /// Already qualified and quoted (`` `shop`.`orders` ``).
    public let table: String
    /// The identifying key (primary key, else a NOT NULL unique key); empty when the table has none.
    public let keyColumns: [String]
    public let pageSize: Int
    let noBackslashEscapes: Bool

    public private(set) var sort: Sort?
    public private(set) var pageIndex = 0
    public private(set) var hasNext = false
    private var current: Request?
    /// The order columns' values in the page's first and last rows; `nil` where the page cannot be left by key.
    private var firstValues: [String]?
    private var lastValues: [String]?

    public init(table: String, keyColumns: [String], pageSize: Int = 200, noBackslashEscapes: Bool = false) {
        self.table = table
        self.keyColumns = keyColumns
        self.pageSize = max(1, pageSize)
        self.noBackslashEscapes = noBackslashEscapes
    }

    /// 1-based number of the page's first row.
    public var firstRow: Int { pageIndex * pageSize + 1 }
    public var hasPrevious: Bool { pageIndex > 0 }
    /// Whether the next and previous pages are read by key.
    public var seeksByKey: Bool { lastValues != nil }
    /// The page on screen, as a query to run in the editor.
    public var editorSQL: String { reload().editorSQL }

    /// "Rows 201–400 of ≈ 2.8M" (the server's estimate), "Rows 2,801–2,837 of 2,837" (the last page knows the count),
    /// "No rows".
    public func position(rowsOnPage: Int, estimatedTotal: Int64?, locale: Locale = .current) -> String {
        guard rowsOnPage > 0 else { return "No rows" }
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        let range = "Rows \(firstRow.formatted(number))–\((firstRow + rowsOnPage - 1).formatted(number))"
        if !hasNext { return range + " of " + (firstRow + rowsOnPage - 1).formatted(number) }
        guard let estimatedTotal, estimatedTotal > 0 else { return range }
        return range + " of ≈ " + estimatedTotal.formatted(.number.notation(.compactName).locale(locale))
    }

    public func first(sortedBy sort: Sort?) -> Request {
        request(sort: sort, pageIndex: 0, seek: nil, offset: nil)
    }

    public func next() -> Request? {
        guard hasNext, let current else { return nil }
        if let lastValues { return request(sort: current.sort, pageIndex: pageIndex + 1, seek: (lastValues, forward: true), offset: nil) }
        return request(sort: current.sort, pageIndex: pageIndex + 1, seek: nil, offset: (pageIndex + 1) * pageSize)
    }

    public func previous() -> Request? {
        guard pageIndex > 0, let current else { return nil }
        // The first page is read from the start: exact even when rows came and went meanwhile.
        if pageIndex == 1 { return first(sortedBy: current.sort) }
        if let firstValues { return request(sort: current.sort, pageIndex: pageIndex - 1, seek: (firstValues, forward: false), offset: nil) }
        return request(sort: current.sort, pageIndex: pageIndex - 1, seek: nil, offset: (pageIndex - 1) * pageSize)
    }

    /// The page on screen again (after an edit or Reload).
    public func reload() -> Request { current ?? first(sortedBy: sort) }

    /// Takes the answer to `request`: moves to its page and returns that page's rows in reading order.
    public mutating func apply(_ request: Request, columns: [ColumnDefinition], rows: [[String?]]) -> [[String?]] {
        var page = Array(rows.prefix(pageSize))
        if request.reversed { page.reverse() }
        sort = request.sort
        current = request
        if request.reversed {
            hasNext = true
            // Nothing before this page any more (rows were deleted meanwhile): it is the first page.
            pageIndex = rows.count > pageSize ? request.pageIndex : 0
        } else {
            hasNext = rows.count > pageSize
            pageIndex = request.pageIndex
        }
        let seek = Self.seekColumns(Self.orderColumns(sort: request.sort, key: keyColumns), key: keyColumns, in: columns)
        firstValues = seek.flatMap { Self.values(of: page.first, at: $0) }
        lastValues = seek.flatMap { Self.values(of: page.last, at: $0) }
        return page
    }

    // MARK: Queries

    /// The sort column, then the key's columns not sorted on already: with a key, the order is total.
    static func orderColumns(sort: Sort?, key: [String]) -> [String] {
        guard let sort else { return key }
        return [sort.column] + key.filter { $0.caseInsensitiveCompare(sort.column) != .orderedSame }
    }

    private func request(sort: Sort?, pageIndex: Int, seek: (values: [String], forward: Bool)?, offset: Int?) -> Request {
        let order = Self.orderColumns(sort: sort, key: keyColumns)
        let ascending = sort?.ascending ?? true
        let reversed = seek.map { !$0.forward } ?? false
        let readsAscending = reversed ? !ascending : ascending
        var query = "SELECT * FROM \(table)"
        if let seek { query += " WHERE " + seekCondition(order, values: seek.values, greater: readsAscending) }
        query += Self.orderBy(order, ascending: readsAscending)
        let offsetClause = offset.map { " OFFSET \($0)" } ?? ""
        let editorSQL = reversed
            ? "SELECT * FROM (\(query) LIMIT \(pageSize)) AS page" + Self.orderBy(order, ascending: ascending)
            : query + " LIMIT \(pageSize)" + offsetClause
        return Request(sql: query + " LIMIT \(pageSize + 1)" + offsetClause, editorSQL: editorSQL, sort: sort, pageIndex: pageIndex,
                       reversed: reversed)
    }

    private static func orderBy(_ columns: [String], ascending: Bool) -> String {
        guard !columns.isEmpty else { return "" }
        return " ORDER BY " + columns.map { SQLText.quoteIdentifier($0) + (ascending ? " ASC" : " DESC") }.joined(separator: ", ")
    }

    /// Rows after (`greater`) or before `values` in the order of `columns`: `a > x OR (a = x AND b > y)`, the form
    /// MySQL and MariaDB read as a range of the index.
    private func seekCondition(_ columns: [String], values: [String], greater: Bool) -> String {
        let comparison = greater ? " > " : " < "
        let names = columns.map(SQLText.quoteIdentifier)
        let literals = values.map { SQLText.literal($0, noBackslashEscapes: noBackslashEscapes) }
        return names.indices.map { index in
            let equal = (0..<index).map { names[$0] + " = " + literals[$0] }
            let clause = (equal + [names[index] + comparison + literals[index]]).joined(separator: " AND ")
            return index == 0 ? clause : "(" + clause + ")"
        }.joined(separator: " OR ")
    }

    /// The result positions of the order columns, when every one compares exactly: a key makes the order total, and
    /// each column is NOT NULL (NULL compares as unknown), not floating point or binary (text cannot round-trip it),
    /// and not ENUM/SET (sorted by member position, compared as text).
    static func seekColumns(_ order: [String], key: [String], in columns: [ColumnDefinition]) -> [Int]? {
        guard !key.isEmpty, !order.isEmpty else { return nil }
        var indices: [Int] = []
        for name in order {
            guard let index = columns.firstIndex(where: { $0.originalName.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            let column = columns[index]
            guard column.isNotNull, !column.isEnumOrSet, RowEditor.isExactKeyType(column) else { return nil }
            indices.append(index)
        }
        return indices
    }

    private static func values(of row: [String?]?, at indices: [Int]) -> [String]? {
        guard let row else { return nil }
        var values: [String] = []
        for index in indices {
            guard index < row.count, let value = row[index] else { return nil }
            values.append(value)
        }
        return values
    }
}
