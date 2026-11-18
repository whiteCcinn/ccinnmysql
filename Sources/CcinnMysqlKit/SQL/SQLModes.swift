import Foundation

/// sql_mode handling for statements checked by the app's lexer (design D10): NO_BACKSLASH_ESCAPES and ANSI_QUOTES
/// change how the server tokenizes strings and quotes, so a session running guarded SQL must not use them.
public enum SQLModes {
    /// Modes that change how the server reads SQL beyond what the app models (NO_BACKSLASH_ESCAPES, ANSI_QUOTES): other
    /// dialects' grammars (MariaDB's ORACLE, MSSQL, …), `||` as concatenation, function names as reserved words, operator
    /// precedence, and the old MYSQL323 / MYSQL40 combinations.
    public static let unmodelled: Set<String> = ["ORACLE", "MSSQL", "DB2", "POSTGRESQL", "MAXDB", "ANSI", "PIPES_AS_CONCAT", "IGNORE_SPACE",
                                                 "HIGH_NOT_PRECEDENCE", "MYSQL323", "MYSQL40"]
    static let lexerAffecting: Set<String> = unmodelled.union(["NO_BACKSLASH_ESCAPES", "ANSI_QUOTES"])

    public static func affectsLexing(_ mode: String) -> Bool {
        components(mode).contains { lexerAffecting.contains($0) }
    }

    /// The same mode without NO_BACKSLASH_ESCAPES, ANSI_QUOTES and the ANSI combination (whose other parts stay).
    public static func withoutLexerAffectingModes(_ mode: String) -> String {
        components(mode).filter { !lexerAffecting.contains($0) && $0.allSatisfy { $0.isLetter || $0 == "_" } }.joined(separator: ",")
    }

    static func components(_ mode: String) -> [String] {
        mode.uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// How a session tokenizes SQL. Under sql_mode NO_BACKSLASH_ESCAPES a backslash in a string is an ordinary character
/// (`'C:\'` is complete); under ANSI_QUOTES (also part of ANSI) `"…"` is a quoted name, in which backslashes never escape.
/// Everything that splits or lexes the user's SQL (run, format, local checks, highlighting) must use the session's mode.
public struct SQLLexingMode: Sendable, Equatable, Hashable {
    public var backslashEscapes: Bool
    public var ansiQuotes: Bool
    /// Active modes the app does not model (`SQLModes.unmodelled`), sorted: SQL is then not formatted, and splitting it
    /// cannot be relied on.
    public var unmodelledModes: [String]

    public init(backslashEscapes: Bool = true, ansiQuotes: Bool = false, unmodelledModes: [String] = []) {
        self.backslashEscapes = backslashEscapes
        self.ansiQuotes = ansiQuotes
        self.unmodelledModes = unmodelledModes
    }

    /// The mode in `@@SESSION.sql_mode` (a comma-separated list; `ANSI` includes ANSI_QUOTES).
    public init(sqlMode: String) {
        let parts = Set(SQLModes.components(sqlMode))
        self.init(backslashEscapes: !parts.contains("NO_BACKSLASH_ESCAPES"), ansiQuotes: parts.contains("ANSI_QUOTES") || parts.contains("ANSI"),
                  unmodelledModes: parts.intersection(SQLModes.unmodelled).sorted())
    }

    /// The servers' default, and what MCP read-only sessions enforce.
    public static let standard = SQLLexingMode()
    /// Every combination: text that lexes the same under all of them does not depend on the session's mode.
    public static let all = [true, false].flatMap { escapes in [false, true].map { SQLLexingMode(backslashEscapes: escapes, ansiQuotes: $0) } }
}

extension SQLLexingMode {
    /// Whether running `sql` may change how the session reads SQL (its sql_mode or character set), so they should be read
    /// again: any SET (`SET CHARACTER SET gbk`, `SET NAMES`, `SET sql_mode`, `SET STATEMENT … FOR`, `SET @@…`, also inside a
    /// compound statement), a CALL (a procedure can run SET), or an executable comment (`/*!40101 SET NAMES gbk */`).
    /// Strings, quoted names and comments do not count. The text is read with and without backslash escapes, so a mode
    /// known wrongly cannot hide a SET; saying yes too often costs one query.
    public static func mayBeChanged(by sql: String, readAs mode: SQLLexingMode) -> Bool {
        var otherReading = mode
        otherReading.backslashEscapes.toggle()
        return [mode, otherReading].contains { reading in
            let lexer = SQLLexer(sql, mode: reading)
            return lexer.tokens().contains { token in
                switch token.kind {
                case .executableComment:
                    true
                case .keyword, .identifier:
                    ["SET", "CALL"].contains(SQLLexer.asciiUppercased(lexer.units[token.range]) ?? "")
                default:
                    false
                }
            }
        }
    }
}
