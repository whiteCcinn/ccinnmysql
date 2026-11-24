import Foundation

/// What a DDL statement may have changed, for the completion schema cache: every database it names (and the current
/// one), and every name it uses as a table. Over-approximates: a column name becomes a "table" that is not cached, and
/// `t.c` names a "database" `t` that the caller does not know; dropping or reloading those costs nothing.
public struct SchemaChange: Sendable, Equatable {
    /// As written in the statement (case kept); match them case-insensitively.
    public let databases: Set<String>
    public let tables: Set<TableKey>
    /// `CREATE`/`DROP DATABASE` (or `SCHEMA`): the list of databases changed.
    public let changesDatabaseList: Bool

    public init(sql: String, currentDatabase: String?) {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        let leading = tokens.prefix(2).map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }
        changesDatabaseList = leading.count == 2 && ["CREATE", "DROP"].contains(leading[0]) && ["DATABASE", "SCHEMA"].contains(leading[1])
        let current = currentDatabase.flatMap { $0.isEmpty ? nil : $0 }
        var databases = Set<String>()
        var tables = Set<TableKey>()
        if let current { databases.insert(current) }
        func isName(_ token: SQLToken) -> Bool {
            switch token.kind {
            case .identifier, .quotedIdentifier: true
            case .keyword: !SQLKeywords.reserved.contains(lexer.text(of: token).uppercased())
            default: false
            }
        }
        func isDot(_ token: SQLToken) -> Bool { token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E }
        var index = 0
        while index < tokens.count {
            guard isName(tokens[index]) else {
                index += 1
                continue
            }
            var parts = [lexer.identifierValue(of: tokens[index])]
            index += 1
            while index + 1 < tokens.count, isDot(tokens[index]), isName(tokens[index + 1]) {
                parts.append(lexer.identifierValue(of: tokens[index + 1]))
                index += 2
            }
            if parts.count >= 2 {
                let database = parts[parts.count - 2]
                databases.insert(database)
                tables.insert(TableKey(database: database, table: parts[parts.count - 1]))
            } else if let current {
                tables.insert(TableKey(database: current, table: parts[0]))
            }
        }
        self.databases = databases
        self.tables = tables
    }
}

/// How long completion trusts cached schema, and how long it leaves a failed load alone.
public enum SchemaCachePolicy {
    /// Object lists and columns older than this are reloaded in the background (tables created by migrations or
    /// other clients appear without a manual refresh).
    public static let maxAge: TimeInterval = 300
    /// A database whose object list failed to load (no privilege, gone) is not asked again on every key.
    public static let failureBackoff: TimeInterval = 60

    public static func isStale(loadedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(loadedAt) > maxAge
    }

    public static func mayRetry(failedAt: Date?, now: Date) -> Bool {
        guard let failedAt else { return true }
        return now.timeIntervalSince(failedAt) > failureBackoff
    }
}
