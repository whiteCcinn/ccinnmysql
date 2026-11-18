import Foundation
import Testing
@testable import CcinnMysqlKit

/// Text of a UTF-16 range (what the editor would underline).
private func slice(_ text: String, _ range: Range<Int>?) -> String? {
    guard let range else { return nil }
    let units = Array(text.utf16)
    guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
    return String(decoding: units[range], as: UTF16.self)
}

private func utf16Offset(of needle: String, in text: String, backwards: Bool = false) -> Int {
    (text as NSString).range(of: needle, options: backwards ? .backwards : []).location
}

/// Messages recorded from MySQL 8.4.13 and MariaDB 10.11.19 (design.md has the full table).
private enum Recorded {
    static func mysql(_ snippet: String, line: Int = 1) -> String {
        "You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near '\(snippet)' at line \(line)"
    }

    static func mariadb(_ snippet: String, line: Int = 1) -> String {
        "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '\(snippet)' at line \(line)"
    }

    /// MySQL cuts the snippet at 80 bytes; a split character comes back as Latin-1 scalars (`吉` = E5 90 89).
    static let mysqlCutCJK = String(repeating: "吉", count: 26) + "\u{E5}\u{90}"
    /// MariaDB cuts at a character boundary and appends `...`.
    static let mariadbCutCJK = String(repeating: "吉", count: 25) + "..."
    static let eightyBytes = "col0 col1 col2 col3 col4 col5 col6 col7 col8 col9 col10 col11 col12 col13 col14 "
}

@Suite("Error location regressions")
struct ErrorLocatorRegressionTests {
    // The tab passed `describe(error)`, which ends with ` (error 1064)`: the old locator never matched it.
    @Test func appFormattedMessagesAreLocated() {
        let message = Recorded.mysql("shop.orders") + " (error 1064)"
        #expect(SQLErrorLocator.offset(in: "SELECT 1 FORM shop.orders", message: message) == 14)
        #expect(slice("SELECT 1 FORM shop.orders", SQLErrorLocator.range(in: "SELECT 1 FORM shop.orders", message: message)) == "shop")
    }
}

@Suite("Server error parsing")
struct ServerErrorParsingTests {
    @Test func syntaxErrorWithSnippet() {
        let error = SQLServerError.parse(Recorded.mysql("shop.orders"), code: 1064)
        #expect(error.phase == .syntax)
        #expect(error.code == 1064)
        #expect(error.syntax == SQLServerError.SyntaxPosition(snippet: "shop.orders", line: 1, isTruncated: false))
        #expect(error.summary == "Syntax error near 'shop.orders'")
        #expect(error.names.isEmpty)
    }

    @Test func appSuffixGivesTheCode() {
        let error = SQLServerError.parse(Recorded.mariadb("= 1") + " (error 1064)")
        #expect(error.code == 1064)
        #expect(error.syntax?.snippet == "= 1")
        #expect(error.detail == Recorded.mariadb("= 1"))
    }

    @Test func snippetsKeepQuotesAndLineFeeds() {
        #expect(SQLServerError.parse(Recorded.mysql("'abc FROM shop.orders")).syntax?.snippet == "'abc FROM shop.orders")
        #expect(SQLServerError.parse(Recorded.mysql("= 'x''")).syntax?.snippet == "= 'x''")
        let multi = SQLServerError.parse(Recorded.mysql("FORM orders\nWHERE x = 1", line: 2))
        #expect(multi.syntax == SQLServerError.SyntaxPosition(snippet: "FORM orders\nWHERE x = 1", line: 2, isTruncated: false))
        #expect(SQLServerError.parse(Recorded.mysql("shop.orders", line: 1501)).syntax?.line == 1501)
    }

    @Test func emptySnippetIsTheEndOfTheStatement() {
        let error = SQLServerError.parse(Recorded.mysql(""), code: 1064)
        #expect(error.syntax?.snippet == "")
        #expect(error.syntax?.isEndOfInput == true)
        #expect(error.summary == "Syntax error at the end of the statement")
    }

    @Test func truncatedSnippets() {
        let ascii = SQLServerError.parse(Recorded.mysql(Recorded.eightyBytes)).syntax
        #expect(ascii?.isTruncated == true)
        #expect(ascii?.snippet == Recorded.eightyBytes)
        // MySQL: the half character past byte 80 is dropped.
        let mysql = SQLServerError.parse(Recorded.mysql(Recorded.mysqlCutCJK)).syntax
        #expect(mysql == SQLServerError.SyntaxPosition(snippet: String(repeating: "吉", count: 26), line: 1, isTruncated: true))
        let oneByte = SQLServerError.parse(Recorded.mysql("a" + String(repeating: "吉", count: 26) + "\u{E5}")).syntax
        #expect(oneByte?.snippet == "a" + String(repeating: "吉", count: 26))
        // MariaDB: `...` is not part of the statement.
        let mariadb = SQLServerError.parse(Recorded.mariadb(Recorded.mariadbCutCJK)).syntax
        #expect(mariadb == SQLServerError.SyntaxPosition(snippet: String(repeating: "吉", count: 25), line: 1, isTruncated: true))
        #expect(SQLServerError.parse(Recorded.mariadb(Recorded.mariadbCutCJK)).summary == "Syntax error near '\(String(repeating: "吉", count: 25))…'")
        // A short snippet ending in dots is the statement's own text.
        #expect(SQLServerError.parse(Recorded.mysql("x ...")).syntax == SQLServerError.SyntaxPosition(snippet: "x ...", line: 1, isTruncated: false))
    }

