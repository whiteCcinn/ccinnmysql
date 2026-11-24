import Foundation
import MySQLKit
import MySQLWire

/// The Data tab's pages of a table: sorted by the server, read forward and back. Pages are left by key where the
/// server compares the order columns exactly as it sorts them (`WHERE (sort, key) > (last row)`: page 5,000 costs
/// what page 1 does) and by offset otherwise. Pure: the caller runs `Request.sql` and hands the rows to `apply`.
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
        let sort: Sort?
        /// Forward reads: the 0-based index of the page's first row. Backward reads: the index of the row after the page.
        let boundary: Int
        /// A previous page read by key: the server returns it last row first.
        public let readsBackward: Bool
    }

    /// An order column the page can be left by: where it is in the result, and how its values are written.
    struct SeekColumn: Sendable, Equatable {
        let index: Int
        let isNumber: Bool
    }

    /// Already qualified and quoted (`` `shop`.`orders` ``).
    public let table: String
    /// The identifying key (primary key, else a NOT NULL unique key); empty when the table has none.
    public let keyColumns: [String]
    /// Without a key: the columns that break ties after the sort column, so OFFSET pages stay stable.
    public let tieBreakers: [String]
    public let pageSize: Int
    let noBackslashEscapes: Bool

    public private(set) var sort: Sort?
    public private(set) var hasNext = false
    /// 0-based index of the page's first row in the sorted table.
    private var firstRowIndex = 0
    private var rowsShown = 0
    private var current: Request?
    private var seek: [SeekColumn]?
    /// The order columns' values in the page's first and last rows; `nil` where the page cannot be left by key.
    private var firstValues: [String]?
    private var lastValues: [String]?

    /// The server orders strings by their first `max_sort_length` bytes (1,024 by default) but compares them whole:
    /// longer strings cannot be sought by.
    static let maxSortLength: UInt32 = 1_024

    public init(table: String, keyColumns: [String], tieBreakers: [String] = [], pageSize: Int = 200, noBackslashEscapes: Bool = false) {
        self.table = table
        self.keyColumns = keyColumns
        self.tieBreakers = tieBreakers
        self.pageSize = max(1, pageSize)
        self.noBackslashEscapes = noBackslashEscapes
    }

    /// 1-based number of the page's first row.
    public var firstRow: Int { firstRowIndex + 1 }
    public var hasPrevious: Bool { firstRowIndex > 0 }
    /// Whether the next and previous pages are read by key.
    public var seeksByKey: Bool { lastValues != nil }

    /// The page on screen as a query for the editor: an offset, so no values need escaping for its session.
    public var editorSQL: String {
        let order = orderColumns(sort: sort)
        return "SELECT * FROM \(table)" + Self.orderBy(order, ascending: sort?.ascending ?? true) + " LIMIT \(pageSize)"
            + (firstRowIndex > 0 ? " OFFSET \(firstRowIndex)" : "")
    }

    /// "Rows 201–400 of ≈ 2.8M" (the server's estimate), "Rows 2,801–2,837 of 2,837" (the last page knows the count),
    /// "No rows".
    public func position(rowsOnPage: Int, estimatedTotal: Int64?, locale: Locale = .current) -> String {
        guard rowsOnPage > 0 else { return "No rows" }
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        let last = firstRow + rowsOnPage - 1
        let range = "Rows \(firstRow.formatted(number))–\(last.formatted(number))"
        if !hasNext { return range + " of " + last.formatted(number) }
        guard let estimatedTotal, estimatedTotal > 0 else { return range }
        return range + " of ≈ " + estimatedTotal.formatted(.number.notation(.compactName).locale(locale))
    }

    public func first(sortedBy sort: Sort?) -> Request {
        request(sort: sort, boundary: 0, seekingFrom: nil, backward: false, offset: nil)
    }

    public func next() -> Request? {
        guard hasNext, let current else { return nil }
        let start = firstRowIndex + rowsShown
        if let lastValues { return request(sort: current.sort, boundary: start, seekingFrom: lastValues, backward: false, offset: nil) }
        return request(sort: current.sort, boundary: start, seekingFrom: nil, backward: false, offset: start)
    }

    public func previous() -> Request? {
        guard firstRowIndex > 0, let current else { return nil }
        // The first page is read from the start: exact even when rows came and went meanwhile.
        if firstRowIndex <= pageSize { return first(sortedBy: current.sort) }
        if let firstValues { return request(sort: current.sort, boundary: firstRowIndex, seekingFrom: firstValues, backward: true, offset: nil) }
        let start = firstRowIndex - pageSize
        return request(sort: current.sort, boundary: start, seekingFrom: nil, backward: false, offset: start)
    }

    /// The page on screen again (after an edit or Reload).
    public func reload() -> Request { current ?? first(sortedBy: sort) }

    /// Takes the answer to `request` and returns the page's rows in reading order. `truncated`: the reader stopped
    /// before the end of the answer (its byte limit), so more rows may follow even with fewer than a page.
    public mutating func apply(_ request: Request, columns: [ColumnDefinition], rows: [[String?]], truncated: Bool = false) -> [[String?]] {
        var page = Array(rows.prefix(pageSize))
        sort = request.sort
        current = request
        if request.readsBackward {
            page.reverse()
            // Nothing (more) before these rows: they start the table, whatever moved meanwhile.
            let reachedStart = !truncated && rows.count <= pageSize
            firstRowIndex = reachedStart ? 0 : max(0, request.boundary - page.count)
            hasNext = true
        } else {
            firstRowIndex = request.boundary
            hasNext = truncated || rows.count > pageSize
        }
        rowsShown = page.count
        seek = Self.seekColumns(orderColumns(sort: request.sort), key: keyColumns, in: columns)
        firstValues = seek.flatMap { Self.values(of: page.first, at: $0) }
        lastValues = seek.flatMap { Self.values(of: page.last, at: $0) }
        return page
    }

    /// Whether a column of `dataType` (information_schema's `DATA_TYPE`) can break ties in a keyless sort: cheap to
    /// compare and not a document.
    public static func breaksTies(dataType: String) -> Bool {
        !["tinytext", "text", "mediumtext", "longtext", "tinyblob", "blob", "mediumblob", "longblob", "json", "geometry", "point",
          "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geomcollection", "vector"]
            .contains(dataType.lowercased())
    }

    // MARK: Queries

    /// The sort column, then the key's columns not sorted on already: with a key the order is total. Without one,
    /// a sort is followed by the tie-breakers.
    func orderColumns(sort: Sort?) -> [String] {
        Self.orderColumns(sort: sort, key: keyColumns, tieBreakers: tieBreakers)
    }

    static func orderColumns(sort: Sort?, key: [String], tieBreakers: [String] = []) -> [String] {
        guard let sort else { return key }
        let following = key.isEmpty ? tieBreakers : key
        return [sort.column] + following.filter { $0.caseInsensitiveCompare(sort.column) != .orderedSame }
    }

    private func request(sort: Sort?, boundary: Int, seekingFrom values: [String]?, backward: Bool, offset: Int?) -> Request {
        let order = orderColumns(sort: sort)
        let ascending = sort?.ascending ?? true
        let readsAscending = backward ? !ascending : ascending
        var query = "SELECT * FROM \(table)"
        if let values, let seek { query += " WHERE " + seekCondition(order, seek: seek, values: values, greater: readsAscending) }
        query += Self.orderBy(order, ascending: readsAscending) + " LIMIT \(pageSize + 1)"
        if let offset { query += " OFFSET \(offset)" }
        return Request(sql: query, sort: sort, boundary: boundary, readsBackward: backward)
    }

    private static func orderBy(_ columns: [String], ascending: Bool) -> String {
        guard !columns.isEmpty else { return "" }
        return " ORDER BY " + columns.map { SQLText.quoteIdentifier($0) + (ascending ? " ASC" : " DESC") }.joined(separator: ", ")
    }

    /// Rows after (`greater`) or before `values` in the order of `columns`: `a > x OR (a = x AND b > y)`, the form
    /// MySQL and MariaDB read as a range of the index.
    private func seekCondition(_ columns: [String], seek: [SeekColumn], values: [String], greater: Bool) -> String {
        let comparison = greater ? " > " : " < "
        let names = columns.map(SQLText.quoteIdentifier)
        let literals = values.indices.map { literal(values[$0], isNumber: seek[$0].isNumber) }
        return names.indices.map { index in
            let equal = (0..<index).map { names[$0] + " = " + literals[$0] }
            let clause = (equal + [names[index] + comparison + literals[index]]).joined(separator: " AND ")
            return index == 0 ? clause : "(" + clause + ")"
        }.joined(separator: " OR ")
    }

    /// Integers and decimals unquoted: MySQL compares a quoted string with a DECIMAL as a double, inexact past 15 digits.
    private func literal(_ value: String, isNumber: Bool) -> String {
        isNumber && Self.isPlainNumber(value) ? value : SQLText.literal(value, noBackslashEscapes: noBackslashEscapes)
    }

    /// `-12`, `3.50`: digits with an optional sign and fraction, nothing else.
    static func isPlainNumber(_ value: String) -> Bool {
        var digitsBeforePoint = 0
        var digitsAfterPoint = 0
        var sawPoint = false
        for (offset, unit) in value.utf8.enumerated() {
            switch unit {
            case UInt8(ascii: "-") where offset == 0:
                continue
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if sawPoint { digitsAfterPoint += 1 } else { digitsBeforePoint += 1 }
            case UInt8(ascii: ".") where !sawPoint && digitsBeforePoint > 0:
                sawPoint = true
            default:
                return false
            }
        }
        return digitsBeforePoint > 0 && (!sawPoint || digitsAfterPoint > 0)
    }

    /// The order columns, when the server compares every one exactly as it sorts it: a key makes the order total,
    /// and each column is NOT NULL (NULL compares as unknown); not floating point, binary, BIT or JSON (text cannot
    /// round-trip it); not ENUM/SET (sorted by member position, compared as text); not TEXT/BLOB or a string longer
    /// than `max_sort_length` (sorted by a prefix, compared whole); not TIMESTAMP (sorted by instant, compared as
    /// local time, which repeats when clocks go back).
    static func seekColumns(_ order: [String], key: [String], in columns: [ColumnDefinition]) -> [SeekColumn]? {
        guard !key.isEmpty, !order.isEmpty else { return nil }
        var seek: [SeekColumn] = []
        for name in order {
            guard let index = columns.firstIndex(where: { $0.originalName.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            let column = columns[index]
            guard column.isNotNull, !column.isEnumOrSet, RowEditor.isExactKeyType(column), column.type != .timestamp,
                  !(249...252).contains(column.type.rawValue), !(column.type.kind == .text && column.length > maxSortLength)
            else { return nil }
            seek.append(SeekColumn(index: index, isNumber: column.type.kind == .integer || column.type.kind == .decimal))
        }
        return seek
    }

    private static func values(of row: [String?]?, at seek: [SeekColumn]) -> [String]? {
        guard let row else { return nil }
        var values: [String] = []
        for column in seek {
            guard column.index < row.count, let value = row[column.index] else { return nil }
            values.append(value)
        }
        return values
    }
}
