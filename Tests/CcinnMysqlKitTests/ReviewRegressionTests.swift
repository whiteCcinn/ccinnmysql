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
                      "SELECT is_free_lock('x')", "SELECT 'a\r\nb' FROM t", "SELECT 1 # comment\r\n"])
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