    @Test func overflowingLinesAreIgnored() {
        let error = SQLServerError.parse("near 'x' at line 999999999999999999999")
        #expect(error.syntax?.snippet == "x")
        #expect(error.syntax?.line == nil)
    }

    static let nameCases: [(message: String, names: [[String]], clause: String?)] = [
        ("Unknown column 'nosuch' in 'field list'", [["nosuch"]], nil),
        ("Unknown column 'NOSUCH' in 'SELECT'", [["NOSUCH"]], nil),
        ("Unknown column 'o.nosuch' in 'where clause'", [["o", "nosuch"]], "WHERE"),
        ("Unknown column 'o.nosuch' in 'WHERE'", [["o", "nosuch"]], "WHERE"),
        ("Unknown column 'shop.orders.nosuch' in 'field list'", [["shop", "orders", "nosuch"]], nil),
        ("Unknown column 'nosuch col' in 'SELECT'", [["nosuch col"]], nil),
        ("Unknown column 'we'ird' in 'field list'", [["we'ird"]], nil),
        ("Unknown column 'a.b' in 'field list'", [["a", "b"]], nil),
        ("Unknown column 'c.nosuch' in 'on clause'", [["c", "nosuch"]], "ON"),
        ("Unknown column 'c.nosuch' in 'ON'", [["c", "nosuch"]], "ON"),
        ("Unknown column 'nosuch' in 'order clause'", [["nosuch"]], "ORDER"),
        ("Unknown column 'nosuch' in 'ORDER BY'", [["nosuch"]], "ORDER"),
        ("Unknown column 'nosuch' in 'group statement'", [["nosuch"]], "GROUP"),
        ("Unknown column 'nosuch' in 'GROUP BY'", [["nosuch"]], "GROUP"),
        ("Unknown column 'nosuch' in 'having clause'", [["nosuch"]], "HAVING"),
        ("Unknown column 'nosuch' in 'HAVING'", [["nosuch"]], "HAVING"),
        ("Unknown column 'nosuch' in 'SET'", [["nosuch"]], "SET"),
        ("Unknown column 'nosuch' in 'INSERT INTO'", [["nosuch"]], nil),
        ("Column 'id' in field list is ambiguous", [["id"]], nil),
        ("Column 'id' in where clause is ambiguous", [["id"]], "WHERE"),
        ("Column 'id' in WHERE is ambiguous", [["id"]], "WHERE"),
        ("Column 'id' in SELECT is ambiguous", [["id"]], nil),
        ("Table 'shop.nosuch_table' doesn't exist", [["shop", "nosuch_table"]], nil),
        ("Unknown database 'nosuchdb'", [["nosuchdb"]], nil),
        ("Unknown table 'shop.nosuch_table'", [["shop", "nosuch_table"]], nil),
        ("Unknown table 'x'", [["x"]], nil),
        ("FUNCTION shop.nosuch_fn does not exist", [["shop", "nosuch_fn"]], nil),
        ("PROCEDURE shop.nosuch_proc does not exist", [["shop", "nosuch_proc"]], nil),
        ("FUNCTION nosuch_fn does not exist", [["nosuch_fn"]], nil),
        ("Incorrect number of arguments for FUNCTION shop.fn_order_total; expected 1, got 0", [["shop", "fn_order_total"]], nil),
        ("Key column 'nosuch' doesn't exist in table", [["nosuch"]], nil),
    ]

    @Test(arguments: nameCases)
    func namesInMessages(message: String, names: [[String]], clause: String?) {
        for text in [message, message + " (error 1054)"] {
            let error = SQLServerError.parse(text)
            #expect(error.phase == .other)
            #expect(error.names == names, "\(text)")
            #expect(error.clause == clause, "\(text)")
        }
    }

    @Test func systemVariables() {
        let error = SQLServerError.parse("Unknown system variable 'nosuch_var'", code: 1193)
        #expect(error.variable == "nosuch_var")
        #expect(error.names.isEmpty)
    }

    @Test func otherErrorsKeepTheWholeMessage() {
        let error = SQLServerError.parse("No database selected", code: 1046)
        #expect(error.phase == .other)
        #expect(error.syntax == nil)
        #expect(error.names.isEmpty && error.variable == nil)
        #expect(error.summary == "No database selected")
    }

