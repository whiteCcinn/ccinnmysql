import Foundation
import Testing
import MySQLWire
@testable import CcinnMysqlKit
import MySQLKit

@Suite("SQL lexer")
struct SQLLexerTests {
    private func kinds(_ sql: String) -> [SQLToken.Kind] { SQLLexer.tokenize(sql).map(\.kind) }

    @Test func classifiesTokens() {
        let lexer = SQLLexer("SELECT `my col`, @x, @@session.sql_mode FROM t WHERE a >= 1.5e3")
        let tokens = lexer.tokens()
        #expect(tokens.map(\.kind) == [.keyword, .quotedIdentifier, .punctuation, .variable, .punctuation, .variable, .keyword, .identifier,
                                        .keyword, .identifier, .operator, .number])
        #expect(lexer.identifierValue(of: tokens[1]) == "my col")
    }

    @Test func mysqlCommentRules() {
        #expect(kinds("SELECT 1 -- comment") == [.keyword, .number, .comment])
        #expect(kinds("SELECT 1--1") == [.keyword, .number, .operator, .operator, .number], "-- needs a following space in MySQL")
        #expect(kinds("SELECT 1 # hash comment") == [.keyword, .number, .comment])
        #expect(kinds("SELECT /*+ MAX_EXECUTION_TIME(1000) */ 1") == [.keyword, .comment, .number])
        #expect(kinds("/*!40101 SET NAMES utf8 */") == [.executableComment])
        #expect(kinds("/*M!100100 SET x=1 */") == [.executableComment])
    }

    @Test func handlesStringsAndUnicode() {
        let tokens = SQLLexer.tokenize("SELECT 'it''s', \"a\\\"b\", '雪', _utf8mb4'x', X'4D'")
        #expect(tokens.filter { $0.kind == .string }.count == 4)
        #expect(tokens.last?.kind == .number, "X'4D' is one hexadecimal literal")
    }

    @Test func unterminatedConstructsExtendToEnd() {
        #expect(kinds("SELECT 'abc") == [.keyword, .string])
        #expect(kinds("SELECT /* abc") == [.keyword, .comment])
        #expect(kinds("SELECT `abc") == [.keyword, .quotedIdentifier])
    }

    // The server reads `0x1g` and `0x1and` as identifiers (a hex literal must not run into name characters), like `1abc`.
    @Test func numbersRunningIntoNameCharactersAreOneToken() {
        for text in ["0x1and", "0xZZ", "0x", "1abc", "0b12x"] {
            #expect(SQLLexer.tokenize(text).map(\.range) == [0..<text.utf16.count], "\(text)")
        }
        #expect(kinds("0x1F+1") == [.number, .operator, .number])
    }

    /// Kind and text of each token.
    private func lexed(_ text: String) -> [String] {
        let lexer = SQLLexer(text)
        return lexer.tokens().map { "\($0.kind) \(lexer.text(of: $0))" }
    }

    // Review: numbers end exactly where MySQL and MariaDB end them (sql_lex.cc; every case below was run on MySQL 8.4 and
    // MariaDB 10.11, and the integration tests re-check them). A word glued to a number is an alias (`1.5x`), a keyword
    // (`1e2end` ends a CASE) or part of a name (`1abc`); the formatter re-lexes its output with this lexer, so a
    // disagreement here could never be caught there.
    @Test func numbersEndWhereTheServerEndsThem() {
        let expected: [String: [String]] = [
            // A number, then a separate word.
            "1.5x": ["number 1.5", "identifier x"], "1e2x": ["number 1e2", "identifier x"], "1e2e3": ["number 1e2", "identifier e3"],
            "1.a": ["number 1.", "identifier a"], ".5x": ["number .5", "identifier x"], "1.5e+3x": ["number 1.5e+3", "identifier x"],
            "1e+3x": ["number 1e+3", "identifier x"], "1.$": ["number 1.", "identifier $"], "1.5é": ["number 1.5", "identifier é"],
            "1e2end": ["number 1e2", "keyword end"], "1.5and": ["number 1.5", "keyword and"], "1.5into": ["number 1.5", "keyword into"],
            "x'41'z": ["number x'41'", "identifier z"], "X'41'end": ["number X'41'", "keyword end"], "b'1'z": ["number b'1'", "identifier z"],
            "x'41''42'": ["number x'41'", "string '42'"], "x''": ["number x''"], "B''": ["number B''"],
            "0x41.5": ["number 0x41", "number .5"], "1e2.5": ["number 1e2", "number .5"], "1.5.5": ["number 1.5", "number .5"],
            "0b1": ["number 0b1"], "0x4F": ["number 0x4F"], "1.e5": ["number 1.e5"], "1.": ["number 1."],
            // Names: digits followed by name characters, unless they make a number.
            "1abc": ["identifier 1abc"], "0b12": ["identifier 0b12"], "0X41": ["identifier 0X41"], "0B1": ["identifier 0B1"],
            "0x1g": ["identifier 0x1g"], "0x": ["identifier 0x"], "0b": ["identifier 0b"], "1e": ["identifier 1e"], "1ex": ["identifier 1ex"],
            "1$": ["identifier 1$"], "1é": ["identifier 1é"], "0xé": ["identifier 0xé"], "1eé": ["identifier 1eé"], "1__": ["identifier 1__"],
            "1e+x": ["identifier 1e", "operator +", "identifier x"], "1e+": ["identifier 1e", "operator +"],
            "1e+é": ["identifier 1e", "operator +", "identifier é"],
            // After `name.` the server reads a name, whatever it starts with; after a back-quoted name `.5` is a number.
            "t.5e+2": ["identifier t", "punctuation .", "identifier 5e", "operator +", "number 2"],
            "t.1e2": ["identifier t", "punctuation .", "identifier 1e2"],
            "t.1.5x": ["identifier t", "punctuation .", "identifier 1", "punctuation .", "identifier 5x"],
            "date.5": ["keyword date", "punctuation .", "identifier 5"], "1abc.5": ["identifier 1abc", "punctuation .", "identifier 5"],
            "`t`.5": ["quotedIdentifier `t`", "number .5"], "t .5": ["identifier t", "number .5"],
            "t. 5": ["identifier t", "punctuation .", "number 5"], "t.x'41'": ["identifier t", "punctuation .", "identifier x", "string '41'"],
        ]
        for (text, tokens) in expected {
            #expect(lexed(text) == tokens, "\(text)")
        }
    }

    // Review: the server rejects these while lexing (1064): an exponent without digits after a decimal, a hexadecimal
    // literal with an odd number of digits or a non-digit, a bit literal with another digit. They are kept whole (an END
    // inside `1.end` is never a keyword) and flagged, so the formatter refuses rather than guess.
    @Test func malformedLiteralsAreFlagged() {
        for text in ["1.e", "1.end", ".5e", "1.5ex", "1.5e", "1.5e+", "1.5e+x", "1.eé", "1.5Ex", "1.5e-"] {
            let lexer = SQLLexer(text)
            let tokens = lexer.tokens()
            #expect(tokens.map(\.range) == [0..<text.utf16.count], "\(text)")
            #expect(lexer.containsMalformedLiteral(tokens), "\(text)")
        }
        for text in ["x'4'", "x'4g'", "b'12'", "X'41", "b'1"] {
            let lexer = SQLLexer(text)
            #expect(lexer.containsMalformedLiteral(lexer.tokens()), "\(text)")
        }
        for text in ["1.5x", "1e2end", "x'41'z", "1e+x", "1abc", "N'a'", "_utf8mb4'a'", "x 'a'", "t.x'41'", "select 'x'", "ax'41'"] {
            let lexer = SQLLexer(text)
            #expect(!lexer.containsMalformedLiteral(lexer.tokens()), "\(text)")
        }
    }

    // Security review: MariaDB (and MySQL 5.x) read `\\N` as NULL and end it after the N, so `\\Nlock` is NULL LOCK; MySQL 8
    // rejects any `\\` outside strings. The lexer ends `\\N` where MariaDB does, and flags every backslash outside strings,
    // back-quoted names and comments: the read-only guard and the formatter refuse such text.
    @Test func backslashNEndsAfterTheN() {
        #expect(lexed("SELECT \\Nlock") == ["keyword SELECT", "keyword \\N", "keyword lock"])
        #expect(lexed("\\Nx") == ["keyword \\N", "identifier x"])
        #expect(lexed("\\Ninto @v") == ["keyword \\N", "keyword into", "variable @v"])
        #expect(lexed("\\nx") == ["operator \\", "identifier nx"], "only a capital N")
        for text in ["SELECT \\N", "SELECT \\x", "a \\ b", "SELECT 1 IS NOT \\Nlock in share mode", "@`a`\\N"] {
            let lexer = SQLLexer(text)
            #expect(lexer.containsBareBackslash(lexer.tokens()), "\(text)")
        }
        for text in ["SELECT 'a\\b'", "SELECT `a\\b`", "SELECT 1 -- \\N", "SELECT 1 /* \\N */", "SELECT @`a\\b`", "SELECT \"a\\\"b\""] {
            let lexer = SQLLexer(text)
            #expect(!lexer.containsBareBackslash(lexer.tokens()), "\(text)")
        }
    }

    // Review: only ASCII words are keywords, as for the server. Unicode case mapping would make the ligature `ﬁrst` FIRST,
    // the long s in `ſelect` SELECT and the dotless i in `lımıt` LIMIT, all names on the server.
    @Test func onlyASCIIWordsAreKeywords() {
        #expect(kinds("ﬁrst ſelect lımıt ＳＥＬＥＣＴ") == [.identifier, .identifier, .identifier, .identifier])
        #expect(kinds("first Select LIMIT") == [.keyword, .keyword, .keyword])
    }

    @Test func rangesAreUTF16() {
        let tokens = SQLLexer.tokenize("SELECT '😀', x")
        #expect(tokens[1].range == 7..<11)
        #expect(tokens[3].range == 13..<14)
    }

    @Test func randomInputNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("SELECT'\"`#-/*!;$@.0123456789eE abc\n\\()=<>DELIMITER")
        for _ in 0..<3_000 {
            let text = String((0..<Int.random(in: 0..<80, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? " " })
            _ = SQLLexer.tokenize(text)
            _ = SQLStatementSplitter.split(text)
            _ = SQLStatementKind.of(text)
            _ = AutoLimit.apply(to: text, limit: 10)
            _ = ReadOnlySQLGuard.check(text)
            _ = SQLRedactor.redact(text)
            _ = SQLErrorLocator.offset(in: text, message: "near '\(text.prefix(5))' at line 1")
        }
    }
}

