import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Final review, item 9: loadable and component functions need no privilege to call, and stored functions ran INTO OUTFILE,
/// LOAD_FILE, SLEEP and GET_LOCK inside READ ONLY. Read-only AI access calls only reviewed natives of the server's flavor;
/// anything else needs the connection's allowance.
@Suite("Read-only function allow-list")
struct FunctionAllowListTests {
    static let mysql = ReadOnlySQLGuard.FunctionPolicy(flavor: .mysql)
    static let mariadb = ReadOnlySQLGuard.FunctionPolicy(flavor: .mariadb)
    static let policies = [ReadOnlySQLGuard.FunctionPolicy(), mysql, mariadb]

    // The reviewer's calls (live on 8.4 as a plain account at ecc2c72), and stored functions qualified or not.
    @Test(arguments: [
        "SELECT audit_api_message_emit_udf('x')", "SELECT mysql_query_attribute_string('a')", "SELECT mysqlx_generate_document_id()",
        "SELECT innodb_redo_log_archive_start('rvlabel', 'mcp')", "SELECT sys_get('PATH')", "SELECT sys_set('a', 'b')", "SELECT sys_bineval('x')",
        "SELECT gen_dictionary_load('d')", "SELECT shop.f()", "SELECT fn_order_total(1)", "SELECT shop.`f`(1)", "SELECT * FROM t WHERE x = f(1)",
        "SELECT `abs`(1)", "SELECT COUNT (*) FROM t", "SELECT SUM/* x */(a) FROM t", "SELECT CAST (a AS CHAR) FROM t",
        "SHOW TABLES WHERE f(1)", "EXPLAIN SELECT f(1)", "SELECT 1 FROM t ORDER BY f(a)", "SELECT (SELECT f(1))",
    ])
    func nonNativeCallsAreRefused(sql: String) {
        for policy in Self.policies {
            let message = ReadOnlySQLGuard.check(sql, functions: policy)
            #expect(message?.contains("reviewed built-in") == true, "\(sql) \(String(describing: policy.flavor)): \(message ?? "allowed")")
        }
    }

    // Words that are syntax only in some places, or not reserved on every server, are calls elsewhere: `value(1)` resolves to a
    // stored function there. COLUMNS is JSON_TABLE's only inside JSON_TABLE; an accented spelling of a keyword is a name.
    @Test(arguments: ["SELECT columns(1)", "SELECT columns(f(1))", "SELECT value(1)", "SELECT escape(1)", "SELECT offset(1)", "SELECT any(1)",
                      "SELECT a FROM t WHERE a = some(1)", "SELECT lateral(1)", "SELECT over(1)", "SELECT x, partition(1) FROM t",
                      "SELECT of(1)", "SELECT recursive(1)", "SELECT except(1)", "SELECT sélect(1)", "SELECT 1 FROM t WHERE x = ánd(1)",
                      "SELECT CONVERT(x USING utf8mb4), f(1) FROM t"])
    func contextualSyntaxIsACallElsewhere(sql: String) {
        let message = ReadOnlySQLGuard.check(sql, functions: Self.mysql)
        #expect(message?.contains("reviewed built-in") == true, "\(sql): \(message ?? "allowed")")
    }

    @Test func theMessageNamesTheFunction() {
        let message = ReadOnlySQLGuard.check("SELECT innodb_redo_log_archive_start('rvlabel', 'mcp')", functions: Self.mysql) ?? ""
        #expect(message.contains("innodb_redo_log_archive_start") && message.contains("editor"), "\(message)")
        #expect(ReadOnlySQLGuard.check("SELECT COUNT (*) FROM t", functions: Self.mysql)?.contains("COUNT(") == true)
        #expect(ReadOnlySQLGuard.check("SELECT shop.f()", functions: Self.mysql)?.contains("shop.f") == true)
    }

    // The connection's allowance (privileged accounts and stored functions) lets stored and loadable functions through; the
    // natives with side effects stay refused.
    @Test func theAllowanceAdmitsStoredFunctionsButNotSideEffects() {
        let allowed = ReadOnlySQLGuard.FunctionPolicy(flavor: .mysql, allowsNonNative: true)
        for sql in ["SELECT shop.f()", "SELECT fn_order_total(1)", "SELECT `abs`(1)", "SELECT COUNT (*) FROM t"] {
            #expect(ReadOnlySQLGuard.check(sql, functions: allowed) == nil, "\(sql)")
        }
        for sql in ["SELECT SLEEP(1)", "SELECT shop.sleep(1)", "SELECT LOAD_FILE('/etc/hosts')", "SELECT GET_LOCK('k', 1)"] {
            #expect(ReadOnlySQLGuard.check(sql, functions: allowed) != nil, "\(sql)")
        }
    }