    // Without an editor position the title has no (statement-relative) position.
    @Test func titleUsesOnlyEditorPositions() {
        #expect(SQLServerError.parse(Recorded.mysql("x", line: 2), code: 1064).title(at: nil) == "Syntax error 1064")
        #expect(SQLServerError.parse(Recorded.mysql("x", line: 2), code: 1064).title(at: SQLTextPosition(line: 11, column: 4))
            == "Syntax error 1064 at line 11, column 4")
        #expect(SQLServerError.parse("Unknown column 'x' in 'field list'", code: 1054).title(at: SQLTextPosition(line: 1, column: 8))
            == "Error 1054 at line 1, column 8")
        #expect(SQLServerError.parse("Lost connection").title(at: nil) == "Error")
    }

    // Review: the echo includes text the app added (` LIMIT 1000`) and the rest of the statement; a marker's
    // message names only the marked text, which is the user's own.
    @Test func markerMessagesNameTheMarkedText() {
        let echo = SQLServerError.parse(Recorded.mysql("customer_id = 42\nORDER BY id DESC LIMIT 1000", line: 4), code: 1064)
        #expect(echo.markerMessage(for: "customer_id") == "Syntax error near 'customer_id'")
        #expect(SQLServerError.parse(Recorded.mysql("")).markerMessage(for: "WHERE") == "Syntax error at the end of the statement")
        let long = "'" + String(repeating: "x", count: 100) + "\nFROM t"
        #expect(echo.markerMessage(for: long) == "Syntax error near '\(String(long.replacingOccurrences(of: "\n", with: " ").prefix(SQLServerError.markerTextLimit)))…'")
        let column = SQLServerError.parse("Unknown column 'x' in 'field list'", code: 1054)
        #expect(column.markerMessage(for: "x") == "Unknown column 'x' in 'field list'")
    }

    @Test func longMessagesAreSummarised() {
        let huge = String(repeating: "x ", count: 100_000)
        let error = SQLServerError.parse(huge + " near 'x' at line 1")
        #expect(error.summary.count <= SQLServerError.summaryLimit + 1)
        #expect(error.summary.hasSuffix("…"))
        #expect(error.syntax == nil) // not a server message: never scanned
        let longSnippet = String(repeating: "y", count: 2_000)
        #expect(SQLServerError.parse(Recorded.mysql(longSnippet)).summary.count <= SQLServerError.summaryLimit + 1)
    }
}

@Suite("Server error location")
struct ServerErrorLocatorTests {
    private func locate(_ statement: String, _ message: String) -> String? {
        slice(statement, SQLErrorLocator.range(in: statement, message: message))
    }

    @Test func syntaxErrorsMarkTheFailingToken() {
        #expect(locate("SELECT 1 FORM shop.orders", Recorded.mysql("shop.orders")) == "shop")
        #expect(locate("SELECT COUNT(1 FROM shop.orders", Recorded.mysql("FROM shop.orders")) == "FROM")
        #expect(locate("SELECT * FROM shop.orders WHERE id = 1 AND status = = 'x'", Recorded.mysql("= 'x'")) == "=")
        #expect(locate("SELEC 1", Recorded.mariadb("SELEC 1")) == "SELEC")
    }

    // MySQL echoes the whole rest of the statement, so a complete snippet is its suffix: unique.
    @Test func repeatedTextResolvesToTheSuffix() {
        let sql = "SELECT 1 FROM shop.orders WHERE id = 1 1"
        let range = SQLErrorLocator.range(in: sql, message: Recorded.mysql("1"))
        #expect(range == (sql.utf16.count - 1)..<sql.utf16.count)
        let twice = "SELECT a FROM t WHERE x = = 1 AND y = = 2"
        #expect(SQLErrorLocator.range(in: twice, message: Recorded.mysql("= 1 AND y = = 2"))?.lowerBound == utf16Offset(of: "= 1 AND", in: twice))
    }

    @Test func multiLineStatements() {
        let sql = "SELECT id,\n  status\nFROM shop.orders\nWHER id = 1"
        #expect(SQLErrorLocator.range(in: sql, message: Recorded.mysql("id = 1", line: 4))?.lowerBound == utf16Offset(of: "id = 1", in: sql))
        let list = "SELECT\n  id\nFROM shop.orders\nWHERE id IN (1, 2,\n)"
        #expect(SQLErrorLocator.range(in: list, message: Recorded.mysql(")", line: 5)) == (list.utf16.count - 1)..<list.utf16.count)
        // A multi-line token: MySQL reports the line where it ends, MariaDB where it starts.
        let string = "SELECT 'a\nb' FORM t"
        #expect(locate(string, Recorded.mysql("t", line: 2)) == "t")
        #expect(locate(string, Recorded.mariadb("t", line: 1)) == "t")
        // CR LF is one line break.
        let crlf = "SELECT 1 FROM shop.orders\r\nWHER id = 1"
        #expect(SQLErrorLocator.range(in: crlf, message: Recorded.mysql("id = 1", line: 2))?.lowerBound == utf16Offset(of: "id = 1", in: crlf))
    }

    @Test func truncatedSnippetsUseTheLineHint() {
        let run = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho"
        let sql = "SELECT 1 FROM t WHERE x IN (\(run))\nUNION SELECT 1 FORM \(run)"
        let snippet = String(run.prefix(80))
        let range = SQLErrorLocator.range(in: sql, message: Recorded.mysql(snippet, line: 2))
        #expect(range?.lowerBound == utf16Offset(of: run, in: sql, backwards: true))
        #expect(slice(sql, range) == "alpha")
        // Without a usable line, the first occurrence.
        #expect(SQLErrorLocator.range(in: sql, message: "near '\(snippet)' at line 99999999999999999999")?.lowerBound == utf16Offset(of: run, in: sql))
    }

    @Test func truncatedMultibyteSnippets() {
        let identifier = String(repeating: "吉", count: 40)
        let sql = "SELECT 1 FORM " + identifier
        #expect(locate(sql, Recorded.mysql(Recorded.mysqlCutCJK)) == identifier)
        #expect(locate(sql, Recorded.mariadb(Recorded.mariadbCutCJK)) == identifier)
    }

    @Test func nonBMPCharactersComeBackAsQuestionMarks() {
        let sql = "SELECT 1 FORM ab🇲🇲🇲"
        #expect(locate(sql, Recorded.mysql("ab???")) == "ab🇲🇲🇲")
        let flag = "SELECT '🇲🇾', 1 FORM shop.orders"
        #expect(locate(flag, Recorded.mysql("shop.orders")) == "shop")
        #expect(locate("SELECT '🇲🇾' FORM t", Recorded.mysql("'??' FORM t")) == "'🇲🇾'")
    }