@Suite("Statements")
struct StatementTests {
    @Test func splitsOutsideStringsCommentsAndQuotedIdentifiers() {
        let statements = SQLStatementSplitter.split("SELECT ';' ; -- ; comment\nSELECT `a;b` FROM t; /* ; */ SELECT \"x;\";")
        #expect(statements.map(\.text) == ["SELECT ';'", "SELECT `a;b` FROM t", "SELECT \"x;\""])
    }

    @Test func honoursDelimiterCommands() {
        let script = """
        DROP PROCEDURE IF EXISTS p;
        DELIMITER $$
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
          SELECT 2;
        END$$
        DELIMITER ;
        CALL p();
        """
        let statements = SQLStatementSplitter.split(script)
        #expect(statements.count == 3)
        #expect(statements[0].text == "DROP PROCEDURE IF EXISTS p")
        #expect(statements[1].text.hasPrefix("CREATE PROCEDURE p()"))
        #expect(statements[1].text.hasSuffix("END"))
        #expect(statements[1].text.contains("SELECT 1;\n  SELECT 2;"))
        #expect(statements[2].text == "CALL p()")
    }

    @Test func delimiterInsideStatementTextIsNotACommand() {
        let statements = SQLStatementSplitter.split("SELECT 'DELIMITER //';\nSELECT 2")
        #expect(statements.map(\.text) == ["SELECT 'DELIMITER //'", "SELECT 2"])
    }

