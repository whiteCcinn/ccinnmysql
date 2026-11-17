import Foundation
import MySQLWire
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Regression tests for the independent adversarial review findings.
@Suite("Review regressions: read-only guard")
struct GuardReviewRegressionTests {
    /// MySQL ends `#` and `-- ` comments only at `\n` (or NUL), and `--` + any control byte (incl. 0x7F) starts one.
    @Test(arguments: [
        "SELECT 1 #\r'\nINTO OUTFILE '/var/lib/mysql-files/x' -- '",
        "SELECT 1 -- \r'\nINTO OUTFILE '/var/lib/mysql-files/x' -- '",
        "SELECT 1 --\u{7F}'\nINTO OUTFILE '/var/lib/mysql-files/x' #'",
        "SELECT 1 #\r'\n, LOAD_FILE('/etc/passwd') -- '",
        "SELECT 1 #\r'\nFOR UPDATE -- '",
        "SELECT 1\u{0} INTO OUTFILE '/tmp/x'",
        "SELECT 1 #\u{0}'\nINTO OUTFILE '/tmp/x' -- '",
        "SELECT 1 -- note\rFROM t", "SELECT 1 # note\u{0B}FROM t", "SELECT 1 # note\u{0C}FROM t", "SELECT 1 -- a\r\rb\n",
        "SELECT 1 # note\u{85}FROM t", "SELECT 1 -- note\u{2028}FROM t", "SELECT 1 # note\u{2029}FROM t",
    ])
    func commentBoundariesMatchTheServer(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
    }

    @Test func lexerEndsLineCommentsOnlyAtNewline() {
        let lexer = SQLLexer("SELECT 1 #a\rb\nFROM t")
        let tokens = lexer.tokens()
        #expect(tokens.map(\.kind) == [.keyword, .number, .comment, .keyword, .identifier])
        #expect(lexer.text(of: tokens[2]) == "#a\rb")
        #expect(SQLLexer.tokenize("SELECT 1 --\u{7F}x\nFROM t").map(\.kind) == [.keyword, .number, .comment, .keyword, .identifier])
        #expect(SQLStatementSplitter.split("SELECT 1 #;\r;\nFROM t; SELECT 2").map(\.text) == ["SELECT 1 #;\r;\nFROM t", "SELECT 2"])
    }

    @Test(arguments: [
        "SELECT `LOAD_FILE`('/etc/passwd')", "SELECT `GET_LOCK`('x', 0)", "SELECT `sleep`(100)", "SELECT `Release_All_Locks`()",
        "SELECT group_replication_set_as_primary('3e11fa47-71ca-11e1-9e33-c80aa9429562')",
        "SELECT group_replication_switch_to_single_primary_mode()", "SELECT asynchronous_connection_failover_add_source('ch', 'h', 3306, '', 50)",
        "SELECT version_tokens_set('a=b')", "SELECT keyring_key_remove('k', 'u')", "SELECT audit_log_filter_set_filter('f', '{}')",
        "SELECT set_firewall_mode('u@h', 'OFF')", "SELECT mysql_firewall_flush_status()", "SELECT service_get_write_locks('ns', 'l', 10)",
        "SELECT /*+ MAX_EXECUTION_TIME(0) */ * FROM t", "SELECT /*+ SET_VAR(max_execution_time = 0) */ 1",
        "SELECT /*+ RESOURCE_GROUP(rg) */ 1",
    ])
    func sideEffectsAndLimitOverridesAreRejected(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    @Test(arguments: ["SELECT /*+ INDEX(t idx_a) */ * FROM t", "SELECT `group_replication_applier` FROM t", "SELECT `sleep` FROM t",
                      "SELECT is_free_lock('x')", "SELECT 'a\r\nb' FROM t", "SELECT 1 # comment\r\n",
                      "SELECT 1 -- comment\r\nFROM t", "SELECT 1 # comment\r", "SELECT '\u{0B}\u{0C}' -- ok\n", "SELECT '\u{2028}' /* \u{85}\r */ FROM t"])
    func harmlessQueriesStillPass(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription)")
    }
}

