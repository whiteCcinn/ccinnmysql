import Foundation

/// One statement of a script. `range` is in UTF-16 offsets of the whole script, excludes leading
/// comments/whitespace and the terminating delimiter; `text` is the statement source.
public struct SQLStatement: Sendable, Equatable {
    public let text: String
    public let range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

public enum SQLStatementSplitter {
    /// Splits a script on its delimiter (`;`, or what a `DELIMITER` line sets, as in the `mysql` client) outside
    /// strings, quoted identifiers and comments. `DELIMITER` lines themselves are not statements; statements made
    /// only of comments/whitespace are dropped. Linear in the script length.
    public static func split(_ script: String) -> [SQLStatement] {
        let units = Array(script.utf16)
        var statements: [SQLStatement] = []
        var delimiter: [UInt16] = [0x3B]
        var start = 0
        var index = 0
        let count = units.count

        func flush(_ end: Int) {
            guard let range = significantRange(units, start..<end) else { return }
            statements.append(SQLStatement(text: String(decoding: units[range], as: UTF16.self), range: range))
        }

        while index < count {
            let unit = units[index]
            // A DELIMITER command: only at the start of a line, before any statement text.
            if (unit == 0x44 || unit == 0x64), significantRange(units, start..<index) == nil, isLineStart(units, index),
               let (newDelimiter, lineEnd) = delimiterCommand(units, at: index) {
                if !newDelimiter.isEmpty { delimiter = newDelimiter }
                index = lineEnd
                start = lineEnd
                continue
            }
            if matches(units, delimiter, at: index) {
                flush(index)
                index += delimiter.count
                start = index
                continue
            }
            switch unit {
            case 0x27, 0x22: // ' "
                index = endOfQuoted(units, from: index, quote: unit, backslash: true)
            case 0x60: // `
                index = endOfQuoted(units, from: index, quote: unit, backslash: false)
            case 0x23: // #
                index = endOfLine(units, from: index)
            case 0x2D where index + 1 < count && units[index + 1] == 0x2D && SQLLexer.endsDashComment(index + 2 < count ? units[index + 2] : nil):
                index = endOfLine(units, from: index)
            case 0x2F where index + 1 < count && units[index + 1] == 0x2A:
                index = endOfBlockComment(units, from: index)
            default:
                index += 1
            }
        }
        flush(count)
        return statements
    }

    /// The statement containing `offset` (UTF-16). A cursor right after a statement's delimiter or in the
    /// blank space after it belongs to that statement.
    public static func statement(at offset: Int, in script: String) -> SQLStatement? {
        let statements = split(script)
        guard !statements.isEmpty else { return nil }
        if let containing = statements.first(where: { $0.range.lowerBound <= offset && offset <= $0.range.upperBound }) {
            return containing
        }
        return statements.last { $0.range.upperBound <= offset } ?? statements.first
    }

    // MARK: Scanning helpers

    /// Range without leading whitespace/comments and trailing whitespace; `nil` when nothing significant remains.
    /// Executable comments (`/*! … */`) are code, so they count as significant.
    static func significantRange(_ units: [UInt16], _ range: Range<Int>) -> Range<Int>? {
        var lower = range.lowerBound
        let upper = range.upperBound
        while lower < upper {
            let unit = units[lower]
            if unit <= 0x20 {
                lower += 1
            } else if unit == 0x23 {
                lower = min(upper, endOfLine(units, from: lower))
            } else if unit == 0x2D, lower + 1 < upper, units[lower + 1] == 0x2D, SQLLexer.endsDashComment(lower + 2 < units.count ? units[lower + 2] : nil) {
                lower = min(upper, endOfLine(units, from: lower))
            } else if unit == 0x2F, lower + 1 < upper, units[lower + 1] == 0x2A,
                      !(lower + 2 < upper && (units[lower + 2] == 0x21 || units[lower + 2] == 0x4D)) {
                lower = min(upper, endOfBlockComment(units, from: lower))
            } else {
                break
            }
        }
        var end = upper
        while end > lower, units[end - 1] <= 0x20 { end -= 1 }
        return lower < end ? lower..<end : nil
    }

    static func isLineStart(_ units: [UInt16], _ index: Int) -> Bool {
        var position = index - 1
        while position >= 0 {
            let unit = units[position]
            if unit == 0x0A || unit == 0x0D { return true }
            if unit != 0x20 && unit != 0x09 { return false }
            position -= 1
        }
        return true
    }

