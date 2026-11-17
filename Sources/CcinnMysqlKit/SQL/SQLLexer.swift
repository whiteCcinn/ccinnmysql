import Foundation

/// One lexical token. Ranges are UTF-16 offsets so they map 1:1 onto `NSRange` in the editor.
public struct SQLToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyword
        case identifier
        /// `` `name` `` (back-quoted).
        case quotedIdentifier
        case string
        case number
        case comment
        /// `/*! … */` or `/*M! … */`: MySQL/MariaDB execute the content (version-conditional code).
        case executableComment
        case `operator`
        /// `( ) , ; .`
        case punctuation
        /// `@user_var`, `@@session_var`
        case variable
    }

    public let kind: Kind
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// Tokenizer for MySQL / MariaDB SQL. Never fails: unterminated strings and comments extend to the
/// end of the input, unknown characters become operators. Linear time over UTF-16 code units.
public struct SQLLexer: Sendable {
    public let units: [UInt16]
    /// A backslash escapes the next character in strings, as the server lexes them unless sql_mode has
    /// NO_BACKSLASH_ESCAPES. Never in back-quoted identifiers.
    public let backslashEscapes: Bool
    /// `"…"` is a quoted name (sql_mode ANSI_QUOTES), in which a backslash never escapes; a string otherwise.
    public let ansiQuotes: Bool

    public init(_ text: String, backslashEscapes: Bool = true, ansiQuotes: Bool = false) {
        units = Array(text.utf16)
        self.backslashEscapes = backslashEscapes
        self.ansiQuotes = ansiQuotes
    }

    public init(_ text: String, mode: SQLLexingMode) {
        self.init(text, backslashEscapes: mode.backslashEscapes, ansiQuotes: mode.ansiQuotes)
    }

    public var mode: SQLLexingMode { SQLLexingMode(backslashEscapes: backslashEscapes, ansiQuotes: ansiQuotes) }

    public static func tokenize(_ text: String) -> [SQLToken] {
        SQLLexer(text).tokens()
    }

    /// Source text of a token (identifier quotes are kept).
    public func text(of token: SQLToken) -> String {
        text(in: token.range)
    }

