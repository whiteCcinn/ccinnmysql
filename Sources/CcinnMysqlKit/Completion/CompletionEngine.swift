import Foundation
import MySQLKit

/// Context-aware SQL completion (design D6). Pure and synchronous; callers run it off the main actor.
public enum CompletionEngine {
    public static let defaultLimit = 200

    enum Context: Equatable {
        case statementStart
        case showTarget
        case tableName
        case routineName
        case afterTableReference
        case database
        /// After a statement-leading `EXPLAIN`/`DESC`/`DESCRIBE`: a table, or the statement to explain.
        case explainTarget
        /// A name that does not exist yet (`RENAME TABLE a TO |`): only a database may qualify it.
        case newName
        case expression

        /// Only a table, routine or database name can follow, so the list is worth offering before anything is typed.
        var expectsObjectName: Bool {
            switch self {
            case .tableName, .routineName, .database, .explainTarget: true
            case .statementStart, .showTarget, .afterTableReference, .newName, .expression: false
            }
        }
    }

    /// The name being completed: the token at the cursor, or an empty name at the cursor.
    struct NameAtCursor {
        var replacementRange: Range<Int>
        var prefix: String
        var isQuoted: Bool
        /// All digits (`2024`): a name only where a name must follow, a number elsewhere.
        var isNumber: Bool
    }

    /// A table reference in scope: a base table (database + name) or a derived table/CTE with known columns.
    struct ScopeTable {
        var alias: String?
        var database: String?
        var table: String
        var derivedColumns: [String]?
    }

    public static func complete(text: String, cursor: Int, schema: SchemaSnapshot, limit: Int = defaultLimit) -> CompletionResult {
        let lexer = SQLLexer(text)
        let cursor = max(0, min(cursor, lexer.units.count))
        let allTokens = lexer.tokens()

        // Restrict to the statement around the cursor.
        let isSemicolon: (SQLToken) -> Bool = { $0.kind == .punctuation && lexer.units[$0.range.lowerBound] == 0x3B }
        let statementStart = allTokens.last { isSemicolon($0) && $0.range.upperBound <= cursor }?.range.upperBound ?? 0
        let statementEnd = allTokens.first { isSemicolon($0) && $0.range.lowerBound >= cursor }?.range.lowerBound ?? lexer.units.count
        let tokens = allTokens.filter { $0.range.lowerBound >= statementStart && $0.range.upperBound <= statementEnd }

        // No completion inside strings or comments.
        if let enclosing = tokens.first(where: { $0.range.lowerBound < cursor && cursor < $0.range.upperBound }),
           enclosing.kind == .string || enclosing.kind == .comment {
            return .empty(at: cursor)
        }
        if let ending = tokens.last(where: { $0.range.upperBound == cursor }) {
            if ending.kind == .comment, lexer.text(of: ending).hasPrefix("--") || lexer.text(of: ending).hasPrefix("#") {
                return .empty(at: cursor)
            }
            if ending.kind == .string, !isTerminated(ending, lexer: lexer) { return .empty(at: cursor) }
        }
        guard let name = nameAtCursor(tokens: tokens, cursor: cursor, lexer: lexer) else { return .empty(at: cursor) }

        let replacementStart = name.replacementRange.lowerBound
        let before = tokens.filter { $0.range.upperBound <= replacementStart && $0.kind != .comment }
        let significant = tokens.filter { $0.kind != .comment }
        let ctes = commonTableExpressions(tokens: significant, lexer: lexer)
        let scope = scopeTables(tokens: significant, lexer: lexer, schema: schema, ctes: ctes)

        var candidates: [CompletionItem]
        var missing: [TableKey] = []
        var missingDatabases: [String] = []
        var expectsObjectName = false
        var allowsNumericName = true
        if let last = before.last, isDot(last, lexer) {
            let qualifier = qualifierChain(before: before, lexer: lexer)
            (candidates, missing) = memberCandidates(qualifier: qualifier, scope: scope, schema: schema)
            if let database = qualifier.first, qualifier.count == 1, schema.isDatabase(database), schema.objects(in: database) == nil {
                missingDatabases.append(database)
            }
        } else {
            let context = clauseContext(before: before, lexer: lexer)
            if name.isNumber, !context.expectsObjectName { return .empty(at: cursor) }
            (candidates, missing) = contextCandidates(context, scope: scope, ctes: ctes, schema: schema)
            if context == .tableName || context == .explainTarget, let current = schema.currentDatabase, schema.objects(in: current) == nil {
                missingDatabases.append(current)
            }
            expectsObjectName = context.expectsObjectName
            allowsNumericName = context.expectsObjectName
        }
        let pool = CompletionPool(candidates)
        return CompletionResult(replacementRange: name.replacementRange, prefix: name.prefix,
                                items: CompletionRanking.rank(pool, prefix: name.prefix, limit: limit, quoted: name.isQuoted),
                                missingColumns: missing, missingDatabases: missingDatabases, expectsObjectName: expectsObjectName,
                                isQuoted: name.isQuoted, allowsNumericName: allowsNumericName, pool: pool)
    }

