import Foundation

/// Case-insensitive lookups of a database's tables and columns for the code scanner.
public struct CodeSchemaIndex: Sendable {
    public let tables: [String: TableFacts]
    /// Lower-cased name → exact name; `nil` when two tables differ only in case (ambiguous without the original case).
    private let tablesByLowercase: [String: String?]
    /// Exact table name → lower-cased column → exact column.
    private let columnsByTable: [String: [String: String]]

    public init(_ tables: [TableFacts]) {
        var exact: [String: TableFacts] = [:]
        var lowered: [String: String?] = [:]
        var columns: [String: [String: String]] = [:]
        for table in tables where table.state != .dropped {
            exact[table.name] = table
            let key = table.name.lowercased()
            lowered[key] = lowered[key] == nil ? .some(table.name) : .some(nil)
            var byName: [String: String] = [:]
            for column in table.columns where byName[column.name.lowercased()] == nil {
                byName[column.name.lowercased()] = column.name
            }
            columns[table.name] = byName
        }
        self.tables = exact
        tablesByLowercase = lowered
        columnsByTable = columns
    }

    /// The exact name of a table given its lower-cased name.
    public func table(lowercased name: String) -> String? {
        tablesByLowercase[name] ?? nil
    }

    public func column(lowercased name: String, in table: String) -> String? {
        columnsByTable[table]?[name]
    }

    /// A one-column primary key, or a one-column unique key.
    public func isSingleColumnKey(_ column: String, of table: String) -> Bool {
        guard let keys = tables[table]?.keys else { return false }
        let lowered = column.lowercased()
        if keys.primary.count == 1, keys.primary[0].lowercased() == lowered { return true }
        return keys.unique.contains { $0.count == 1 && $0[0].lowercased() == lowered }
    }
}

/// Finds `JOIN … ON a.x = b.y`, `USING (c)` and comma-join equalities in arbitrary text: source files of any language,
/// MyBatis XML, `.sql` files (CcinnMysql 1.5's code scanner, kept as a knowledge source). A token state machine, not a parser: precision
/// comes from resolving every qualifier and column against the snapshot, so unknown names never produce a finding.
public enum CodeSQLScanner {
    /// One side of a join found in code.
    public struct End: Sendable, Hashable {
        public let table: String
        public let columns: [String]

        /// `orders(customer_id)`.
        public var label: String { "\(table)(\(columns.joined(separator: ", ")))" }

        public init(table: String, columns: [String]) {
            self.table = table
            self.columns = columns
        }
    }

    public enum Cardinality: String, Sendable, Hashable {
        /// Many rows of `from` reference one row of `to`.
        case manyToOne
        case oneToOne
        /// Neither side is a single-column key: the direction is as written.
        case unknown
    }

    /// What `analyze` builds for each join before counting.
    struct Found {
        let from: End
        let to: End
        let cardinality: Cardinality
    }

    public struct Join: Sendable, Hashable {
        public let from: End
        public let to: End
        public let cardinality: Cardinality
        /// First line where it was seen.
        public let line: Int
        public let count: Int
    }

    public struct TableUse: Sendable, Hashable {
        public var count: Int
        public var firstLine: Int
        /// Seen after FROM/JOIN/INTO/UPDATE/TABLE, not only as a string equal to the name.
        public var sql: Bool
    }

    public struct Findings: Sendable {
        public var joins: [Join] = []
        /// Exact table name → use.
        public var tables: [String: TableUse] = [:]
    }

    enum Kind: UInt8 {
        case word, dot, comma, semicolon, open, close, equals
    }

    struct Token {
        let kind: Kind
        /// Lower-cased (ASCII letters) for words; empty otherwise.
        let text: String
        let line: Int
        /// A word written as a whole string literal: `"orders"`, `'orders'`.
        let isWholeString: Bool
    }

    /// Aliases expire this many tokens after their definition (and at `;`).
    static let aliasReach = 600
    static let maxIdentifierBytes = 64

