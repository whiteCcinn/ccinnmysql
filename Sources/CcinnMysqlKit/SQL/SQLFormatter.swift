import Foundation

/// How `SQLFormatter` lays out SQL.
public struct SQLFormatOptions: Sendable, Equatable {
    public enum KeywordCase: String, Sendable, CaseIterable, Identifiable {
        case upper, lower, preserve
        public var id: String { rawValue }
    }

    public var keywordCase: KeywordCase
    /// Spaces per indent level, always 1…8: every assignment is clamped, so no value can make the formatter trap.
    public var indentWidth: Int {
        get { clampedIndentWidth }
        set { clampedIndentWidth = Self.clamped(newValue) }
    }
    /// Lex strings as the session does: false when its sql_mode has NO_BACKSLASH_ESCAPES.
    public var backslashEscapes: Bool
    /// `"…"` is a quoted name, as under the session's sql_mode ANSI_QUOTES.
    public var ansiQuotes: Bool
    /// Active sql_modes the formatter does not model (ORACLE, PIPES_AS_CONCAT, …): nothing is formatted.
    public var unmodelledSQLModes: [String]
    /// Whether the session's sql_mode and character set are known. When they are not, text that lexes differently under
    /// NO_BACKSLASH_ESCAPES, ANSI_QUOTES or another character set (a backslash in a string, a `"…"` token, a character
    /// outside ASCII) is not formatted.
    public var sessionModeKnown: Bool
    /// The session's character set (`@@character_set_client`), when known. The app sends UTF-8; in any other multibyte
    /// character set a byte such as 0x5C can be part of a character, so nothing is formatted unless it is one of
    /// `SQLFormatter.safeCharsets`.
    public var sessionCharset: String?
    private var clampedIndentWidth: Int

    public init(keywordCase: KeywordCase = .upper, indentWidth: Int = 2, backslashEscapes: Bool = true, ansiQuotes: Bool = false,
                sessionModeKnown: Bool = true, sessionCharset: String? = nil) {
        self.keywordCase = keywordCase
        clampedIndentWidth = Self.clamped(indentWidth)
        self.backslashEscapes = backslashEscapes
        self.ansiQuotes = ansiQuotes
        unmodelledSQLModes = []
        self.sessionModeKnown = sessionModeKnown
        self.sessionCharset = sessionCharset
    }

    public var lexingMode: SQLLexingMode {
        get { SQLLexingMode(backslashEscapes: backslashEscapes, ansiQuotes: ansiQuotes, unmodelledModes: unmodelledSQLModes) }
        set {
            backslashEscapes = newValue.backslashEscapes
            ansiQuotes = newValue.ansiQuotes
            unmodelledSQLModes = newValue.unmodelledModes
        }
    }

    /// The session's character set reads UTF-8 text as the app sends it (latin1 and ASCII have no multibyte characters).
    public var sessionCharsetIsSafe: Bool { sessionCharset.map { SQLFormatter.safeCharsets.contains($0.lowercased()) } ?? true }

    /// Whether this session's text can be formatted at all: no unmodelled sql_mode, a safe character set.
    var sessionAllowsFormatting: Bool { unmodelledSQLModes.isEmpty && sessionCharsetIsSafe }

    static func clamped(_ width: Int) -> Int { min(max(width, 1), 8) }
}

/// A formatted part of a text: replace `range` (UTF-16, whole tokens) of the original with `replacement`.
public struct SQLFormatEdit: Sendable, Equatable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Formats MySQL / MariaDB SQL by deciding the whitespace between the lexer's tokens (design D1–D9).
///
/// Only whitespace and the letter case of *safe* words change: words every supported server reserves, and words recognised
/// by a position where they cannot be names. Tokens that touch in the input keep touching unless whitespace between them
/// is known not to matter (`COUNT (*)`, `X'41'`, `\N`, `t.order` mean something else when split or joined). The result is
/// re-lexed and compared with the input, and the statement splitter must see the same statements; otherwise the formatter
/// returns `nil` rather than a text that might mean something else. It also returns `nil` when its task is cancelled or
/// the text would grow out of proportion.
public enum SQLFormatter {
    /// Deepest indent level written; deeper structure keeps this indent.
    public static let maxIndentLevel = 16

    /// The longest formatted text accepted for an input of `length` UTF-16 units (16× plus some slack).
    public static func maxOutputLength(forInputLength length: Int) -> Int {
        16 * max(0, length) + 4_096
    }

    /// Character sets in which the app's UTF-8 text reads as written.
    public static let safeCharsets: Set<String> = ["utf8mb4", "utf8mb3", "utf8", "ascii", "latin1"]

    public static func format(_ text: String, options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        layout(text, options: options)?.text
    }

    /// Formats the part of `text` in `range` (UTF-16). A range that starts or ends inside a token is widened to whole tokens
    /// of `text` (and to whole qualified names, which MySQL reads differently in part), whitespace around the tokens stays
    /// outside the edit, and the whole text with the replacement is checked against the original: same tokens, letter case
    /// changed only where the formatter marked it. `nil` when the range is invalid or the part cannot be formatted safely.
    public static func formatSelection(in text: String, range: NSRange, options: SQLFormatOptions = SQLFormatOptions()) -> SQLFormatEdit? {
        let lexer = SQLLexer(text, mode: options.lexingMode)
        let count = lexer.units.count
        // Not NSMaxRange: `location + length` overflows (and traps) for NSNotFound.
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location else { return nil }
        guard !Task.isCancelled, options.sessionAllowsFormatting, options.sessionModeKnown || !dependsOnSession(text) else { return nil }
        let tokens = lexer.tokens()
        guard let span = tokenSpan(of: range, in: tokens, lexer: lexer) else {
            return SQLFormatEdit(range: range, replacement: lexer.text(in: range.location..<NSMaxRange(range))) // nothing to format
        }
        let start = tokens[span.lowerBound].range.lowerBound
        let snapped = start..<tokens[span.upperBound - 1].range.upperBound
        let fragment = lexer.text(in: snapped)
        // The fragment must lex exactly as that part of the whole text, or it is not the same SQL.
        let fragmentTokens = SQLLexer(fragment, mode: options.lexingMode).tokens()
        guard fragmentTokens.count == span.count,
              zip(fragmentTokens, tokens[span]).allSatisfy({ $0.kind == $1.kind && $0.range.lowerBound + start == $1.range.lowerBound
                  && $0.range.upperBound + start == $1.range.upperBound }) else { return nil }
        // The fragment keeps the CASE words its statement in the whole text does not prove (`case … end end`: alone,
        // `case … end` would be proven; a fragment of a procedure body is still in a compound statement).
        let wholeFrozen = frozenCaseWordOffsets(text, lexer: lexer, tokens: tokens)
        let frozen = Set(span.map { tokens[$0].range.lowerBound }.filter(wholeFrozen.contains).map { $0 - start })
        guard let formatted = layout(fragment, options: options, lineBreak: lineBreak(of: lexer, tokens), frozenOffsets: frozen) else { return nil }
        let spliced = lexer.text(in: 0..<start) + formatted.text + lexer.text(in: snapped.upperBound..<lexer.units.count)
        let marked = Set(formatted.caseChangeable.map { $0 + start })
        let changeable = Set(span.filter { marked.contains(tokens[$0].range.lowerBound) })
        guard !Task.isCancelled,
              equivalent(lexer: lexer, tokens: tokens, to: spliced, caseChangeable: changeable, mode: options.lexingMode),
              sameStatements(text, spliced, mode: options.lexingMode) else { return nil }
        return SQLFormatEdit(range: NSRange(location: start, length: snapped.count), replacement: formatted.text)
    }

    /// The tokens a selection touches, widened across `.` so a qualified name is never split; `nil` when it touches none.
    static func tokenSpan(of range: NSRange, in tokens: [SQLToken], lexer: SQLLexer) -> Range<Int>? {
        let lower = range.location
        let upper = NSMaxRange(range)
        // First token ending after the start (a token the start is inside counts), last token starting before the end.
        guard var first = tokens.firstIndex(where: { $0.range.upperBound > lower }),
              var last = tokens.lastIndex(where: { $0.range.lowerBound < upper }), first <= last else { return nil }
        let isDot: (Int) -> Bool = { tokens[$0].kind == .punctuation && lexer.units[tokens[$0].range.lowerBound] == 0x2E }
        while first > 0, isDot(first) || isDot(first - 1) { first -= 1 }
        while last + 1 < tokens.count, isDot(last) || isDot(last + 1) { last += 1 }
        return first..<(last + 1)
    }