    @Test func executableCommentsAreStatementText() {
        let statements = SQLStatementSplitter.split("/*!40101 SET NAMES utf8mb4 */;\nSELECT 1")
        #expect(statements.map(\.text) == ["/*!40101 SET NAMES utf8mb4 */", "SELECT 1"])
    }

    @Test func statementUnderCursor() {
        let script = "SELECT 1;\n\nSELECT 2;  \nSELECT 3"
        #expect(SQLStatementSplitter.statement(at: 3, in: script)?.text == "SELECT 1")
        #expect(SQLStatementSplitter.statement(at: 9, in: script)?.text == "SELECT 1")
        #expect(SQLStatementSplitter.statement(at: 14, in: script)?.text == "SELECT 2")
        #expect(SQLStatementSplitter.statement(at: (script as NSString).length, in: script)?.text == "SELECT 3")
    }

    @Test(arguments: [
        ("SELECT * FROM t", "SELECT * FROM t LIMIT 100"),
        ("select a from t order by a -- trailing", "select a from t order by a LIMIT 100 -- trailing"),
        ("WITH x AS (SELECT 1) SELECT * FROM x", "WITH x AS (SELECT 1) SELECT * FROM x LIMIT 100"),
        ("SELECT * FROM (SELECT * FROM t LIMIT 5) s", "SELECT * FROM (SELECT * FROM t LIMIT 5) s LIMIT 100"),
        ("SELECT 1 UNION SELECT 2", "SELECT 1 UNION SELECT 2 LIMIT 100"),
    ])
    func autoLimitApplies(input: String, expected: String) {
        let outcome = AutoLimit.apply(to: input, limit: 100)
        #expect(outcome.applied)
        #expect(outcome.sql == expected)
    }

