import Foundation

/// A condition typed into the Data tab's filter (`geo = 'US' AND total > 10`). It is sent as typed, in parentheses
/// ahead of the page's own condition, so it is checked to be one condition that can only narrow the rows: no `;`,
/// balanced parentheses, no unterminated string or comment, no executable comment, and none of the clauses that would
/// reshape the query (ORDER BY, LIMIT, UNION, INTO, …) outside parentheses (a subquery may use them).
public struct TableFilter: Sendable, Equatable {
    /// As typed, trimmed, without a leading `WHERE`.
    public let condition: String
    /// The condition in parentheses; a trailing line comment ends on its own line first.
    public let sql: String

    public struct Refusal: Error, Equatable {
        public let message: String
    }

    /// Clauses that end a WHERE condition and start something else.
    static let clauses: Set<String> = ["ORDER", "LIMIT", "UNION", "INTERSECT", "EXCEPT", "INTO", "PROCEDURE", "GROUP",
                                       "HAVING", "WINDOW", "FROM", "WHERE", "SELECT"]
    /// Locking clauses: `FOR UPDATE`, `FOR SHARE`, `LOCK IN SHARE MODE` (`lock` alone may be a column).
    static let lockingClauses: [String: Set<String>] = ["FOR": ["UPDATE", "SHARE"], "LOCK": ["IN"]]

    /// `nil`: nothing typed, no filter.
    public static func parse(_ text: String) -> Result<TableFilter?, Refusal> {
        var condition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = SQLLexer(condition)
        if let first = leading.tokens().first, first.kind == .keyword, leading.text(of: first).uppercased() == "WHERE" {
            condition = leading.text(in: first.range.upperBound..<leading.units.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !condition.isEmpty else { return .success(nil) }

        // A closing parenthesis on a line of its own survives only if every string, name and comment is closed.
        let probe = condition + "\n)"
        let lexer = SQLLexer(probe)
        var tokens = lexer.tokens()
        guard let sentinel = tokens.last, sentinel.kind == .punctuation, sentinel.range == (lexer.units.count - 1)..<lexer.units.count else {
            return .failure(Refusal(message: "A string, back-quoted name or comment is not closed."))
        }
        tokens.removeLast()
        var depth = 0
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : "" }
        for (index, token) in tokens.enumerated() {
            let text = lexer.text(of: token)
            if depth == 0, let following = lockingClauses[words[index]], index + 1 < words.count, following.contains(words[index + 1]) {
                return .failure(Refusal(message: "“\(words[index]) \(words[index + 1])” is not part of a condition; the filter can only narrow the rows."))
            }
            switch token.kind {
            case .executableComment:
                return .failure(Refusal(message: "Executable comments (/*! … */) are not allowed in a filter."))
            case .punctuation where text == ";":
                return .failure(Refusal(message: "A filter is one condition: remove the “;”."))
            case .punctuation where text == "(":
                depth += 1
            case .punctuation where text == ")":
                depth -= 1
                if depth < 0 { return .failure(Refusal(message: "A “)” closes a parenthesis that was not opened.")) }
            case .keyword where depth == 0 && clauses.contains(text.uppercased()):
                let word = text.uppercased()
                return .failure(Refusal(message: word == "ORDER"
                    ? "ORDER BY is not part of a condition: click a column header to sort."
                    : "“\(word)” is not part of a condition; the filter can only narrow the rows."))
            default:
                break
            }
        }
        guard depth == 0 else { return .failure(Refusal(message: "A “(” is not closed.")) }
        let endsWithLineComment = tokens.last.map { $0.kind == .comment && !lexer.text(of: $0).hasPrefix("/*") } ?? false
        return .success(TableFilter(condition: condition, sql: "(" + condition + (endsWithLineComment ? "\n)" : ")")))
    }
}
