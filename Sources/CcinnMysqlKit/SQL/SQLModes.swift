import Foundation

/// sql_mode handling for statements checked by the app's lexer (design D10): NO_BACKSLASH_ESCAPES and ANSI_QUOTES
/// change how the server tokenizes strings and quotes, so a session running guarded SQL must not use them.
public enum SQLModes {
    static let lexerAffecting: Set<String> = ["NO_BACKSLASH_ESCAPES", "ANSI_QUOTES", "ANSI"]

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

    public init(backslashEscapes: Bool = true, ansiQuotes: Bool = false) {
        self.backslashEscapes = backslashEscapes
        self.ansiQuotes = ansiQuotes
    }

    /// The mode in `@@SESSION.sql_mode` (a comma-separated list; `ANSI` includes ANSI_QUOTES).
    public init(sqlMode: String) {
        let parts = Set(SQLModes.components(sqlMode))
        self.init(backslashEscapes: !parts.contains("NO_BACKSLASH_ESCAPES"), ansiQuotes: parts.contains("ANSI_QUOTES") || parts.contains("ANSI"))
    }

    /// The servers' default, and what MCP read-only sessions enforce.
    public static let standard = SQLLexingMode()
    /// Every combination: text that lexes the same under all of them does not depend on the session's mode.
    public static let all = [true, false].flatMap { escapes in [false, true].map { SQLLexingMode(backslashEscapes: escapes, ansiQuotes: $0) } }
}