    /// `DELIMITER <token>` up to the end of the line; returns the new delimiter and the index after the line.
    static func delimiterCommand(_ units: [UInt16], at index: Int) -> ([UInt16], Int)? {
        let keyword = Array("DELIMITER".utf16)
        guard index + keyword.count < units.count else { return nil }
        for (offset, expected) in keyword.enumerated() {
            let unit = units[index + offset]
            let upper = unit >= 0x61 && unit <= 0x7A ? unit - 0x20 : unit
            guard upper == expected else { return nil }
        }
        let afterKeyword = index + keyword.count
        guard units[afterKeyword] == 0x20 || units[afterKeyword] == 0x09 else { return nil }
        let lineEnd = endOfTextLine(units, from: afterKeyword)
        var tokenStart = afterKeyword
        while tokenStart < lineEnd, units[tokenStart] == 0x20 || units[tokenStart] == 0x09 { tokenStart += 1 }
        var tokenEnd = tokenStart
        while tokenEnd < lineEnd, units[tokenEnd] > 0x20 { tokenEnd += 1 }
        return (Array(units[tokenStart..<tokenEnd].prefix(16)), lineEnd)
    }

    static func matches(_ units: [UInt16], _ needle: [UInt16], at index: Int) -> Bool {
        guard !needle.isEmpty, index + needle.count <= units.count else { return false }
        for offset in 0..<needle.count where units[index + offset] != needle[offset] { return false }
        return true
    }

    /// End of a line comment, as the server sees it (`\n` or NUL; `\r` does not end a comment).
    static func endOfLine(_ units: [UInt16], from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A, units[index] != 0x00 { index += 1 }
        return index
    }

    /// End of the current line for `DELIMITER` commands (`\r` and `\n`).
    static func endOfTextLine(_ units: [UInt16], from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A, units[index] != 0x0D { index += 1 }
        return index
    }

    static func endOfBlockComment(_ units: [UInt16], from index: Int) -> Int {
        var index = index + 2
        while index + 1 < units.count, !(units[index] == 0x2A && units[index + 1] == 0x2F) { index += 1 }
        return min(units.count, index + 2)
    }

