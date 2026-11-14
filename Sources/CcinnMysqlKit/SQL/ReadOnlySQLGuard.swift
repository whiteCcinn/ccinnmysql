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
        "SYS_EXEC", "SYS_EVAL", "SET_USER_ID",
    ]

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String) -> String? {
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let lexer = SQLLexer(statement.text)
        let all = lexer.tokens()
        if all.contains(where: { $0.kind == .executableComment }) {
            return "Executable comments (/*! … */) are not allowed in read-only mode."
        }
        let tokens = all.filter { $0.kind != .comment }
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
        guard let first = words.first else { return "The statement is empty." }

        switch first {
        case "SELECT", "WITH", "(", "TABLE", "VALUES":
            return checkQuery(tokens: tokens, words: words)
        case "SHOW", "HELP":
            // SHOW cannot change anything, but its WHERE clause can call functions.
            return checkQuery(tokens: tokens, words: words, keywordsAllowed: true)
        case "DESC", "DESCRIBE", "EXPLAIN":
            var index = 1
            let modifiers: Set<String> = ["ANALYZE", "EXTENDED", "PARTITIONS", "FORMAT", "=", "JSON", "TREE", "TRADITIONAL"]
            while index < words.count, modifiers.contains(words[index]) { index += 1 }
            guard index < words.count else { return nil }
            let verb = words[index]
            if verb == "FOR", index + 1 < words.count, words[index + 1] == "CONNECTION" { return nil }
            if ["SELECT", "WITH", "(", "TABLE", "VALUES"].contains(verb) {
                return checkQuery(tokens: Array(tokens[index...]), words: Array(words[index...]))
            }
            // `DESC <table> [column]`.
            if index == 1, first != "EXPLAIN", tokens[index].kind != .keyword || !forbidden.contains(verb) {
                return checkQuery(tokens: tokens, words: words)
            }
            return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
        case "ANALYZE":
            // MariaDB ANALYZE FORMAT=JSON SELECT … (executes the query and reports actual rows).
            var index = 1
            while index < words.count, ["FORMAT", "=", "JSON"].contains(words[index]) { index += 1 }
            guard index > 1, index < words.count, ["SELECT", "WITH", "("].contains(words[index]) else { return rejection(first) }
            return checkQuery(tokens: Array(tokens[index...]), words: Array(words[index...]))
        default:
            return rejection(first)
        }
    }

    private static func checkQuery(tokens: [SQLToken], words: [String], keywordsAllowed: Bool = false) -> String? {
        for (index, token) in tokens.enumerated() {
            guard token.kind == .keyword || token.kind == .identifier else { continue }
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : ""
            if forbidden.contains(word), !keywordsAllowed || word == "INTO" {
                return word == "INTO" ? "SELECT … INTO is not allowed in read-only mode." : "`\(word)` is not allowed in a read-only query."
            }
            if word == "FOR", next == "UPDATE" || next == "SHARE" {
                return "Locking reads (FOR UPDATE / FOR SHARE) are not allowed in read-only mode."
            }
            if next == "(", forbiddenFunctions.contains(word) {
                return "`\(word)()` has side effects and is not allowed in read-only mode."
            }
            if word == "NEXT", next == "VALUE" {
                return "Sequence updates (NEXT VALUE FOR) are not allowed in read-only mode."
            }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, TABLE, VALUES, SHOW, DESCRIBE, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write AI access."
    }
}