    // Normal analytics: aggregates, window functions, casts, JSON, dates, CTE and derived-table column lists, index hints.
    @Test(arguments: [
        "SELECT COUNT(*), SUM(amount), AVG(amount), MIN(created_at), MAX(created_at) FROM orders GROUP BY customer_id",
        "SELECT id, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at DESC) AS rn FROM orders",
        "SELECT LAG(amount, 1) OVER (ORDER BY id), FIRST_VALUE(amount) OVER (PARTITION BY customer_id) FROM orders",
        "SELECT a, SUM(b) OVER w FROM t WINDOW w AS (PARTITION BY a)",
        "SELECT CAST(amount AS DECIMAL(10,2)), CONVERT(note, CHAR(20)), CAST(note AS CHAR(10) CHARACTER SET utf8mb4) FROM orders",
        "SELECT CONVERT(note USING utf8mb4), CAST(created_at AS DATETIME(6)), CONVERT(created_at, DATETIME(3)) FROM orders",
        "SELECT JSON_EXTRACT(doc, '$.a'), JSON_UNQUOTE(JSON_EXTRACT(doc, '$.b')), JSON_OBJECT('k', 1), JSON_ARRAY(1, 2) FROM t",
        "SELECT DATE_FORMAT(created_at, '%Y-%m'), DATE_ADD(NOW(), INTERVAL 1 DAY), TIMESTAMPDIFF(DAY, a, b), EXTRACT(YEAR FROM d) FROM t",
        "WITH monthly (m, total) AS (SELECT DATE_FORMAT(created_at, '%Y-%m'), SUM(amount) FROM orders GROUP BY 1) SELECT * FROM monthly",
        "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5) SELECT n FROM seq",
        "WITH a AS (SELECT 1 AS x), b(y) AS (SELECT 2) SELECT * FROM a, b",
        "SELECT * FROM (SELECT 1, 2) AS t(a, b)", "SELECT * FROM (SELECT 1) t(a)",
        "SELECT REPLACE(note, 'o', '0'), INSERT(note, 1, 1, 'F'), TRUNCATE(amount, 0) FROM orders",
        "SELECT REPLACE('hello', 'l', 'L'), INSERT('abcdef', 2, 3, 'X'), TRUNCATE(3.14159, 2)",
        "SELECT REPLACE (note, 'o', '0'), REPLACE/* c */(note, 'a', 'b') FROM orders",
        "SELECT IF(a > 0, 'pos', 'neg'), IFNULL(b, 0), COALESCE(c, d), NULLIF(e, 0), LEFT(s, 3), RIGHT(s, 2), CHAR(65) FROM t",
        "SELECT * FROM t WHERE a IN (1, 2) AND EXISTS (SELECT 1) AND b = ANY (SELECT 1) AND NOT (c = 1)",
        "SELECT MATCH (title) AGAINST ('x' IN BOOLEAN MODE) FROM docs", "SELECT * FROM t FORCE INDEX (idx_a) WHERE a = 1",
        "SELECT GROUP_CONCAT(DISTINCT name ORDER BY name SEPARATOR ', ') FROM t",
        "SELECT * FROM JSON_TABLE('[1,2]', '$[*]' COLUMNS (id INT PATH '$', name VARCHAR(10) PATH '$')) AS jt",
        "SELECT ABS (x), ROUND(x, 2), FLOOR(x), x MOD (3), a DIV (2) FROM t",
        "SELECT UPPER(name), LOWER(name), CONCAT_WS('-', a, b), SUBSTRING(s, 1, 3), TRIM(s), LENGTH(s) FROM t",
        "SELECT * FROM t WHERE (a, b) IN ((1, 2))", "SELECT * FROM t1 JOIN (t2) USING (id)", "SELECT * FROM t1 LEFT JOIN t2 ON (t1.a = t2.a)",
        "SELECT CASE WHEN (a > 1) THEN (1) ELSE (2) END FROM t", "SELECT a FROM t WHERE b BETWEEN (1) AND (2)",
        "SELECT USER(), CURRENT_USER(), DATABASE(), VERSION(), CONNECTION_ID(), NOW(6), UUID()",
        "SELECT sleep, load_file, `sleep`, `load_file`, t.sleep FROM t ORDER BY sleep", "SELECT 1 AS `count` FROM t",
        "SELECT (1) UNION (SELECT 2)", "SELECT * FROM t PARTITION (p0)", "SHOW TABLES WHERE Tables_in_shop LIKE CONCAT('o', '%')",
        "EXPLAIN SELECT COUNT(*) FROM orders", "SELECT IS_FREE_LOCK('x')",
        "SELECT * FROM (SELECT 1) AS `t`(a)", "WITH `c`(a) AS (SELECT 1) SELECT * FROM `c`", "SELECT 1 MEMBER OF ('[1, 2]')",
        "SELECT * FROM t1, LATERAL (SELECT 1) AS d", "SELECT a FROM t WHERE a = SOME (SELECT 1)", "SELECT 1 EXCEPT (SELECT 2)",
    ])
    func normalAnalyticsStayAllowed(sql: String) {
        for policy in [Self.mysql, Self.mariadb, ReadOnlySQLGuard.FunctionPolicy()] {
            #expect(ReadOnlySQLGuard.check(sql, functions: policy) == nil,
                    "\(sql) \(String(describing: policy.flavor)): \(ReadOnlySQLGuard.check(sql, functions: policy) ?? "")")
        }
    }

    // The statement verbs stay refused, also in their optional-INTO forms and after WITH.
    @Test(arguments: ["INSERT INTO t VALUES (1)", "INSERT t (a) VALUES (1)", "REPLACE t (a) VALUES (1)", "REPLACE INTO t (a) VALUES (1)",
                      "TRUNCATE TABLE t", "TRUNCATE t", "WITH c AS (SELECT 1) REPLACE INTO t SELECT * FROM c",
                      "WITH c AS (SELECT 1) REPLACE t SELECT * FROM c", "WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c",
                      "insert(t) values (1)", "REPLACE (a) VALUES (1)"])
    func statementVerbsStayRefused(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql, functions: Self.mysql) != nil, "\(sql)")
    }

    @Test func eachFlavorCallsOnlyItsOwnNatives() {
        #expect(ReadOnlySQLGuard.check("SELECT SFORMAT('{}', 1)", functions: Self.mariadb) == nil)
        #expect(ReadOnlySQLGuard.check("SELECT SFORMAT('{}', 1)", functions: Self.mysql) != nil, "a stored function on MySQL")
        #expect(ReadOnlySQLGuard.check("SELECT ANY_VALUE(a) FROM t", functions: Self.mysql) == nil)
        #expect(ReadOnlySQLGuard.check("SELECT ANY_VALUE(a) FROM t", functions: Self.mariadb) != nil)
        #expect(ReadOnlySQLGuard.check("SELECT POINT(1, 2)", functions: Self.mysql) == nil)
        #expect(ReadOnlySQLGuard.check("SELECT POINT(1, 2)", functions: Self.mariadb) != nil, "POINT() resolves to a stored function there")
        // MariaDB's JSON_TABLE is native only as a table.
        #expect(ReadOnlySQLGuard.check("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (id INT PATH '$')) AS jt", functions: Self.mariadb) == nil)
        #expect(ReadOnlySQLGuard.check("SELECT JSON_TABLE('[1]', '$')", functions: Self.mariadb) != nil)
        #expect(ReadOnlySQLGuard.check("SELECT * FROM orders o, JSON_TABLE(o.note, '$' COLUMNS (v INT PATH '$')) AS jt", functions: Self.mariadb) == nil)
        #expect(ReadOnlySQLGuard.check("SELECT * FROM orders o LEFT JOIN JSON_TABLE(o.note, '$' COLUMNS (v INT PATH '$')) AS jt ON TRUE",
                                       functions: Self.mariadb) == nil)
        #expect(ReadOnlySQLGuard.check("SELECT a, JSON_TABLE('[1]', '$') FROM t", functions: Self.mariadb) != nil)
        #expect(ReadOnlySQLGuard.check("SELECT * FROM t WHERE a IN (1, JSON_TABLE('[1]', '$'))", functions: Self.mariadb) != nil)
        // Spelled with letters outside ASCII, a name is not a native (the server may look for a stored function).
        #expect(ReadOnlySQLGuard.check("SELECT cöunt(1)", functions: Self.mysql)?.contains("reviewed built-in") == true)
        // Denied natives are refused by their folded spelling too, also with the allowance.
        #expect(ReadOnlySQLGuard.check("SELECT SLÉEP(1)", functions: ReadOnlySQLGuard.FunctionPolicy(flavor: .mysql, allowsNonNative: true)) != nil)
    }

    @Test func callsAreFoundWhereTheServerSeesThem() {
        func calls(_ sql: String) -> [String] {
            let lexer = SQLLexer(sql)
            return SQLFunctionCalls.calls(in: lexer.tokens().filter { $0.kind != .comment }, lexer: lexer).map { call in
                call.name + (call.form == .quoted ? "`" : call.form == .qualified ? "." : "") + (call.spaced ? "_" : "")
            }
        }
        #expect(calls("SELECT COUNT(*), f (1), g/**/(2), `h`(3), db.k(4) FROM t") == ["COUNT", "f_", "g_", "h`", "k."])
        #expect(calls("SELECT CAST(a AS DECIMAL(10,2)), CONVERT(b, CHAR(3)) FROM t WHERE c IN (1) AND EXISTS (SELECT 1)") == ["CAST", "CONVERT"])
        #expect(calls("WITH c(a) AS (SELECT 1) SELECT * FROM (SELECT 1) AS d(x), JSON_TABLE('[]', '$' COLUMNS (v VARCHAR(5) PATH '$')) j")
            == ["JSON_TABLE"])
        #expect(calls("SELECT MATCH (a) AGAINST ('x'), ROW(1, 2) = ROW(1, 2)") == ["MATCH_", "ROW", "ROW"])
        // Words skipped as syntax are reserved on every supported server, so `word(` can never be a call there.
        #expect(SQLFunctionCalls.syntax.isSubset(of: SQLKeywords.reservedEverywhere), "\(SQLFunctionCalls.syntax.subtracting(SQLKeywords.reservedEverywhere))")
    }
}