    /// Words that end a table reference instead of naming an alias.
    static let notAliases: Set<String> = [
        "where", "on", "join", "inner", "left", "right", "outer", "cross", "natural", "straight_join", "using", "set", "values",
        "value", "select", "group", "order", "limit", "having", "union", "except", "intersect", "minus", "for", "lock", "force",
        "use", "ignore", "partition", "window", "as", "and", "or", "into", "from", "update", "delete", "insert", "replace", "with",
        "returning", "not", "exists", "in", "is", "null", "then", "when", "else", "end", "case", "full", "lateral", "procedure",
        "offset", "fetch", "by", "asc", "desc", "default", "key", "index", "primary", "unique", "foreign", "references",
        "constraint", "if", "table", "tables", "like", "engine", "charset", "character", "collate", "comment", "low_priority",
        "high_priority", "quick", "delayed", "duplicate", "begin", "commit", "rollback", "do", "while", "loop", "repeat", "return",
        "returns", "declare", "open", "close", "cursor", "handler", "continue", "exit", "leave", "iterate", "signal", "elseif", "call",
        "all", "any", "some", "distinct", "straight", "sql_calc_found_rows", "nowait", "skip", "share", "mode", "tablesample",
    ]

    public static func scan(_ bytes: [UInt8], index: CodeSchemaIndex, database: String) -> Findings {
        let tokens = tokenize(bytes)
        return analyze(tokens, index: index, database: database.lowercased())
    }

