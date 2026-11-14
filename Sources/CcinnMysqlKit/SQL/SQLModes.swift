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
