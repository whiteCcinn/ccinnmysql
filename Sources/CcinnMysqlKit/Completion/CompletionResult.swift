import Foundation
import MySQLKit

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Hashable {
        case column, alias, table, view, routine, database, function, keyword
    }

    public let kind: Kind
    public let label: String
    public let insertText: String
    /// Secondary text: column type and table, function signature, object kind.
    public let detail: String?

    public init(kind: Kind, label: String, insertText: String, detail: String?) {
        self.kind = kind
        self.label = label
        self.insertText = insertText
        self.detail = detail
    }

    public var id: String { "\(kind.rawValue)\u{1F}\(label)\u{1F}\(detail ?? "")" }
}

/// The suggestions for the name at the cursor, and every candidate for its position, so the editor can follow the
/// keys typed in that name without asking again (`narrowed(in:cursor:)`).
public struct CompletionResult: Sendable {
    /// UTF-16 range of the whole name at the cursor (back-quotes included), which the chosen item replaces.
    public let replacementRange: Range<Int>
    /// The part of the name before the cursor, without its back-quote.
    public let prefix: String
    public let items: [CompletionItem]
    /// Tables referenced by the statement whose columns are not in the snapshot yet; the app loads
    /// them and asks again.
    public let missingColumns: [TableKey]
    /// Databases whose object lists are needed but not loaded yet.
    public let missingDatabases: [String]
    /// The cursor is where a table, routine or database name must follow (`FROM `, `JOIN `, `CALL `, `USE `, …), so
    /// the editor may offer the list before anything is typed.
    public let expectsObjectName: Bool
    /// The name is back-quoted; items go in back-quoted.
    public let isQuoted: Bool
    /// Digits may start a name here (after `FROM`, after a dot); elsewhere `20` is a number and matches nothing.
    let allowsNumericName: Bool
    let pool: CompletionPool

    public init(replacementRange: Range<Int>, prefix: String, items: [CompletionItem], missingColumns: [TableKey] = [],
                missingDatabases: [String] = [], expectsObjectName: Bool = false, isQuoted: Bool = false) {
        self.init(replacementRange: replacementRange, prefix: prefix, items: items, missingColumns: missingColumns,
                  missingDatabases: missingDatabases, expectsObjectName: expectsObjectName, isQuoted: isQuoted,
                  allowsNumericName: expectsObjectName, pool: CompletionPool(items))
    }

    init(replacementRange: Range<Int>, prefix: String, items: [CompletionItem], missingColumns: [TableKey],
         missingDatabases: [String], expectsObjectName: Bool, isQuoted: Bool, allowsNumericName: Bool, pool: CompletionPool) {
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.items = items
        self.missingColumns = missingColumns
        self.missingDatabases = missingDatabases
        self.expectsObjectName = expectsObjectName
        self.isQuoted = isQuoted
        self.allowsNumericName = allowsNumericName
        self.pool = pool
    }

    /// This result for a text with `offset` more UTF-16 units before the text it was computed for (the editor sends
    /// the engine one statement of the script).
    public func shifted(by offset: Int) -> CompletionResult {
        guard offset != 0 else { return self }
        return CompletionResult(replacementRange: (replacementRange.lowerBound + offset)..<(replacementRange.upperBound + offset),
                                prefix: prefix, items: items, missingColumns: missingColumns, missingDatabases: missingDatabases,
                                expectsObjectName: expectsObjectName, isQuoted: isQuoted, allowsNumericName: allowsNumericName,
                                pool: pool)
    }

    public var needsMoreSchema: Bool { !missingColumns.isEmpty || !missingDatabases.isEmpty }

    public static func empty(at cursor: Int) -> CompletionResult {
        CompletionResult(replacementRange: cursor..<cursor, prefix: "", items: [])
    }

    /// This position's suggestions for `text` with the cursor at `cursor`, while the name being completed still starts
    /// where this result's does: the cursor is in it, and everything typed before the cursor belongs to it. `nil` once
    /// it does not (Backspace past its start, a space, a dot, a back-quote typed into a plain name). The caller makes
    /// sure nothing before the name changed. O(candidates), no lexing.
    public func narrowed(in text: NSString, cursor: Int, limit: Int = CompletionEngine.defaultLimit) -> CompletionResult? {
        let start = replacementRange.lowerBound
        let length = text.length
        guard start <= cursor, cursor <= length else { return nil }
        var nameStart = start
        if isQuoted {
            guard cursor > start, text.character(at: start) == Self.backQuote else { return nil }
            nameStart = start + 1
        }
        for index in nameStart..<cursor {
            let unit = text.character(at: index)
            let belongs = isQuoted ? !Self.endsQuotedName(unit) : SQLLexer.isIdentifierPart(unit)
            guard belongs else { return nil }
        }
        let end = isQuoted ? Self.endOfQuotedName(in: text, from: cursor) : Self.endOfPlainName(in: text, from: cursor)
        let prefix = text.substring(with: NSRange(location: nameStart, length: cursor - nameStart))
        let items = !isQuoted && !allowsNumericName && Self.isNumber(prefix)
            ? [] : CompletionRanking.rank(pool, prefix: prefix, limit: limit, quoted: isQuoted)
        return CompletionResult(replacementRange: start..<end, prefix: prefix, items: items,
                                missingColumns: missingColumns, missingDatabases: missingDatabases,
                                expectsObjectName: expectsObjectName, isQuoted: isQuoted, allowsNumericName: allowsNumericName,
                                pool: pool)
    }

    /// `20`, `0x1F`: the server reads it as a number, not a name (`1abc` is a name).
    private static func isNumber(_ typed: String) -> Bool {
        guard let first = typed.utf16.first, SQLLexer.isDigit(first) else { return false }
        let tokens = SQLLexer(typed).tokens()
        return tokens.count != 1 || tokens[0].kind != .identifier
    }

    /// Where the name ending at `cursor` starts: its letters and digits, and an opening back-quote right before them.
    public static func nameStart(in text: NSString, before cursor: Int) -> Int {
        var start = max(0, min(cursor, text.length))
        while start > 0, SQLLexer.isIdentifierPart(text.character(at: start - 1)) { start -= 1 }
        if start > 0, text.character(at: start - 1) == backQuote { start -= 1 }
        return start
    }

    private static let backQuote: unichar = 0x60

    private static func endsQuotedName(_ unit: unichar) -> Bool { unit == backQuote || unit == 0x0A || unit == 0x0D }

    /// After the closing back-quote on the same line; at the end of the name's letters when there is none.
    private static func endOfQuotedName(in text: NSString, from cursor: Int) -> Int {
        var index = cursor
        while index < text.length, !endsQuotedName(text.character(at: index)) { index += 1 }
        if index < text.length, text.character(at: index) == backQuote { return index + 1 }
        return endOfPlainName(in: text, from: cursor)
    }

    private static func endOfPlainName(in text: NSString, from cursor: Int) -> Int {
        var index = cursor
        while index < text.length, SQLLexer.isIdentifierPart(text.character(at: index)) { index += 1 }
        return index
    }
}
