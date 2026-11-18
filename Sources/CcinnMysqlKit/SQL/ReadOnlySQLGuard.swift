import Foundation
import MySQLKit

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

    /// Characters some tools treat as line ends although the server ends a line comment only at `\n`.
    static let lineBreaksInOtherTools: Set<UInt32> = [0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029]

    /// Optimizer hints that would override the server-side time limit or session settings.
    static let forbiddenHints = ["MAX_EXECUTION_TIME", "SET_VAR", "RESOURCE_GROUP"]

    /// Which functions a statement may call (final review, item 9).
    public struct FunctionPolicy: Sendable, Equatable {
        /// The server's flavor, whose natives apply; `nil` before it is known (any flavor's natives: the check is repeated in
        /// the call's session, where it is).
        public var flavor: ServerFlavor?
        /// Loadable, component and stored functions are allowed too (the connection allows privileged accounts and stored
        /// functions). Natives with side effects stay refused.
        public var allowsNonNative: Bool

        public init(flavor: ServerFlavor? = nil, allowsNonNative: Bool = false) {
            self.flavor = flavor
            self.allowsNonNative = allowsNonNative
        }
    }

    /// `nil` when allowed; otherwise the reason it is rejected. `defaultDatabase` is the schema unqualified names resolve
    /// in (the MCP `database` argument); `functions` says which functions the statement may call.
    public static func check(_ sql: String, defaultDatabase: String? = nil, functions: FunctionPolicy = FunctionPolicy()) -> String? {
        if let database = defaultDatabase {
            // A handshake string ends at NUL and the server ignores some control characters: the database it receives could
            // differ from the one checked here.
            if database.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                return "The database name contains a control character (such as NUL), so it cannot be checked the way the server would read it. Use the plain name."
            }
            if let letter = SQLNameFolding.firstLetterFoldingToASCII(in: database) { return SQLNameFolding.refusal(name: database, letter: letter) }
        }
        // NUL bytes end comments for the server but not for most tools; there is no legitimate use in a query.
        if sql.unicodeScalars.contains(where: { $0.value == 0 }) { return "The statement contains a NUL byte." }
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let lexer = SQLLexer(statement.text)
        let all = lexer.tokens()
        // The lexer is a security boundary: wherever servers or sessions could read the text differently, reject.
        // A backslash in a string ends it early under NO_BACKSLASH_ESCAPES (and in an ANSI_QUOTES name): what is a
        // string in one mode can be `INTO OUTFILE` or a second statement in the other.
        let unescaped = SQLLexer(statement.text, backslashEscapes: false)
        if SQLStatementSplitter.split(sql, backslashEscapes: false).map(\.range) != statements.map(\.range)
            || unescaped.tokens().map(\.range) != all.map(\.range) {
            return "A backslash in a string is read differently depending on NO_BACKSLASH_ESCAPES; write a quote inside a string as '' instead."
        }
        // `\N` is NULL on MariaDB, which ends it after the N (`\Nlock` is NULL LOCK), and an error on MySQL 8; any `\`
        // outside strings and quoted names is read differently by different servers.
        if lexer.containsBareBackslash(all) {
            return "A backslash outside a string (such as \\N) is read differently by MySQL and MariaDB; write NULL instead."
        }
        // A `;` left inside the statement (after a DELIMITER command): the server would see more than one statement.
        if all.contains(where: { $0.kind == .punctuation && lexer.text(of: $0) == ";" }) {
            return "Only one statement can be run at a time; send statements separately."
        }
        // A literal the server rejects while lexing (`1.e`, `x'4'`): where its tokens end is guesswork.
        if lexer.containsMalformedLiteral(all) {
            return "The statement contains a number or hexadecimal literal the server cannot read."
        }
        if all.contains(where: { $0.kind == .executableComment }) {
            return "Executable comments (/*! … */) are not allowed in read-only mode."
        }
        // Be stricter than the server wherever line-ending rules differ between tools: the server ends a line comment
        // only at `\n`, other tools also at `\r`, VT, FF, NEL, LS or PS. A `\r` directly before the ending `\n` (CRLF) is
        // unambiguous.
        for comment in all where comment.kind == .comment {
            let text = lexer.text(of: comment)
            guard text.hasPrefix("#") || text.hasPrefix("--") else { continue }
            var body = Array(text.unicodeScalars)
            if body.last == "\r" { body.removeLast() }
            if body.contains(where: { lineBreaksInOtherTools.contains($0.value) }) {
                return "Line comments containing carriage returns, vertical tabs, form feeds or Unicode line separators are not allowed in read-only mode."
            }
        }
        for hint in all where hint.kind == .comment && lexer.text(of: hint).hasPrefix("/*+") {
            let text = SQLNameFolding.upperSkeleton(lexer.text(of: hint))
            if let name = forbiddenHints.first(where: text.contains) {
                return "The optimizer hint \(name) is not allowed in read-only mode."
            }
        }
        let tokens = all.filter { $0.kind != .comment }
        // The servers fold some letters to ASCII (`processlıst`, `ſleep`, `ınformation_schema`): a name holding one cannot be
        // compared with the lists below the way the server reads it. Strings stay free.
        for token in tokens where [.identifier, .keyword, .quotedIdentifier, .variable].contains(token.kind) {
            let text = lexer.text(of: token)
            if let letter = SQLNameFolding.firstLetterFoldingToASCII(in: text) { return SQLNameFolding.refusal(name: text, letter: letter) }
        }
        // Names compare by their ASCII skeleton (case, compatibility forms and accents folded), as the servers may.
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? SQLNameFolding.upperSkeleton(lexer.text(of: $0)) : lexer.text(of: $0) }
        guard let first = words.first else { return "The statement is empty." }
        if let reason = secretsRejection(tokens: tokens, words: words, lexer: lexer, defaultDatabase: defaultDatabase) { return reason }
        if let reason = statementRejection(first: first, tokens: tokens, words: words, lexer: lexer) { return reason }
        return functionCallRejection(tokens: tokens, lexer: lexer, policy: functions)
    }

    /// Whether the statement is a read, and every keyword in it one a read may use.
    private static func statementRejection(first: String, tokens: [SQLToken], words: [String], lexer: SQLLexer) -> String? {
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
            // `EXPLAIN [FORMAT=…] FOR CONNECTION <id>`: another session's plan, with its literals.
            if verb == "FOR" { return otherSessionsPlanMessage }
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

    // MARK: Secrets

    static let secretsMessage = "The mysql, performance_schema and sys schemas, and the process list, are not available in read-only "
        + "mode: they hold password hashes and other sessions' statements with their values. Use information_schema for schema "
        + "browsing, and the get_processlist, get_innodb_status and get_top_statements tools, which replace every literal with ?."

    static let accountsMessage = "SHOW GRANTS and SHOW CREATE USER are not available in read-only mode: they can print password "
        + "hashes (MariaDB's SHOW GRANTS prints the account's own)."

    static let logEventsMessage = "SHOW BINLOG EVENTS and SHOW RELAYLOG EVENTS are not available in read-only mode: they print "
        + "replicated statements with their values."

    static let replicaStatusMessage = "SHOW REPLICA STATUS is not available in read-only mode: its last SQL error can quote a replicated "
        + "statement with its values. Use get_replication_status, which replaces them with ?."

    static let otherSessionsPlanMessage = "EXPLAIN FOR CONNECTION, SHOW EXPLAIN and SHOW ANALYZE are not available in read-only mode: "
        + "they show another session's statement plan with its values. Use get_processlist, which replaces every literal with ?."

    /// Schemas refused whole (deny by default: any table, view or routine, listed or not): credentials (mysql), other
    /// sessions' statements and values (performance_schema, and sys, which reads it).
    static let secretSchemas: Set<String> = ["mysql", "performance_schema", "sys"]
    /// information_schema views that show other sessions' statement text or locked rows' values.
    static let secretInformationSchemaViews: Set<String> = ["processlist", "innodb_trx", "innodb_locks", "innodb_lock_waits", "query_cache_info"]

    /// Names compare by their ASCII skeleton (`MySQL`.`USER`, `PERFORMANCE_SCHEMA`, `performance_schéma`), whatever
    /// lower_case_table_names is: refusing a user schema called `MySQL` on a case-sensitive server is the safe direction.
    static func isSecretSource(schema: String, table: String) -> Bool {
        let schema = SQLNameFolding.skeleton(schema)
        if secretSchemas.contains(schema) { return true }
        return schema == "information_schema" && secretInformationSchemaViews.contains(SQLNameFolding.skeleton(table))
    }

    /// A direct reference to a secret source (`mysql.user`, `performance_schema.events_statements_history`, also
    /// back-quoted and spaced around the dot, or unqualified in such a default schema), a SHOW that prints one, or an account
    /// definition (SHOW GRANTS, SHOW CREATE USER), which can print a password hash.
    private static func secretsRejection(tokens: [SQLToken], words: [String], lexer: SQLLexer, defaultDatabase: String?) -> String? {
        func isName(_ index: Int) -> Bool { [.identifier, .keyword, .quotedIdentifier].contains(tokens[index].kind) }
        func value(_ index: Int) -> String { lexer.identifierValue(of: tokens[index]) }
        func isDot(_ index: Int) -> Bool { tokens[index].kind == .punctuation && words[index] == "." }
        for index in tokens.indices where isDot(index) && index > 0 && index + 1 < tokens.count {
            if isName(index - 1), isName(index + 1), isSecretSource(schema: value(index - 1), table: value(index + 1)) { return secretsMessage }
        }
        if let schema = defaultDatabase?.trimmingCharacters(in: .whitespaces), !schema.isEmpty {
            if secretSchemas.contains(SQLNameFolding.skeleton(schema)) { return secretsMessage }
            for index in tokens.indices where isName(index) && !(index > 0 && isDot(index - 1)) && !(index + 1 < tokens.count && isDot(index + 1)) {
                if isSecretSource(schema: schema, table: value(index)) { return secretsMessage }
            }
        }
        if words.first == "SHOW" {
            // `SHOW TABLES FROM mysql`, `SHOW COLUMNS FROM user IN sys`: the schema whole, also by name.
            for index in tokens.indices.dropLast() where ["FROM", "IN"].contains(words[index]) && isName(index + 1) {
                if secretSchemas.contains(SQLNameFolding.skeleton(value(index + 1))) { return secretsMessage }
            }
            let rest = Array(words.dropFirst())
            if rest.first == "GRANTS" || rest.starts(with: ["CREATE", "USER"]) { return accountsMessage }
            // MariaDB `SHOW EXPLAIN|ANALYZE [FORMAT=JSON] FOR <id>`: another session's plan (`attached_condition: … 'card-…'`).
            if rest.first == "EXPLAIN" || rest.first == "ANALYZE" { return otherSessionsPlanMessage }
            // SHOW REPLICA|SLAVE [name] STATUS, SHOW ALL SLAVES|REPLICAS STATUS: the last SQL error quotes a replicated statement.
            if ["REPLICA", "SLAVE", "ALL"].contains(rest.first ?? ""), rest.contains("STATUS") { return replicaStatusMessage }
            if ["BINLOG", "RELAYLOG"].contains(rest.first ?? ""), rest.contains("EVENTS") { return logEventsMessage }
            if rest.contains("PROCESSLIST") || rest.first == "ENGINE" {
                return secretsMessage
            }
        }
        return nil
    }

    private static func checkQuery(tokens: [SQLToken], words: [String], lexer: SQLLexer, keywordsAllowed: Bool = false) -> String? {
        var depth = 0
        for (index, token) in tokens.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : ""
            if token.kind == .punctuation, words[index] == "(" { depth += 1 }
            if token.kind == .punctuation, words[index] == ")" { depth = max(0, depth - 1) }
            // The server resolves `quoted` names of native functions too.
            if token.kind == .quotedIdentifier, next == "(",
               let reason = functionRejection(SQLNameFolding.upperSkeleton(lexer.identifierValue(of: token))) {
                return reason
            }
            guard token.kind == .keyword || token.kind == .identifier else { continue }
            let word = words[index]
            if forbidden.contains(word), !keywordsAllowed || word == "INTO" {
                // REPLACE(), INSERT() and TRUNCATE() are functions when `(` follows (they are reserved: whitespace and comments
                // do not matter), except as the statement's verb: first, or right after a WITH clause's closing `)`.
                let verbPosition = index == 0 || (depth == 0 && tokens[index - 1].kind == .punctuation && words[index - 1] == ")")
                let isFunction = ["INSERT", "REPLACE", "TRUNCATE"].contains(word) && next == "(" && !verbPosition
                if !isFunction {
                    return word == "INTO" ? "SELECT … INTO is not allowed in read-only mode." : "`\(word)` is not allowed in a read-only query."
                }
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

    /// Read-only access calls only the reviewed natives of the server's flavor (final review, item 9): loadable and component
    /// functions need no privilege to call, and what runs inside them or a stored function can't be checked. Natives with
    /// side effects stay refused even when the connection allows the rest.
    private static func functionCallRejection(tokens: [SQLToken], lexer: SQLLexer, policy: FunctionPolicy) -> String? {
        for call in SQLFunctionCalls.calls(in: tokens, lexer: lexer) {
            let skeleton = SQLNameFolding.upperSkeleton(call.name)
            if let reason = functionRejection(skeleton) { return reason }
            if SQLNativeFunctions.denied.contains(skeleton) {
                return "`\(call.name)()` is not available in read-only mode: it waits, takes locks, reads server files or internals, or has other side effects."
            }
            if policy.allowsNonNative || isNative(call, flavor: policy.flavor) { continue }
            return nonNativeMessage(call)
        }
        return nil
    }

    /// Whether the server runs `call` as one of the reviewed natives: written plainly in ASCII, without a space before `(`
    /// where the server would then look for a stored function, and on MariaDB JSON_TABLE only as a table.
    static func isNative(_ call: SQLFunctionCall, flavor: ServerFlavor?) -> Bool {
        guard call.form == .plain, call.name.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let name = call.name.uppercased()
        if call.spaced, SQLNativeFunctions.resolvedAsStoredAfterSpace.contains(name) { return false }
        if name == "JSON_TABLE", flavor == .mariadb { return call.isTableReference }
        return SQLNativeFunctions.allowed(for: flavor).contains(name)
    }

    private static func nonNativeMessage(_ call: SQLFunctionCall) -> String {
        let rule = "In read-only mode AI may call only reviewed built-in functions: what runs inside loadable, component and stored "
            + "functions can't be checked. Run it in CcinnMysql's editor, or allow privileged accounts and stored functions for this "
            + "connection in its AI settings."
        switch call.form {
        case .qualified:
            return "`\(call.qualifier.map { $0 + "." } ?? "")\(call.name)()` is a stored function, not a reviewed built-in function. " + rule
        case .quoted:
            return "`` `\(call.name)`() `` is not a reviewed built-in function call: back-quoted, the server looks the name up as a "
                + "loadable or stored function. Write built-in functions without back-quotes. " + rule
        case .plain:
            let upper = call.name.uppercased()
            if call.spaced, SQLNativeFunctions.resolvedAsStoredAfterSpace.contains(upper) {
                return "`\(call.name) (…)` is not a reviewed built-in function call: with a space or comment before the parenthesis, the "
                    + "server looks for a stored function named \(call.name). Write \(upper)( without one."
            }
            return "`\(call.name)()` is not a reviewed built-in function of this server. " + rule
        }
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