    // MARK: Tokens

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "$"), 0x80...0xFF:
            true
        default:
            false
        }
    }

    /// ASCII letters lower-cased. Typed step by step: older compilers give up on literal-heavy byte expressions.
    static func lowercasedText(_ bytes: ArraySlice<UInt8>) -> String {
        var lowered: [UInt8] = []
        lowered.reserveCapacity(bytes.count)
        let upperA: UInt8 = 0x41
        let upperZ: UInt8 = 0x5A
        let offset: UInt8 = 0x20
        for byte in bytes {
            let isUpper: Bool = byte >= upperA && byte <= upperZ
            lowered.append(isUpper ? byte &+ offset : byte)
        }
        return String(decoding: lowered, as: UTF8.self)
    }

    static let notBeforeEquals: Set<UInt8> = Set("=!<>:+-*/%&|^~?".utf8)
    static let notAfterEquals: Set<UInt8> = Set("=>~".utf8)

    static func tokenize(_ bytes: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(bytes.count / 6)
        var line = 1
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if isWordByte(byte) {
                let start = index
                while index < count, isWordByte(bytes[index]) { index += 1 }
                guard index - start <= maxIdentifierBytes else { continue }
                var whole = false
                if start > 0, index < count {
                    let before = bytes[start - 1]
                    whole = (before == UInt8(ascii: "\"") || before == UInt8(ascii: "'")) && bytes[index] == before
                }
                tokens.append(Token(kind: .word, text: lowercasedText(bytes[start..<index]), line: line, isWholeString: whole))
                continue
            }
            switch byte {
            case UInt8(ascii: "\n"):
                line += 1
            case UInt8(ascii: "`"):
                // A back-quoted name is short, on one line and has no white space; otherwise the back quote opens a Go raw
                // string or a JavaScript template literal, whose contents are tokenized as usual.
                var end = index + 1
                while end < count, end - index <= maxIdentifierBytes + 1, bytes[end] != UInt8(ascii: "`"),
                      bytes[end] != UInt8(ascii: " "), bytes[end] != UInt8(ascii: "\n"), bytes[end] != UInt8(ascii: "\t"),
                      bytes[end] != UInt8(ascii: "\r") {
                    end += 1
                }
                if end < count, bytes[end] == UInt8(ascii: "`"), end > index + 1 {
                    tokens.append(Token(kind: .word, text: lowercasedText(bytes[(index + 1)..<end]), line: line, isWholeString: false))
                    index = end + 1
                    continue
                }
            case UInt8(ascii: "."):
                tokens.append(Token(kind: .dot, text: "", line: line, isWholeString: false))
            case UInt8(ascii: ","):
                tokens.append(Token(kind: .comma, text: "", line: line, isWholeString: false))
            case UInt8(ascii: ";"):
                tokens.append(Token(kind: .semicolon, text: "", line: line, isWholeString: false))
            case UInt8(ascii: "("):
                tokens.append(Token(kind: .open, text: "", line: line, isWholeString: false))
            case UInt8(ascii: ")"):
                tokens.append(Token(kind: .close, text: "", line: line, isWholeString: false))
            case UInt8(ascii: "="):
                let before = index > 0 ? bytes[index - 1] : 0
                let after = index + 1 < count ? bytes[index + 1] : 0
                if !notBeforeEquals.contains(before), !notAfterEquals.contains(after) {
                    tokens.append(Token(kind: .equals, text: "", line: line, isWholeString: false))
                }
            default:
                break
            }
            index += 1
        }
        return tokens
    }

    // MARK: State machine

    private struct Alias {
        let table: String
        let definedAt: Int
    }

    private struct JoinKey: Hashable {
        let from: End
        let to: End
    }

    static func analyze(_ tokens: [Token], index: CodeSchemaIndex, database: String) -> Findings {
        var findings = Findings()
        var aliases: [String: Alias] = [:]
        var previousTable: String?
        var joins: [JoinKey: (cardinality: Cardinality, line: Int, count: Int)] = [:]
        var joinOrder: [JoinKey] = []

        func isWord(_ position: Int) -> Bool { position < tokens.count && tokens[position].kind == .word }
        func kind(_ position: Int) -> Kind? { position < tokens.count ? tokens[position].kind : nil }

        func use(_ table: String, line: Int, sql: Bool) {
            if var existing = findings.tables[table] {
                existing.count += 1
                existing.sql = existing.sql || sql
                findings.tables[table] = existing
            } else {
                findings.tables[table] = TableUse(count: 1, firstLine: line, sql: sql)
            }
        }

        /// `[schema.]table` at `position`: the exact table (nil when unknown or in another database) and the next position.
        func tableReference(at position: Int) -> (table: String?, word: String, next: Int)? {
            guard isWord(position) else { return nil }
            if kind(position + 1) == .dot, isWord(position + 2) {
                let schema = tokens[position].text
                let name = tokens[position + 2].text
                return (schema == database ? index.table(lowercased: name) : nil, name, position + 3)
            }
            let name = tokens[position].text
            return (index.table(lowercased: name), name, position + 1)
        }

        /// A qualifier (alias or table name) seen at `position`.
        func resolve(qualifier: String, at position: Int) -> String? {
            if let alias = aliases[qualifier], position - alias.definedAt <= aliasReach { return alias.table }
            return index.table(lowercased: qualifier)
        }

        /// `q.c` or `schema.t.c` at `position`: the exact table and column, and the next position.
        func columnReference(at position: Int) -> (table: String?, column: String?, next: Int)? {
            guard isWord(position), kind(position + 1) == .dot, isWord(position + 2) else { return nil }
            if kind(position + 3) == .dot, isWord(position + 4) {
                let schema = tokens[position].text
                let table = schema == database ? index.table(lowercased: tokens[position + 2].text) : nil
                return (table, table.flatMap { index.column(lowercased: tokens[position + 4].text, in: $0) }, position + 5)
            }
            let table = resolve(qualifier: tokens[position].text, at: position)
            return (table, table.flatMap { index.column(lowercased: tokens[position + 2].text, in: $0) }, position + 3)
        }

        func addJoin(_ leftTable: String, _ leftColumn: String, _ rightTable: String, _ rightColumn: String, line: Int) {
            guard leftTable != rightTable || leftColumn != rightColumn else { return }
            let leftKey = index.isSingleColumnKey(leftColumn, of: leftTable)
            let rightKey = index.isSingleColumnKey(rightColumn, of: rightTable)
            let left = End(table: leftTable, columns: [leftColumn])
            let right = End(table: rightTable, columns: [rightColumn])
            let relationship: Found
            switch (leftKey, rightKey) {
            case (false, true): relationship = Found(from: left, to: right, cardinality: .manyToOne)
            case (true, false): relationship = Found(from: right, to: left, cardinality: .manyToOne)
            case (true, true):
                // Both sides are keys: the text gives no direction, so the order is canonical (the same join written
                // either way is one relationship).
                let (first, second) = left.label <= right.label ? (left, right) : (right, left)
                relationship = Found(from: first, to: second, cardinality: .oneToOne)
            case (false, false): relationship = Found(from: left, to: right, cardinality: .unknown)
            }
            let key = JoinKey(from: relationship.from, to: relationship.to)
            if let existing = joins[key] {
                joins[key] = (existing.cardinality, existing.line, existing.count + 1)
            } else {
                joins[key] = (relationship.cardinality, line, 1)
                joinOrder.append(key)
            }
        }

        var position = 0
        /// Inside SET, a SELECT list or ON DUPLICATE KEY UPDATE: `a.x = b.y` there is an assignment or a value, not a join.
        var outsideConditions = false
        while position < tokens.count {
            // Hostile or huge text stops when the scan is cancelled (what was found so far is returned).
            if position & 0x1FFF == 0, Task.isCancelled { break }
            let token = tokens[position]
            var resume = position + 1
            switch token.kind {
            case .semicolon:
                aliases.removeAll(keepingCapacity: true)
                previousTable = nil
                outsideConditions = false
            case .word:
                if token.isWholeString, let table = index.table(lowercased: token.text) {
                    use(table, line: token.line, sql: false)
                }
                switch token.text {
                case "set", "select":
                    outsideConditions = true
                case "where", "on", "using", "having":
                    outsideConditions = false
                case "update" where position > 0 && tokens[position - 1].text == "key":
                    // ON DUPLICATE KEY UPDATE assignments.
                    outsideConditions = true
                case "from", "join", "update", "into", "straight_join":
                    if token.text == "from" || token.text == "join" || token.text == "straight_join" { outsideConditions = false }
                    let joining = token.text == "join" || token.text == "straight_join"
                    let before = previousTable
                    var next = position + 1
                    // MySQL writes view joins as `from (`a` `x` join `b` …)`.
                    while kind(next) == .open { next += 1 }
                    while let reference = tableReference(at: next) {
                        next = reference.next
                        var alias: String?
                        if isWord(next), tokens[next].text == "as", isWord(next + 1) {
                            alias = tokens[next + 1].text
                            next += 2
                        } else if isWord(next), !notAliases.contains(tokens[next].text) {
                            alias = tokens[next].text
                            next += 1
                        }
                        guard let table = reference.table else {
                            previousTable = nil
                            break
                        }
                        use(table, line: tokens[reference.next - 1].line, sql: true)
                        aliases[reference.word] = Alias(table: table, definedAt: position)
                        if let alias { aliases[alias] = Alias(table: table, definedAt: position) }
                        if joining, let before, isWord(next), tokens[next].text == "using", kind(next + 1) == .open {
                            var cursor = next + 2
                            while isWord(cursor) {
                                let name = tokens[cursor].text
                                if let left = index.column(lowercased: name, in: before), let right = index.column(lowercased: name, in: table) {
                                    addJoin(before, left, table, right, line: tokens[cursor].line)
                                }
                                cursor += 1
                                guard kind(cursor) == .comma else { break }
                                cursor += 1
                            }
                        }
                        previousTable = table
                        // `FROM a x, b y` continues the list.
                        guard token.text == "from", kind(next) == .comma else { break }
                        next += 1
                    }
                    // The list is consumed once: rescanning it from every token would be quadratic.
                    resume = max(position + 1, next)
                case "table":
                    if let reference = tableReference(at: position + 1), let table = reference.table {
                        use(table, line: tokens[position + 1].line, sql: true)
                    }
                default:
                    if let left = columnReference(at: position), kind(left.next) == .equals, let right = columnReference(at: left.next + 1) {
                        if !outsideConditions, let leftTable = left.table, let leftColumn = left.column, let rightTable = right.table,
                           let rightColumn = right.column {
                            addJoin(leftTable, leftColumn, rightTable, rightColumn, line: tokens[left.next].line)
                        }
                        resume = right.next
                    }
                }
            default:
                break
            }
            position = resume
        }
        findings.joins = joinOrder.compactMap { key in
            joins[key].map { Join(from: key.from, to: key.to, cardinality: $0.cardinality, line: $0.line, count: $0.count) }
        }
        return findings
    }
}