    @Test func endOfInputMarksTheLastToken() {
        #expect(locate("SELECT 1 FROM shop.orders WHERE", Recorded.mysql("")) == "WHERE")
        #expect(locate("SELECT 1 FROM shop.orders WHERE -- todo", Recorded.mysql("")) == "WHERE")
    }

    @Test func unterminatedCommentsAndStrings() {
        #expect(locate("SELECT 1 /* x", Recorded.mysql("/* x")) == "/*")
        #expect(locate("SELECT * FROM shop.orders /* note", Recorded.mariadb("/* note")) == "/*")
        #expect(locate("SELECT 1 /*! x", Recorded.mysql("/*! x")) == "/*")
        #expect(locate("SELECT 'abc FROM shop.orders", Recorded.mysql("'abc FROM shop.orders")) == "'abc FROM shop.orders")
        #expect(locate("SELECT * FROM shop.orders WHERE status = 'paid", Recorded.mysql("'paid")) == "'paid")
    }

    // Review: MySQL echoes the whole rest of the statement, so a complete echo that is not this statement's
    // rest comes from another statement (e.g. one a procedure prepared): no guess.
    @Test func completeEchoesMustBeTheRestOfTheStatement() {
        #expect(SQLErrorLocator.range(in: "SELECT a FROM t WHERE b = 1 AND c = 2", message: Recorded.mysql("b = 1")) == nil)
        #expect(SQLErrorLocator.range(in: "CALL shop.p(1)", message: Recorded.mysql("FORM t")) == nil)
        #expect(SQLErrorLocator.offset(in: "SELECT a FROM t WHERE b = 1 AND c = 2", message: Recorded.mysql("b = 1", line: 1)) == nil)
    }