    public func text(in range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, units.count))
        let upper = max(lower, min(range.upperBound, units.count))
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// Identifier value: quotes (`` ` `` or, under ANSI_QUOTES, `"`) removed and doubled quotes unescaped.
    public func identifierValue(of token: SQLToken) -> String {
        let raw = text(of: token)
        guard token.kind == .quotedIdentifier, let quote = raw.first else { return raw }
        var inner = Substring(raw.dropFirst())
        if inner.hasSuffix(String(quote)) { inner = inner.dropLast() }
        return inner.replacingOccurrences(of: String(repeating: quote, count: 2), with: String(quote))
    }

    public func tokens() -> [SQLToken] {
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(units.count / 4)
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            let start = index
            switch unit {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C:
                index += 1
                continue
            case 0x2D where peek(index + 1) == 0x2D && Self.endsDashComment(peek(index + 2)): // "-- " (MySQL needs a space)
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x23: // # (MySQL line comment)
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x2F where peek(index + 1) == 0x2A: // /*
                let executable = peek(index + 2) == 0x21 || (peek(index + 2) == 0x4D && peek(index + 3) == 0x21) // /*! or /*M!
                index += 2
                while index < count, !(units[index] == 0x2A && peek(index + 1) == 0x2F) { index += 1 }
                index = min(count, index + 2)
                tokens.append(SQLToken(kind: executable ? .executableComment : .comment, range: start..<index))
            case 0x22 where ansiQuotes: // "name" under ANSI_QUOTES
                index = endOfQuoted(from: index, quote: unit, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: start..<index))
            case 0x27, 0x22: // ' or "
                index = endOfQuoted(from: index, quote: unit, backslashEscapes: backslashEscapes)
                tokens.append(SQLToken(kind: .string, range: start..<index))
            case 0x60: // `
                index = endOfQuoted(from: index, quote: unit, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: start..<index))
            case 0x40: // @ / @@
                index += 1
                if peek(index) == 0x40 { index += 1 }
                if peek(index) == 0x60 {
                    index = endOfQuoted(from: index, quote: 0x60, backslashEscapes: false)
                } else {
                    while index < count, Self.isIdentifierPart(units[index]) || units[index] == 0x2E { index += 1 }
                }
                tokens.append(SQLToken(kind: .variable, range: start..<index))
            case 0x5C where peek(index + 1) == 0x4E: // `\N`: NULL on MariaDB and MySQL 5.x, which end it after the N
                index += 2
                tokens.append(SQLToken(kind: .keyword, range: start..<index))
            case 0x30...0x39 where followsMemberAccess(tokens, at: index):
                // `t.5e`, `t.1abc`: after `name.` the server reads a name, whatever it starts with.
                index = endOfWord(from: index)
                tokens.append(SQLToken(kind: .identifier, range: start..<index))
            case 0x30...0x39:
                let number = scanNumber(from: index)
                index = number.end
                tokens.append(SQLToken(kind: number.isName ? .identifier : .number, range: start..<index))
            case 0x2E where peek(index + 1).map(Self.isDigit) == true && !isMemberAccess(tokens, at: index):
                index = scanNumber(from: index).end
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x28, 0x29, 0x2C, 0x3B, 0x2E: // ( ) , ; .
                index += 1
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            default:
                if let end = endOfBitOrHexString(from: index), !followsMemberAccess(tokens, at: index) { // X'4D', b'01'
                    index = end
                    tokens.append(SQLToken(kind: .number, range: start..<index))
                } else if Self.isIdentifierStart(unit) {
                    index = endOfWord(from: index)
                    // Keywords are ASCII: Unicode case mapping would read `ﬁrst` as FIRST or `ſelect` as SELECT.
                    let isKeyword = Self.asciiUppercased(units[start..<index]).map(SQLKeywords.all.contains) ?? false
                    tokens.append(SQLToken(kind: isKeyword ? .keyword : .identifier, range: start..<index))
                } else {
                    index += 1
                    // Combine multi-character operators: <= >= <> != || && := <=> ->
                    while index < count, Self.isOperatorContinuation(units[index]), index - start < 3 { index += 1 }
                    tokens.append(SQLToken(kind: .operator, range: start..<index))
                }
            }
        }
        return tokens
    }

    // MARK: Scanners

    private func peek(_ index: Int) -> UInt16? { index < units.count ? units[index] : nil }

    /// `t.5` is member access, `.5` alone is a number. The server decides by the word before the dot: an unquoted one
    /// (`t`, `date`, `1abc`) is a name followed by `.`; after a back-quoted name (`` `t`.5 ``) `.5` is a number.
    private func isMemberAccess(_ tokens: [SQLToken], at index: Int) -> Bool {
        guard let last = tokens.last, last.range.upperBound == index else { return false }
        return last.kind == .identifier || last.kind == .keyword
    }

    /// The token starting at `index` directly follows a member-access `.` (`t.|5e`): the server reads a name there.
    private func followsMemberAccess(_ tokens: [SQLToken], at index: Int) -> Bool {
        Self.followsMemberAccess(tokens, count: tokens.count, at: index, units: units)
    }

    /// Whether `tokens[..<count]` ends with `word.` touching `index`.
    private static func followsMemberAccess(_ tokens: [SQLToken], count: Int, at index: Int, units: [UInt16]) -> Bool {
        guard count >= 2, count <= tokens.count, index > 0 else { return false }
        let dot = tokens[count - 1]
        let word = tokens[count - 2]
        return dot.kind == .punctuation && dot.range == (index - 1)..<index && units[index - 1] == 0x2E
            && word.range.upperBound == index - 1 && (word.kind == .identifier || word.kind == .keyword)
    }

    /// Line comments end where the server ends them: at `\n` or a NUL byte (not at `\r`).
    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A, units[index] != 0x00 { index += 1 }
        return index
    }

    private func endOfQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        scanQuoted(from: index, quote: quote, backslashEscapes: backslashEscapes).end
    }

    private func scanQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool) -> (end: Int, closed: Bool) {
        var index = index + 1
        while index < units.count {
            let unit = units[index]
            if backslashEscapes, unit == 0x5C {
                index += 2
                continue
            }
            if unit == quote {
                if peek(index + 1) == quote {
                    index += 2
                    continue
                }
                return (index + 1, true)
            }
            index += 1
        }
        return (units.count, false)
    }

    /// A `--` or `#` comment (it runs to the next `\n`); block comments start with `/`.
    public func isLineComment(_ token: SQLToken) -> Bool {
        token.kind == .comment && token.range.lowerBound < units.count && units[token.range.lowerBound] != 0x2F
    }

    /// A string, back-quoted identifier or `/* */` comment (executable or not) that runs to the end of the
    /// input without its closing delimiter. Only the last token can be unterminated, so this rescans at most once.
    public func isUnterminated(_ token: SQLToken) -> Bool {
        let start = token.range.lowerBound
        guard token.range.upperBound >= units.count, start >= 0, start < units.count else { return false }
        switch token.kind {
        case .string:
            return !scanQuoted(from: start, quote: units[start], backslashEscapes: backslashEscapes).closed
        case .quotedIdentifier:
            return !scanQuoted(from: start, quote: units[start], backslashEscapes: false).closed
        case .comment, .executableComment:
            guard units[start] == 0x2F else { return false } // `--` and `#` comments end at the line end
            let end = token.range.upperBound
            return token.range.count < 4 || !(units[end - 2] == 0x2A && units[end - 1] == 0x2F)
        default:
            return false
        }
    }

    /// The end of a run of name characters (letters, digits, `_`, `$`, anything outside ASCII).
    private func endOfWord(from index: Int) -> Int {
        var index = index
        while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
        return index
    }

    /// A token starting with a digit (or `.digit`), decided as MySQL and MariaDB decide it (`lex_one_token` in
    /// sql_lex.cc; every rule checked on live servers by the integration tests):
    /// - `0x` + hex digits and `0b` + binary digits are numbers unless a name character follows (`0x1g`, `0b12`, and
    ///   `0X41` with a capital X, are names);
    /// - digits followed by name characters are a name (`1abc`, `1e`, `1e+x` is `1e` + `x`), except an exponent with
    ///   digits, which ends the number (`1e2x` is `1e2` + `x`);
    /// - a decimal (`1.`, `1.5`, `.5`) ends after its digits (`1.5x` is `1.5` + `x`), and an `e` after it must start
    ///   an exponent: `1.e`, `1.end`, `.5e+x` are rejected by the server (kept whole here and flagged as malformed).
    private func scanNumber(from start: Int) -> (end: Int, isName: Bool, isMalformed: Bool) {
        if units[start] == 0x2E { return scanFraction(from: start + 1) }
        if units[start] == 0x30, let marker = peek(start + 1), marker == 0x78 || marker == 0x62 { // 0x… 0b…
            let hex = marker == 0x78
            var index = start + 2
            while index < units.count, hex ? Self.isHexDigit(units[index]) : Self.isBinaryDigit(units[index]) { index += 1 }
            if index > start + 2, !(peek(index).map(Self.isIdentifierPart) ?? false) { return (index, false, false) }
            return (endOfWord(from: start), true, false)
        }
        var index = start
        while index < units.count, Self.isDigit(units[index]) { index += 1 }
        guard let next = peek(index) else { return (index, false, false) }
        if !Self.isIdentifierPart(next) {
            return next == 0x2E ? scanFraction(from: index + 1) : (index, false, false)
        }
        if next == 0x65 || next == 0x45 { // `1e5`, `1e+5`: an exponent with digits ends the number
            var exponent = index + 1
            if let sign = peek(exponent), sign == 0x2B || sign == 0x2D { exponent += 1 }
            if let digit = peek(exponent), Self.isDigit(digit) {
                while exponent < units.count, Self.isDigit(units[exponent]) { exponent += 1 }
                return (exponent, false, false)
            }
        }
        return (endOfWord(from: start), true, false)
    }

    /// The rest of a decimal from just after its `.`: digits, then an optional exponent that must have digits.
    private func scanFraction(from index: Int) -> (end: Int, isName: Bool, isMalformed: Bool) {
        var index = index
        while index < units.count, Self.isDigit(units[index]) { index += 1 }
        guard let e = peek(index), e == 0x65 || e == 0x45 else { return (index, false, false) }
        var exponent = index + 1
        if let sign = peek(exponent), sign == 0x2B || sign == 0x2D { exponent += 1 }
        guard let digit = peek(exponent), Self.isDigit(digit) else {
            // Rejected by the server; keep the word glued to it so nothing inside (`1.end`) reads as a keyword.
            return (endOfWord(from: exponent), false, true)
        }
        while exponent < units.count, Self.isDigit(units[exponent]) { exponent += 1 }
        return (exponent, false, false)
    }

    /// The end of a well-formed `X'4D'` / `b'01'` literal starting at `index` (one token for the server: an even number
    /// of hex digits, or binary digits, between the quotes); `nil` for anything else, which lexes as a name and a string.
    private func endOfBitOrHexString(from index: Int) -> Int? {
        let marker = units[index] | 0x20 // ASCII lower case
        guard marker == 0x78 || marker == 0x62, peek(index + 1) == 0x27 else { return nil }
        let hex = marker == 0x78
        var close = index + 2
        while close < units.count, hex ? Self.isHexDigit(units[close]) : Self.isBinaryDigit(units[close]) { close += 1 }
        guard peek(close) == 0x27, !hex || (close - index - 2) % 2 == 0 else { return nil }
        return close + 1
    }

    /// A literal the server rejects while lexing: a decimal with an incomplete exponent (`1.e`, `1.end`), or a malformed
    /// `X'…'` / `b'…'` (`x'4'`, `x'4g'`, `b'12'`, unclosed), which lexes here as a one-letter name glued to a string.
    /// Token boundaries after such a literal are guesswork, so the formatter refuses text that contains one.
    public func containsMalformedLiteral(_ tokens: [SQLToken]) -> Bool {
        for (position, token) in tokens.enumerated() {
            let start = token.range.lowerBound
            guard start < units.count else { continue }
            switch token.kind {
            case .number where Self.isDigit(units[start]) || units[start] == 0x2E:
                if scanNumber(from: start).isMalformed { return true }
            case .identifier where token.range.count == 1:
                let marker = units[start] | 0x20
                guard marker == 0x78 || marker == 0x62, position + 1 < tokens.count else { continue }
                let next = tokens[position + 1]
                if next.kind == .string, next.range.lowerBound == token.range.upperBound, units[next.range.lowerBound] == 0x27,
                   !Self.followsMemberAccess(tokens, count: position, at: start, units: units) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// A backslash outside strings, back-quoted names and comments. MariaDB and MySQL 5.x read `\N` as NULL and end it
    /// after the N (`\Nlock` is NULL LOCK), MySQL 8 rejects it, and any other `\` there is an error whose token
    /// boundaries differ between servers. The read-only guard and the formatter refuse text that has one.
    public func containsBareBackslash(_ tokens: [SQLToken]) -> Bool {
        tokens.contains { token in
            switch token.kind {
            case .string, .quotedIdentifier, .comment, .executableComment:
                return false
            case .variable:
                // `@`name\`` keeps its backslash inside the back-quotes.
                return units[token.range].prefix { $0 != 0x60 }.contains(0x5C)
            default:
                return units[token.range].contains(0x5C)
            }
        }
    }

    /// The ASCII upper-case form of a word, or `nil` when it has a character outside ASCII (never a keyword).
    public static func asciiUppercased(_ units: some Collection<UInt16>) -> String? {
        var upper: [UInt16] = []
        upper.reserveCapacity(units.count)
        for unit in units {
            guard unit < 0x80 else { return nil }
            upper.append(unit >= 0x61 && unit <= 0x7A ? unit - 0x20 : unit)
        }
        return String(decoding: upper, as: UTF16.self)
    }

    /// `--` starts a comment only before whitespace, a control character (incl. DEL) or the end of input, exactly as
    /// the server's lexer decides (`1--1` is arithmetic).
    static func endsDashComment(_ unit: UInt16?) -> Bool {
        guard let unit else { return true }
        return unit <= 0x20 || unit == 0x7F
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isBinaryDigit(_ unit: UInt16) -> Bool { unit == 0x30 || unit == 0x31 }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit >= 0x80
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    static func isOperatorContinuation(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x3D, 0x3E, 0x3C, 0x7C, 0x26, 0x21: true // = > < | & !
        default: false
        }
    }
}