    /// The name token the cursor is in or just after (whole token replaced, the part before the cursor matched), an
    /// empty name at the cursor when there is none, `nil` where no name can be typed (`1.5|`, `@var|`).
    static func nameAtCursor(tokens: [SQLToken], cursor: Int, lexer: SQLLexer) -> NameAtCursor? {
        guard let token = tokens.last(where: { $0.range.lowerBound < cursor && cursor <= $0.range.upperBound && $0.kind != .comment })
        else { return NameAtCursor(replacementRange: cursor..<cursor, prefix: "", isQuoted: false, isNumber: false) }
        let start = token.range.lowerBound
        switch token.kind {
        case .identifier, .keyword:
            return NameAtCursor(replacementRange: token.range, prefix: lexer.text(in: start..<cursor), isQuoted: false, isNumber: false)
        case .quotedIdentifier:
            let raw = lexer.text(in: (start + 1)..<cursor)
            let quote = lexer.units[start]
            // Right after the closing back-quote, the prefix is the whole (unescaped) name.
            let prefix = cursor == token.range.upperBound && isTerminated(token, lexer: lexer) && cursor - start >= 2
                ? lexer.identifierValue(of: token)
                : raw.replacingOccurrences(of: String(repeating: String(decoding: [quote], as: UTF16.self), count: 2),
                                           with: String(decoding: [quote], as: UTF16.self))
            return NameAtCursor(replacementRange: token.range, prefix: prefix, isQuoted: true, isNumber: false)
        case .number where lexer.units[token.range].allSatisfy(SQLLexer.isDigit):
            return NameAtCursor(replacementRange: token.range, prefix: lexer.text(in: start..<cursor), isQuoted: false, isNumber: true)
        case .number, .variable:
            return nil
        case .punctuation, .operator, .string, .comment, .executableComment:
            return NameAtCursor(replacementRange: cursor..<cursor, prefix: "", isQuoted: false, isNumber: false)
        }
    }

    // MARK: Scope analysis

    static func isDot(_ token: SQLToken, _ lexer: SQLLexer) -> Bool {
        token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E
    }

    static func isTerminated(_ token: SQLToken, lexer: SQLLexer) -> Bool {
        guard token.range.count >= 2 else { return false }
        return lexer.units[token.range.upperBound - 1] == lexer.units[token.range.lowerBound]
    }

    static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    /// `a.b.` before the cursor → ["a", "b"].
    static func qualifierChain(before: [SQLToken], lexer: SQLLexer) -> [String] {
        var parts: [String] = []
        var index = before.count - 1
        while index >= 1, isDot(before[index], lexer), isName(before[index - 1]),
              before[index - 1].range.upperBound == before[index].range.lowerBound {
            parts.insert(lexer.identifierValue(of: before[index - 1]), at: 0)
            index -= 2
        }
        return parts
    }

    static let aliasStopWords: Set<String> = SQLKeywords.reserved.union([
        "LATERAL", "WINDOW", "OUTER", "INNER", "PARTITION", "LIMIT", "WHERE", "ON", "USING", "FORCE", "IGNORE", "STRAIGHT_JOIN",
    ])

    /// `FROM` inside these calls is part of the call (`EXTRACT(YEAR FROM d)`, `TRIM(x FROM s)`), not a table list.
    static let callsWithFrom: Set<String> = ["EXTRACT", "TRIM", "SUBSTRING", "SUBSTR", "POSITION", "OVERLAY"]