    @Test(arguments: [
        "SELECT * FROM t LIMIT 5", "SELECT * FROM t LIMIT 5 OFFSET 10", "SELECT * FROM t FOR UPDATE", "SELECT * FROM t LOCK IN SHARE MODE",
        "SELECT * INTO OUTFILE '/tmp/x' FROM t", "SELECT a INTO @v FROM t", "SHOW TABLES", "UPDATE t SET a = 1",
        "WITH x AS (SELECT 1) DELETE FROM t", "SELECT * FROM t OFFSET 5 ROWS FETCH FIRST 3 ROWS ONLY", "/*!50000 SELECT * FROM t */",
    ])
    func autoLimitSkips(input: String) {
        #expect(!AutoLimit.apply(to: input, limit: 100).applied)
    }

    @Test(arguments: [
        ("SELECT 1", SQLStatementKind.query), ("TABLE t", .query), ("VALUES ROW(1)", .query), ("(SELECT 1)", .query),
        ("EXPLAIN SELECT 1", .explain), ("EXPLAIN FORMAT=JSON SELECT 1", .explain), ("EXPLAIN ANALYZE SELECT 1", .explain),
        ("DESC t", .show), ("DESCRIBE SELECT 1", .explain), ("SHOW TABLES", .show), ("HELP 'x'", .show), ("USE shop", .use),
        ("SET sql_mode = ''", .set), ("SET NAMES utf8mb4", .set), ("SET GLOBAL max_connections = 1", .administration),
        ("SET PERSIST x = 1", .administration), ("SET @@GLOBAL.x = 1", .administration), ("SET PASSWORD = 'x'", .administration),
        ("BEGIN", .transaction), ("START TRANSACTION", .transaction), ("COMMIT", .transaction), ("START REPLICA", .administration),
        ("WITH x AS (SELECT 1) DELETE FROM t", .dataModification), ("WITH x AS (SELECT 1) UPDATE t SET a = 1", .dataModification),
        ("SELECT * INTO OUTFILE '/tmp/x' FROM t", .dataModification), ("EXPLAIN ANALYZE UPDATE t SET a = 1", .dataModification),
        // INTO glued to a number is still INTO (the server ends the number first): writes ask for confirmation.
        ("SELECT 1.5into outfile '/tmp/x'", .dataModification), ("SELECT 1e5into @v", .dataModification),
        ("ANALYZE TABLE t", .administration), ("ANALYZE UPDATE t SET a = 1", .dataModification), ("ANALYZE FORMAT=JSON SELECT 1", .explain),
        ("CALL p()", .dataModification), ("DO SLEEP(1)", .dataModification), ("LOAD DATA INFILE 'x' INTO TABLE t", .dataModification),
        ("REPLACE INTO t VALUES (1)", .dataModification), ("CREATE TABLE t (a INT)", .definition), ("RENAME TABLE a TO b", .definition),
        ("KILL QUERY 4", .administration), ("FLUSH PRIVILEGES", .administration), ("LOCK TABLES t WRITE", .administration),
        ("/*!40101 SET NAMES utf8 */", .other), ("FROBNICATE", .other),
    ])
    func statementKinds(sql: String, kind: SQLStatementKind) {
        #expect(SQLStatementKind.of(sql) == kind, "\(sql)")
    }

