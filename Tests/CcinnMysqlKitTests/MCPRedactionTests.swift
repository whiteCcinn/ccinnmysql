import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit
import MySQLWire

/// Final review: tools that return other sessions' SQL replace every literal with `?` (digest style), since that is why
/// the raw sources are refused; and definer-rights objects are reported, not refused.
@Suite("MCP redaction and definer rights")
struct MCPRedactionTests {
    @Test func everyLiteralBecomesAPlaceholder() {
        #expect(SQLRedactor.redactLiterals("SELECT * FROM users WHERE email = 'alice@example.com' AND pin = 1234 AND f = 1.5e3")
            == "SELECT * FROM users WHERE email = ? AND pin = ? AND f = ?")
        #expect(SQLRedactor.redactLiterals("UPDATE t SET note = \"secret note\", hex = x'41', bits = b'01' WHERE id IN (1, 2)")
            == "UPDATE t SET note = ?, hex = ?, bits = ? WHERE id IN (?, ?)")
        #expect(SQLRedactor.redactLiterals("SELECT a /* card 4111111111111111 */ FROM t -- ssn 123-45-6789\nWHERE b = _utf8mb4'x'")
            == "SELECT a ? FROM t ?\nWHERE b = _utf8mb4?")
        #expect(SQLRedactor.redactLiterals("SELECT `name`, t.col FROM `db`.t") == "SELECT `name`, t.col FROM `db`.t", "names stay")
        // The other session's sql_mode is unknown: whatever is a literal in some mode is hidden.
        for statement in ["UPDATE t SET p = 'C:\\' , q = 'hunter2'", "SELECT \"a\\\" , 'hunter2' AS x", "SELECT 'unterminated hunter2"] {
            let redacted = SQLRedactor.redactLiterals(statement)
            #expect(!redacted.contains("hunter2"), "\(statement) -> \(redacted)")
        }
    }

    @Test func innodbStatusLosesRowDumpsAndLiterals() {
        let deadlock = """
            *** (1) TRANSACTION:
            TRANSACTION 1859, ACTIVE 4 sec starting index read
            MySQL thread id 12, OS thread handle 1401, query id 87 localhost root updating
            UPDATE accounts SET balance = 0 WHERE owner = 'hunter2'
            *** (1) HOLDS THE LOCK(S):
            RECORD LOCKS space id 2 page no 4 n bits 72 index PRIMARY of table `shop`.`accounts` trx id 1859 lock_mode X locks rec but not gap
            Record lock, heap no 2 PHYSICAL RECORD: n_fields 4; compact format; info bits 0
             0: len 4; hex 80000001; asc     ;;
             1: len 7; hex 68756e74657232; asc hunter2;;
             2: SQL NULL;
             3: len 12; hex 6c696e65310a73656372657432; asc line1
            secret2;;
            *** (2) TRANSACTION:
            MySQL thread id 13, OS thread handle 1402, query id 88 localhost root updating
            UPDATE accounts SET note = 'two
            lines secret3' WHERE id = 2
            *** WE ROLL BACK TRANSACTION (2)
            """
        let redacted = SQLRedactor.redactInnoDBStatus(deadlock)
        for secret in ["hunter2", "68756e74", "secret2", "secret3", "line1"] {
            #expect(!redacted.contains(secret), "\(secret): \(redacted)")
        }
        #expect(redacted.contains("UPDATE accounts SET note = ? WHERE id = ?"))
        #expect(redacted.contains("*** WE ROLL BACK TRANSACTION (2)") && redacted.contains("MySQL thread id 13"))
        #expect(redacted.contains("UPDATE accounts SET balance = ? WHERE owner = ?"))
        #expect(redacted.contains("RECORD LOCKS"))
    }

    @Test func toolEncodersRedactEveryLiteral() throws {
        var activity = InnoDBActivity()
        let names = ["waiting_trx_id", "waiting_thread", "waiting_query", "blocking_trx_id", "blocking_thread", "blocking_query", "lock_data"]
        let values: [String?] = ["1", "12", "UPDATE t SET p = 'hunter2' WHERE id = 7", "2", "13", "SELECT * FROM t WHERE ssn = '123-45-6789' FOR UPDATE",
                                 "7, 'hunter2'"]
        activity.lockWaits = [LockWait(record: Record(values: values, lookup: ColumnLookup(names: names)))]
        activity.latestDeadlock = "UPDATE t SET p = 'hunter2'\n 1: len 7; hex 68756e74657232; asc hunter2;;"
        let encoded = MySQLMCPTools.encode(activity: activity).serialized()
        #expect(!encoded.contains("hunter2") && !encoded.contains("123-45-6789"), "\(encoded)")
        #expect(encoded.contains("UPDATE t SET p = ? WHERE id = ?"))
    }

    /// Answers like a server would; statements not listed fail (access denied).
    private actor FakeServer {
        let answers: [String: [[String?]]]
        init(_ answers: [String: [[String?]]]) { self.answers = answers }
        func run(_ sql: String) throws -> [ResultSet] {
            guard let rows = answers[sql] else { throw MySQLError(.server, "Access denied: \(sql)") }
            let width = rows.first?.count ?? 1
            return [ResultSet(columns: (0..<width).map { ColumnDefinition(name: "c\($0)", type: .varString) }, rows: rows)]
        }
    }

    static let routines = "SELECT ROUTINE_TYPE, ROUTINE_SCHEMA, ROUTINE_NAME, DEFINER FROM information_schema.ROUTINES WHERE SECURITY_TYPE = 'DEFINER'"
    static let views = "SELECT 'VIEW', TABLE_SCHEMA, TABLE_NAME, DEFINER FROM information_schema.VIEWS WHERE SECURITY_TYPE = 'DEFINER'"

    @Test func definerRightsObjectsAreReported() async throws {
        let server = FakeServer([
            "SELECT CURRENT_USER()": [["ai@%"]],
            Self.routines: [["FUNCTION", "shop", "fn_root", "root@localhost"], ["PROCEDURE", "shop", "own", "ai@%"],
                            ["FUNCTION", "sys", "format_statement", "mysql.sys@localhost"], ["FUNCTION", "shop", "fn_app", "app@%"]],
            Self.views: [["VIEW", "shop", "v_admin", "admin@%"]],
            // admin's grants are visible and privileged, app's are visible and plain, root's are not visible.
            "SHOW GRANTS FOR 'admin'@'%'": [["GRANT FILE ON *.* TO `admin`@`%`"]],
            "SHOW GRANTS FOR 'app'@'%'": [["GRANT SELECT ON `shop`.* TO `app`@`%`"]],
        ])
        let objects = try await DefinerRights.load { try await server.run($0) }
        #expect(objects.map { "\($0.schema).\($0.name)" } == ["shop.fn_root", "shop.v_admin"], "own, sys and plain definers are not reported")
        #expect(objects.first?.definerPrivileged == nil && objects.last?.definerPrivileged == true)
        let notice = try #require(DefinerRights.notice(for: objects))
        #expect(notice.hasPrefix("2 definer-rights routines or views run with a privileged account's rights; the read-only check can't see inside them"))
        #expect(notice.contains("shop.fn_root") && notice.contains("privileges not visible"))
        #expect(DefinerRights.notice(for: []) == nil)
        let report = AIAccessReport(privileges: AccountPrivileges(reasons: []), definerRights: objects)
        #expect(report.summary(allowsPrivilegedAccount: false).contains("Not a privileged account"))
        #expect(AIAccessReport(privileges: AccountPrivileges(reasons: ["FILE"]), definerRights: []).summary(allowsPrivilegedAccount: false)
            .contains("read-only AI tools refuse it"))
    }

    // A definer holding PROCESS sees every session's statements: a definer-rights view over the process list shows them to
    // anyone who can select from it.
    @Test func definersHoldingProcessAreReported() async throws {
        let server = FakeServer([
            "SELECT CURRENT_USER()": [["ai@%"]],
            Self.routines: [],
            Self.views: [["VIEW", "shop", "v_sessions", "monitor@%"]],
            "SHOW GRANTS FOR 'monitor'@'%'": [["GRANT PROCESS ON *.* TO `monitor`@`%`"], ["GRANT SELECT ON `shop`.* TO `monitor`@`%`"]],
        ])
        let objects = try await DefinerRights.load { try await server.run($0) }
        #expect(objects.map(\.label) == ["shop.v_sessions (view, definer monitor@%)"])
        #expect(objects.first?.definerPrivileged == true)
    }
}