@Suite("Review regressions: redaction")
struct RedactionReviewRegressionTests {
    @Test func currentPasswordInReplaceClause() {
        #expect(SQLRedactor.redact("ALTER USER u IDENTIFIED BY 'new' REPLACE 'old'") == "ALTER USER u IDENTIFIED BY '***' REPLACE '***'")
        #expect(SQLRedactor.redact("SET PASSWORD = 'new' REPLACE 'old'") == "SET PASSWORD = '***' REPLACE '***'")
        #expect(SQLRedactor.redact("SELECT REPLACE('a', 'b', 'c')") == "SELECT REPLACE('a', 'b', 'c')")
    }

    @Test func secretsEchoedInServerErrorsAreRemoved() {
        let sql = "CREATE USR bob IDENTIFIED BY 'Hunter2'"
        let message = "You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'USR bob IDENTIFIED BY 'Hunter2'' at line 1"
        let redacted = SQLRedactor.redact(message: message, statement: sql)
        #expect(!redacted.contains("Hunter2"))
        #expect(redacted.contains("near 'USR bob IDENTIFIED BY '***'' at line 1"))
        #expect(SQLRedactor.redact(message: "Table 'x' doesn't exist", statement: "SELECT * FROM x") == "Table 'x' doesn't exist")
    }

    @Test func historyAndAuditStoreRedactedErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-redact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = QueryHistoryStore(directory: directory, profileID: UUID())
        await history.append(QueryHistoryEntry(sql: "CREATE USR bob IDENTIFIED BY 'Hunter2'", database: nil, durationMilliseconds: 1,
                                               errorMessage: "… near 'USR bob IDENTIFIED BY 'Hunter2'' at line 1"))
        let stored = try String(contentsOf: history.fileURL, encoding: .utf8)
        #expect(!stored.contains("Hunter2"))
        let audit = MCPAuditLog(directory: directory)
        await audit.record(tool: "execute_statement", connection: "c", statement: "ALTER USER x IDENTIFIED BY 'S3cret!'", durationMilliseconds: 1, rows: nil,
                           error: "Access denied … 'S3cret!'")
        let auditText = try String(contentsOf: audit.fileURL, encoding: .utf8)
        #expect(!auditText.contains("S3cret!"))
    }
}

@Suite("Review regressions: inline edit")
struct RowEditReviewRegressionTests {
    private func column(_ name: String, table alias: String, original: String = "customers") -> ColumnDefinition {
        var writer = PayloadWriter()
        for part in ["def", "shop", alias, original, name, name] { writer.writeLengthEncodedString(part) }
        writer.writeLengthEncoded(0x0C)
        writer.writeUInt16(45)
        writer.writeUInt32(255)
        writer.writeUInt8(ColumnType.varString.rawValue)
        writer.writeUInt16(0)
        writer.writeUInt8(0)
        writer.writeUInt16(0)
        return (try? ColumnDefinition(payload: writer.bytes)) ?? ColumnDefinition(name: name, type: .varString)
    }

    @Test func selfJoinIsReadOnly() {
        let columns = [column("id", table: "a"), column("name", table: "b")]
        #expect(RowEditor.eligibility(columns: columns, keys: [["id"]], isBaseTable: true).plan == nil)
    }

    @Test func singleAliasStaysEditable() {
        let columns = [column("id", table: "c"), column("name", table: "c")]
        #expect(RowEditor.eligibility(columns: columns, keys: [["id"]], isBaseTable: true).plan != nil)
    }
}

@Suite("Review regressions: sql_mode")
struct SQLModeReviewRegressionTests {
    @Test func lexerAffectingModesAreRemoved() {
        #expect(SQLModes.affectsLexing("STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES"))
        #expect(SQLModes.affectsLexing("REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI"))
        #expect(!SQLModes.affectsLexing("ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES"))
        #expect(SQLModes.withoutLexerAffectingModes("REAL_AS_FLOAT,ANSI_QUOTES,ANSI,NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES")
            == "REAL_AS_FLOAT,STRICT_TRANS_TABLES")
        #expect(SQLModes.withoutLexerAffectingModes("") == "")
        #expect(SQLModes.withoutLexerAffectingModes("A';DROP") == "", "only mode names survive")
    }
}