    @Test func mutationsNeedConfirmation() {
        #expect(SQLStatementKind.of("WITH x AS (SELECT 1) DELETE FROM t").isMutation)
        #expect(SQLStatementKind.of("FROBNICATE").isMutation, "unknown verbs are treated as mutations")
        #expect(!SQLStatementKind.of("SELECT 1").isMutation)
        #expect(!SQLStatementKind.of("COMMIT").isMutation)
    }
}

@Suite("Read-only guard")
struct ReadOnlyGuardTests {
    @Test(arguments: [
        "SELECT * FROM t", "  select 1 ; ", "WITH x AS (SELECT 1) SELECT * FROM x", "TABLE t", "VALUES ROW(1)", "SHOW TABLES",
        "SHOW CREATE TABLE t", "DESC t", "DESCRIBE t c", "EXPLAIN SELECT 1", "EXPLAIN FORMAT=JSON SELECT * FROM t",
        "EXPLAIN ANALYZE SELECT 1", "EXPLAIN FOR CONNECTION 5", "ANALYZE FORMAT=JSON SELECT 1", "SELECT 'DELETE FROM t'",
        "SELECT `update` FROM t", "SELECT 1 -- DROP TABLE t", "SELECT /* INSERT */ 1", "SELECT JSON_EXTRACT(doc, '$.a') FROM t",
        "SELECT IS_FREE_LOCK('x')", "SELECT @a := 1", "HELP 'SELECT'",
    ])
    func allowsReads(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    @Test(arguments: [
        "DELETE FROM t", "UPDATE t SET a = 1", "INSERT INTO t VALUES (1)", "REPLACE INTO t VALUES (1)", "DROP TABLE t",
        "WITH x AS (SELECT 1) DELETE FROM t", "SELECT * FROM t FOR UPDATE", "SELECT * FROM t FOR SHARE", "SELECT * FROM t LOCK IN SHARE MODE",
        "SELECT * INTO OUTFILE '/tmp/x' FROM t", "SELECT * FROM t INTO DUMPFILE '/tmp/x'", "SELECT a INTO @v FROM t",
        "SELECT 1; DROP TABLE t", "SELECT 1; SELECT 2", "/*!50000 DELETE FROM t */", "SELECT /*!50000 1 */",
        "SELECT SLEEP(10)", "SELECT GET_LOCK('x', 10)", "SELECT LOAD_FILE('/etc/passwd')", "SELECT BENCHMARK(1000000, SHA2('x', 256))",
        "SELECT NEXT VALUE FOR s", "SELECT NEXTVAL(s)", "CALL p()", "DO 1", "SET GLOBAL x = 1", "SET sql_mode = ''", "KILL 4",
        "EXPLAIN ANALYZE DELETE FROM t", "EXPLAIN DELETE FROM t", "ANALYZE TABLE t", "ANALYZE UPDATE t SET a = 1", "LOCK TABLES t READ",
        "SELECT * FROM t PROCEDURE ANALYSE()", "HANDLER t OPEN", "FLUSH TABLES", "", "-- only a comment",
        "PREPARE s FROM 'DELETE FROM t'", "EXECUTE s", "XA START 'x'", "BEGIN",
    ])
    func rejectsEverythingElse(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Final review (security): the shared lexer is a security boundary. Each of these hides INTO, a locking read or a
    // second statement behind a construct that some server, session or tool reads differently; every one is rejected.
    // 1.2.0 let the `INTO @v` and locking forms with a glued number through (its lexer took `into` into the number).
    @Test(arguments: [
        // Numbers end before a glued word (`1.5into` is `1.5 INTO`).
        "SELECT 1.5into outfile '/tmp/x'", "SELECT 1e5into dumpfile '/tmp/x'", "SELECT 0x41into outfile '/tmp/x'",
        "SELECT x'41'into outfile '/tmp/x'", "SELECT 1.5into @v", "SELECT 1e5into @v", "SELECT .5into @v FROM t", "SELECT 1e+5into @v",
        "SELECT 1.5e3into @v", "SELECT x'41'into @v", "SELECT b'1'into @v", "SELECT * FROM t WHERE a = 1.0for update",
        "SELECT * FROM t WHERE a = 1.0for share", "SELECT * FROM t WHERE a = 1e0lock in share mode", "SELECT 1 FROM t WHERE 1.0or sleep(1)",
        // Literals the server rejects while lexing.
        "SELECT 1.einto @v", "SELECT 1.e", "SELECT x'4'",
        // `ınto` upper-cases to INTO in Unicode: a name to MySQL and MariaDB (both reject `SELECT 1 ınto @v` with 1064),
        // refused anyway.
        "SELECT 1 ınto @v", "SELECT 1.5 ınto outfile '/tmp/x'",
        // A backslash ends a string early under NO_BACKSLASH_ESCAPES (and in an ANSI_QUOTES name).
        "SELECT 'a\\' INTO OUTFILE '/tmp/x' -- '", "SELECT \"a\\\" INTO OUTFILE '/tmp/x' -- \"", "SELECT '\\'; DROP TABLE t; -- '",
        // Comments: `--` needs whitespace, other tools end line comments at \r or U+2028, executable comments run code.
        "SELECT 1 --x; DROP TABLE t", "SELECT 1 --\tx\n; DROP TABLE t", "SELECT 1 #\r; DROP TABLE t", "SELECT 1 -- x\u{2028}; DROP TABLE t",
        "SELECT 1 /*! ; DROP TABLE t */", "SELECT 1 /*!99999 INTO OUTFILE '/tmp/x' */", "SELECT 1 /*M!100000 INTO DUMPFILE '/tmp/x' */",
        // MariaDB reads `\\N` as NULL and ends it after the N (`\\Nlock` is NULL LOCK); 1.2.0 read `\\` and the name `Nlock`.
        "(SELECT * FROM t WHERE a IS NOT \\Nlock in share mode)", "SELECT \\Ninto @v",
        "ANALYZE FORMAT=JSON SELECT * FROM t WHERE a IS NOT \\Nlock in share mode",
        "EXPLAIN FORMAT=JSON SELECT * FROM t WHERE a IS NOT \\Nlock in share mode", "SELECT \\N", "SELECT \\Nfrom t", "SELECT \\x",
        // DELIMITER is a client command: the server would see the `;`.
        "DELIMITER ;;\nSELECT 1; SET GLOBAL read_only = 0;;", "DELIMITER //\nSELECT 1 INTO OUTFILE '/tmp/x'//",
    ])
    func rejectsSmugglingThroughLexerDifferences(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
    }

    // The stricter checks keep ordinary reads: doubled quotes, escaped backslashes, numbers with aliases, hex literals,
    // non-ASCII names.
    @Test(arguments: ["SELECT 'it''s'", "SELECT 'a\\\\b'", "SELECT 1.5 AS x, 1e5 y, x'41' z", "SELECT 1.5x", "SELECT ſelect FROM t",
                      "SELECT 1 ﬁrst", "DELIMITER //\nSELECT 1//"])
    func stillAllowsReadsWrittenUnambiguously(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription)")
    }
}

@Suite("Redaction")
struct RedactionTests {
    @Test(arguments: [
        ("CREATE USER a IDENTIFIED BY 'secret'", "CREATE USER a IDENTIFIED BY '***'"),
        ("ALTER USER a IDENTIFIED WITH caching_sha2_password BY 'secret'", "ALTER USER a IDENTIFIED WITH caching_sha2_password BY '***'"),
        ("CREATE USER a IDENTIFIED WITH mysql_native_password AS '*HASH'", "CREATE USER a IDENTIFIED WITH mysql_native_password AS '***'"),
        ("GRANT ALL ON *.* TO a IDENTIFIED BY PASSWORD '*HASH'", "GRANT ALL ON *.* TO a IDENTIFIED BY PASSWORD '***'"),
        ("CREATE USER e IDENTIFIED VIA ed25519 USING PASSWORD('pw')", "CREATE USER e IDENTIFIED VIA ed25519 USING PASSWORD('***')"),
        ("CREATE USER e IDENTIFIED VIA ed25519 USING 'hash'", "CREATE USER e IDENTIFIED VIA ed25519 USING '***'"),
        ("SET PASSWORD FOR 'a'@'%' = 'pw'", "SET PASSWORD FOR 'a'@'%' = '***'"),
        ("SET PASSWORD = PASSWORD('pw')", "SET PASSWORD = PASSWORD('***')"),
        ("CHANGE MASTER TO MASTER_HOST='h', MASTER_PASSWORD='pw'", "CHANGE MASTER TO MASTER_HOST='h', MASTER_PASSWORD='***'"),
        ("CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = \"pw\"", "CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD = \"***\""),
        ("CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u', PASSWORD 'pw')", "CREATE SERVER s FOREIGN DATA WRAPPER mysql OPTIONS (USER 'u', PASSWORD '***')"),
        ("SELECT * FROM users WHERE name = 'bob'", "SELECT * FROM users WHERE name = 'bob'"),
    ])
    func redacts(input: String, expected: String) {
        #expect(SQLRedactor.redact(input) == expected)
    }
}

@Suite("Error location")
struct ErrorLocatorTests {
    @Test func mapsNearSnippetAndLine() throws {
        let statement = "SELECT id\nFORM orders\nWHERE x = 1"
        let message = "You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'FORM orders\nWHERE x = 1' at line 2"
        #expect(SQLErrorLocator.offset(in: statement, message: message) == 10)
    }