    @Test func unmatchedSnippetsGiveNoMarker() {
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: Recorded.mysql("x")) == nil)
        #expect(SQLErrorLocator.range(in: "", message: Recorded.mysql("")) == nil)
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: "No database selected") == nil)
    }

    @Test func explainPrefixesMapBack() {
        let source = "SELECT 1 FORM shop.orders"
        for prefix in ["EXPLAIN FORMAT=JSON ", "EXPLAIN ANALYZE ", "ANALYZE FORMAT=JSON ", "EXPLAIN "] {
            let mapping = SQLExecutedTextMapping(prefixLength: prefix.utf16.count)
            let error = SQLServerError.parse(Recorded.mysql("shop.orders"))
            #expect(slice(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: mapping, error: error)) == "shop")
        }
        // A failure inside the prefix itself maps to the start.
        let mapping = SQLExecutedTextMapping(prefixLength: "EXPLAIN ".utf16.count)
        let error = SQLServerError.parse(Recorded.mysql("EXPLAIN SELEC 1"))
        #expect(slice("SELEC 1", SQLErrorLocator.range(in: "SELEC 1", executed: "EXPLAIN SELEC 1", mapping: mapping, error: error)) == "SELEC")
    }

    @Test func autoLimitInsertionMapsBack() {
        let source = "SELECT * FROM shop.orders WHERE -- todo"
        let outcome = AutoLimit.apply(to: source, limit: 1000)
        #expect(outcome.applied)
        #expect(outcome.sql == "SELECT * FROM shop.orders WHERE LIMIT 1000 -- todo")
        #expect(outcome.insertion == 31..<42)
        let mapping = SQLExecutedTextMapping(insertion: outcome.insertion)
        let error = SQLServerError.parse(Recorded.mysql("LIMIT 1000 -- todo"))
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: outcome.sql, mapping: mapping, error: error)) == "WHERE")
        #expect(mapping.sourceOffset(forExecuted: (outcome.sql as NSString).length) == (source as NSString).length)
        #expect(AutoLimit.apply(to: "SELECT 1 LIMIT 3", limit: 10).insertion == nil)
    }

    @Test(arguments: [
        ("SELECT nosuch FROM shop.orders", "Unknown column 'nosuch' in 'field list'", "nosuch"),
        ("SELECT NOSUCH FROM shop.orders", "Unknown column 'NOSUCH' in 'SELECT'", "NOSUCH"),
        ("select Nosuch from shop.orders", "Unknown column 'NOSUCH' in 'field list'", "Nosuch"),
        ("SELECT * FROM shop.orders o WHERE o.nosuch = 1", "Unknown column 'o.nosuch' in 'where clause'", "o.nosuch"),
        ("SELECT shop.orders.nosuch FROM shop.orders", "Unknown column 'shop.orders.nosuch' in 'field list'", "shop.orders.nosuch"),
        ("SELECT `o` . `nosuch` FROM shop.orders o", "Unknown column 'o.nosuch' in 'field list'", "`o` . `nosuch`"),
        ("SELECT `nosuch col` FROM shop.orders", "Unknown column 'nosuch col' in 'field list'", "`nosuch col`"),
        ("SELECT `we'ird` FROM shop.orders", "Unknown column 'we'ird' in 'field list'", "`we'ird`"),
        ("SELECT `a.b` FROM shop.orders", "Unknown column 'a.b' in 'field list'", "`a.b`"),
        ("SELECT 吉 FROM shop.orders", "Unknown column '吉' in 'field list'", "吉"),
        ("SELECT * FROM shop.nosuch_table", "Table 'shop.nosuch_table' doesn't exist", "shop.nosuch_table"),
        ("SELECT * FROM `shop`.`nosuch_table`", "Table 'shop.nosuch_table' doesn't exist", "`shop`.`nosuch_table`"),
        ("SELECT * FROM nosuch_table", "Table 'shop.nosuch_table' doesn't exist", "nosuch_table"),
        ("SELECT * FROM nosuchdb.t", "Unknown database 'nosuchdb'", "nosuchdb"),
        ("SELECT * FROM nosuchdb.t", "Table 'nosuchdb.t' doesn't exist", "nosuchdb.t"),
        ("SELECT nosuch_fn(1)", "FUNCTION shop.nosuch_fn does not exist", "nosuch_fn"),
        ("CALL shop.nosuch_proc()", "PROCEDURE shop.nosuch_proc does not exist", "shop.nosuch_proc"),
        ("SELECT shop.fn_order_total()", "Incorrect number of arguments for FUNCTION shop.fn_order_total; expected 1, got 0", "shop.fn_order_total"),
        ("DROP TABLE shop.nosuch_table", "Unknown table 'shop.nosuch_table'", "shop.nosuch_table"),
        ("SELECT x.* FROM shop.orders", "Unknown table 'x'", "x"),
        ("SELECT x.* FROM shop.orders", "Unknown table 'shop.x'", "x"),
        ("ALTER TABLE shop.orders ADD INDEX (nosuch)", "Key column 'nosuch' doesn't exist in table", "nosuch"),
        ("SELECT @@nosuch_var", "Unknown system variable 'nosuch_var'", "@@nosuch_var"),
        ("SET @@session.nosuch_var = 1", "Unknown system variable 'nosuch_var'", "@@session.nosuch_var"),
        ("SET SESSION nosuch_var = 1", "Unknown system variable 'nosuch_var'", "nosuch_var"),
        ("SELECT status FROM shop.orders GROUP BY nosuch", "Unknown column 'nosuch' in 'group statement'", "nosuch"),
    ])
    func namedObjects(statement: String, message: String, expected: String) {
        #expect(locate(statement, message) == expected)
    }

    @Test func clausesPickTheRightOccurrence() {
        let ambiguous = "SELECT o.id FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id WHERE id = 1"
        for message in ["Column 'id' in where clause is ambiguous", "Column 'id' in WHERE is ambiguous"] {
            #expect(SQLErrorLocator.range(in: ambiguous, message: message)?.lowerBound == utf16Offset(of: "id = 1", in: ambiguous))
        }
        let field = "SELECT id FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id"
        #expect(SQLErrorLocator.range(in: field, message: "Column 'id' in field list is ambiguous") == 7..<9)
        let twice = "SELECT nosuch FROM shop.orders WHERE nosuch = 1"
        #expect(SQLErrorLocator.range(in: twice, message: "Unknown column 'nosuch' in 'where clause'")?.lowerBound == utf16Offset(of: "nosuch = 1", in: twice))
        let on = "SELECT c.nosuch FROM shop.orders o JOIN shop.customers c ON c.nosuch = o.id"
        #expect(SQLErrorLocator.range(in: on, message: "Unknown column 'c.nosuch' in 'on clause'")?.lowerBound == utf16Offset(of: "c.nosuch = o.id", in: on))
        // The clause is a preference: a name elsewhere is still found.
        #expect(locate("SELECT nosuch FROM t", "Unknown column 'nosuch' in 'where clause'") == "nosuch")
    }

    // An unqualified message is about an unqualified reference.
    @Test func unqualifiedNamesArePreferred() {
        let sql = "SELECT o.status, status FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id"
        #expect(SQLErrorLocator.range(in: sql, message: "Column 'status' in field list is ambiguous")?.lowerBound == utf16Offset(of: " status FROM", in: sql) + 1)
        // When every occurrence is qualified, the first one.
        #expect(locate("SELECT o.status FROM shop.orders o", "Column 'status' in field list is ambiguous") == "status")
    }

    @Test func namesInsideStringsAndCommentsAreSkipped() {
        let sql = "SELECT 'nosuch', /* nosuch */ -- nosuch\n nosuch FROM t"
        let range = SQLErrorLocator.range(in: sql, message: "Unknown column 'nosuch' in 'field list'")
        #expect(range?.lowerBound == utf16Offset(of: " nosuch FROM", in: sql) + 1)
    }

    @Test func unknownNamesGiveNoMarker() {
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: "Unknown column 'zzz' in 'field list'") == nil)
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: "Unknown system variable 'zzz'") == nil)
        #expect(SQLErrorLocator.range(in: "", message: "Unknown column 'zzz' in 'field list'") == nil)
    }
}

@Suite("Error location bounds")
struct ErrorLocatorBoundsTests {
    @Test func mappingNeverGoesNegative() {
        let mapping = SQLExecutedTextMapping(prefixLength: 8, insertion: 20..<29)
        #expect(mapping.sourceOffset(forExecuted: 0) == 0)
        #expect(mapping.sourceOffset(forExecuted: Int.max) == Int.max - 9 - 8)
        #expect(mapping.sourceOffset(forExecuted: 25) == 12)
    }

