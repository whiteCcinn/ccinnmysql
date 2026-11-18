import Foundation

/// One function call in a statement, as MySQL and MariaDB read it.
public struct SQLFunctionCall: Sendable, Equatable {
    public enum Form: Sendable, Equatable {
        /// `name(`: a native when the name is one, else a loadable or stored function of the session database.
        case plain
        /// `` `name`( ``: looked up by name, which skips the natives the grammar parses (COUNT, CAST, …).
        case quoted
        /// `db.name(`: always a stored function.
        case qualified
    }

    /// The name as written, back-quotes removed.
    public let name: String
    public let form: Form
    /// The schema of a qualified call (`db` in `db.name(`).
    public let qualifier: String?
    /// Whitespace or a comment between the name and `(`.
    public let spaced: Bool
    /// The word before the call, upper-case when written in ASCII (punctuation as written), empty at the start or when the
    /// word holds other letters.
    public let previousWord: String
    /// In a table position: right after FROM or a JOIN, or after a comma of a FROM clause at the same depth.
    public let isTableReference: Bool
}

/// Finds the function calls in a statement's tokens (comments removed), the way the read-only guard needs them: `name(`
/// and `` `name`( ``, also with whitespace or comments before `(`; `db.name(`; keyword-style functions (CAST, CONVERT,
/// CHAR, IF, INSERT(), REPLACE(), LEFT, RIGHT, …). A word before `(` is not a call only where the server cannot read it as
/// one: a word reserved on every supported server (IN, EXISTS, VALUES, ON, USING, …); ANY, SOME, LATERAL, EXCEPT and
/// INTERSECT before a subquery; OF after MEMBER; PARTITION after a table name; an alias column list (`AS t(a)`, `) t(a)`, a
/// CTE's `c(a) AS (`); a type after AS or RETURNING, in CONVERT's second argument, or in JSON_TABLE's COLUMNS. Keywords
/// match only in their exact ASCII spelling (`sélect(` is a name to the server). Anything else before `(` is a call.
public enum SQLFunctionCalls {
    /// Words reserved on every supported server (`SQLKeywords.reservedEverywhere`) that precede `(` as syntax.
    static let syntax: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "AND", "OR", "XOR", "NOT", "ON", "USING", "IN", "EXISTS", "ALL", "AS", "WITH", "VALUES", "JOIN",
        "STRAIGHT_JOIN", "UNION", "BY", "WHEN", "THEN", "ELSE", "CASE", "BETWEEN", "LIKE", "REGEXP", "RLIKE", "IS", "DIV", "DISTINCT",
        "DISTINCTROW", "INDEX", "KEY", "BINARY", "EXPLAIN", "DESCRIBE", "DESC", "ANALYZE", "TABLE", "LIMIT",
    ]

    /// Syntax only before a subquery (not reserved on every server, so a call elsewhere).
    static let beforeSubquery: Set<String> = ["ANY", "SOME", "LATERAL", "EXCEPT", "INTERSECT"]

    private enum Frame { case call(String), columns, other }

    /// The keywords that start a clause; the latest one at each parenthesis depth says where a comma-separated item stands.
    static let clauseWords: Set<String> = ["SELECT", "FROM", "JOIN", "STRAIGHT_JOIN", "WHERE", "ON", "USING", "GROUP", "HAVING", "ORDER", "LIMIT",
                                           "UNION", "EXCEPT", "INTERSECT", "WINDOW", "SET", "VALUES"]

    public static func calls(in tokens: [SQLToken], lexer: SQLLexer) -> [SQLFunctionCall] {
        /// The token in its exact ASCII spelling, upper-cased; empty when it holds other characters.
        func exact(_ index: Int) -> String {
            let text = lexer.text(of: tokens[index])
            return text.unicodeScalars.allSatisfy(\.isASCII) ? text.uppercased() : ""
        }
        func isPunctuation(_ index: Int, _ text: String) -> Bool {
            tokens[index].kind == .punctuation && lexer.text(of: tokens[index]) == text
        }
        var closing = [Int?](repeating: nil, count: tokens.count)
        var open: [Int] = []
        for index in tokens.indices {
            if isPunctuation(index, "(") {
                open.append(index)
            } else if isPunctuation(index, ")"), let start = open.popLast() {
                closing[start] = index
            }
        }
        var calls: [SQLFunctionCall] = []
        var frames: [Frame] = []
        var clauses = [""] // the latest clause keyword at each depth (top level first)
        var nextFrame: Frame?
        for index in tokens.indices {
            if isPunctuation(index, "(") {
                frames.append(nextFrame ?? .other)
                clauses.append("")
                nextFrame = nil
                continue
            }
            if isPunctuation(index, ")") {
                _ = frames.popLast()
                if clauses.count > 1 { clauses.removeLast() }
                continue
            }
            if tokens[index].kind == .keyword, clauseWords.contains(exact(index)) { clauses[clauses.count - 1] = exact(index) }
            let kind = tokens[index].kind
            guard [.identifier, .keyword, .quotedIdentifier].contains(kind), index + 1 < tokens.count, isPunctuation(index + 1, "(") else { continue }
            if case .columns? = frames.last { continue } // JSON_TABLE column definitions: types, NESTED PATH … COLUMNS
            let quoted = kind == .quotedIdentifier
            let name = quoted ? lexer.identifierValue(of: tokens[index]) : lexer.text(of: tokens[index])
            let word = quoted ? "" : exact(index)
            let previous = index > 0 ? exact(index - 1) : ""
            if !word.isEmpty {
                if word == "COLUMNS", case .call("JSON_TABLE")? = frames.last {
                    nextFrame = .columns
                    continue
                }
                if syntax.contains(word) { continue }
                if beforeSubquery.contains(word), index + 2 < tokens.count, ["SELECT", "WITH", "VALUES", "TABLE", "("].contains(exact(index + 2)) { continue }
                if word == "OF", previous == "MEMBER" { continue }
                if word == "PARTITION", index > 0, [.identifier, .quotedIdentifier].contains(tokens[index - 1].kind) { continue }
            }
            // Types (`AS DECIMAL(10,2)`, `RETURNING CHAR(10)`) and alias column lists (`AS t(a)`, `) t(a)`, `MATCH (…) AGAINST (`,
            // `… ) OVER (`), back-quoted or not.
            if previous == "AS" || previous == "RETURNING" || (index > 0 && isPunctuation(index - 1, ")")) { continue }
            if case .call("CONVERT")? = frames.last, previous == "," { continue } // CONVERT(x, CHAR(10))
            // A CTE's column list: `c (a, b) AS (`.
            if let close = closing[index + 1], close + 2 < tokens.count, exact(close + 1) == "AS", isPunctuation(close + 2, "(") { continue }
            let qualified = index > 0 && isPunctuation(index - 1, ".")
            let qualifier: String? = qualified && index > 1 && [.identifier, .keyword, .quotedIdentifier].contains(tokens[index - 2].kind)
                ? lexer.identifierValue(of: tokens[index - 2]) : nil
            let spaced = tokens[index].range.upperBound != tokens[index + 1].range.lowerBound
            let tableClauses: Set<String> = ["FROM", "JOIN", "STRAIGHT_JOIN"]
            let isTableReference = tableClauses.contains(previous) || (previous == "," && tableClauses.contains(clauses.last ?? ""))
            calls.append(SQLFunctionCall(name: name, form: qualified ? .qualified : quoted ? .quoted : .plain, qualifier: qualifier, spaced: spaced,
                                         previousWord: previous, isTableReference: isTableReference))
            nextFrame = .call(word)
        }
        return calls
    }
}