    static func endOfQuoted(_ units: [UInt16], from index: Int, quote: UInt16, backslash: Bool) -> Int {
        var index = index + 1
        while index < units.count {
            let unit = units[index]
            if backslash, unit == 0x5C {
                index += 2
                continue
            }
            if unit == quote {
                if index + 1 < units.count, units[index + 1] == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return units.count
    }
}

/// What kind of statement a text is; drives auto-limit, history and confirmation UI.
public enum SQLStatementKind: Sendable, Equatable {
    case query
    case explain
    case show
    case use
    case set
    case transaction
    case dataModification
    case definition
    case administration
    case other

    /// Classifies by grammar, not by the first word alone: `WITH … DELETE`, `SELECT … INTO OUTFILE`,
    /// `EXPLAIN ANALYZE UPDATE` and MariaDB `ANALYZE UPDATE` (which execute the update) are mutations.
    public static func of(_ statement: String) -> SQLStatementKind {
        let lexer = SQLLexer(statement)
        let all = lexer.tokens()
        if all.first(where: { $0.kind != .comment })?.kind == .executableComment { return .other }
        let tokens = all.filter { $0.kind != .comment && $0.kind != .executableComment }
        guard !tokens.isEmpty else { return .other }
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
        return classify(words: words, tokens: tokens)
    }

    static func classify(words: [String], tokens: [SQLToken]) -> SQLStatementKind {
        guard var word = words.first else { return .other }
        var start = 0
        if word == "WITH" {
            start = mainVerbIndex(afterWith: tokens, words: words) ?? 0
            word = start == 0 ? "WITH" : words[start]
        }
        func next(_ offset: Int = 1) -> String { start + offset < words.count ? words[start + offset] : "" }
        switch word {
        case "SELECT", "VALUES", "TABLE", "(":
            return writesInto(words: Array(words[start...]), tokens: Array(tokens[start...])) ? .dataModification : .query
        case "EXPLAIN", "DESC", "DESCRIBE":
            var index = start + 1
            let modifiers: Set<String> = ["ANALYZE", "EXTENDED", "PARTITIONS", "FORMAT", "=", "JSON", "TREE", "TRADITIONAL"]
            var analyze = false
            while index < words.count, modifiers.contains(words[index]) {
                if words[index] == "ANALYZE" { analyze = true }
                index += 1
            }
            guard index < words.count else { return .show }
            let verb = words[index]
            if ["SELECT", "WITH", "TABLE", "VALUES", "(", "FOR"].contains(verb) { return .explain }
            if ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(verb) { return analyze ? .dataModification : .explain }
            return index == start + 1 && (word == "DESC" || word == "DESCRIBE") ? .show : .explain
        case "ANALYZE":
            // MariaDB `ANALYZE <statement>` executes the statement; `ANALYZE TABLE` updates statistics.
            var index = start + 1
            while index < words.count, ["FORMAT", "=", "JSON"].contains(words[index]) { index += 1 }
            let verb = index < words.count ? words[index] : ""
            if ["SELECT", "WITH", "(", "TABLE"].contains(verb), verb != "TABLE" || index > start + 1 { return .explain }
            if ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(verb) { return .dataModification }
            return .administration
        case "SHOW", "HELP":
            return .show
        case "USE":
            return .use
        case "SET":
            let second = next()
            if ["GLOBAL", "PERSIST", "PERSIST_ONLY", "PASSWORD", "DEFAULT", "RESOURCE", "ROLE"].contains(second) || second.hasPrefix("@@GLOBAL")
                || second.hasPrefix("@@PERSIST") {
                return second == "ROLE" ? .set : .administration
            }
            return .set
        case "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "XA":
            return .transaction
        case "START":
            return next() == "TRANSACTION" ? .transaction : .administration
        case "INSERT", "UPDATE", "DELETE", "REPLACE", "TRUNCATE", "LOAD", "CALL", "DO", "HANDLER", "IMPORT":
            return .dataModification
        case "CREATE", "ALTER", "DROP", "RENAME":
            return .definition
        case "GRANT", "REVOKE", "KILL", "FLUSH", "RESET", "PURGE", "OPTIMIZE", "REPAIR", "CHECK", "CHECKSUM", "CACHE", "INSTALL",
             "UNINSTALL", "SHUTDOWN", "RESTART", "CHANGE", "STOP", "LOCK", "UNLOCK", "PREPARE", "EXECUTE", "DEALLOCATE", "BINLOG", "CLONE":
            return .administration
        default:
            return .other
        }
    }

    /// The statement verb after a `WITH` list: the first SELECT/INSERT/UPDATE/DELETE/REPLACE/TABLE/VALUES at depth 0,
    /// or a parenthesised query directly following the CTE list.
    static func mainVerbIndex(afterWith tokens: [SQLToken], words: [String]) -> Int? {
        var depth = 0
        for index in tokens.indices.dropFirst() {
            let word = words[index]
            if tokens[index].kind == .punctuation {
                if word == "(" {
                    if depth == 0, words[index - 1] == ")" { return index }
                    depth += 1
                }
                if word == ")" { depth = max(0, depth - 1) }
                continue
            }
            if depth == 0, ["SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "TABLE", "VALUES"].contains(word) { return index }
        }
        return nil
    }

    /// `SELECT … INTO OUTFILE/DUMPFILE/@var` writes files or session variables.
    static func writesInto(words: [String], tokens: [SQLToken]) -> Bool {
        for (index, token) in tokens.enumerated() where token.kind == .keyword || token.kind == .identifier {
            if words[index] == "INTO" { return true }
        }
        return false
    }

    /// Statements that may change data, schema or server state (confirmed on connections that ask for it).
    /// Unknown statements are treated as mutations.
    public var isMutation: Bool {
        switch self {
        case .dataModification, .definition, .administration, .other: true
        case .query, .explain, .show, .use, .set, .transaction: false
        }
    }
}

/// Adds `LIMIT n` to top-level queries without one (workbench auto-limit and MCP).
public enum AutoLimit {
    public struct Outcome: Sendable, Equatable {
        public let sql: String
        public let applied: Bool
    }

    /// Depth-0 words after which appending `LIMIT` would be wrong or change semantics.
    static let blockers: Set<String> = ["LIMIT", "INTO", "FOR", "LOCK", "PROCEDURE", "FETCH"]

    public static func apply(to sql: String, limit: Int) -> Outcome {
        guard limit > 0 else { return Outcome(sql: sql, applied: false) }
        let lexer = SQLLexer(sql)
        let all = lexer.tokens()
        guard !all.contains(where: { $0.kind == .executableComment }) else { return Outcome(sql: sql, applied: false) }
        let tokens = all.filter { $0.kind != .comment }
        guard let first = tokens.first else { return Outcome(sql: sql, applied: false) }
        let firstWord = lexer.text(of: first).uppercased()
        guard firstWord == "SELECT" || firstWord == "WITH", SQLStatementKind.of(sql) == .query else { return Outcome(sql: sql, applied: false) }

        var depth = 0
        var lastSignificant: SQLToken?
        for token in tokens {
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" { depth = max(0, depth - 1) }
                if text == ";" { break }
            }
            if depth == 0, token.kind == .keyword || token.kind == .identifier, blockers.contains(text.uppercased()) {
                return Outcome(sql: sql, applied: false)
            }
            lastSignificant = token
        }
        guard let lastSignificant else { return Outcome(sql: sql, applied: false) }
        let insertAt = lastSignificant.range.upperBound
        let units = lexer.units
        let head = String(decoding: units[0..<insertAt], as: UTF16.self)
        let tail = String(decoding: units[insertAt...], as: UTF16.self)
        return Outcome(sql: head + " LIMIT \(limit)" + tail, applied: true)
    }
}