    @Test func emptySnippetPointsAtTheEnd() {
        let statement = "SELECT * FROM"
        #expect(SQLErrorLocator.offset(in: statement, message: "… syntax to use near '' at line 1") == 13)
    }

    @Test func snippetWithQuotesAndUnknownLines() {
        #expect(SQLErrorLocator.offset(in: "SELECT 'a' 'b' x", message: "near ''b' x' at line 1") == 11)
        #expect(SQLErrorLocator.offset(in: "SELECT 1", message: "near 'x' at line 99") == nil)
        #expect(SQLErrorLocator.offset(in: "SELECT 1", message: "near 'x' at line 999999999999999999999") == nil)
        #expect(SQLErrorLocator.offset(in: "SELECT 1", message: "Unknown column 'x' in 'field list'") == nil)
    }
}

@Suite("Completion")
struct CompletionTests {
    static let schema = SchemaSnapshot(
        currentDatabase: "shop",
        databases: ["shop", "ads"],
        objectsByDatabase: [
            "shop": [.init(name: "orders", kind: .table), .init(name: "customers", kind: .table),
                     .init(name: "v_paid_orders", kind: .view), .init(name: "sp_orders_by_city", kind: .procedure),
                     .init(name: "trg_orders_bi", kind: .trigger)],
            "ads": [.init(name: "impressions", kind: .table)],
        ],
        columnsByTable: [
            TableKey(database: "shop", table: "orders"): [
                ColumnInfo(name: "order_id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false, columnKey: "PRI"),
                ColumnInfo(name: "city", ordinal: 2, dataType: "varchar", columnType: "varchar(32)", isNullable: false),
                ColumnInfo(name: "total", ordinal: 3, dataType: "decimal", columnType: "decimal(12,2)", isNullable: true),
            ],
            TableKey(database: "shop", table: "customers"): [
                ColumnInfo(name: "customer_id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false, columnKey: "PRI"),
                ColumnInfo(name: "city", ordinal: 2, dataType: "varchar", columnType: "varchar(32)", isNullable: true),
            ],
        ])

    private func complete(_ textWithCursor: String) -> CompletionResult {
        let cursor = (textWithCursor as NSString).range(of: "|").location
        let text = textWithCursor.replacingOccurrences(of: "|", with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, schema: Self.schema)
    }

    @Test func columnsOfAnAlias() {
        let result = complete("SELECT o.| FROM orders o")
        #expect(result.items.map(\.label) == ["order_id", "city", "total"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(result.items.allSatisfy { $0.kind == .column })
    }

    @Test func aliasMemberWithPrefixReplacesOnlyThePrefix() {
        let result = complete("SELECT o.ci| FROM orders AS o")
        #expect(result.items.first?.label == "city")
        #expect(result.prefix == "ci")
        #expect(result.replacementRange == 9..<11)
    }

    @Test func tablesAfterFrom() {
        let labels = complete("SELECT * FROM |").items.map(\.label)
        #expect(labels.contains("orders"))
        #expect(labels.contains("v_paid_orders"))
        #expect(!labels.contains("sp_orders_by_city"), "procedures are not relations")
        #expect(!labels.contains("trg_orders_bi"))
        #expect(labels.contains("ads"))
        #expect(!labels.contains("SELECT"))
    }

    @Test func tablesAfterJoinAndComma() {
        #expect(complete("SELECT * FROM orders o JOIN cu|").items.first?.label == "customers")
        #expect(complete("SELECT * FROM orders o, |").items.contains { $0.label == "customers" })
    }

    @Test func keywordsAfterATableReference() {
        let labels = complete("SELECT * FROM orders o |").items.map(\.label)
        #expect(labels.contains("WHERE"))
        #expect(labels.contains("JOIN"))
        #expect(!labels.contains("orders"))
    }

    @Test func columnsInWhereFromEveryJoinedTable() {
        let result = complete("SELECT * FROM orders o JOIN customers c ON o.city = c.city WHERE cus|")
        #expect(result.items.first?.label == "customer_id")
        let city = complete("SELECT * FROM orders o JOIN customers c WHERE ci|").items.filter { $0.label == "city" }
        #expect(city.count == 2)
    }

    @Test func membersOfADatabase() {
        let labels = complete("SELECT * FROM ads.|").items.map(\.label)
        #expect(labels == ["impressions"])
    }

    @Test func columnsOfQualifiedTable() {
        #expect(complete("SELECT shop.orders.t| FROM shop.orders").items.first?.label == "total")
    }

    @Test func missingColumnsAreReported() {
        let result = complete("SELECT | FROM ads.impressions")
        #expect(result.missingColumns == [TableKey(database: "ads", table: "impressions")])
    }

    @Test func cteAndDerivedColumns() {
        let cte = complete("WITH top AS (SELECT city, SUM(total) AS revenue FROM orders GROUP BY city) SELECT t.| FROM top t")
        #expect(Set(cte.items.map(\.label)) == ["city", "revenue"])
        let derived = complete("SELECT d.| FROM (SELECT order_id AS id, city FROM orders) d")
        #expect(Set(derived.items.map(\.label)) == ["id", "city"])
    }

    @Test func statementStartAndShow() {
        #expect(complete("|").items.contains { $0.label == "SELECT" })
        #expect(complete("SHOW |").items.contains { $0.label == "ENGINE INNODB STATUS" })
        #expect(complete("show index from |").items.contains { $0.label == "orders" })
        let procedures = complete("CALL |").items
        #expect(procedures.first?.label == "sp_orders_by_city")
        #expect(!procedures.contains { $0.label == "orders" })
        #expect(complete("use |").items.contains { $0.label == "ads" })
    }

    @Test func noCompletionInsideStringsAndComments() {
        #expect(complete("SELECT 'or|' FROM orders").items.isEmpty)
        #expect(complete("SELECT 1 -- or|").items.isEmpty)
    }

    @Test func functionsAndFuzzyMatching() {
        let items = complete("SELECT date_f| FROM orders").items
        #expect(items.first?.label == "DATE_FORMAT")
        #expect(items.first?.insertText == "DATE_FORMAT(")
        #expect(complete("SELECT gc| FROM orders").items.contains { $0.label == "GROUP_CONCAT" })
    }

    @Test func onlyTheCurrentStatementIsAnalysed() {
        let result = complete("SELECT * FROM customers c;\nSELECT c.| FROM orders c")
        #expect(result.items.map(\.label).contains("order_id"))
        #expect(!result.items.map(\.label).contains("customer_id"))
    }

    @Test func quotesReservedAndUnusualNames() {
        #expect(CompletionEngine.quoteIfNeeded("order") == "`order`")
        #expect(CompletionEngine.quoteIfNeeded("my col") == "`my col`")
        #expect(CompletionEngine.quoteIfNeeded("city") == "city")
        #expect(CompletionEngine.quoteIfNeeded("吉隆坡") == "`吉隆坡`")
    }
}

@Suite("Chart robustness")
struct ChartRobustnessTests {
    @Test func extremeRangesDoNotTrap() {
        let columns = [ColumnDefinition(name: "x", type: .double), ColumnDefinition(name: "y", type: .double)]
        var rows: [[String?]] = (0..<3_000).map { [String(Double($0)), "1"] }
        rows.append(["1.6e308", "1"])
        rows.append(["-1.6e308", "1"])
        let huge = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .line, xColumn: 0, yColumns: [1]), roles: [.numeric, .numeric])
        #expect(huge.points.count <= 2_100)
        let tiny: [[String?]] = (0..<3_000).map { [$0 % 2 == 0 ? "0" : "5e-324", "1"] }
        let denormal = ChartDataBuilder.build(columns: columns, rows: tiny, spec: ChartSpec(kind: .line, xColumn: 0, yColumns: [1], aggregation: .none),
                                              roles: [.numeric, .numeric])
        #expect(!denormal.points.isEmpty)
    }
}