/// Differential check: an independent, server-like tokenizer (line comments end only at `\n`/NUL; `--` + space/control;
/// `/*!` and `/*M!` content is code; backslash escapes in strings; `1abc` is one identifier) must find no forbidden
/// keyword and no forbidden function call in any statement the guard accepts.
@Suite("Read-only guard differential fuzz")
struct GuardDifferentialFuzzTests {
    /// Words the guard forbids anywhere in a SELECT (a subset of `ReadOnlySQLGuard.forbidden`).
    static let forbiddenWords: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE", "DROP", "CREATE", "ALTER", "INTO", "OUTFILE",
                                              "LOAD", "CALL", "LOCK", "KILL", "GRANT", "TRUNCATE", "DO", "HANDLER"]
    static let forbiddenCalls: Set<String> = ["LOAD_FILE", "GET_LOCK", "SLEEP", "RELEASE_LOCK", "BENCHMARK"]

    /// Deterministic generator so a failure reproduces.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Tokens outside strings, quoted identifiers and plain comments, as the server would see them (words upper-cased,
    /// punctuation as single characters).
    static func serverTokens(_ sql: String) -> [String] {
        let chars = Array(sql.unicodeScalars)
        var tokens: [String] = []
        var index = 0
        var word = ""
        func flush() {
            if !word.isEmpty { tokens.append(word.uppercased()) }
            word = ""
        }
        func at(_ offset: Int) -> Unicode.Scalar? { index + offset < chars.count ? chars[index + offset] : nil }
        func isName(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || c == "_" || c == "$" || ("0"..."9").contains(c) || c.value >= 0x80 }
        /// A digit, or `.digit` not after a name; never right after `name.` (the server reads a name there).
        func startsNumber(_ index: Int) -> Bool {
            let c = chars[index]
            let afterName = index > 0 && isName(chars[index - 1])
            let afterMemberDot = index >= 2 && chars[index - 1] == "." && isName(chars[index - 2])
            if afterMemberDot { return false }
            if ("0"..."9").contains(c) { return true }
            return c == "." && !afterName && (at(1).map { ("0"..."9").contains($0) } ?? false)
        }
        while index < chars.count {
            let c = chars[index]
            if c == "'" || c == "\"" || c == "`" {
                flush()
                tokens.append("<literal>")
                index += 1
                while index < chars.count {
                    if c != "`", chars[index] == "\\" { index += 2; continue }
                    if chars[index] == c {
                        if at(1) == c { index += 2; continue }
                        break
                    }
                    index += 1
                }
                index += 1
            } else if c == "#" || (c == "-" && at(1) == "-" && (at(2).map { $0.value <= 0x20 || $0.value == 0x7F } ?? true)) {
                flush()
                while index < chars.count, chars[index] != "\n", chars[index].value != 0 { index += 1 }
            } else if c == "/", at(1) == "*" {
                flush()
                if at(2) == "!" || (at(2) == "M" && at(3) == "!") {
                    index += at(2) == "!" ? 3 : 4 // executable: the content is code
                    continue
                }
                index += 2
                while index < chars.count, !(chars[index] == "*" && at(1) == "/") { index += 1 }
                index += 2
            } else if c == "\\", at(1) == "N" {
                // MariaDB (and MySQL 5.x) read `\N` as NULL and end it after the N: `\Ninto` is NULL INTO.
                flush()
                tokens.append("NULL")
                index += 2
            } else if word.isEmpty, startsNumber(index), let length = Self.serverNumber(chars, from: index) {
                // A number ends before a glued word (`1.5into` is 1.5 INTO); a malformed one stops the server's lexer.
                if length < 0 { return ["<rejected>"] }
                tokens.append("<number>")
                index += length
            } else if isName(c) {
                word.unicodeScalars.append(c)
                index += 1
            } else {
                flush()
                if c.value > 0x20 { tokens.append(String(c)) }
                index += 1
            }
        }
        flush()
        return tokens
    }

    /// Length of the number the server reads at `start` (sql_lex.cc, written independently of `SQLLexer`): `0x…` / `0b…`
    /// not followed by a name character; digits with a complete exponent; a decimal with an optional complete exponent.
    /// `nil` where the server reads a name (`1abc`, `1e`), `-1` where it rejects the text (`1.e`).
    static func serverNumber(_ chars: [Unicode.Scalar], from start: Int) -> Int? {
        func digit(_ i: Int) -> Bool { i < chars.count && ("0"..."9").contains(chars[i]) }
        func nameCharacter(_ i: Int) -> Bool {
            i < chars.count && (chars[i].properties.isAlphabetic || chars[i] == "_" || chars[i] == "$" || digit(i) || chars[i].value >= 0x80)
        }
        func afterExponent(_ e: Int) -> Int? {
            guard e < chars.count, chars[e] == "e" || chars[e] == "E" else { return nil }
            var k = e + 1
            if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
            guard digit(k) else { return nil }
            while digit(k) { k += 1 }
            return k
        }
        if chars[start] == "0", start + 1 < chars.count, chars[start + 1] == "x" || chars[start + 1] == "b" {
            let hex = chars[start + 1] == "x"
            var end = start + 2
            while end < chars.count, hex ? chars[end].properties.isASCIIHexDigit : (chars[end] == "0" || chars[end] == "1") { end += 1 }
            return end > start + 2 && !nameCharacter(end) ? end - start : nil
        }
        var end = start
        while digit(end) { end += 1 }
        if end < chars.count, chars[end] == "." {
            end += 1
            while digit(end) { end += 1 }
            guard end < chars.count, chars[end] == "e" || chars[end] == "E" else { return end - start }
            return afterExponent(end).map { $0 - start } ?? -1
        }
        if let exponentEnd = afterExponent(end) { return exponentEnd - start }
        return nameCharacter(end) ? nil : end - start
    }

    static func leaks(_ sql: String) -> [String] {
        let tokens = serverTokens(sql)
        return tokens.indices.compactMap { index in
            let token = tokens[index]
            if forbiddenWords.contains(token) { return token }
            if forbiddenCalls.contains(token), index + 1 < tokens.count, tokens[index + 1] == "(" { return token + "(" }
            return nil
        }
    }

    @Test func oracleSeesTheKnownSmuggles() {
        #expect(Self.leaks("SELECT 1 #\r'\nINTO OUTFILE '/tmp/x' -- '") == ["INTO", "OUTFILE"])
        #expect(Self.leaks("SELECT /*!50000 SLEEP(1) */") == ["SLEEP("])
        #expect(Self.leaks("SELECT 'a\\' INTO' FROM t") == [])
        #expect(Self.leaks("SELECT 1LOAD_FILE('x')") == [])
        #expect(Self.leaks("SELECT 1.5into @v") == ["INTO"])
        #expect(Self.leaks("SELECT 1e5into @v, 1einto, t.1e5into") == ["INTO"])
        #expect(Self.leaks("SELECT 1.einto @v") == [], "rejected by the server's lexer")
        #expect(Self.leaks("SELECT \\Ninto @v") == ["INTO"])
    }

    @Test(arguments: [UInt64(1), 2, 3, 4])
    func acceptedStatementsHideNoForbiddenTokens(seed: UInt64) {
        let pieces = [" ", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\t", "#", "-- ", "--", "--\u{7F}", "--\r", "/*", "*/", "/*!",
                      "/*M!", "/*+ ", "'", "\"", "`", "\\", "\\'", "INTO OUTFILE '/tmp/x'", "LOAD_FILE('/etc/passwd')", "GET_LOCK('x', 0)",
                      " FROM t", ", 2", " SLEEP (1)", "DELETE FROM t", "x", "''", "\"\"", "``", "(", ")", " FOR UPDATE", " CHARACTER SET utf8mb4",
                      "\u{0}", " ; SELECT 2", "/**/(", "1", "1.5", "1e5", ".5", "e", "into @v", " for share", " lock in share mode", "x'41'",
                      "ınto", "\\N", "\\Ninto @v", " IS NOT \\Nlock in share mode"]
        var generator = SplitMix64(state: seed)
        var accepted = 0
        for _ in 0..<15_000 {
            var sql = "SELECT 1"
            for _ in 0..<Int.random(in: 1...9, using: &generator) {
                sql += pieces.randomElement(using: &generator) ?? " "
            }
            guard ReadOnlySQLGuard.check(sql) == nil else { continue }
            accepted += 1
            let leaked = Self.leaks(sql)
            #expect(leaked.isEmpty, "\(sql.debugDescription) → \(leaked)")
            if !leaked.isEmpty { return }
        }
        #expect(accepted > 500, "the fuzz must exercise accepted statements too (\(accepted))")
    }
}