    @Test func hugeStatementsStayLinear() async {
        // Many partial matches of a truncated snippet must not make the search quadratic. Quadratic work takes minutes; the
        // bound leaves room for a busy CI runner.
        let sql = "SELECT " + String(repeating: "a, ", count: 50_000) + "b FORM t"
        let snippet = String(repeating: "a, ", count: 26) + "a,"
        let (first, second, elapsed) = await onDedicatedThread { () -> (Range<Int>?, Range<Int>?, Duration) in
            let started = ContinuousClock.now
            let first = SQLErrorLocator.range(in: sql, message: Recorded.mysql("t"))
            let second = SQLErrorLocator.range(in: sql, message: Recorded.mysql(snippet, line: 1))
            return (first, second, ContinuousClock.now - started)
        }
        #expect(slice(sql, first) == "t")
        #expect(second == 7..<8)
        #expect(elapsed < .seconds(15))
    }
}

@Suite("Local checks")
struct LinterTests {
    private func lint(_ text: String, backslashEscapes: Bool = true) -> [(SQLDiagnostic.Severity, String, String)] {
        SQLLinter.diagnose(text, backslashEscapes: backslashEscapes).map { ($0.severity, slice(text, $0.range) ?? "?", $0.message) }
    }

    @Test func unclosedParenthesis() {
        let found = lint("SELECT count(1 FROM t")
        #expect(found.count == 1)
        #expect(found.first?.0 == .error)
        #expect(found.first?.1 == "(")
        #expect(found.first?.2.contains("not closed") == true)
    }

    @Test func unmatchedClosingParenthesis() {
        let found = lint("SELECT 1)")
        #expect(found.map(\.1) == [")"])
        #expect(found.first?.2.contains("no matching") == true)
    }

    @Test func parenthesesArePerStatement() {
        let text = "SELECT (1; SELECT 2)"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map { slice(text, $0.range) } == ["(", ")"])
        #expect(diagnostics.first?.scope == 7..<9)
    }

    @Test func unterminatedQuotes() {
        #expect(lint("SELECT 'abc").map { [$0.1, $0.2] } == [["'", "Unterminated string: add the closing '"]])
        #expect(lint("SELECT \"abc").map(\.1) == ["\""])
        #expect(lint("SELECT `abc").map(\.2) == ["Unterminated quoted identifier: add the closing `"])
        #expect(lint("SELECT 'a\\'").map(\.1) == ["'"])
    }

    // NO_BACKSLASH_ESCAPES: a backslash is an ordinary character, as the server lexes it.
    @Test func backslashEscapesFollowTheSession() {
        #expect(lint("SELECT 'C:\\'", backslashEscapes: false).isEmpty)
        #expect(lint("SELECT 'C:\\'").map(\.1) == ["'"])
        #expect(lint("SELECT 'it\\'s'", backslashEscapes: true).isEmpty)
        #expect(lint("SELECT `a\\` FROM t", backslashEscapes: true).isEmpty) // never an escape in identifiers
    }

    @Test func unterminatedQuoteSuppressesParenthesisNoise() {
        #expect(lint("SELECT count('abc)").map(\.1) == ["'"])
    }

    // MySQL rejects an unterminated comment (`near '/* x'`), executable or not.
    @Test func unterminatedBlockCommentsAreErrors() {
        let found = lint("SELECT 1 /* note")
        #expect(found.map(\.0) == [.error])
        #expect(found.map(\.1) == ["/*"])
        #expect(found.map(\.2) == ["Unterminated comment: add the closing */"])
        #expect(lint("SELECT 1 /*/").map(\.1) == ["/*"])
        #expect(lint("SELECT 1 /*! STRAIGHT_JOIN").map(\.1) == ["/*"])
    }

    @Test(arguments: ["SELECT 'it''s', \"a\\\"b\", (1), `x``y` FROM t", "SELECT 1 -- (", "/**/ SELECT (1)", "SELECT ')' FROM t", "",
                      "SELECT 1 # )", "SELECT /*! (1) */ 2", "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT (1); END$$\nDELIMITER ;"])
    func cleanTextHasNoDiagnostics(text: String) {
        #expect(SQLLinter.diagnose(text).isEmpty)
    }

    @Test func dashDashNeedsASpace() {
        // `--(` is arithmetic in MySQL, so the parenthesis is open.
        #expect(lint("SELECT 1 --(").map(\.1) == ["("])
    }

    @Test func diagnosticsAreCapped() {
        let text = String(repeating: ")", count: 500)
        #expect(SQLLinter.diagnose(text).count == SQLLinter.maximumDiagnostics)
    }

    @Test func localDiagnosticsAreMarkedAsLocal() {
        #expect(SQLLinter.diagnose("SELECT (").allSatisfy { $0.source == .local })
    }
}

@Suite("Diagnostic edit tracking")
struct DiagnosticTrackingTests {
    private let diagnostic = SQLDiagnostic(range: 10..<14, scope: 5..<20, severity: .error, source: .server, message: "m")

    private func apply(_ edits: SQLTextEdit...) -> SQLDiagnostic? {
        SQLDiagnosticTracker.apply(edits, to: [diagnostic]).first
    }

    @Test func editBeforeShifts() {
        let moved = apply(SQLTextEdit(range: 0..<0, replacementLength: 3))
        #expect(moved?.range == 13..<17)
        #expect(moved?.scope == 8..<23)
    }

