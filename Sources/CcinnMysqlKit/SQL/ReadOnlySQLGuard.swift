import Foundation

/// Decides whether SQL is a single read-only statement (MCP read-only access, design D10). The check is
/// token-based (strings, quoted identifiers and comments cannot smuggle keywords) and conservative:
/// anything not clearly a read is rejected. The server additionally runs MCP reads in a READ ONLY transaction.
public enum ReadOnlySQLGuard {
    /// Keywords that must not appear anywhere in a read-only statement.
    static let forbidden: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "DROP", "CREATE", "ALTER", "TRUNCATE", "RENAME", "GRANT", "REVOKE", "KILL",
        "LOAD", "CALL", "DO", "HANDLER", "LOCK", "UNLOCK", "FLUSH", "RESET", "PURGE", "OPTIMIZE", "REPAIR", "INSTALL",
        "UNINSTALL", "SHUTDOWN", "RESTART", "OUTFILE", "DUMPFILE", "INTO", "PROCEDURE", "PREPARE", "EXECUTE", "DEALLOCATE",
        "CHANGE", "PERSIST", "IMPORT", "CLONE", "BINLOG",
    ]

    /// Functions with side effects (locks, waits, server file access, sequence updates).
    static let forbiddenFunctions: Set<String> = [
        "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS", "LOAD_FILE", "SLEEP", "BENCHMARK", "MASTER_POS_WAIT", "SOURCE_POS_WAIT",
        "WAIT_FOR_EXECUTED_GTID_SET", "WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS", "MASTER_GTID_WAIT", "NEXTVAL", "SETVAL", "LASTVAL",
        "SYS_EXEC", "SYS_EVAL", "SET_USER_ID", "SET_FIREWALL_MODE", "NORMALIZE_STATEMENT",
    ]

    /// Admin function families (Group Replication, failover, version tokens, keyring, audit, firewall, locking service,
    /// masking dictionaries) whose effects a read-only transaction does not stop.
    static let forbiddenFunctionPrefixes = [
        "GROUP_REPLICATION_", "ASYNCHRONOUS_CONNECTION_FAILOVER_", "VERSION_TOKENS_", "KEYRING_", "AUDIT_LOG_", "MYSQL_FIREWALL_",
        "SERVICE_GET_", "SERVICE_RELEASE_", "MASKING_DICTIONARY", "ROTATE_", "ADD_", "DROP_", "SET_",
    ]

    /// Optimizer hints that would override the server-side time limit or session settings.
    static let forbiddenHints = ["MAX_EXECUTION_TIME", "SET_VAR", "RESOURCE_GROUP"]

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String) -> String? {
        // NUL bytes end comments for the server but not for most tools; there is no legitimate use in a query.
        if sql.unicodeScalars.contains(where: { $0.value == 0 }) { return "The statement contains a NUL byte." }
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let lexer = SQLLexer(statement.text)
        let all = lexer.tokens()
        if all.contains(where: { $0.kind == .executableComment }) {
            return "Executable comments (/*! … */) are not allowed in read-only mode."
        }
        for hint in all where hint.kind == .comment && lexer.text(of: hint).hasPrefix("/*+") {
            let text = lexer.text(of: hint).uppercased()
            if let name = forbiddenHints.first(where: text.contains) {
                return "The optimizer hint \(name) is not allowed in read-only mode."
            }
        }
        let tokens = all.filter { $0.kind != .comment }
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
        guard let first = words.first else { return "The statement is empty." }

        switch first {
        case "SELECT", "WITH", "(", "TABLE", "VALUES":
            return checkQuery(tokens: tokens, words: words, lexer: lexer)
        case "SHOW", "HELP":
            // SHOW cannot change anything, but its WHERE clause can call functions.
            return checkQuery(tokens: tokens, words: words, lexer: lexer, keywordsAllowed: true)
        case "DESC", "DESCRIBE", "EXPLAIN":
            var index = 1
            let modifiers: Set<String> = ["ANALYZE", "EXTENDED", "PARTITIONS", "FORMAT", "=", "JSON", "TREE", "TRADITIONAL"]
            while index < words.count, modifiers.contains(words[index]) { index += 1 }
            guard index < words.count else { return nil }
            let verb = words[index]
            if verb == "FOR", index + 1 < words.count, words[index + 1] == "CONNECTION" { return nil }
            if ["SELECT", "WITH", "(", "TABLE", "VALUES"].contains(verb) {
                return checkQuery(tokens: Array(tokens[index...]), words: Array(words[index...]), lexer: lexer)
            }
            // `DESC <table> [column]`.
            if index == 1, first != "EXPLAIN", tokens[index].kind != .keyword || !forbidden.contains(verb) {
                return checkQuery(tokens: tokens, words: words, lexer: lexer)
            }
            return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
        case "ANALYZE":
            // MariaDB ANALYZE FORMAT=JSON SELECT … (executes the query and reports actual rows).
            var index = 1
            while index < words.count, ["FORMAT", "=", "JSON"].contains(words[index]) { index += 1 }
            guard index > 1, index < words.count, ["SELECT", "WITH", "("].contains(words[index]) else { return rejection(first) }
            return checkQuery(tokens: Array(tokens[index...]), words: Array(words[index...]), lexer: lexer)
        default:
            return rejection(first)
        }
    }

    private static func checkQuery(tokens: [SQLToken], words: [String], lexer: SQLLexer, keywordsAllowed: Bool = false) -> String? {
        for (index, token) in tokens.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : ""
            // The server resolves `quoted` names of native functions too.
            if token.kind == .quotedIdentifier, next == "(", let reason = functionRejection(lexer.identifierValue(of: token).uppercased()) {
                return reason
            }
            guard token.kind == .keyword || token.kind == .identifier else { continue }
            let word = words[index]
            if forbidden.contains(word), !keywordsAllowed || word == "INTO" {
                return word == "INTO" ? "SELECT … INTO is not allowed in read-only mode." : "`\(word)` is not allowed in a read-only query."
            }
            if word == "FOR", next == "UPDATE" || next == "SHARE" {
                return "Locking reads (FOR UPDATE / FOR SHARE) are not allowed in read-only mode."
            }
            if next == "(", let reason = functionRejection(word) { return reason }
            if word == "NEXT", next == "VALUE" {
                return "Sequence updates (NEXT VALUE FOR) are not allowed in read-only mode."
            }
        }
        return nil
    }

    private static func functionRejection(_ name: String) -> String? {
        let isAdminFamily = forbiddenFunctionPrefixes.contains { prefix in
            // ADD_/DROP_/SET_/ROTATE_ only for the known admin UDF shapes, not ordinary names such as SET_ID.
            guard name.hasPrefix(prefix) else { return false }
            if ["ADD_", "DROP_", "SET_", "ROTATE_"].contains(prefix) {
                return ["FIREWALL", "KEYRING", "VERSION_TOKEN", "MASKING", "SYSTEM_KEY", "AUDIT"].contains { name.contains($0) }
            }
            return true
        }
        guard forbiddenFunctions.contains(name) || isAdminFamily else { return nil }
        return "`\(name)()` has side effects and is not allowed in read-only mode."
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, TABLE, VALUES, SHOW, DESCRIBE, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write AI access."
    }
}