    /// The offset in `formatted` that corresponds to `offset` in `original`: the position after the same number of
    /// non-whitespace UTF-16 units. Exact for formatter output, which only changes whitespace and letter case.
    public static func mapOffset(_ offset: Int, from original: String, to formatted: String) -> Int {
        let source = Array(original.utf16)
        let target = Array(formatted.utf16)
        let end = min(max(0, offset), source.count)
        let count = source[..<end].reduce(0) { $0 + (isWhitespace($1) ? 0 : 1) }
        var index = 0
        var seen = 0
        while index < target.count, seen < count {
            if !isWhitespace(target[index]) { seen += 1 }
            index += 1
        }
        return index
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    /// Same tokens in the same order with the same texts, except the letter case of keywords. A coarse check (any
    /// keyword may differ in case); the formatter itself only accepts case changes it marked.
    public static func sameTokens(_ lhs: String, _ rhs: String, backslashEscapes: Bool = true, ansiQuotes: Bool = false) -> Bool {
        sameTokens(lhs, rhs, mode: SQLLexingMode(backslashEscapes: backslashEscapes, ansiQuotes: ansiQuotes))
    }

    static func sameTokens(_ lhs: String, _ rhs: String, mode: SQLLexingMode) -> Bool {
        let left = SQLLexer(lhs, mode: mode)
        let leftTokens = left.tokens()
        let keywordIndices = Set(leftTokens.indices.filter { leftTokens[$0].kind == .keyword })
        return equivalent(lexer: left, tokens: leftTokens, to: rhs, caseChangeable: keywordIndices, mode: mode)
    }

    /// Whether `text` lexes differently under some sql_mode: a backslash in a string or quoted name (NO_BACKSLASH_ESCAPES),
    /// or a `"…"` token (ANSI_QUOTES). Without any, every mode reads the same tokens: a string can only end at another place
    /// because of a backslash or a different quote character, and everything else is read the same in every mode.
    public static func dependsOnLexingMode(_ text: String) -> Bool {
        let lexer = SQLLexer(text)
        return lexer.tokens().contains { token in
            (token.kind == .string || token.kind == .quotedIdentifier)
                && (lexer.units[token.range.lowerBound] == 0x22 || lexer.units[token.range].contains(0x5C))
        }
    }

    /// Whether `text` could read differently depending on the session: `dependsOnLexingMode`, or a character outside
    /// ASCII outside comments (in a multibyte character set such as GBK its bytes can swallow the quote or backslash after
    /// them). Comments are safe: they end at `*/` or a line break, bytes no such character set uses inside a character.
    public static func dependsOnSession(_ text: String) -> Bool {
        if dependsOnLexingMode(text) { return true }
        let lexer = SQLLexer(text)
        return lexer.tokens().contains { $0.kind != .comment && lexer.units[$0.range].contains { $0 >= 0x80 } }
    }

    static func equivalent(lexer: SQLLexer, tokens: [SQLToken], to output: String, caseChangeable: Set<Int>, mode: SQLLexingMode) -> Bool {
        let outLexer = SQLLexer(output, mode: mode)
        let outTokens = outLexer.tokens()
        guard outTokens.count == tokens.count else { return false }
        for index in tokens.indices {
            let original = lexer.units[tokens[index].range]
            let formatted = outLexer.units[outTokens[index].range]
            guard tokens[index].kind == outTokens[index].kind, original.count == formatted.count else { return false }
            if original.elementsEqual(formatted) { continue }
            // Only ASCII letters change case: Unicode case mapping reads `ſ` as `S` and `ı` as `I`, names to the server.
            guard caseChangeable.contains(index),
                  zip(original, formatted).allSatisfy({ $0 == $1 || (isASCIILetter($0) && $0 | 0x20 == $1 | 0x20) }) else { return false }
        }
        return true
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool { (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }

    /// `\r\n` when the text breaks lines with CRLF outside strings, comments and quoted names; `\n` otherwise. The `\r`
    /// before the `\n` that ends a `--` or `#` comment belongs to the comment (the server ends it at `\n`) and counts.
    static func lineBreak(of lexer: SQLLexer, _ tokens: [SQLToken]) -> String {
        let units = lexer.units
        var gapStart = 0
        for index in 0...tokens.count {
            let gapEnd = index < tokens.count ? tokens[index].range.lowerBound : units.count
            var cursor = gapStart
            while cursor < gapEnd {
                if units[cursor] == 0x0A, cursor > 0, units[cursor - 1] == 0x0D { return "\r\n" }
                cursor += 1
            }
            if index < tokens.count { gapStart = tokens[index].range.upperBound }
        }
        return "\n"
    }

    /// The splitter finds the same statements (by tokens) in both texts. It handles DELIMITER commands, which the
    /// token check alone does not see.
    static func sameStatements(_ lhs: String, _ rhs: String, mode: SQLLexingMode) -> Bool {
        let left = SQLStatementSplitter.split(lhs, mode: mode)
        let right = SQLStatementSplitter.split(rhs, mode: mode)
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { sameTokens($0.text, $1.text, mode: mode) }
    }

    /// UTF-16 offsets of the CASE words that stay as written, per top-level statement as the splitter (and so the
    /// server) sees it: in a DELIMITER script a statement can hold `;` (a procedure body), elsewhere `;` ends one.
    static func frozenCaseWordOffsets(_ text: String, lexer: SQLLexer, tokens: [SQLToken]) -> Set<Int> {
        guard SQLStatementSplitter.usesDelimiterCommands(text, mode: lexer.mode) else {
            let cases = CaseStructure(tokens: tokens, facts: TokenFacts(lexer: lexer, tokens: tokens), splitsAtSemicolons: true)
            return Set(cases.frozenWords.map { tokens[$0].range.lowerBound })
        }
        var offsets = Set<Int>()
        for statement in SQLStatementSplitter.split(text, mode: lexer.mode) {
            let statementLexer = SQLLexer(statement.text, mode: lexer.mode)
            let statementTokens = statementLexer.tokens()
            let cases = CaseStructure(tokens: statementTokens, facts: TokenFacts(lexer: statementLexer, tokens: statementTokens),
                                      splitsAtSemicolons: false)
            offsets.formUnion(cases.frozenWords.map { statementTokens[$0].range.lowerBound + statement.range.lowerBound })
        }
        return offsets
    }

    /// A formatted text and the UTF-16 offsets (in the input) of the tokens whose letter case it may change.
    struct Layout {
        var text: String
        var caseChangeable: Set<Int>
    }

    /// `lineBreak` is the line break of the whole text (a selection takes its text's); found in `text` when `nil`.
    /// `frozenOffsets`: UTF-16 offsets (in `text`) of tokens that keep their exact text.
    static func layout(_ text: String, options: SQLFormatOptions, lineBreak: String? = nil, frozenOffsets: Set<Int> = []) -> Layout? {
        guard !Task.isCancelled, options.sessionAllowsFormatting, options.sessionModeKnown || !dependsOnSession(text) else { return nil }
        let lexer = SQLLexer(text, mode: options.lexingMode)
        let tokens = lexer.tokens()
        guard !tokens.isEmpty else { return Layout(text: "", caseChangeable: []) }
        // A literal the server rejects while lexing (`1.end`, `x'4'`), or a backslash outside strings (`\N` is NULL on
        // MariaDB, an error on MySQL 8): where the tokens end is guesswork.
        guard !Task.isCancelled, !lexer.containsMalformedLiteral(tokens), !lexer.containsBareBackslash(tokens) else { return nil }
        let lineBreak = lineBreak ?? Self.lineBreak(of: lexer, tokens)
        let result: Layout?
        if SQLStatementSplitter.usesDelimiterCommands(text, mode: options.lexingMode) {
            // DELIMITER lines are client commands that must stay alone on their line: format statement by statement
            // and keep everything between statements (commands, delimiters, comments) as written.
            result = layoutStatements(text, options: options, lineBreak: lineBreak, frozenOffsets: frozenOffsets)
        } else {
            result = layoutTokens(lexer: lexer, tokens: tokens, options: options, lineBreak: lineBreak, frozenOffsets: frozenOffsets,
                                  splitsAtSemicolons: true)
        }
        guard let result, !Task.isCancelled,
              result.text.utf16.count <= maxOutputLength(forInputLength: lexer.units.count),
              // The app runs what the splitter sees: formatting must not change it.
              sameStatements(text, result.text, mode: options.lexingMode) else { return nil }
        return result
    }

    /// Lays out the tokens of `lexer`'s text and checks the result against them.
    /// `splitsAtSemicolons`: the text is a script whose `;` end statements; false for one statement of a DELIMITER script.
    static func layoutTokens(lexer: SQLLexer, tokens: [SQLToken], options: SQLFormatOptions, lineBreak: String,
                             frozenOffsets: Set<Int> = [], splitsAtSemicolons: Bool) -> Layout? {
        var engine = Engine(lexer: lexer, tokens: tokens, options: options, lineBreak: lineBreak, frozenOffsets: frozenOffsets,
                            splitsAtSemicolons: splitsAtSemicolons)
        guard !Task.isCancelled, var output = engine.run() else { return nil }
        // Keep a trailing newline only when the input ended with one after its last token.
        if let last = tokens.last, lexer.units[last.range.upperBound...].contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            output += lexer.isLineComment(last) ? "\n" : lineBreak // as after any line comment
        }
        guard equivalent(lexer: lexer, tokens: tokens, to: output, caseChangeable: engine.caseChangeable, mode: options.lexingMode)
        else { return nil }
        return Layout(text: output, caseChangeable: Set(engine.caseChangeable.map { tokens[$0].range.lowerBound }))
    }

    /// Each statement the splitter finds, formatted on its own; the text between statements stays as written.
    static func layoutStatements(_ text: String, options: SQLFormatOptions, lineBreak: String, frozenOffsets: Set<Int> = []) -> Layout? {
        let units = Array(text.utf16)
        var output = ""
        var caseChangeable = Set<Int>()
        var cursor = 0
        for statement in SQLStatementSplitter.split(text, mode: options.lexingMode) {
            guard statement.range.lowerBound >= cursor, statement.range.upperBound <= units.count else { return nil }
            output += String(decoding: units[cursor..<statement.range.lowerBound], as: UTF16.self)
            let lexer = SQLLexer(statement.text, mode: options.lexingMode)
            let tokens = lexer.tokens()
            let range = statement.range
            let frozen = Set(frozenOffsets.filter { range.contains($0) }.map { $0 - range.lowerBound })
            guard !tokens.isEmpty,
                  let formatted = layoutTokens(lexer: lexer, tokens: tokens, options: options, lineBreak: lineBreak, frozenOffsets: frozen,
                                               splitsAtSemicolons: false)
            else { return nil }
            output += formatted.text
            caseChangeable.formUnion(formatted.caseChangeable.map { $0 + statement.range.lowerBound })
            cursor = statement.range.upperBound
        }
        output += String(decoding: units[cursor...], as: UTF16.self)
        return Layout(text: output, caseChangeable: caseChangeable)
    }
}

// MARK: - Engine

extension SQLFormatter {
    /// Words before which a statement-level (or subquery-level) clause starts on its own line.
    static let clauseWords: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "INTERSECT",
                                           "EXCEPT", "VALUES", "SET", "WINDOW"]
    /// Words that end a clause for the list look-ahead.
    static let clauseEndWords: Set<String> = clauseWords.union(["JOIN", "INNER", "LEFT", "RIGHT", "CROSS", "NATURAL", "STRAIGHT_JOIN",
                                                                "ON", "USING", "OFFSET", "INTO", "FOR"])
    /// Statements that get clause layout; others only get normalised spacing.
    static let layoutStatements: Set<String> = ["SELECT", "WITH", "INSERT", "REPLACE", "UPDATE", "DELETE", "VALUES", "TABLE", "CREATE",
                                                "EXPLAIN", "DESCRIBE", "DESC", "ANALYZE"]
    /// Statements whose query follows without a break (`EXPLAIN FORMAT=JSON SELECT …`).
    static let explainWords: Set<String> = ["EXPLAIN", "DESCRIBE", "DESC", "ANALYZE"]
    static let explainOptionWords: Set<String> = ["FORMAT", "JSON", "TREE", "TRADITIONAL", "EXTENDED", "PARTITIONS", "ANALYZE"]
    /// Reserved keywords written directly before `(` like a function call (whitespace after a reserved word does not
    /// matter to the server). Other words keep the space they had.
    static let callLikeKeywords: Set<String> = {
        var words = Set(SQLFunctions.names)
        words.formUnion(["CAST", "CONVERT", "IF", "CHAR", "LEFT", "RIGHT", "MOD", "REPEAT", "REPLACE", "INSERT", "MATCH", "CURRENT_USER",
                         "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP", "LOCALTIME",
                         "LOCALTIMESTAMP", "BIGINT", "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "DECIMAL", "DEC", "NUMERIC",
                         "FLOAT", "DOUBLE", "REAL", "VARCHAR", "BINARY", "VARBINARY", "VALUES"])
        words.subtract(["IN", "AS", "ON", "USING", "EXISTS", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "INDEX", "INTO", "TABLE", "FROM",
                        "WHERE", "SELECT", "WITH", "KEY", "RANGE", "UNION"])
        return words.intersection(SQLKeywords.reservedEverywhere)
    }()
    /// Reserved words that are values: a `-` after them is binary, and an END after them closes a CASE.
    static let operandKeywords: Set<String> = ["NULL", "TRUE", "FALSE", "END", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
                                               "CURRENT_USER", "LOCALTIME", "LOCALTIMESTAMP", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP",
                                               "DUAL", "MAXVALUE"]
    /// Operator characters next to which whitespace never changes how the server reads the text.
    static let spacingNeutralOperatorUnits: Set<UInt16> = Set("=<>!|&^+-*/%~:?".utf16)

    struct Frame {
        enum Kind { case statement, subquery, list, paren }
        enum Clause { case none, select, from, whereLike, groupBy, orderBy, limit, join, on, set, values, with, ddl, locking, window, other }

        var kind: Kind
        /// Indent level of clauses (statement, subquery) or items (list) in this frame.
        var indent: Int
        /// Indent level of the line holding the opening `(`.
        var openIndent: Int
        /// The significant token before the opening `(`.
        var opener: Int?
        var clause: Clause = .none
        var listBreak = false
        var betweenPending = false
        var cases: [CaseInfo] = []
        /// `OVER (…)` or `WINDOW w AS (…)`.
        var isWindowSpec = false
        /// After ROWS / RANGE in a window specification: the frame bounds.
        var inFrameExtent = false
        /// After INTERVAL in the frame bounds: PRECEDING / FOLLOWING ends `INTERVAL n unit`.
        var intervalPending = false
        /// `(PARTITION p0 …, …)` of a table definition.
        var isPartitionList = false

        var allowsClauses: Bool { kind == .statement || kind == .subquery }
    }

    /// What the layout needs to know about the words of the statement so far (keyword and identifier texts, "" for other
    /// tokens and for names next to `.`), updated in constant time per token.
    struct StatementWords {
        private(set) var isEmpty = true
        private(set) var first: String?
        private(set) var last: String?
        private(set) var containsTable = false
        /// EXPLAIN (DESCRIBE, DESC, ANALYZE) and only its options so far: the next query word starts the query.
        private(set) var onlyExplainPrefix = false

        mutating func append(_ word: String) {
            if isEmpty {
                first = word
                onlyExplainPrefix = SQLFormatter.explainWords.contains(word)
            } else if onlyExplainPrefix, !word.isEmpty, !SQLFormatter.explainOptionWords.contains(word) {
                onlyExplainPrefix = false
            }
            if word == "TABLE" { containsTable = true }
            last = word
            isEmpty = false
        }
    }

    /// Per-token facts every pass needs: the upper-cased (ASCII) words, neighbours with comments skipped, and whether a
    /// token touches a `.` (MySQL reads a word there as a name).
    struct TokenFacts {
        /// Upper-cased (ASCII) text of keyword and identifier tokens; the raw text otherwise, and for words with a
        /// character outside ASCII, which are never keywords (`ſelect` is not SELECT).
        let words: [String]
        let previous: [Int?]
        let next: [Int?]
        /// Next to a `.`: MySQL reads a word there as a name (`shop.order`), never as a keyword.
        let qualified: [Bool]

        init(lexer: SQLLexer, tokens: [SQLToken]) {
            let words = tokens.map { token in
                guard token.kind == .keyword || token.kind == .identifier else { return lexer.text(of: token) }
                return SQLLexer.asciiUppercased(lexer.units[token.range]) ?? lexer.text(of: token)
            }
            var previous = [Int?](repeating: nil, count: tokens.count)
            var next = [Int?](repeating: nil, count: tokens.count)
            var last: Int?
            for index in tokens.indices {
                previous[index] = last
                if tokens[index].kind != .comment { last = index }
            }
            last = nil
            for index in tokens.indices.reversed() {
                next[index] = last
                if tokens[index].kind != .comment { last = index }
            }
            let isDot: (Int?) -> Bool = { $0.map { tokens[$0].kind == .punctuation && words[$0] == "." } ?? false }
            qualified = tokens.indices.map { tokens[$0].kind != .comment && (isDot(previous[$0]) || isDot(next[$0])) }
            self.words = words
            self.previous = previous
            self.next = next
        }
    }

    /// The CASE … END structure of each top-level statement, proven by counting rather than by guessing which bare `end`
    /// is a name (END is not reserved: a column, alias, table alias or CTE can be called `end`). A statement is proven when
    /// every bare `end` keyword, also one next to `.`, closes the innermost open CASE at its parenthesis depth, no CASE
    /// stays open, and nothing hides a CASE or END from the lexer (an executable comment). In a valid statement each real
    /// CASE expression has exactly one END, so equal counts mean no `end` is a name. An `end` next to `.` is a name to the
    /// server (`end.a`, `t.end`), so its presence fails the proof. Compound statements and stored programs are never
    /// proven: `END CASE`, `END IF` and the bare `end` of BEGIN … END cannot be told from a CASE's END by counting, and a
    /// CASE statement's branches hold `;`.
    struct CaseStructure {
        /// Words that only occur in compound statements and stored-program definitions (unqualified).
        static let compoundWords: Set<String> = ["BEGIN", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT", "DECLARE"]
        /// Words after END that end a compound statement (`END IF`, `END CASE`, …).
        static let compoundEnds: Set<String> = ["IF", "CASE", "LOOP", "WHILE", "REPEAT"]

        /// CASE → its END and its number of WHEN / ELSE branches, for proven statements.
        private(set) var shapes: [Int: (end: Int, branches: Int)] = [:]
        /// CASE, WHEN, THEN, ELSE and END of the other statements.
        private(set) var frozenWords = Set<Int>()

        /// `splitsAtSemicolons`: `;` ends a statement (a script without DELIMITER commands); false when `tokens` are one
        /// statement of a DELIMITER script, whose `;` belong to a compound body.
        init(tokens: [SQLToken], facts: TokenFacts, splitsAtSemicolons: Bool) {
            var statementStart = 0
            if splitsAtSemicolons {
                for index in tokens.indices where tokens[index].kind == .punctuation && facts.words[index] == ";" {
                    settle(statementStart..<index, tokens: tokens, facts: facts)
                    statementStart = index + 1
                }
            }
            settle(statementStart..<tokens.count, tokens: tokens, facts: facts)
        }

        private mutating func settle(_ statement: Range<Int>, tokens: [SQLToken], facts: TokenFacts) {
            var caseWords: [Int] = []
            var found: [Int: (end: Int, branches: Int)] = [:]
            var open: [(index: Int, depth: Int, branches: Int)] = []
            var depth = 0
            var proven = true
            for index in statement {
                switch tokens[index].kind {
                case .executableComment:
                    proven = false
                case .punctuation where facts.words[index] == "(":
                    depth += 1
                case .punctuation where facts.words[index] == ")":
                    if let top = open.last, top.depth == depth { proven = false } // a CASE left open inside parentheses
                    depth = max(0, depth - 1)
                case .keyword:
                    let word = facts.words[index]
                    if !facts.qualified[index] {
                        if Self.compoundWords.contains(word) { proven = false }
                        if word == "END", let next = facts.next[index], tokens[next].kind == .keyword,
                           Self.compoundEnds.contains(facts.words[next]) {
                            proven = false
                        }
                    }
                    guard ["CASE", "WHEN", "THEN", "ELSE", "END"].contains(word) else { continue }
                    caseWords.append(index)
                    if facts.qualified[index] {
                        if word == "END" { proven = false } // `end.a`, `t.end`: a name that a count would take for an END
                        continue // `t.case` is a name too, never counted as a CASE
                    }
                    switch word {
                    case "CASE":
                        open.append((index, depth, 0))
                    case "END":
                        guard let top = open.last, top.depth == depth else {
                            proven = false
                            continue
                        }
                        found[top.index] = (index, top.branches)
                        open.removeLast()
                    case "WHEN", "ELSE":
                        if let top = open.last, top.depth == depth { open[open.count - 1].branches += 1 }
                    default:
                        break
                    }
                default:
                    continue
                }
            }
            if proven, open.isEmpty {
                shapes.merge(found) { first, _ in first }
            } else {
                frozenWords.formUnion(caseWords)
            }
        }
    }

    struct CaseInfo {
        var multiline: Bool
        var indent: Int
        var endIndex: Int?
    }

    struct Engine {
        let lexer: SQLLexer
        let tokens: [SQLToken]
        let options: SQLFormatOptions
        /// `\n`, or `\r\n` for a text written with CRLF.
        let lineBreak: String
        /// Upper-cased (ASCII) text of keyword and identifier tokens; the raw text otherwise, and for words with a
        /// character outside ASCII, which are never keywords (`ſelect` is not SELECT).
        let words: [String]
        /// Neighbouring tokens, comments skipped.
        private let previousSignificant: [Int?]
        private let nextSignificant: [Int?]
        /// Next to a `.`: MySQL reads a word there as a name (`shop.order`), never as a keyword.
        private let qualified: [Bool]
        /// For each `(`, its `)`; look-aheads skip parenthesised groups with it.
        private let closing: [Int?]
        /// For each CASE of a statement whose CASE structure is proven, its END and its number of WHEN / ELSE branches.
        private let caseShapes: [Int: (end: Int, branches: Int)]
        /// CASE, WHEN, THEN, ELSE and END of statements whose CASE structure is not proven: written exactly as they are.
        private let frozenCaseWords: Set<Int>
        private(set) var caseChangeable = Set<Int>()

        private var output = ""
        private var lineIndent = 0
        private var atLineStart = true
        private var pendingBreak: (indent: Int, blank: Bool)?
        /// Comments that started their own line (and comments after them on that line), written before the next token
        /// at that token's indent.
        private var heldComments: [(index: Int, sameLine: Bool)] = []
        /// The innermost frame, stored apart from the enclosing ones so it is mutated in place (through an array element
        /// accessor, every change would copy its CASE stack: quadratic for thousands of nested CASEs).
        private var frame = Frame(kind: .statement, indent: 0, openIndent: 0)
        private var enclosingFrames: [Frame] = []
        private var lastWritten: Int?
        private var lastSignificant: Int?
        /// The last `)` written and the token before its `(`.
        private var lastClose: (index: Int, opener: Int?)?
        private var attachNext = false
        private var statementWords = StatementWords()
        private var layout = true
        private var listHeadEnd: Int?
        private var structural = Set<Int>()
        /// After INTO / TABLE / VIEW: 1 = expecting the name, 2 = inside the (qualified) name.
        private var tableNameState = 0
        private var tableNameIsCreateTable = false
        /// Last word of a multi-word operator being written (`LEFT OUTER JOIN`, `ON DUPLICATE KEY UPDATE`).
        private var joinWordsThrough: Int?
        /// The last token written started its line (a comma there takes the next item along instead of breaking).
        private var lastStartedLine = false

        /// `frozenOffsets`: UTF-16 offsets of tokens to keep as written whatever this text proves (a selection inherits
        /// the CASE verdict of its whole statement).
        init(lexer: SQLLexer, tokens: [SQLToken], options: SQLFormatOptions, lineBreak: String, frozenOffsets: Set<Int> = [],
             splitsAtSemicolons: Bool = true) {
            self.lexer = lexer
            self.tokens = tokens
            self.options = options
            self.lineBreak = lineBreak
            let facts = TokenFacts(lexer: lexer, tokens: tokens)
            words = facts.words
            previousSignificant = facts.previous
            nextSignificant = facts.next
            qualified = facts.qualified
            closing = Self.matchingParentheses(tokens, words: facts.words)
            let cases = CaseStructure(tokens: tokens, facts: facts, splitsAtSemicolons: splitsAtSemicolons)
            var frozen = cases.frozenWords
            if !frozenOffsets.isEmpty {
                frozen.formUnion(tokens.indices.filter { frozenOffsets.contains(tokens[$0].range.lowerBound) })
            }
            caseShapes = cases.shapes.filter { !frozen.contains($0.key) && !frozen.contains($0.value.end) }
            frozenCaseWords = frozen
            for index in tokens.indices where tokens[index].kind == .keyword && !qualified[index] && !frozen.contains(index)
                && SQLKeywords.reservedEverywhere.contains(words[index]) {
                caseChangeable.insert(index)
            }
        }

        private static func matchingParentheses(_ tokens: [SQLToken], words: [String]) -> [Int?] {
            var closing = [Int?](repeating: nil, count: tokens.count)
            var open: [Int] = []
            for index in tokens.indices where tokens[index].kind == .punctuation {
                switch words[index] {
                case "(": open.append(index)
                case ")": if let start = open.popLast() { closing[start] = index }
                case ";": open.removeAll()
                default: break
                }
            }
            return closing
        }

        /// The token can end an operand (a name, a value, `)`), so a word after it is not another operand.
        static func isExpressionEnd(_ index: Int, tokens: [SQLToken], words: [String], qualified: [Bool]) -> Bool {
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier, .number, .string, .variable: true
            case .punctuation: words[index] == ")"
            case .operator: words[index] == "?"
            case .keyword: qualified[index] || !SQLKeywords.reservedEverywhere.contains(words[index]) || SQLFormatter.operandKeywords.contains(words[index])
            case .comment, .executableComment: false
            }
        }

        // MARK: Run

        /// The laid-out text, or nil when the task running it was cancelled.
        mutating func run() -> String? {
            for index in tokens.indices {
                if index & 0x3FF == 0, Task.isCancelled { return nil }
                if tokens[index].kind == .comment {
                    comment(index)
                } else {
                    token(index)
                }
            }
            flushHeldComments(final: true)
            caseChangeable.formUnion(structural)
            return output
        }

        private func isKeyword(_ index: Int, _ word: String) -> Bool {
            tokens[index].kind == .keyword && words[index] == word && !qualified[index]
        }

        /// A keyword every supported server reserves, used as one (not next to a `.`).
        private func isReserved(_ index: Int) -> Bool {
            tokens[index].kind == .keyword && !qualified[index] && SQLKeywords.reservedEverywhere.contains(words[index])
        }

        private func isPunctuation(_ index: Int, _ text: String) -> Bool {
            (tokens[index].kind == .punctuation || tokens[index].kind == .operator) && words[index] == text
        }

        /// A name, or a word that can be one: an identifier, a back-quoted name or a keyword not reserved everywhere.
        private func isName(_ index: Int) -> Bool {
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier: true
            case .keyword: !isReserved(index)
            default: false
            }
        }

        private func isExpressionEnd(_ index: Int) -> Bool {
            Self.isExpressionEnd(index, tokens: tokens, words: words, qualified: qualified)
        }

        /// The input had whitespace (or a comment) between the two tokens.
        private func wasSeparated(_ previous: Int, _ index: Int) -> Bool {
            tokens[previous].range.upperBound < tokens[index].range.lowerBound
        }

        private func isSpacingNeutralOperator(_ index: Int) -> Bool {
            tokens[index].kind == .operator && lexer.units[tokens[index].range].allSatisfy { SQLFormatter.spacingNeutralOperatorUnits.contains($0) }
        }

        /// Whether whitespace may go between two tokens that touch in the input (design D8). Only next to `,` `;` `(` `)`,
        /// a plain comment or an operator, or after a string or back-quoted name (not before `@`: `'root'@'%'`); before
        /// `(` only after a reserved word, punctuation, an operator or a comment. Never at a `.` or an executable comment.
        private func mayInsertSpace(_ first: Int, _ second: Int) -> Bool {
            let firstKind = tokens[first].kind
            let secondKind = tokens[second].kind
            if isPunctuation(first, ".") || isPunctuation(second, ".") { return false }
            if firstKind == .executableComment || secondKind == .executableComment { return false }
            if isPunctuation(second, "(") {
                return isReserved(first) || firstKind == .punctuation || firstKind == .comment || isSpacingNeutralOperator(first)
            }
            if firstKind == .comment || secondKind == .comment || firstKind == .punctuation || secondKind == .punctuation { return true }
            if isSpacingNeutralOperator(first) || isSpacingNeutralOperator(second) { return true }
            // After a string or back-quoted name, but not before `@…`: `'root'@'%'` is one account name.
            return (firstKind == .string || firstKind == .quotedIdentifier) && secondKind != .variable
        }

        /// The token touches the one before it in the input, and whitespace between them is not known to be harmless.
        private func isGlued(_ index: Int) -> Bool {
            index > 0 && tokens[index - 1].range.upperBound == tokens[index].range.lowerBound && !mayInsertSpace(index - 1, index)
        }

        // MARK: Comments

        private mutating func comment(_ index: Int) {
            let startsLine = index == 0 || lexer.units[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]
                .contains(where: { $0 == 0x0A || $0 == 0x0D })
            // A comment after a held one goes with it, so comments on one line keep their order.
            if !heldComments.isEmpty || (startsLine && !output.isEmpty) {
                heldComments.append((index, !startsLine))
                return
            }
            // Inline: stays on the current line, whatever break is pending for the next token.
            if !output.isEmpty, !atLineStart, !isGlued(index) { output += " " }
            output += lexer.text(of: tokens[index])
            atLineStart = false
            lastWritten = index
            if isLineComment(index) {
                requestBreak(pendingBreak?.indent ?? continuationIndent, blank: pendingBreak?.blank ?? false)
            }
        }

        private func isLineComment(_ index: Int) -> Bool {
            lexer.isLineComment(tokens[index])
        }

        private var continuationIndent: Int {
            statementWords.isEmpty ? frame.openIndent : frame.indent + (frame.kind == .list || frame.kind == .paren ? 0 : 1)
        }

        private mutating func flushHeldComments(final: Bool = false) {
            guard !heldComments.isEmpty else { return }
            let indent = pendingBreak?.indent ?? continuationIndent
            let blank = pendingBreak?.blank ?? false
            pendingBreak = nil
            newline(indent: indent, blank: blank)
            for (position, held) in heldComments.enumerated() {
                if position > 0 {
                    if held.sameLine {
                        output += " "
                    } else {
                        newline(indent: indent, blank: false)
                    }
                }
                output += lexer.text(of: tokens[held.index])
                atLineStart = false
                lastWritten = held.index
            }
            heldComments.removeAll()
            if !final { requestBreak(indent) }
        }

        // MARK: Writing

        private mutating func requestBreak(_ indent: Int, blank: Bool = false) {
            guard !output.isEmpty else { return }
            pendingBreak = (indent, blank || (pendingBreak?.blank ?? false))
        }

        private mutating func newline(indent: Int, blank: Bool) {
            guard !output.isEmpty else { return }
            // No trailing-space trimming: the formatter never writes trailing spaces, and spaces at the end of a
            // `--` comment belong to the comment token.
            // Right after a `--` or `#` comment only `\n`: the server ends the comment there, so a `\r` written before it
            // would become part of the comment (one the comment ends with is already part of it).
            output += lastWritten.map(isLineComment) == true ? "\n" : lineBreak
            if blank { output += lineBreak }
            let level = min(max(0, indent), SQLFormatter.maxIndentLevel)
            output += String(repeating: " ", count: level * SQLFormatOptions.clamped(options.indentWidth))
            lineIndent = level
            atLineStart = true
        }

        private mutating func write(_ index: Int, space: Bool) {
            let unary = isUnaryOperator(index)
            let glued = isGlued(index)
            let attached = attachNext && lastWritten.map { !mustSeparate($0, index) && tokens[$0].kind != .comment } == true
            attachNext = false
            flushHeldComments()
            if glued {
                pendingBreak = nil // touching in the input: no line break or space may come between
            } else if let pending = pendingBreak {
                pendingBreak = nil
                newline(indent: pending.indent, blank: pending.blank)
            } else if space, !attached, !atLineStart, !output.isEmpty {
                output += " "
            }
            lastStartedLine = atLineStart && !output.isEmpty
            output += text(of: index)
            atLineStart = false
            lastWritten = index
            lastSignificant = index
            attachNext = unary
        }

        private func text(of index: Int) -> String {
            let raw = lexer.text(of: tokens[index])
            guard caseChangeable.contains(index) || structural.contains(index) else { return raw }
            switch options.keywordCase {
            case .upper: return raw.uppercased()
            case .lower: return raw.lowercased()
            case .preserve: return raw
            }
        }

        // MARK: Tokens

        private mutating func token(_ index: Int) {
            let kind = tokens[index].kind
            let word = words[index]

            if kind == .punctuation, word == ";" {
                write(index, space: false)
                endStatement()
                return
            }
            if statementWords.isEmpty {
                layout = word == "(" || (kind == .keyword && !qualified[index] && SQLFormatter.layoutStatements.contains(word))
            }

            if kind == .punctuation, word == "(" {
                openParen(index)
            } else {
                if kind == .punctuation, word == ")" {
                    closeParen(index)
                } else if kind == .punctuation, word == "," {
                    comma(index)
                } else if kind == .keyword, !qualified[index] {
                    keyword(index)
                } else {
                    write(index, space: spaceBefore(index)) // names, values, operators; a keyword next to `.` is a name
                }
                advanceTableName(index)
            }
            statementWords.append((kind == .keyword || kind == .identifier) && !qualified[index] ? word : "")
        }

        private mutating func endStatement() {
            frame = Frame(kind: .statement, indent: 0, openIndent: 0)
            enclosingFrames.removeAll()
            statementWords = StatementWords()
            listHeadEnd = nil
            joinWordsThrough = nil
            tableNameState = 0
            attachNext = false
            lastClose = nil
            requestBreak(0, blank: true)
        }

        // MARK: Parentheses, commas

        private mutating func openParen(_ index: Int) {
            let previous = lastSignificant
            let afterTableName = tableNameState == 2
            let isColumnList = afterTableName && tableNameIsCreateTable && frame.kind == .statement
            let nextWord = nextSignificant[index].map { words[$0] }
            // `PARTITION BY RANGE (id) (PARTITION p0 …, …)`: one partition per line.
            let isPartitionList = nextWord == "PARTITION" && frame.kind == .statement
                && (statementWords.first == "CREATE" || statementWords.first == "ALTER")
            // `OVER (…)`, `WINDOW w AS (…)`.
            let isWindowSpec = previous.map { (structural.contains($0) && words[$0] == "OVER") || (frame.clause == .window && isKeyword($0, "AS")) } == true
            var space = spaceBeforeOpenParen(index, previous: previous)
            if lastWritten.map({ tokens[$0].kind == .comment }) == true { space = true }
            write(index, space: space)
            tableNameState = 0
            var opened: Frame
            if layout, nextWord == "SELECT" || nextWord == "WITH" {
                opened = Frame(kind: .subquery, indent: lineIndent + 1, openIndent: lineIndent)
                requestBreak(lineIndent + 1)
            } else if layout, isColumnList || isPartitionList {
                opened = Frame(kind: .list, indent: lineIndent + 1, openIndent: lineIndent)
                opened.isPartitionList = isPartitionList
                requestBreak(lineIndent + 1)
            } else {
                opened = Frame(kind: .paren, indent: lineIndent + 1, openIndent: lineIndent)
                opened.isWindowSpec = isWindowSpec
            }
            opened.opener = previous
            enclosingFrames.append(frame)
            frame = opened
        }

        private mutating func closeParen(_ index: Int) {
            guard let enclosing = enclosingFrames.popLast() else {
                write(index, space: false) // unbalanced: nothing to close
                lastClose = (index, nil)
                return
            }
            let closing = frame
            frame = enclosing
            if closing.kind == .subquery || closing.kind == .list {
                requestBreak(closing.openIndent)
            }
            write(index, space: false)
            lastClose = (index, closing.opener)
        }

        private mutating func comma(_ index: Int) {
            write(index, space: false)
            // A line comment before it pushed the comma to the start of a line: the next item follows it (`, b`)
            // instead of leaving it alone on its line.
            guard !lastStartedLine else { return }
            switch frame.kind {
            case .list:
                requestBreak(frame.indent)
            case .statement, .subquery:
                if frame.clause == .with {
                    requestBreak(frame.indent)
                } else if frame.listBreak {
                    requestBreak(frame.indent + 1)
                }
            case .paren:
                break
            }
        }

        // MARK: Keywords

        private mutating func keyword(_ index: Int) {
            let word = words[index]
            let next = nextSignificant[index]
            let nextWord = next.map { words[$0] }

            // The rest of a multi-word operator (`LEFT OUTER JOIN`, `DUPLICATE KEY UPDATE`): written as is.
            if let last = joinWordsThrough, index <= last {
                if index == last { joinWordsThrough = nil }
                write(index, space: true)
                finishListHead(index)
                return
            }
            if word == "CASE" {
                beginCase(index)
                return
            }
            if let info = frame.cases.last {
                if word == "END", info.endIndex == index {
                    structural.insert(index)
                    if info.multiline { requestBreak(info.indent) }
                    write(index, space: spaceBefore(index))
                    frame.cases.removeLast()
                    return
                }
                if info.multiline, word == "WHEN" || word == "ELSE" {
                    requestBreak(info.indent + 1)
                    write(index, space: true)
                    return
                }
            }
            recognisePosition(index, word: word, next: next)
            if layout, frame.allowsClauses, clause(index, word: word, next: next, nextWord: nextWord) {
                finishListHead(index)
                return
            }
            if layout, frame.kind == .statement, statementWords.first == "CREATE" || statementWords.first == "ALTER",
               ddlClause(index, word: word, nextWord: nextWord) {
                return
            }
            if word == "BETWEEN" { frame.betweenPending = true }
            write(index, space: spaceBefore(index))
            finishListHead(index)
        }

        /// Words that are keywords only by position change case only where no server could read them as names (design D2):
        /// the neighbours must make a name there a syntax error on every server. Never in a name position after INTO /
        /// TABLE / VIEW, never next to `.`.
        private mutating func recognisePosition(_ index: Int, word: String, next: Int?) {
            guard tableNameState == 0 else { return }
            let previous = previousSignificant[index]
            let nextWord = next.map { words[$0] }
            let nextIsOpen = next.map { isPunctuation($0, "(") } ?? false
            let nextIsName = next.map(isName) ?? false
            let afterNext = next.flatMap { nextSignificant[$0] }
            func previousIs(_ keyword: String) -> Bool { previous.map { isKeyword($0, keyword) } ?? false }
            func previousIsRecognised(_ keyword: String) -> Bool { previous.map { structural.contains($0) && words[$0] == keyword } ?? false }
            var recognised = false
            switch word {
            // Window frames: only inside `OVER (…)` / `WINDOW w AS (…)`, and the bounds only after ROWS / RANGE.
            case "ROWS":
                recognised = frame.isWindowSpec
                    && (["BETWEEN", "UNBOUNDED", "CURRENT"].contains(nextWord ?? "") || next.map { tokens[$0].kind == .number } == true)
                if recognised { frame.inFrameExtent = true }
            case "RANGE":
                if frame.isWindowSpec { frame.inFrameExtent = true } // reserved: its case changes anyway
            case "INTERVAL":
                if frame.inFrameExtent { frame.intervalPending = true }
            case "UNBOUNDED":
                recognised = frame.inFrameExtent && (nextWord == "PRECEDING" || nextWord == "FOLLOWING")
            case "PRECEDING", "FOLLOWING":
                recognised = frame.inFrameExtent
                    && (previousIsRecognised("UNBOUNDED") || previous.map { tokens[$0].kind == .number } == true || frame.intervalPending)
                if recognised { frame.intervalPending = false }
            case "CURRENT":
                recognised = frame.inFrameExtent && nextWord == "ROW"
            case "ROW":
                recognised = previousIsRecognised("CURRENT") || previousIs("EACH") // `FOR EACH ROW`: EACH is reserved
            case "OVER":
                // After the `)` of a call: `rank() OVER (…)`, `sum(a) OVER w`.
                let closesCall = previous.map { $0 == lastClose?.index } == true
                    && lastClose?.opener.map(isName) == true
                recognised = closesCall && (nextIsOpen || nextIsName)
            case "WINDOW":
                recognised = frame.allowsClauses && nextIsName && afterNext.map { isKeyword($0, "AS") } == true
                    && afterNext.flatMap { nextSignificant[$0] }.map { isPunctuation($0, "(") } == true
            case "PARTITION":
                recognised = next.map { isKeyword($0, "BY") } == true
                    || (frame.isPartitionList && previous.map { isPunctuation($0, "(") || isPunctuation($0, ",") } == true && nextIsName)
            case "RECURSIVE":
                recognised = previousIs("WITH") && nextIsName
            case "EXCEPT", "INTERSECT":
                // Between a query and a proven one; otherwise a name: `from (select 1 a) except (x)` is a derived table
                // aliased `except` with a column list where EXCEPT is not reserved (MySQL before 8.0.31).
                recognised = startsQuery(next) && previous.map(isExpressionEnd) == true
            case "LATERAL":
                recognised = nextIsOpen && (frame.clause == .from || frame.clause == .join)
                    && (previousIs("JOIN") || previous.map { isPunctuation($0, ",") } == true)
            case "FUNCTION", "DATABASE", "SCHEMA", "VIEW", "EVENT":
                // The object kind after CREATE / DROP / ALTER (all reserved: a name cannot follow them directly).
                recognised = previousIs("CREATE") || previousIs("DROP") || previousIs("ALTER") || (word == "FUNCTION" && previousIs("SHOW"))
            case "GENERATED":
                recognised = nextWord == "ALWAYS" && afterNext.map { isKeyword($0, "AS") } == true
            case "STORED", "VIRTUAL":
                // `… AS (expr) STORED` in a column definition.
                recognised = previous.map { $0 == lastClose?.index } == true && lastClose?.opener.map { isKeyword($0, "AS") } == true
                    && (statementWords.first == "CREATE" || statementWords.first == "ALTER") && statementWords.containsTable
            case "LESS":
                recognised = previousIs("VALUES") && nextWord == "THAN"
            case "THAN":
                recognised = previousIsRecognised("LESS")
            case "SHARE":
                let lockInShareMode = previousIs("IN") && previous.flatMap { previousSignificant[$0] }.map { isKeyword($0, "LOCK") } == true
                    && nextWord == "MODE"
                recognised = (frame.clause == .locking && previousIs("FOR")) || lockInShareMode
            case "SKIP":
                recognised = frame.clause == .locking && (previousIs("UPDATE") || previousIsRecognised("SHARE")) && nextWord == "LOCKED"
            case "LOCKED":
                recognised = previousIsRecognised("SKIP")
            case "NOWAIT":
                recognised = frame.clause == .locking && (previousIs("UPDATE") || previousIsRecognised("SHARE"))
            default:
                break
            }
            if recognised { structural.insert(index) }
        }

        /// Clause layout inside a statement or subquery. Returns `true` when the token was written.
        private mutating func clause(_ index: Int, word: String, next: Int?, nextWord: String?) -> Bool {
            let isFirstQueryWord = statementWords.isEmpty || statementWords.onlyExplainPrefix
            let breakIndent = frame.indent
            let statementFirst = statementWords.first

            // AND / OR conditions; the AND of BETWEEN stays.
            if word == "AND" || word == "OR" {
                if word == "AND", frame.betweenPending {
                    frame.betweenPending = false
                    return false
                }
                guard frame.cases.isEmpty, frame.clause == .whereLike || frame.clause == .on else { return false }
                requestBreak(breakIndent + 1)
                write(index, space: true)
                return true
            }
            // Joins: [NATURAL] [LEFT|RIGHT] [OUTER] JOIN, INNER JOIN, CROSS JOIN, STRAIGHT_JOIN.
            if ["JOIN", "INNER", "LEFT", "RIGHT", "CROSS", "NATURAL", "STRAIGHT_JOIN"].contains(word), let end = joinEnd(from: index) {
                requestBreak(breakIndent)
                write(index, space: true)
                if end > index { joinWordsThrough = end }
                setClause(.join)
                return true
            }
            // INSERT … ON DUPLICATE KEY UPDATE a = …, b = …
            if word == "ON", nextWord == "DUPLICATE", statementFirst == "INSERT" || statementFirst == "REPLACE",
               let duplicate = next, let key = nextSignificant[duplicate], isKeyword(key, "KEY"),
               let update = nextSignificant[key], isKeyword(update, "UPDATE") {
                structural.insert(duplicate) // not reserved, but a keyword here
                requestBreak(breakIndent)
                write(index, space: true)
                joinWordsThrough = update
                startList(.set, headEnd: update)
                return true
            }
            if word == "ON", frame.clause == .join {
                requestBreak(breakIndent + 1)
                write(index, space: true)
                setClause(.on)
                return true
            }
            // `LIMIT n OFFSET m`; `LIMIT offset` names a variable.
            if word == "OFFSET", frame.clause == .limit, let previous = previousSignificant[index],
               [.number, .identifier, .variable].contains(tokens[previous].kind) || isPunctuation(previous, "?") {
                structural.insert(index)
                requestBreak(breakIndent)
                write(index, space: true)
                return true
            }
            // Locking reads: FOR UPDATE, FOR SHARE.
            if word == "FOR", nextWord == "UPDATE" || nextWord == "SHARE" {
                requestBreak(breakIndent)
                write(index, space: true)
                setClause(.locking)
                return true
            }
            if word == "WITH" {
                // A WITH that starts the query (statement or subquery); others (`WITH ROLLUP`, …) stay inline.
                let startsQuery = isFirstQueryWord || (lastSignificant.map { isPunctuation($0, "(") } ?? false)
                guard startsQuery else { return false }
                write(index, space: true)
                setClause(.with)
                return true
            }

            guard SQLFormatter.clauseWords.contains(word) else { return false }
            // `a = VALUES(b)`, `x = LEFT(…)`: an operand, not a clause.
            if let previous = lastSignificant, isOperand(index, after: previous) { return false }
            switch word {
            case "SET":
                guard ["UPDATE", "INSERT", "REPLACE"].contains(statementFirst ?? "") || statementWords.isEmpty else { return false }
            case "VALUES":
                guard ["INSERT", "REPLACE"].contains(statementFirst ?? "") || statementWords.isEmpty || frame.kind == .subquery
                else { return false }
            case "GROUP", "ORDER":
                guard nextWord == "BY" else { return false }
            case "WINDOW", "EXCEPT", "INTERSECT":
                guard structural.contains(index) else { return false } // otherwise a name (MySQL 5.7, MariaDB)
            case "FROM":
                if statementWords.last == "DELETE" {
                    write(index, space: true)
                    setClause(.from)
                    return true
                }
            default:
                break
            }
            if !(isFirstQueryWord && (word == "SELECT" || word == "VALUES" || word == "SET")) {
                requestBreak(breakIndent)
            }
            write(index, space: true)
            switch word {
            case "SELECT":
                var head = index
                if let next, isKeyword(next, "DISTINCT") || isKeyword(next, "ALL") || isKeyword(next, "DISTINCTROW") { head = next }
                startList(.select, headEnd: head)
            case "GROUP": startList(.groupBy, headEnd: next ?? index)
            case "ORDER": startList(.orderBy, headEnd: next ?? index)
            case "SET": startList(.set, headEnd: index)
            case "VALUES": startList(.values, headEnd: index)
            case "FROM": setClause(.from)
            case "WHERE", "HAVING": setClause(.whereLike)
            case "LIMIT": setClause(.limit)
            case "WINDOW": setClause(.window)
            default: setClause(.other)
            }
            return true
        }

        /// A clause word called like a function right after an operator is an operand (`a = VALUES(b)`), not the start
        /// of a clause. `*` (as in `SELECT * FROM (…)`) is not an operator there.
        private func isOperand(_ index: Int, after previous: Int) -> Bool {
            guard tokens[previous].kind == .operator, words[previous] != "*" else { return false }
            return nextSignificant[index].map { isPunctuation($0, "(") } ?? false
        }

        /// MySQL CREATE / ALTER TABLE at statement level: `PARTITION BY` starts a line. Table options (`ENGINE=…`)
        /// stay after the `)`, as `SHOW CREATE TABLE` writes them. Returns `true` when the token was written.
        private mutating func ddlClause(_ index: Int, word: String, nextWord: String?) -> Bool {
            guard word == "PARTITION", nextWord == "BY" else { return false }
            requestBreak(frame.indent)
            write(index, space: true)
            setClause(.ddl)
            return true
        }

        /// Words that start a query, so a set operator before them is one.
        static let queryStarts: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE"]

        /// Whether a query starts at `index`: SELECT, WITH, VALUES or TABLE after an optional ALL / DISTINCT and any number
        /// of opening parentheses. Each parenthesis is looked at by at most one set operator (the one right before it).
        private func startsQuery(_ index: Int?) -> Bool {
            var cursor = index
            if let start = cursor, isKeyword(start, "ALL") || isKeyword(start, "DISTINCT") { cursor = nextSignificant[start] }
            while let current = cursor {
                if isPunctuation(current, "(") {
                    cursor = nextSignificant[current]
                    continue
                }
                return tokens[current].kind == .keyword && !qualified[current] && Self.queryStarts.contains(words[current])
            }
            return false
        }

        /// Index of the `JOIN` that completes a join operator starting at `index`, or `nil`.
        private func joinEnd(from index: Int) -> Int? {
            if words[index] == "JOIN" || words[index] == "STRAIGHT_JOIN" { return index }
            var cursor = index
            while let next = nextSignificant[cursor] {
                guard tokens[next].kind == .keyword, !qualified[next] else { return nil }
                switch words[next] {
                case "JOIN": return next
                case "OUTER", "LEFT", "RIGHT", "INNER": cursor = next
                default: return nil
                }
            }
            return nil
        }

        private mutating func setClause(_ clause: Frame.Clause) {
            frame.clause = clause
            frame.listBreak = false
            frame.betweenPending = false
            listHeadEnd = nil
        }

        private mutating func startList(_ clause: Frame.Clause, headEnd: Int) {
            setClause(clause)
            frame.listBreak = hasTopLevelComma(after: headEnd)
            listHeadEnd = headEnd
        }

        /// After the last word of a list clause head (SELECT [DISTINCT], GROUP BY, …): break before the first item.
        private mutating func finishListHead(_ index: Int) {
            guard let head = listHeadEnd, head == index, frame.allowsClauses else { return }
            listHeadEnd = nil
            if frame.listBreak { requestBreak(frame.indent + 1) }
        }

        /// A comma at nesting level zero before the clause ends. Parenthesised groups are skipped whole, so the
        /// look-ahead stays linear in the clause, however deeply it nests.
        private func hasTopLevelComma(after index: Int) -> Bool {
            var cursor = index + 1
            var previous = index
            while cursor < tokens.count {
                let token = tokens[cursor]
                let word = words[cursor]
                if token.kind == .punctuation {
                    switch word {
                    case "(":
                        guard let close = closing[cursor] else { return false }
                        previous = close
                        cursor = close + 1
                        continue
                    case ")", ";": return false
                    case ",": return true
                    default: break
                    }
                } else if token.kind == .keyword, !qualified[cursor], SQLFormatter.clauseEndWords.contains(word),
                          !isOperand(cursor, after: previous) {
                    return false
                }
                if token.kind != .comment { previous = cursor }
                cursor += 1
            }
            return false
        }

        // MARK: CASE

        private mutating func beginCase(_ index: Int) {
            let shape = caseShapes[index]
            let endIndex = shape?.end
            let multiline = layout && frame.kind != .paren && endIndex != nil && (shape?.branches ?? 0) >= 2
            write(index, space: spaceBefore(index))
            frame.cases.append(CaseInfo(multiline: multiline, indent: lineIndent, endIndex: endIndex))
            finishListHead(index)
        }

        // MARK: Spacing

        /// Tracks whether the tokens after INTO / TABLE / VIEW are a (qualified) table name.
        private mutating func advanceTableName(_ index: Int) {
            let kind = tokens[index].kind
            let word = words[index]
            if kind == .keyword, !qualified[index], word == "INTO" || word == "TABLE" || word == "VIEW" {
                tableNameState = 1
                tableNameIsCreateTable = word == "TABLE" && statementWords.first == "CREATE"
                return
            }
            switch tableNameState {
            case 1:
                if isKeyword(index, "IF") || isKeyword(index, "NOT") || isKeyword(index, "EXISTS") { return }
                // Words only some servers reserve are table names elsewhere (`INSERT INTO row (a)`).
                tableNameState = isName(index) || qualified[index] ? 2 : 0
            case 2:
                tableNameState = isPunctuation(index, ".") ? 1 : 0
            default:
                break
            }
        }

        /// MySQL resolves a built-in function only when `(` follows its name directly (`COUNT (*)` is another statement),
        /// so after a name or a word not reserved everywhere the space is kept as written. After a reserved word the
        /// server ignores whitespace: function-like ones are attached, others spaced.
        private func spaceBeforeOpenParen(_ index: Int, previous: Int?) -> Bool {
            guard let previous else { return false }
            let word = words[previous]
            switch tokens[previous].kind {
            case .keyword:
                guard isReserved(previous) else { return wasSeparated(previous, index) }
                if word == "VALUES" { return frame.clause == .values } // the VALUES clause, or the `VALUES(col)` function
                return !SQLFormatter.callLikeKeywords.contains(word)
            case .identifier, .quotedIdentifier, .variable, .number, .string, .executableComment:
                return wasSeparated(previous, index)
            case .punctuation:
                if word == "." { return wasSeparated(previous, index) } // kept as written, like every gap at a `.`
                return word == "," || word == ")"
            case .operator, .comment:
                return true
            }
        }

        private func spaceBefore(_ index: Int) -> Bool {
            guard let previous = lastWritten else { return false }
            let current = tokens[index]
            let text = words[index]
            let prev = tokens[previous]
            let prevText = words[previous]

            if prev.kind == .comment { return true }
            switch current.kind {
            case .punctuation where text == ")" || text == "," || text == ";":
                return false
            case .punctuation where text == ".":
                // Kept as written: `t. order` and `t.order` are read differently.
                return wasSeparated(previous, index) || mustSeparate(previous, index)
            default:
                break
            }
            if prev.kind == .punctuation, prevText == "." { return wasSeparated(previous, index) || mustSeparate(previous, index) }
            if prev.kind == .punctuation, prevText == "(" { return mustSeparate(previous, index) }
            return true
        }

        /// A `-` / `+` sign (not a binary operator), judged from the token before it.
        private func isUnaryOperator(_ index: Int) -> Bool {
            guard tokens[index].kind == .operator, words[index] == "-" || words[index] == "+" else { return false }
            guard let previous = lastSignificant else { return true }
            let word = words[previous]
            switch tokens[previous].kind {
            case .operator: return true
            case .punctuation: return word == "(" || word == ","
            case .keyword: return isReserved(previous) && !SQLFormatter.operandKeywords.contains(word)
            default: return false
            }
        }

        /// Whether writing `index` directly after `previous` would lex differently.
        private func mustSeparate(_ previous: Int, _ index: Int) -> Bool {
            let prev = tokens[previous]
            let current = tokens[index]
            let wordLike: Set<SQLToken.Kind> = [.identifier, .keyword, .number, .variable]
            if wordLike.contains(prev.kind), wordLike.contains(current.kind) { return true }
            if prev.kind == current.kind, prev.kind == .string || prev.kind == .quotedIdentifier { return true }
            if prev.kind == .number, words[index] == "." { return true }
            if words[previous] == ".", current.kind == .number { return true }
            if prev.kind == .variable, words[index] == "." { return true }
            if prev.kind == .operator, current.kind == .operator || current.kind == .number || current.kind == .comment {
                let last = lexer.units[prev.range.upperBound - 1]
                let first = lexer.units[current.range.lowerBound]
                if current.kind == .operator, SQLLexer.isOperatorContinuation(first) { return true }
                if last == 0x2D, first == 0x2D { return true } // `- -` would start a comment
                if last == 0x2F, first == 0x2A { return true } // `/ *` would start a comment
            }
            return false
        }
    }
}