    @Test func separatedInsertionAtScopeStartShifts() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 2, separatorBeforeEnd: true))?.range == 12..<16)
    }

    @Test func gluedInsertionAtScopeStartDrops() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 1, separatorBeforeEnd: false)) == nil)
    }

    @Test func deletionEndingAtScopeStart() {
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: true))?.scope == 2..<17)
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: false)) == nil)
    }

    @Test func separatedInsertionAtScopeEndKeeps() {
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: true)) == diagnostic)
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: false)) == nil)
    }

    @Test func editAfterKeeps() {
        #expect(apply(SQLTextEdit(range: 21..<21, replacementLength: 1)) == diagnostic)
    }

    @Test(arguments: [SQLTextEdit(range: 12..<12, replacementLength: 1), SQLTextEdit(range: 20..<20, replacementLength: 1),
                      SQLTextEdit(range: 3..<6, replacementLength: 1), SQLTextEdit(range: 19..<25, replacementLength: 0),
                      SQLTextEdit(range: 0..<100, replacementLength: 0), SQLTextEdit(range: 6..<6, replacementLength: 1, separatorBeforeEnd: true)])
    func editTouchingTheScopeDrops(edit: SQLTextEdit) {
        #expect(SQLDiagnosticTracker.apply([edit], to: [diagnostic]).isEmpty)
    }

    @Test func sequencesApplyInOrder() {
        let roundTrip = apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 0..<3, replacementLength: 0))
        #expect(roundTrip == diagnostic)
        #expect(apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 14..<14, replacementLength: 1)) == nil)
    }

    @Test func rangeEditTracksASingleRange() {
        #expect(SQLTextEdit(range: 0..<0, replacementLength: 4).adjust(6..<9) == 10..<13)
        #expect(SQLTextEdit(range: 7..<7, replacementLength: 4).adjust(6..<9) == nil)
    }

    @Test func malformedEditsDrop() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<0, replacementLength: -5)], to: [diagnostic]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [diagnostic]).isEmpty)
    }

    @Test func editsDescribedFromTheEditedText() throws {
        // `SELECT 1;SELECT x FORM t`, type `x` at 9 → `xSELECT`: glued onto the statement.
        let glued = try #require(SQLTextEdit.made(in: "SELECT 1;xSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(!glued.separatorBeforeEnd)
        #expect(glued.adjust(9..<24) == nil)
        // Return at the start of the statement: it moves down.
        let newline = try #require(SQLTextEdit.made(in: "SELECT 1;\nSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(newline.adjust(9..<24) == 10..<25)
        // Return right after the last token (no `;`): the statement keeps its marker.
        let after = try #require(SQLTextEdit.made(in: "SELECT x FORM t\n", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(after.separatorAtStart)
        #expect(after.adjust(0..<15) == 0..<15)
        #expect(after.insertedLineBreaks == [0])
        // Typing right after the last token extends it.
        let typed = try #require(SQLTextEdit.made(in: "SELECT x FORM tx", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(typed.adjust(0..<15) == nil)
        // Deleting the `;` between two statements glues them.
        let merged = try #require(SQLTextEdit.made(in: "SELECT 1SELECT x", editedRange: NSRange(location: 8, length: 0), changeInLength: -1))
        #expect(merged.range == 8..<9)
        #expect(merged.adjust(9..<16) == nil)
        // Inconsistent reports are refused.
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 2, length: 5), changeInLength: 0) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 1, length: 1), changeInLength: 3) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: NSNotFound, length: 0), changeInLength: 0) == nil)
    }
}

@Suite("Local diagnostic tracking")
struct LocalTrackingTests {
    private let local = SQLDiagnostic(range: 12..<13, scope: 12..<20, severity: .error, source: .local, message: "'(' is not closed")

    @Test func typingInsideTheScopeKeepsTheMarker() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 15..<15, replacementLength: 1)], to: [local]).first
        #expect(moved?.range == 12..<13)
        #expect(moved?.scope == 12..<21)
    }

    @Test func typingRightAfterTheMarkKeepsIt() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 13..<13, replacementLength: 2)], to: [local]).first?.range == 12..<13)
    }

    @Test func insertionBeforeTheMarkShiftsIt() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 12..<12, replacementLength: 2)], to: [local]).first
        #expect(moved?.range == 14..<15)
        #expect(moved?.scope == 14..<22)
    }

    @Test func editingTheMarkedTextDrops() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 11..<13, replacementLength: 0)], to: [local]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [local]).isEmpty)
    }
}

@Suite("Diagnostic navigation")
struct NavigationTests {
    @Test func adjacentDiagnosticsAreReachable() {
        let text = "SELECT count((a FROM t"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map(\.range) == [12..<13, 13..<14])
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 12) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 13) == 1)
    }

    @Test func preferenceResolvesTies() {
        let a = SQLDiagnostic(range: 5..<9, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 5..<6, scope: 5..<20, severity: .error, source: .local, message: "b")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5, preferred: b) == 1)
    }

    @Test func cursorPositions() {
        let a = SQLDiagnostic(range: 2..<10, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 4..<5, scope: 4..<20, severity: .error, source: .local, message: "b")
        let c = SQLDiagnostic(range: 14..<15, scope: 14..<20, severity: .error, source: .local, message: "c")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 4) == 1)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 7) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 15) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 12) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 0) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 99) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [], cursor: 0) == nil)
    }
}