    /// `WITH [RECURSIVE] name AS ( … ), name AS ( … )` at the start of the statement: names and output columns, in order.
    static func commonTableExpressions(tokens: [SQLToken], lexer: SQLLexer) -> [(name: String, columns: [String])] {
        let words = tokens.map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }
        guard words.first == "WITH" else { return [] }
        var result: [(name: String, columns: [String])] = []
        var index = 1
        if index < words.count, words[index] == "RECURSIVE" { index += 1 }
        while index + 2 < tokens.count, isName(tokens[index]), words[index + 1] == "AS", lexer.text(of: tokens[index + 2]) == "(" {
            let close = matchingParen(tokens: tokens, open: index + 2, lexer: lexer)
            result.append((lexer.identifierValue(of: tokens[index]),
                           derivedColumns(tokens: Array(tokens[(index + 3)..<min(close, tokens.count)]), lexer: lexer)))
            index = close + 1
            if index < tokens.count, lexer.text(of: tokens[index]) == "," { index += 1 } else { break }
        }
        return result
    }

    /// For every token, the call it is an argument of (`EXTRACT` for `FROM` in `EXTRACT(YEAR FROM d)`), if any.
    static func enclosingCalls(tokens: [SQLToken], lexer: SQLLexer) -> [String?] {
        var result = [String?](repeating: nil, count: tokens.count)
        var open: [String?] = []
        for index in tokens.indices {
            let token = tokens[index]
            if token.kind == .punctuation, lexer.text(of: token) == ")" { _ = open.popLast() }
            result[index] = open.last ?? nil
            if token.kind == .punctuation, lexer.text(of: token) == "(" {
                let callee = index > 0 && isName(tokens[index - 1]) ? lexer.text(of: tokens[index - 1]).uppercased() : nil
                open.append(callee)
            }
        }
        return result
    }

    /// Tables, derived tables and CTEs referenced anywhere in the statement, with their aliases.
    static func scopeTables(tokens: [SQLToken], lexer: SQLLexer, schema: SchemaSnapshot,
                            ctes: [(name: String, columns: [String])]? = nil) -> [ScopeTable] {
        var result: [ScopeTable] = []
        let words = tokens.map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }
        let cteColumns = Dictionary((ctes ?? commonTableExpressions(tokens: tokens, lexer: lexer)).map { ($0.name.lowercased(), $0.columns) },
                                    uniquingKeysWith: { first, _ in first })
        let calls = enclosingCalls(tokens: tokens, lexer: lexer)

        var index = 0
        while index < tokens.count {
            let word = words[index]
            let startsReference = ["FROM", "JOIN", "STRAIGHT_JOIN", "UPDATE", "INTO", "TABLE"].contains(word)
                && !(word == "FROM" && calls[index].map(callsWithFrom.contains) == true)
            index += 1
            guard startsReference else { continue }
            var parsingList = true
            while parsingList, index < tokens.count {
                parsingList = false
                if lexer.text(of: tokens[index]) == "(" {
                    // Derived table: ( SELECT … ) [AS] alias
                    let close = matchingParen(tokens: tokens, open: index, lexer: lexer)
                    let columns = derivedColumns(tokens: Array(tokens[(index + 1)..<min(close, tokens.count)]), lexer: lexer)
                    index = close + 1
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        result.append(ScopeTable(alias: alias, database: nil, table: alias, derivedColumns: columns))
                        index = next
                    }
                } else if isName(tokens[index]), !aliasStopWords.contains(words[index]) || tokens[index].kind != .keyword {
                    var parts = [lexer.identifierValue(of: tokens[index])]
                    index += 1
                    while index + 1 < tokens.count, isDot(tokens[index], lexer), isName(tokens[index + 1]) {
                        parts.append(lexer.identifierValue(of: tokens[index + 1]))
                        index += 2
                    }
                    let table = parts[parts.count - 1]
                    let database = parts.count >= 2 ? parts[parts.count - 2] : nil
                    var reference = ScopeTable(alias: nil, database: database, table: table, derivedColumns: nil)
                    if database == nil, let columns = cteColumns[table.lowercased()] { reference.derivedColumns = columns }
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        reference.alias = alias
                        index = next
                    }
                    result.append(reference)
                }
                if index < tokens.count, lexer.text(of: tokens[index]) == ",", word == "FROM" {
                    index += 1
                    parsingList = true
                }
            }
        }
        return result
    }

    static func parseAlias(tokens: [SQLToken], words: [String], at index: Int, lexer: SQLLexer) -> (String, Int)? {
        var index = index
        if index < tokens.count, words[index] == "AS" { index += 1 }
        guard index < tokens.count, isName(tokens[index]) else { return nil }
        if tokens[index].kind == .keyword, aliasStopWords.contains(words[index]) { return nil }
        return (lexer.identifierValue(of: tokens[index]), index + 1)
    }

    static func matchingParen(tokens: [SQLToken], open: Int, lexer: SQLLexer) -> Int {
        var depth = 0
        var index = open
        while index < tokens.count {
            let text = lexer.text(of: tokens[index])
            if tokens[index].kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return tokens.count
    }

    /// Output column names of `SELECT a, b AS c, t.d, count(*) AS n FROM …`.
    static func derivedColumns(tokens: [SQLToken], lexer: SQLLexer) -> [String] {
        guard let selectIndex = tokens.firstIndex(where: { lexer.text(of: $0).uppercased() == "SELECT" }) else { return [] }
        var columns: [String] = []
        var depth = 0
        var item: [SQLToken] = []
        // The output name is the item's last identifier: `b AS c` → c, `t.d` → d, `count(*) n` → n.
        func flushItem() {
            defer { item.removeAll() }
            guard let last = item.last, isName(last) else { return }
            columns.append(lexer.identifierValue(of: last))
        }
        for token in tokens[(selectIndex + 1)...] {
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" { depth -= 1 }
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "FROM" { break }
            if depth == 0, text == "," {
                flushItem()
                continue
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "DISTINCT", item.isEmpty { continue }
            item.append(token)
        }
        flushItem()
        return columns
    }

    // MARK: Clause context

    static func clauseContext(before: [SQLToken], lexer: SQLLexer) -> Context {
        guard !before.isEmpty else { return .statementStart }
        let words = before.map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }
        let firstWord = words.first ?? ""
        let lastText = lexer.text(of: before[before.count - 1]).uppercased()

        if lastText == "SHOW" { return .showTarget }
        if lastText == "USE" { return .database }
        if lastText == "CALL" { return .routineName }
        if before.count == 1, ["EXPLAIN", "DESC", "DESCRIBE"].contains(firstWord) { return .explainTarget }

        // Walk back within the current parenthesis level to the nearest clause keyword.
        var depth = 0
        var distance = 0
        var sawComma = false
        for index in stride(from: before.count - 1, through: 0, by: -1) {
            let token = before[index]
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == ")" { depth += 1 }
                if text == "(" {
                    if depth == 0 { return .expression } // inside a function call or subquery start
                    depth -= 1
                }
                if depth == 0, text == ",", distance == 0 { sawComma = true }
            }
            guard depth == 0 else { continue }
            let word = words[index]
            let previous = index > 0 ? words[index - 1] : ""
            switch word {
            case "DESC" where index > 0, "DESCRIBE" where index > 0:
                break // `ORDER BY x DESC`: a sort direction; only a statement-leading DESC describes a table.
            case "FROM" where firstWord == "SHOW":
                let lowered = words.joined(separator: " ")
                return lowered.contains("TABLES") || lowered.contains("EVENTS") || lowered.contains("TRIGGERS") || lowered.contains("STATUS")
                    ? .database : .tableName
            case "FROM" where callsWithFrom.contains(enclosingCall(before: before, at: index, lexer: lexer) ?? ""):
                return .expression // `EXTRACT(YEAR FROM |`
            case "FROM", "JOIN", "STRAIGHT_JOIN", "UPDATE", "INTO", "TABLE", "DESC", "DESCRIBE", "EXPLAIN", "TRUNCATE":
                if distance == 0 || sawComma { return .tableName }
                return word == "UPDATE" || word == "INTO" || word == "TABLE" ? .expression : .afterTableReference
            case "TABLES" where previous == "LOCK" || previous == "FLUSH":
                // `LOCK TABLES a READ, |`
                return distance == 0 || sawComma ? .tableName : .expression
            case "TO" where firstWord == "RENAME" && distance == 0:
                return .newName // `RENAME TABLE a TO |`; after `a TO b, ` the walk reaches TABLE.
            case "ON" where namesTableAfterOn(firstWord: firstWord, words: words, tokens: before, at: index):
                return distance == 0 ? .tableName : .expression // `CREATE INDEX i ON |`, `GRANT SELECT ON |`
            case "SELECT", "WHERE", "ON", "HAVING", "BY", "SET", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "CASE",
                 "DISTINCT", "IN", "LIKE", "BETWEEN", "IS", "USING", "OVER", "PARTITION", "VALUES":
                return .expression
            case "USE":
                return .database
            default:
                break
            }
            if token.kind == .operator { return .expression }
            if token.kind != .punctuation || text != "." { distance += 1 }
        }
        return .expression
    }

    /// `ON` at `words[index]` names a table in the header of `CREATE/DROP INDEX name [USING BTREE|HASH] ON`,
    /// `CREATE TRIGGER name BEFORE|AFTER INSERT|UPDATE|DELETE ON`, and in `GRANT`/`REVOKE`. Elsewhere (a join, a
    /// foreign key's `ON DELETE`, a trigger body) it does not.
    static func namesTableAfterOn(firstWord: String, words: [String], tokens: [SQLToken], at index: Int) -> Bool {
        switch firstWord {
        case "GRANT", "REVOKE":
            return true
        case "CREATE", "DROP":
            var position = index - 1
            if position >= 1, words[position] == "BTREE" || words[position] == "HASH", words[position - 1] == "USING" { position -= 2 }
            if position >= 1, isName(tokens[position]), words[position - 1] == "INDEX" { return true }
            return firstWord == "CREATE" && index >= 2 && ["INSERT", "UPDATE", "DELETE"].contains(words[index - 1])
                && ["BEFORE", "AFTER"].contains(words[index - 2])
        default:
            return false
        }
    }

    /// The call whose parentheses enclose `before[index]` (upper-cased), if they belong to a call.
    static func enclosingCall(before: [SQLToken], at index: Int, lexer: SQLLexer) -> String? {
        var depth = 0
        var position = index - 1
        while position >= 0 {
            let token = before[position]
            if token.kind == .punctuation {
                let text = lexer.text(of: token)
                if text == ")" { depth += 1 }
                if text == "(" {
                    if depth == 0 {
                        guard position > 0, isName(before[position - 1]) else { return nil }
                        return lexer.text(of: before[position - 1]).uppercased()
                    }
                    depth -= 1
                }
            }
            position -= 1
        }
        return nil
    }

    // MARK: Candidates

    static func memberCandidates(qualifier: [String], scope: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        guard let head = qualifier.first else { return ([], []) }
        let current = schema.currentDatabase
        switch qualifier.count {
        case 1:
            // Precedence: explicit alias, schema name, table referenced without alias, table in current schema.
            if let table = scope.first(where: { $0.alias?.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if schema.isDatabase(head) {
                return (objectCandidates(database: head, schema: schema, routines: false), [])
            }
            if let table = scope.first(where: { $0.alias == nil && $0.table.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if let current, schema.object(named: head, in: current) != nil {
                return columnCandidates(of: [ScopeTable(alias: nil, database: current, table: head, derivedColumns: nil)], schema: schema)
            }
            return ([], [])
        case 2:
            return columnCandidates(of: [ScopeTable(alias: nil, database: head, table: qualifier[1], derivedColumns: nil)], schema: schema)
        default:
            return columnCandidates(of: [ScopeTable(alias: nil, database: qualifier[qualifier.count - 2],
                                                    table: qualifier[qualifier.count - 1], derivedColumns: nil)], schema: schema)
        }
    }

    /// What may follow a statement-leading `EXPLAIN`/`DESC`/`DESCRIBE` besides a table.
    static let explainableStatements = ["SELECT", "WITH", "INSERT INTO", "REPLACE INTO", "UPDATE", "DELETE FROM", "TABLE", "ANALYZE",
                                        "FORMAT=TREE", "FORMAT=JSON", "FORMAT=TRADITIONAL"]

    static func contextCandidates(_ context: Context, scope: [ScopeTable], ctes: [(name: String, columns: [String])] = [],
                                  schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        switch context {
        case .statementStart:
            return (SQLKeywords.statementStarters.map(keywordItem), [])
        case .showTarget:
            return (SQLKeywords.showTargets.map(keywordItem), [])
        case .database, .newName:
            return (databaseCandidates(schema), [])
        case .tableName, .explainTarget:
            var items = ctes.map { CompletionItem(kind: .table, label: $0.name, insertText: quoteIfNeeded($0.name), detail: "CTE") }
            if let current = schema.currentDatabase {
                items += objectCandidates(database: current, schema: schema, routines: false)
            }
            items += databaseCandidates(schema)
            if context == .explainTarget { items += explainableStatements.map(keywordItem) }
            return (items, [])
        case .routineName:
            var items: [CompletionItem] = []
            if let current = schema.currentDatabase {
                items += objectCandidates(database: current, schema: schema, routines: true)
            }
            items += databaseCandidates(schema)
            return (items, [])
        case .afterTableReference:
            let keywords = ["WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "STRAIGHT_JOIN", "CROSS JOIN", "NATURAL JOIN",
                            "ON", "USING", "AS", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "UNION ALL", "PARTITION", "FORCE INDEX", "USE INDEX"]
            return (keywords.map(keywordItem), [])
        case .expression:
            let (columns, missing) = columnCandidates(of: scope, schema: schema)
            let aliases = scope.compactMap(\.alias).map {
                CompletionItem(kind: .alias, label: $0, insertText: quoteIfNeeded($0), detail: "alias")
            }
            let functions = SQLFunctions.all.map {
                CompletionItem(kind: .function, label: $0.name, insertText: $0.name + "(", detail: $0.signature)
            }
            return (columns + aliases + functions + SQLKeywords.clauseKeywords.map(keywordItem), missing)
        }
    }

    static func columnCandidates(of tables: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        var items: [CompletionItem] = []
        var missing: [TableKey] = []
        var seen = Set<String>()
        for table in tables {
            let source = table.alias ?? table.table
            if let derived = table.derivedColumns {
                for column in derived where seen.insert("\(source).\(column)").inserted {
                    items.append(CompletionItem(kind: .column, label: column, insertText: quoteIfNeeded(column), detail: source))
                }
                continue
            }
            guard let database = table.database ?? schema.currentDatabase else { continue }
            guard let columns = schema.columns(database: database, table: table.table) else {
                if schema.object(named: table.table, in: database) != nil || table.database != nil {
                    missing.append(TableKey(database: database, table: table.table))
                }
                continue
            }
            for column in columns where seen.insert("\(source).\(column.name)").inserted {
                items.append(CompletionItem(kind: .column, label: column.name, insertText: quoteIfNeeded(column.name),
                                            detail: "\(column.columnType) · \(table.table)"))
            }
        }
        return (items, missing)
    }

    static func objectCandidates(database: String, schema: SchemaSnapshot, routines: Bool) -> [CompletionItem] {
        (schema.objects(in: database) ?? []).compactMap { object in
            let kind: CompletionItem.Kind
            switch object.kind {
            case .table, .sequence: kind = .table
            case .view, .systemView: kind = .view
            case .procedure, .function: kind = .routine
            case .trigger, .event: return nil
            }
            // CALL completes procedures; FROM/JOIN complete relations.
            if routines != (object.kind == .procedure) { return nil }
            return CompletionItem(kind: kind, label: object.name, insertText: quoteIfNeeded(object.name), detail: object.kind.displayName)
        }
    }

    static func databaseCandidates(_ schema: SchemaSnapshot) -> [CompletionItem] {
        schema.databases.map { CompletionItem(kind: .database, label: $0, insertText: quoteIfNeeded($0), detail: "database") }
    }

    static func keywordItem(_ keyword: String) -> CompletionItem {
        CompletionItem(kind: .keyword, label: keyword, insertText: keyword, detail: nil)
    }

    /// Back-quotes identifiers that are reserved words or contain unusual characters.
    public static func quoteIfNeeded(_ name: String) -> String {
        let simple = name.utf16.enumerated().allSatisfy { offset, unit in
            offset == 0 ? SQLLexer.isIdentifierStart(unit) && unit < 0x80 : SQLLexer.isIdentifierPart(unit) && unit < 0x80
        }
        if simple, !SQLKeywords.reserved.contains(name.uppercased()) { return name }
        return SQLText.quoteIdentifier(name)
    }
}
