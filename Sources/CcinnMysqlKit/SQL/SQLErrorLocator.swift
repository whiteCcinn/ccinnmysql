import Foundation

/// A MySQL / MariaDB statement error, parsed from its message.
///
/// Syntax errors carry the rest of the statement from the failing token and that token's line:
/// `You have an error in your SQL syntax; … near 'shop.orders' at line 1`. The echo is cut at 80 bytes
/// (MySQL mid-character, the cut bytes then re-encoded as Latin-1; MariaDB at a character boundary,
/// followed by `...`), and characters outside the BMP come back as `?`. Most other errors name the
/// object instead: `Unknown column 'o.x' in 'where clause'`, `Table 'shop.t' doesn't exist`, … — with
/// MariaDB's clause names (`'WHERE'`, `'SELECT'`) where MySQL has `'where clause'`, `'field list'`.
public struct SQLServerError: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case syntax
        case other
    }

    /// Where a syntax error starts.
    public struct SyntaxPosition: Sendable, Equatable {
        /// The echoed text, without truncation artefacts (a cut character, MariaDB's `...`).
        public var snippet: String
        /// The failing token's 1-based line (`\n` counts); `nil` when absent or too large.
        public var line: Int?
        /// The server shortened the echo: only its start is the statement's text.
        public var isTruncated: Bool

        public init(snippet: String, line: Int?, isTruncated: Bool) {
            self.snippet = snippet
            self.line = line
            self.isTruncated = isTruncated
        }

        /// `near ''`: the statement ended where more was expected.
        public var isEndOfInput: Bool { snippet.isEmpty && !isTruncated }
    }

    public var phase: Phase
    /// MySQL error number (1064, 1054, …), when known.
    public var code: Int?
    public var syntax: SyntaxPosition?
    /// The message without the app's ` (error N)` suffix.
    public var detail: String
    /// What is displayed: `Syntax error near '…'` or the message, at most `summaryLimit` characters.
    public var summary: String
    /// Objects the message names, split on `.` (`'shop.orders.x'` → `["shop", "orders", "x"]`).
    public var names: [[String]]
    /// The clause keyword the named column is in (`WHERE`, `ON`, `ORDER`, `GROUP`, `HAVING`, `SET`).
    public var clause: String?
    /// `Unknown system variable 'x'`.
    public var variable: String?

    public static let summaryLimit = 500
    /// Characters of the marked text quoted in a marker's message.
    public static let markerTextLimit = 60
    /// Server messages are at most 512 bytes; anything much longer is not scanned for positions or names.
    static let scanLimit = 8_192
    /// The server echoes at most this many bytes of the statement.
    static let echoByteLimit = 80

    public init(phase: Phase, code: Int? = nil, syntax: SyntaxPosition? = nil, detail: String, names: [[String]] = [],
                clause: String? = nil, variable: String? = nil) {
        self.phase = phase
        self.code = code
        self.syntax = syntax
        self.detail = detail
        self.names = names
        self.clause = clause
        self.variable = variable
        summary = Self.summarize(detail, syntax: syntax)
    }

    /// Parses a server message (`MySQLError.message`); an app-formatted one (` (error N)`) is accepted too.
    public static func parse(_ message: String, code: Int? = nil) -> SQLServerError {
        var detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = code
        // The app's ` (error N)` suffix (checked from the end: the message may be huge).
        if detail.hasSuffix(")"), let open = detail.range(of: " (error ", options: .backwards) {
            let digits = detail[open.upperBound...].dropLast()
            if !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
                code = code ?? Int(digits)
                detail.removeSubrange(open.lowerBound...)
                detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard detail.utf8.count <= scanLimit else {
            return SQLServerError(phase: .other, code: code, detail: detail)
        }
        var syntax: SyntaxPosition?
        if let match = detail.firstMatch(of: /near '(.*)' at line (\d+)\z/.dotMatchesNewlines()) {
            let digits = match.output.2
            syntax = position(echo: match.output.1, line: digits.count <= 18 ? Int(digits) : nil)
        }
        let isSyntax = syntax != nil || code == 1064 || code == 1149 || detail.contains("You have an error in your SQL syntax")
        guard !isSyntax else { return SQLServerError(phase: .syntax, code: code, syntax: syntax, detail: detail) }
        let (names, clause, variable) = objects(in: detail)
        return SQLServerError(phase: .other, code: code, detail: detail, names: names, clause: clause, variable: variable)
    }

    /// The kind and code, with an **editor** position when one is known. A position the server reports is
    /// relative to the executed statement (and includes an `EXPLAIN` prefix), so it is never shown here.
    public func title(at position: SQLTextPosition?) -> String {
        let kind = code.map { "\(kindLabel) \($0)" } ?? kindLabel
        guard let position else { return kind }
        return "\(kind) at line \(position.line), column \(position.column)"
    }

    /// The message of an editor marker on `marked` (the text the user wrote there). A syntax error names
    /// the marked token: the server's echo runs on to the end of the statement and includes text the app
    /// added (` LIMIT 1000`). Other errors name their object already.
    public func markerMessage(for marked: String) -> String {
        guard let syntax else { return summary }
        if syntax.isEndOfInput { return "Syntax error at the end of the statement" }
        let flat = marked.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let shown = flat.count > Self.markerTextLimit ? String(flat.prefix(Self.markerTextLimit)) + "…" : flat
        return "Syntax error near '\(shown)'"
    }

    /// "Syntax error" or "Error".
    public var kindLabel: String {
        switch phase {
        case .syntax: "Syntax error"
        case .other: "Error"
        }
    }

    // MARK: Syntax echo

    static func position(echo: Substring, line: Int?) -> SyntaxPosition {
        var snippet = String(echo)
        let bytes = snippet.utf8.count
        var truncated = false
        if snippet.hasSuffix("..."), bytes >= echoByteLimit - 3, bytes <= echoByteLimit {
            // MariaDB: cut at a character boundary, then `...`.
            truncated = true
            snippet.removeLast(3)
        } else if bytes > echoByteLimit {
            // MySQL: cut at byte 80; the k bytes of the split character come back as k Latin-1 scalars.
            truncated = true
            let extra = bytes - echoByteLimit
            let scalars = snippet.unicodeScalars
            if extra <= 3, scalars.count >= extra, scalars.suffix(extra).allSatisfy({ (0x80...0xFF).contains($0.value) }) {
                snippet = String(String.UnicodeScalarView(scalars.dropLast(extra)))
            }
        } else if bytes == echoByteLimit {
            truncated = true
        }
        return SyntaxPosition(snippet: snippet, line: line, isTruncated: truncated)
    }

    static func summarize(_ detail: String, syntax: SyntaxPosition?) -> String {
        let text: String
        if let syntax {
            text = syntax.isEndOfInput ? "Syntax error at the end of the statement"
                : "Syntax error near '\(syntax.snippet.prefix(summaryLimit))\(syntax.isTruncated ? "…" : "")'"
        } else {
            text = String(detail.prefix(summaryLimit + 1))
        }
        guard text.count > summaryLimit else { return text }
        return String(text.prefix(summaryLimit)) + "…"
    }

    // MARK: Named objects

    /// Patterns recorded from MySQL 8.4 and MariaDB 10.11 (names are printed unquoted).
    static func objects(in detail: String) -> (names: [[String]], clause: String?, variable: String?) {
        if let match = detail.wholeMatch(of: /Unknown column '(.*)' in '([^']*)'/) {
            return (split(match.output.1), clauseKeyword(match.output.2), nil)
        }
        if let match = detail.wholeMatch(of: /Column '(.*)' in (.*) is ambiguous/) {
            return (split(match.output.1), clauseKeyword(match.output.2), nil)
        }
        if let match = detail.wholeMatch(of: /Unknown system variable '(.*)'/) {
            return ([], nil, String(match.output.1))
        }
        let name: Substring? = detail.wholeMatch(of: /Table '(.*)' doesn't exist/)?.output.1
            ?? detail.wholeMatch(of: /Unknown table '(.*?)'(?: in [^']*)?/)?.output.1
            ?? detail.wholeMatch(of: /Unknown database '(.*)'/)?.output.1
            ?? detail.prefixMatch(of: /(?:FUNCTION|PROCEDURE) (\S+) does not exist/)?.output.1
            ?? detail.prefixMatch(of: /Incorrect number of arguments for (?:FUNCTION|PROCEDURE) (\S+); expected/)?.output.1
            ?? detail.wholeMatch(of: /Key column '(.*)' doesn't exist in table/)?.output.1
        return (name.map(split) ?? [], nil, nil)
    }

    /// `shop.orders.x` → `[["shop", "orders", "x"]]`; a name with an empty part is kept whole.
    static func split(_ raw: Substring) -> [[String]] {
        guard !raw.isEmpty else { return [] }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return [parts.contains(where: \.isEmpty) ? [String(raw)] : parts]
    }

    static func clauseKeyword(_ clause: Substring) -> String? {
        switch clause.lowercased() {
        case "where clause", "where": "WHERE"
        case "on clause", "on": "ON"
        case "order clause", "order by": "ORDER"
        case "group statement", "group by": "GROUP"
        case "having clause", "having": "HAVING"
        case "set": "SET"
        default: nil
        }
    }
}

/// How the text the server executed relates to the statement in the editor: the app may prepend
/// (`EXPLAIN FORMAT=JSON `) and insert (` LIMIT n`). Offsets are UTF-16.
public struct SQLExecutedTextMapping: Sendable, Equatable {
    public var prefixLength: Int
    /// Range of inserted text, in executed coordinates.
    public var insertion: Range<Int>?

    public static let identity = SQLExecutedTextMapping()

    public init(prefixLength: Int = 0, insertion: Range<Int>? = nil) {
        self.prefixLength = max(0, prefixLength)
        self.insertion = insertion
    }

    /// Source offset for an executed offset. Positions inside the insertion map to its start;
    /// positions inside the prefix map to 0. Never negative.
    public func sourceOffset(forExecuted offset: Int) -> Int {
        var value = max(0, offset)
        if let insertion {
            if value >= insertion.upperBound {
                value -= insertion.count
            } else if value > insertion.lowerBound {
                value = insertion.lowerBound
            }
        }
        return max(0, value - prefixLength)
    }
}

/// Finds the text a MySQL / MariaDB error refers to inside the statement that failed.
public enum SQLErrorLocator {
    /// UTF-16 offset in `statement` where the syntax error's echo starts (no token expansion); the end for
    /// `near ''`. `nil` for other errors or when the echo is not found.
    public static func offset(in statement: String, message: String) -> Int? {
        guard let syntax = SQLServerError.parse(message).syntax else { return nil }
        let lexer = SQLLexer(statement)
        if syntax.isEndOfInput { return lexer.units.count }
        return echoStart(syntax, in: lexer, tokens: lexer.tokens())
    }

    /// The range to mark in `statement`, for a message about that same text.
    public static func range(in statement: String, message: String) -> Range<Int>? {
        range(in: statement, error: SQLServerError.parse(message))
    }

    /// The range (UTF-16, in `source`) to mark for `error`. A syntax echo is found in `executed` (what the
    /// server saw; `source` when nil) and mapped back with `mapping`, then widened to its token (the `/*`
    /// of an unterminated comment; the last token for `near ''`). Other errors mark the object they name.
    /// `nil` when nothing can be located.
    public static func range(in source: String, executed: String? = nil, mapping: SQLExecutedTextMapping = .identity,
                             error: SQLServerError) -> Range<Int>? {
        let lexer = SQLLexer(source)
        let allTokens = lexer.tokens()
        let tokens = allTokens.filter { $0.kind != .comment }
        guard !tokens.isEmpty else { return nil }

        if let syntax = error.syntax {
            let executedLexer = executed.map { SQLLexer($0) } ?? lexer
            let executedOffset: Int?
            if syntax.isEndOfInput {
                executedOffset = executedLexer.units.count
            } else {
                executedOffset = echoStart(syntax, in: executedLexer, tokens: executed == nil ? allTokens : executedLexer.tokens())
            }
            guard let executedOffset else { return nil }
            let start = min(mapping.sourceOffset(forExecuted: executedOffset), lexer.units.count)
            // The server stops at an unterminated `/*`; mark the `/*`.
            if let comment = allTokens.last, comment.kind == .comment || comment.kind == .executableComment,
               lexer.isUnterminated(comment), comment.range.lowerBound <= start {
                return comment.range.lowerBound..<min(comment.range.lowerBound + 2, comment.range.upperBound)
            }
            return tokens[tokenIndex(at: start, in: tokens)].range
        }

        if let variable = error.variable {
            if let found = variableToken(named: variable, in: tokens, lexer: lexer) { return found }
            return locate([variable], clause: nil, in: tokens, lexer: lexer)
        }
        for name in error.names {
            if let found = locate(name, clause: error.clause, in: tokens, lexer: lexer) { return found }
        }
        return nil
    }

    // MARK: Syntax echo

    /// Where the echo starts in `lexer`'s text:
    /// 1. a complete echo must be the text's suffix: MySQL echoes the whole rest, so it is unique, and an
    ///    echo found elsewhere is about another statement (one a procedure prepared, say) — no guess;
    /// 2. a truncated echo: the token start where it matches, nearest the reported line (MySQL reports the
    ///    line where a multi-line token ends, MariaDB where it starts), then the first;
    /// 3. else any position on the reported line (in case token boundaries differ from the server's).
    static func echoStart(_ syntax: SQLServerError.SyntaxPosition, in lexer: SQLLexer, tokens: [SQLToken]) -> Int? {
        let pattern = Array(syntax.snippet.unicodeScalars)
        guard !pattern.isEmpty else { return nil }
        let units = lexer.units
        guard syntax.isTruncated else { return suffixStart(of: pattern, in: units) }

        var best: (distance: Int, offset: Int)?
        var line = 1
        var scanned = 0
        for token in tokens {
            let start = token.range.lowerBound
            while scanned < start, scanned < units.count {
                if units[scanned] == 0x0A { line += 1 }
                scanned += 1
            }
            guard matches(pattern, in: units, at: start) else { continue }
            let distance = syntax.line.map { $0 > line ? $0 - line : line - $0 } ?? 0
            if let current = best, current.distance <= distance { continue }
            best = (distance, start)
            if distance == 0 { break }
        }
        if let best { return best.offset }

        guard let reported = syntax.line, let bounds = lineBounds(reported, in: units) else { return nil }
        var index = bounds.lowerBound
        while index < bounds.upperBound {
            if matches(pattern, in: units, at: index) { return index }
            index += scalar(at: index, in: units).width
        }
        return nil
    }

    /// `?` in an echo also stands for a character outside the BMP (the error message's character set has none).
    static func scalar(_ wanted: Unicode.Scalar, matches value: UInt32) -> Bool {
        wanted.value == value || (wanted == "?" && value > 0xFFFF)
    }

    /// The scalar at `index` and its UTF-16 width (a lone surrogate counts as itself).
    static func scalar(at index: Int, in units: [UInt16]) -> (value: UInt32, width: Int) {
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
            return (value, 2)
        }
        return (UInt32(unit), 1)
    }

    /// The whole pattern matches the text starting at `start` (the text may continue). O(pattern).
    static func matches(_ pattern: [Unicode.Scalar], in units: [UInt16], at start: Int) -> Bool {
        var index = start
        for wanted in pattern {
            guard index < units.count else { return false }
            let (value, width) = scalar(at: index, in: units)
            guard scalar(wanted, matches: value) else { return false }
            index += width
        }
        return true
    }

    /// Start of the pattern when the text ends with it (ignoring trailing whitespace and `;` on both).
    static func suffixStart(of pattern: [Unicode.Scalar], in units: [UInt16]) -> Int? {
        var patternEnd = pattern.count
        while patternEnd > 0, pattern[patternEnd - 1].properties.isWhitespace { patternEnd -= 1 }
        guard patternEnd > 0 else { return nil }
        var index = units.count
        while index > 0, units[index - 1] <= 0x20 || units[index - 1] == 0x3B { index -= 1 }
        var remaining = patternEnd
        while remaining > 0 {
            guard index > 0 else { return nil }
            var width = 1
            var value = UInt32(units[index - 1])
            if UTF16.isTrailSurrogate(units[index - 1]), index >= 2, UTF16.isLeadSurrogate(units[index - 2]) {
                value = scalar(at: index - 2, in: units).value
                width = 2
            }
            guard scalar(pattern[remaining - 1], matches: value) else { return nil }
            index -= width
            remaining -= 1
        }
        return index
    }

    /// UTF-16 range of a 1-based line (only `\n` ends a line); `nil` when the text has fewer lines.
    static func lineBounds(_ line: Int, in units: [UInt16]) -> Range<Int>? {
        guard line >= 1 else { return nil }
        var current = 1
        var start = 0
        var index = 0
        while current < line {
            while index < units.count, units[index] != 0x0A { index += 1 }
            guard index < units.count else { return nil }
            index += 1
            current += 1
            start = index
        }
        var end = start
        while end < units.count, units[end] != 0x0A { end += 1 }
        return start..<end
    }

    /// The token containing `offset`, else the last token ending at or before it, else the first.
    static func tokenIndex(at offset: Int, in tokens: [SQLToken]) -> Int {
        // First token that ends after `offset` (binary search).
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        if low < tokens.count, tokens[low].range.lowerBound <= offset { return low }
        return max(0, low - 1)
    }

    // MARK: Named objects

    /// A named object: after the clause keyword, then anywhere, as an unqualified reference (an
    /// unqualified message is about one), then qualified; then the dotted name as one back-quoted
    /// identifier; then shorter suffixes (`shop.nosuch_fn` finds `nosuch_fn(1)`).
    static func locate(_ segments: [String], clause: String?, in tokens: [SQLToken], lexer: SQLLexer) -> Range<Int>? {
        guard !segments.isEmpty else { return nil }
        let clauseStart = clause.flatMap { keyword in
            tokens.firstIndex { $0.kind == .keyword && lexer.text(of: $0).uppercased() == keyword }.map { $0 + 1 }
        }
        var attempts: [(from: Int, unqualified: Bool)] = []
        if let clauseStart { attempts.append((clauseStart, true)) }
        attempts += [(0, true), (0, false)]
        for attempt in attempts {
            if let found = sequence(segments, in: tokens, lexer: lexer, from: attempt.from, unqualifiedOnly: attempt.unqualified) { return found }
        }
        if segments.count > 1,
           let found = sequence([segments.joined(separator: ".")], in: tokens, lexer: lexer, from: 0, unqualifiedOnly: false) {
            return found
        }
        var suffix = segments.dropFirst()
        while !suffix.isEmpty {
            for unqualified in [true, false] {
                if let found = sequence(Array(suffix), in: tokens, lexer: lexer, from: 0, unqualifiedOnly: unqualified) { return found }
            }
            suffix = suffix.dropFirst()
        }
        return nil
    }

    /// Tokens spelling `a . b . c` from token `from` on (identifier values compared case-insensitively);
    /// with `unqualifiedOnly`, not preceded by a `.`.
    static func sequence(_ segments: [String], in tokens: [SQLToken], lexer: SQLLexer, from: Int, unqualifiedOnly: Bool) -> Range<Int>? {
        guard !segments.isEmpty else { return nil }
        let wanted = segments.map { $0.lowercased() }
        let span = segments.count * 2 - 1
        guard from >= 0, tokens.count - from >= span else { return nil }
        func isName(_ token: SQLToken) -> Bool {
            token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
        }
        func isDot(_ token: SQLToken) -> Bool {
            token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E
        }
        for start in from...(tokens.count - span) {
            if unqualifiedOnly, start > 0, isDot(tokens[start - 1]) { continue }
            var matches = true
            for (offset, name) in wanted.enumerated() {
                let token = tokens[start + offset * 2]
                guard isName(token), lexer.identifierValue(of: token).lowercased() == name else { matches = false; break }
                if offset > 0, !isDot(tokens[start + offset * 2 - 1]) { matches = false; break }
            }
            if matches { return tokens[start].range.lowerBound..<tokens[start + span - 1].range.upperBound }
        }
        return nil
    }

    /// `@@name`, `@@session.name`, `@@global.name`, … for `Unknown system variable 'name'`.
    static func variableToken(named name: String, in tokens: [SQLToken], lexer: SQLLexer) -> Range<Int>? {
        let wanted = name.lowercased()
        let scopes: Set<String> = ["global", "session", "local", "persist", "persist_only"]
        for token in tokens where token.kind == .variable {
            var text = Substring(lexer.text(of: token))
            guard text.hasPrefix("@@") else { continue }
            text = text.dropFirst(2)
            if let dot = text.firstIndex(of: "."), scopes.contains(text[..<dot].lowercased()) { text = text[text.index(after: dot)...] }
            if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") { text = text.dropFirst().dropLast() }
            if text.lowercased() == wanted { return token.range }
        }
        return nil
    }
}