@Suite("Line index")
struct LineIndexTests {
    @Test func positionsAreOneBasedCodePoints() {
        let text = "SELECT\n  '🇲🇾' x"
        let index = SQLLineIndex(text)
        #expect(index.lineStarts == [0, 7])
        #expect(index.position(of: utf16Offset(of: "x", in: text), in: text as NSString) == SQLTextPosition(line: 2, column: 8))
        #expect(index.position(of: 999, in: text as NSString) == SQLTextPosition(line: 2, column: 9))
        #expect(index.position(of: -1, in: text as NSString) == SQLTextPosition(line: 1, column: 1))
    }

    @Test func editsKeepTheIndexEqualToARebuild() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab\n;吉🇲🇾 \r")
        var text = "SELECT 1;\nSELECT 2\n"
        var index = SQLLineIndex(text)
        for _ in 0..<1_500 {
            let units = Array(text.utf16)
            let start = Int.random(in: 0...units.count, using: &generator)
            let end = Int.random(in: start...min(units.count, start + 6), using: &generator)
            let inserted = String((0..<Int.random(in: 0...4, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? "a" })
            let updated = String(decoding: units[..<start], as: UTF16.self) + inserted + String(decoding: units[end...], as: UTF16.self)
            // Composed characters can split differently; describe the edit from what actually changed.
            let insertedLength = updated.utf16.count - (units.count - (end - start))
            let edit = try #require(SQLTextEdit.made(in: updated as NSString, editedRange: NSRange(location: start, length: insertedLength),
                                                     changeInLength: insertedLength - (end - start)))
            let applied = index.apply(edit)
            #expect(applied)
            text = updated
            #expect(index == SQLLineIndex(text))
        }
    }

    @Test func invalidEditsAreRefused() {
        var index = SQLLineIndex("ab\ncd")
        let beyondEnd = index.apply(SQLTextEdit(range: 3..<9, replacementLength: 0))
        let negative = index.apply(SQLTextEdit(range: 0..<0, replacementLength: -1))
        #expect(!beyondEnd)
        #expect(!negative)
        #expect(index == SQLLineIndex("ab\ncd"))
    }
}

@Suite("Text positions")
struct TextPositionTests {
    @Test func lineAndColumnAreOneBasedCodePoints() {
        let text = "SELECT\n  o.x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "o.x", in: text), in: text) == SQLTextPosition(line: 2, column: 3))
        let emoji = "'🇲🇾' x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "x", in: emoji), in: emoji) == SQLTextPosition(line: 1, column: 6))
        #expect(SQLTextPosition.lineAndColumn(of: 999, in: "ab\nc") == SQLTextPosition(line: 2, column: 2))
        #expect(SQLTextPosition.lineAndColumn(of: -3, in: "ab") == SQLTextPosition(line: 1, column: 1))
    }
}

@Suite("Diagnostics robustness")
struct DiagnosticsFuzzTests {
    @Test func randomInputNeverCrashes() {
        let alphabet = Array("select from 'x' \"y\" `z` -- # /* */ /*! ; . , ( ) @@ 0x1F 1e9 吉 🇲🇾 \\ ? \n\r")
        let messages = [Recorded.mysql("x", line: 1), Recorded.mysql("", line: 2), Recorded.mariadb("from 'x", line: 3), Recorded.mysql("??", line: 1),
                        Recorded.mysql(Recorded.mysqlCutCJK), Recorded.mariadb(Recorded.mariadbCutCJK), "Unknown column 'a.b' in 'where clause'",
                        "Column 'z' in field list is ambiguous", "Table 'x.y' doesn't exist", "Unknown system variable 'x'",
                        "FUNCTION select does not exist", "near 'x' at line 99999999999999999999"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = String((0..<Int.random(in: 0...80, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? " " })
            let length = text.utf16.count
            let diagnostics = SQLLinter.diagnose(text, backslashEscapes: Bool.random(using: &generator))
            for diagnostic in diagnostics {
                #expect(diagnostic.range.lowerBound >= 0 && diagnostic.range.upperBound <= length)
                #expect(diagnostic.scope.lowerBound <= diagnostic.range.lowerBound && diagnostic.range.upperBound <= diagnostic.scope.upperBound)
            }
            for message in messages {
                if let range = SQLErrorLocator.range(in: text, message: message) {
                    #expect(range.lowerBound >= 0 && range.upperBound <= length && !range.isEmpty)
                }
                if let offset = SQLErrorLocator.offset(in: text, message: message) {
                    #expect(offset >= 0 && offset <= length)
                }
            }
            let prefix = Int.random(in: 0...3, using: &generator)
            let executed = String(repeating: "X ", count: prefix) + text
            if let range = SQLErrorLocator.range(in: text, executed: executed, mapping: SQLExecutedTextMapping(prefixLength: prefix * 2),
                                                 error: SQLServerError.parse(Recorded.mysql(String(text.suffix(3))))) {
                #expect(range.lowerBound >= 0 && range.upperBound <= length)
            }
            let start = Int.random(in: 0...length, using: &generator)
            let end = Int.random(in: start...length, using: &generator)
            let edit = SQLTextEdit(range: start..<end, replacementLength: Int.random(in: 0...5, using: &generator),
                                   separatorBeforeEnd: Bool.random(using: &generator), separatorAtStart: Bool.random(using: &generator))
            for diagnostic in SQLDiagnosticTracker.apply([edit], to: diagnostics) {
                #expect(diagnostic.range.lowerBound >= 0)
            }
            _ = SQLTextPosition.lineAndColumn(of: Int.random(in: -2...(length + 2), using: &generator), in: text)
        }
    }
}
