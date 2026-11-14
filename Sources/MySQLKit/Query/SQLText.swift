import Foundation

/// Safe construction of identifiers and literals for statements the app builds itself.
public enum SQLText {
    /// Back-quoted identifier; embedded back-quotes are doubled, NUL bytes removed.
    public static func quoteIdentifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// `a`.`b`.`c` from the non-empty parts.
    public static func qualified(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.map(quoteIdentifier).joined(separator: ".")
    }

    /// Single-quoted string literal. With `noBackslashEscapes` (sql_mode NO_BACKSLASH_ESCAPES, reported in the
    /// server status flags) only quotes are doubled; otherwise backslashes and control characters are escaped too.
    public static func literal(_ value: String, noBackslashEscapes: Bool) -> String {
        guard noBackslashEscapes else { return literal(value) }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Single-quoted string literal with backslash and quote escaping (MySQL default SQL mode).
    public static func literal(_ value: String) -> String {
        var escaped = "'"
        escaped.reserveCapacity(value.utf8.count + 2)
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "'": escaped += "''"
            case "\0": escaped += "\\0"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\u{1A}": escaped += "\\Z"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return escaped + "'"
    }
}
