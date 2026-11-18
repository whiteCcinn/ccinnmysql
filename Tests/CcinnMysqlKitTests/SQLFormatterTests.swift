import Foundation
import Testing
@testable import CcinnMysqlKit

@Suite("SQL formatter")
struct SQLFormatterTests {
    private func format(_ sql: String, _ options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        SQLFormatter.format(sql, options: options)
    }

    @Test func selectListsBreakOneItemPerLine() {
        #expect(format("select a, b from t where x = 1 and y = 2 order by a") == """
            SELECT
              a,
              b
            FROM t
            WHERE x = 1
              AND y = 2
            ORDER BY a
            """)
    }

    @Test func aSingleItemStaysOnTheClauseLine() {
        #expect(format("select count(*) from t limit 10") == "SELECT count(*)\nFROM t\nLIMIT 10")
        #expect(format("SELECT DISTINCT a, b FROM t") == "SELECT DISTINCT\n  a,\n  b\nFROM t")
        #expect(format("select a from t limit 10, 20") == "SELECT a\nFROM t\nLIMIT 10, 20")
        #expect(format("select a from t limit 10 offset 20") == "SELECT a\nFROM t\nLIMIT 10\nOFFSET 20")
    }

    @Test func joinsAndTheirConditions() {
        #expect(format("select o.id, c.name from orders o left join customers c on o.cid = c.id and c.x > 0 where o.total>10") == """
            SELECT
              o.id,
              c.name
            FROM orders o
            LEFT JOIN customers c
              ON o.cid = c.id
              AND c.x > 0
            WHERE o.total > 10
            """)
        #expect(format("select * from a cross join b inner join c using (id)") == "SELECT *\nFROM a\nCROSS JOIN b\nINNER JOIN c USING (id)")
        #expect(format("select * from a natural left outer join b straight_join c on c.id = b.id")
            == "SELECT *\nFROM a\nNATURAL LEFT OUTER JOIN b\nSTRAIGHT_JOIN c\n  ON c.id = b.id")
    }

    @Test func subqueriesAreIndented() {
        #expect(format("select * from (select a from t) s where a in (select a from u where b = 1)") == """
            SELECT *
            FROM (
              SELECT a
              FROM t
            ) s
            WHERE a IN (
              SELECT a
              FROM u
              WHERE b = 1
            )
            """)
    }

    @Test func commonTableExpressions() {
        #expect(format("with x as (select 1 as a), y as (select 2 as b) select * from x, y") == """
            WITH x AS (
              SELECT 1 AS a
            ),
            y AS (
              SELECT 2 AS b
            )
            SELECT *
            FROM x, y
            """)
        #expect(format("with recursive r as (select 1) select * from r") == "WITH RECURSIVE r AS (\n  SELECT 1\n)\nSELECT *\nFROM r")
    }

    @Test func betweenKeepsItsAnd() {
        #expect(format("select a from t where d between 1 and 5 and b = 2 or c is not null") == """
            SELECT a
            FROM t
            WHERE d BETWEEN 1 AND 5
              AND b = 2
              OR c IS NOT NULL
            """)
    }

    @Test func conditionsInsideParenthesesStayInline() {
        #expect(format("select a from t where (a = 1 or b = 2) and c = 3") == "SELECT a\nFROM t\nWHERE (a = 1 OR b = 2)\n  AND c = 3")
    }

    @Test func caseExpressionsWithSeveralBranches() {
        #expect(format("select case when a then 1 when b then 2 else 3 end as x, y from t") == """
            SELECT
              CASE
                WHEN a THEN 1
                WHEN b THEN 2
                ELSE 3
              END AS x,
              y
            FROM t
            """)
        #expect(format("select case when a then 1 end from t") == "SELECT CASE WHEN a THEN 1 END\nFROM t")
    }

    @Test func groupByHavingAndWindows() {
        #expect(format("select city, sum(total) over (partition by city order by d) s from t group by city, d having sum(total) > 10") == """
            SELECT
              city,
              sum(total) OVER (PARTITION BY city ORDER BY d) s
            FROM t
            GROUP BY
              city,
              d
            HAVING sum(total) > 10
            """)
        #expect(format("select sum(a) over (order by b rows between unbounded preceding and current row) from t")
            == "SELECT sum(a) OVER (ORDER BY b ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)\nFROM t")
        #expect(format("select sum(a) over w from t window w as (order by b)") == "SELECT sum(a) OVER w\nFROM t\nWINDOW w AS (ORDER BY b)")
    }

    @Test func insertReplaceUpdateAndDelete() {
        #expect(format("insert into t (a, b) values (1, 'x'), (2, 'y')") == "INSERT INTO t (a, b)\nVALUES\n  (1, 'x'),\n  (2, 'y')")
        #expect(format("replace into t values (1, 'x')") == "REPLACE INTO t\nVALUES (1, 'x')")
        #expect(format("insert into t select a from u") == "INSERT INTO t\nSELECT a\nFROM u")
        #expect(format("insert into t set a = 1, b = 2") == "INSERT INTO t\nSET\n  a = 1,\n  b = 2")
        #expect(format("update t set a = 1, b = 2 where id = 3") == "UPDATE t\nSET\n  a = 1,\n  b = 2\nWHERE id = 3")
        #expect(format("delete from t where id = 3") == "DELETE FROM t\nWHERE id = 3")
        #expect(format("insert into t (a, b) values (1, 2) on duplicate key update b = values(b), a = a + 1") == """
            INSERT INTO t (a, b)
            VALUES (1, 2)
            ON DUPLICATE KEY UPDATE
              b = VALUES(b),
              a = a + 1
            """)
    }

    @Test func lockingReads() {
        #expect(format("select a from t where id = 1 for update") == "SELECT a\nFROM t\nWHERE id = 1\nFOR UPDATE")
        #expect(format("select a from t for share skip locked") == "SELECT a\nFROM t\nFOR SHARE SKIP LOCKED")
        #expect(format("select a from t lock in share mode") == "SELECT a\nFROM t LOCK IN SHARE mode", "MODE is not a keyword token")
    }

    @Test func mysqlTableDefinitions() {
        let sql = """
            create table shop.t (id bigint unsigned not null auto_increment, name varchar(32) not null default '', \
            total decimal(12,2), created_at datetime default current_timestamp, primary key (id), key idx_name (name)) \
            engine=InnoDB default charset=utf8mb4 partition by range (id) \
            (partition p0 values less than (1000), partition p1 values less than maxvalue)
            """
        #expect(format(sql) == """
            CREATE TABLE shop.t (
              id BIGINT UNSIGNED NOT NULL auto_increment,
              name VARCHAR(32) NOT NULL DEFAULT '',
              total DECIMAL(12, 2),
              created_at datetime DEFAULT CURRENT_TIMESTAMP,
              PRIMARY KEY (id),
              KEY idx_name (name)
            ) engine = InnoDB DEFAULT charset = utf8mb4
            PARTITION BY RANGE (id) (
              PARTITION p0 VALUES LESS THAN (1000),
              PARTITION p1 VALUES LESS THAN MAXVALUE
            )
            """)
    }

    @Test func stringsQuotedNamesAndCommentsAreUntouched() {
        #expect(format("select 'a  b', `x  y` -- keep\nfrom t /* c  d */ where a=1") == """
            SELECT
              'a  b',
              `x  y` -- keep
            FROM t /* c  d */
            WHERE a = 1
            """)
        #expect(format("-- header\n\nselect /*+ BKA(t) */ a, b from t") == """
            -- header
            SELECT /*+ BKA(t) */
              a,
              b
            FROM t
            """)
        #expect(format("select a # note\nfrom t") == "SELECT a # note\nFROM t")
        #expect(format("select /*!40001 SQL_NO_CACHE */ a from t") == "SELECT /*!40001 SQL_NO_CACHE */ a\nFROM t")
    }

    @Test func statementsAreSeparatedByABlankLine() {
        #expect(format("select 1;select 2;\n\n\nuse shop") == "SELECT 1;\n\nSELECT 2;\n\nUSE shop")
        #expect(format("select 1; -- done\nselect 2") == "SELECT 1; -- done\n\nSELECT 2")
        #expect(format("select 1;\n") == "SELECT 1;\n", "a trailing newline is kept")
    }

    // CAST and SIGNED are not reserved in MySQL (they can be names), so they keep their case.
    @Test func operatorsAndPunctuation() {
        #expect(format("select a+b*-1, t.*, -x, @v, @@session.sql_mode, a<>b, c>=-2, a<=>b, j->>'$.a', @x:=1 from t") == """
            SELECT
              a + b * -1,
              t.*,
              -x,
              @v,
              @@session.sql_mode,
              a <> b,
              c >= -2,
              a <=> b,
              j ->> '$.a',
              @x := 1
            FROM t
            """)
        #expect(format("select cast(a as signed), if(b, 1, 2), date_format(d,'%Y'), left(s, 2) from t") == """
            SELECT
              cast(a AS signed),
              IF(b, 1, 2),
              date_format(d, '%Y'),
              LEFT(s, 2)
            FROM t
            """)
        #expect(format("select 1--1") == "SELECT 1 - -1", "`--` without a space is arithmetic in MySQL")
    }

    // MySQL resolves `COUNT (*)` differently from `COUNT(*)` (recorded on 8.4: the first is a syntax error), so the
    // space between a name and `(` is the user's; only reserved keywords, where the server ignores it, are spaced.
    @Test func functionCallSpacingIsKept() {
        #expect(format("select count (*), count(*), date_format (d, '%Y'), ifnull(a,b) from t") == """
            SELECT
              count (*),
              count(*),
              date_format (d, '%Y'),
              ifnull(a, b)
            FROM t
            """)
        #expect(format("select `my fn`(1), shop.fn (2) from t") == "SELECT\n  `my fn`(1),\n  shop.fn (2)\nFROM t")
        #expect(format("select a from t where id in(1,2)") == "SELECT a\nFROM t\nWHERE id IN (1, 2)")
    }

    // `X'41'` and `X '41'` differ (recorded: the second is an unknown column X).
    @Test func introducersAndVariablesStayAttached() {
        #expect(format("select x'41', X'41', _utf8mb4'a', n'b', b'01', @'v', @\"w\", @`x` from t") == """
            SELECT
              x'41',
              X'41',
              _utf8mb4'a',
              n'b',
              b'01',
              @'v',
              @"w",
              @`x`
            FROM t
            """)
    }

    // Words reserved only by MySQL 8.0 can be (case-sensitive) table names on 5.7 and MariaDB: their case changes only
    // where they cannot be names.
    @Test func onlySafeWordsChangeCase() {
        #expect(format("select status, date from Orders") == "SELECT\n  status,\n  date\nFROM Orders")
        #expect(format("select * from row") == "SELECT *\nFROM row")
        #expect(format("select a from Function f join rows r on r.id = f.id") == "SELECT a\nFROM Function f\nJOIN rows r\n  ON r.id = f.id")
        #expect(format("select a from window, lateral") == "SELECT a\nFROM window, lateral")
        #expect(format("SELECT a FROM t", SQLFormatOptions(keywordCase: .lower)) == "select a\nfrom t")
        #expect(format("Select a From t", SQLFormatOptions(keywordCase: .preserve)) == "Select a\nFrom t")
        #expect(format("select a from t", SQLFormatOptions(indentWidth: 4)) == "SELECT a\nFROM t")
        #expect(format("select a, b from t", SQLFormatOptions(indentWidth: 4)) == "SELECT\n    a,\n    b\nFROM t")
    }

    // Review: a word recognised by its position must never be a name there (table names and aliases are visible).
    @Test func positionalKeywordsNeverRecaseNames() {
        #expect(format("select status from Orders join row r on r.id = 1") == "SELECT status\nFROM Orders\nJOIN row r\n  ON r.id = 1")
        #expect(format("insert into row (a) values (1)") == "INSERT INTO row (a)\nVALUES (1)", "`row (` is a table here")
        #expect(format("update nowait set a = 1") == "UPDATE nowait\nSET a = 1")
        #expect(format("select 1 preceding, 2 following, current row from t") == "SELECT\n  1 preceding,\n  2 following,\n  current row\nFROM t",
                "aliases name the result columns")
        #expect(format("select a from t for update nowait") == "SELECT a\nFROM t\nFOR UPDATE NOWAIT")
    }

    // NO_BACKSLASH_ESCAPES: the formatter lexes like the server, so string contents are never touched.
    @Test func backslashEscapesFollowTheSession() {
        let text = "select 'C:\\'  ,  'x  y'"
        #expect(format(text, SQLFormatOptions(backslashEscapes: false)) == "SELECT\n  'C:\\',\n  'x  y'")
        // With escapes, `'C:\'  ,  '` is one string and must keep its spaces.
        let escaped = format(text)
        #expect(escaped?.contains("'C:\\'  ,  '") == true)
    }

    // DELIMITER lines are client commands that must stay alone on their line; statements are formatted one by one.
    @Test func delimiterScriptsKeepTheirCommands() throws {
        let script = "DELIMITER $$\ncreate procedure p() begin select a, b from t; end$$\nDELIMITER ;\nselect a, b from t where x = 1;\n"
        let formatted = try #require(format(script))
        // BEGIN and END are not reserved in MySQL: they keep their case.
        #expect(formatted.hasPrefix("DELIMITER $$\nCREATE PROCEDURE p() begin\nSELECT\n  a,\n  b\nFROM t;"))
        #expect(formatted.contains("end$$\nDELIMITER ;\nSELECT\n  a,\n  b\nFROM t\nWHERE x = 1;\n"))
        let before = SQLStatementSplitter.split(script)
        let after = SQLStatementSplitter.split(formatted)
        #expect(before.count == 2 && after.count == 2)
        #expect(zip(before, after).allSatisfy { SQLFormatter.sameTokens($0.text, $1.text) })
    }

    @Test func emptyAndWhitespaceInput() {
        #expect(format("") == "")
        #expect(format("   \n  ") == "")
        #expect(format("-- just a note") == "-- just a note")
    }

    @Test func unbalancedAndUnterminatedInputNeverCrash() {
        #expect(format("select (a from t") != nil)
        #expect(format("select a) from t") != nil)
        #expect(format("select 'abc") == "SELECT 'abc")
        #expect(format("select /* open") == "SELECT /* open")
    }

    @Test func formattingIsIdempotent() throws {
        for sql in Self.corpus {
            let once = try #require(format(sql), "\(sql)")
            #expect(format(once) == once, "\(sql)")
        }
    }

    /// The safety property on random input, built from pieces MySQL glues together when they touch (`\N`, `0x1F`,
    /// `X'41'`, `@'v'`, `t.order`, `count(`), `:` runs and `@` soup, with and without spaces between them: same tokens,
    /// whitespace only where it cannot matter, case only on reserved or positional words, and idempotent.
    @Test func fuzzedInputKeepsItsMeaningAndIsIdempotent() {
        var generator = SystemRandomNumberGenerator()
        var refused = 0
        for _ in 0..<4_000 {
            var text = ""
            for _ in 0..<Int.random(in: 0...40, using: &generator) {
                text += Self.fuzzPieces.randomElement(using: &generator) ?? ""
                if Bool.random(using: &generator) { text += Bool.random(using: &generator) ? " " : "\n" }
            }
            let options = SQLFormatOptions(keywordCase: Bool.random(using: &generator) ? .upper : .lower,
                                           backslashEscapes: Bool.random(using: &generator))
            let lexer = SQLLexer(text, backslashEscapes: options.backslashEscapes)
            let malformed = lexer.containsMalformedLiteral(lexer.tokens()) || lexer.containsBareBackslash(lexer.tokens())
            guard let formatted = SQLFormatter.format(text, options: options) else {
                if !malformed { refused += 1 } // never wrong, at worst unhelpful
                continue
            }
            #expect(!malformed, "a literal the server rejects, or a backslash outside strings, is never formatted: \(text.debugDescription)")
            let context = "\(text.debugDescription) -> \(formatted.debugDescription)"
            #expect(SQLFormatter.sameTokens(text, formatted, backslashEscapes: options.backslashEscapes), "\(context)")
            #expect(Self.changesAreSafe(from: text, to: formatted, backslashEscapes: options.backslashEscapes), "\(context)")
            #expect(SQLFormatter.format(formatted, options: options) == formatted, "not idempotent: \(context)")
        }
        #expect(refused < 40, "the formatter should almost never have to refuse (\(refused) of 4000)")
    }

    /// The same property for random selections of random text: the whole text after the edit must pass the check, and
    /// the edit covers whole tokens only.
    @Test func fuzzedSelectionsKeepTheWholeTextsMeaning() {
        var generator = SystemRandomNumberGenerator()
        var formatted = 0
        for _ in 0..<3_000 {
            var text = ""
            for _ in 0..<Int.random(in: 0...30, using: &generator) {
                text += Self.fuzzPieces.randomElement(using: &generator) ?? ""
                if Bool.random(using: &generator) { text += Bool.random(using: &generator) ? " " : "\n" }
            }
            let length = (text as NSString).length
            let ends = (Int.random(in: 0...length, using: &generator), Int.random(in: 0...length, using: &generator))
            let range = NSRange(location: min(ends.0, ends.1), length: abs(ends.0 - ends.1))
            let options = SQLFormatOptions(backslashEscapes: Bool.random(using: &generator))
            guard let edit = SQLFormatter.formatSelection(in: text, range: range, options: options) else { continue }
            formatted += 1
            let spliced = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            let context = "\(text.debugDescription) \(range) -> \(spliced.debugDescription)"
            #expect(SQLFormatter.sameTokens(text, spliced, backslashEscapes: options.backslashEscapes), "\(context)")
            #expect(Self.changesAreSafe(from: text, to: spliced, backslashEscapes: options.backslashEscapes), "\(context)")
            let tokens = SQLLexer(text, backslashEscapes: options.backslashEscapes).tokens()
            #expect(!tokens.contains { $0.range.lowerBound < edit.range.location && $0.range.upperBound > edit.range.location }, "\(context)")
            #expect(!tokens.contains { $0.range.lowerBound < NSMaxRange(edit.range) && $0.range.upperBound > NSMaxRange(edit.range) }, "\(context)")
        }
        #expect(formatted > 2_000)
    }

    static let fuzzPieces = [
        "select", "from", "where", "and", "order", "by", "case", "when", "then", "end", "over", "rows", "row", "current",
        "preceding", "unbounded", "window", "as", "limit", "offset", "for", "update", "share", "values", "less", "than",
        "partition", "database", "insert", "into", "t", "a", "x", "N", "count", "(", ")", ",", ";", ".", ":", "::", ":=", "@",
        "@@", "@'v'", "@`w`", "'s  t'", "\"d\"", "`q  r`", "\\N", "\\", "0x", "0x1", "0xZ", "1", "2.5", "1abc", "-", "+", "*",
        "=", "<>", "-- c\n", "# h\n", "/* c */", "/*! e */", "\n",
        // Final review: numbers glued to words (`1.5x`, `1e2end`, `1.e`), hex/bit literals, user@host, set operators,
        // CRLF, non-ASCII look-alikes of keywords.
        "e", "1e2", "1.", ".5", "1e", "x'41'", "b'1'", "'r'", "@'h'", "except", "intersect", "\r\n", "-- y\r\n", "ſelect", "ﬁrst",
    ]

    /// Words whose case the formatter may change by their position (design D2).
    static let positionalWords: Set<String> = [
        "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "ROWS", "OVER", "WINDOW", "RECURSIVE", "EXCEPT", "INTERSECT",
        "LATERAL", "FUNCTION", "DATABASE", "SCHEMA", "VIEW", "EVENT", "GENERATED", "STORED", "VIRTUAL", "DUPLICATE", "LESS", "THAN", "SHARE",
        "SKIP", "LOCKED", "NOWAIT", "OFFSET", "END", "PARTITION",
    ]

    /// An independent statement of what formatting may change (design D3, D8), checked token pair by token pair:
    /// - tokens that touch in the input may be separated only next to `,` `;` `(` `)` (never `.`), a plain comment or an
    ///   operator, or after a string or back-quoted name (not before `@`); before `(` only after a reserved word,
    ///   punctuation or an operator;
    /// - tokens apart in the input may touch only before `,` `;` `)`, after `(` or a sign, or for a reserved word and `(`;
    /// - letter case changes only on reserved words (never next to `.`) and positional words.
    static func changesAreSafe(from input: String, to output: String, backslashEscapes: Bool) -> Bool {
        let inLexer = SQLLexer(input, backslashEscapes: backslashEscapes)
        let outLexer = SQLLexer(output, backslashEscapes: backslashEscapes)
        let before = inLexer.tokens()
        let after = outLexer.tokens()
        guard before.count == after.count else { return false }
        func text(_ index: Int) -> String { inLexer.text(of: before[index]) }
        func isPunctuation(_ index: Int, _ value: String) -> Bool { before[index].kind == .punctuation && text(index) == value }
        func nextToDot(_ index: Int) -> Bool {
            (index > 0 && isPunctuation(index - 1, ".")) || (index + 1 < before.count && isPunctuation(index + 1, "."))
        }
        func isReserved(_ index: Int) -> Bool {
            before[index].kind == .keyword && SQLKeywords.reservedEverywhere.contains(text(index).uppercased()) && !nextToDot(index)
        }
        func isOperator(_ index: Int) -> Bool {
            before[index].kind == .operator && text(index).allSatisfy { "=<>!|&^+-*/%~:?".contains($0) }
        }
        for first in before.indices.dropLast() {
            let second = first + 1
            let wasTouching = before[first].range.upperBound == before[second].range.lowerBound
            let isTouching = after[first].range.upperBound == after[second].range.lowerBound
            if wasTouching, !isTouching {
                if isPunctuation(first, ".") || isPunctuation(second, ".") { return false }
                if before[first].kind == .executableComment || before[second].kind == .executableComment { return false }
                if isPunctuation(second, "(") {
                    guard isReserved(first) || before[first].kind == .punctuation || isOperator(first) || before[first].kind == .comment
                    else { return false }
                    continue
                }
                let separable = before[first].kind == .comment || before[second].kind == .comment
                    || before[first].kind == .punctuation || before[second].kind == .punctuation
                    || isOperator(first) || isOperator(second)
                    || ((before[first].kind == .string || before[first].kind == .quotedIdentifier) && before[second].kind != .variable)
                guard separable else { return false }
            }
            if !wasTouching, isTouching {
                let joinable = isPunctuation(second, ",") || isPunctuation(second, ";") || isPunctuation(second, ")")
                    || isPunctuation(first, "(") || (before[first].kind == .operator && ["-", "+"].contains(text(first)))
                    || (isReserved(first) && isPunctuation(second, "("))
                guard joinable else { return false }
            }
        }
        for index in before.indices where text(index) != outLexer.text(of: after[index]) {
            guard isReserved(index) || (before[index].kind == .keyword && Self.positionalWords.contains(text(index).uppercased()))
            else { return false }
        }
        return true
    }

    @Test func cursorPositionsMapAcrossFormatting() throws {
        let original = "select a,b from   t where x=1"
        let formatted = try #require(format(original))
        let afterFrom = (original as NSString).range(of: "from").upperBound
        #expect(SQLFormatter.mapOffset(afterFrom, from: original, to: formatted) == (formatted as NSString).range(of: "FROM").upperBound)
        #expect(SQLFormatter.mapOffset(0, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(original.utf16.count, from: original, to: formatted) == formatted.utf16.count)
        #expect(SQLFormatter.mapOffset(-5, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(10_000, from: original, to: formatted) == formatted.utf16.count)
    }

    // Review: a selection that starts or ends inside a token is snapped to whole tokens of the whole text (and to whole
    // qualified names), so a fragment is never formatted with a meaning it does not have in the script.
    @Test func selectionsSnapToWholeTokens() throws {
        let text = "select 'a   b' from t; select x,y from u"
        let ns = text as NSString
        let second = ns.range(of: "select x,y from u")
        #expect(SQLFormatter.formatSelection(in: text, range: second) == SQLFormatEdit(range: second, replacement: "SELECT\n  x,\n  y\nFROM u"))
        // Starting inside the string: the whole string goes with it, its spaces untouched.
        let inside = NSRange(location: ns.range(of: "a   b").location, length: ns.range(of: "from").upperBound - ns.range(of: "a   b").location)
        #expect(SQLFormatter.formatSelection(in: text, range: inside)
            == SQLFormatEdit(range: ns.range(of: "'a   b' from"), replacement: "'a   b' FROM"))
        // Part of a name (`or` inside `color`): the whole name, which keeps its case.
        let named = "select color from t"
        let or = NSRange(location: (named as NSString).range(of: "color").location + 3, length: 2)
        #expect(SQLFormatter.formatSelection(in: named, range: or) == SQLFormatEdit(range: (named as NSString).range(of: "color"), replacement: "color"))
        // Half a qualified name: MySQL reads `t.order` as a column, so `order` keeps its case.
        let qualified = "select t.order from x"
        let order = (qualified as NSString).range(of: "order from x")
        #expect(SQLFormatter.formatSelection(in: qualified, range: order)
            == SQLFormatEdit(range: (qualified as NSString).range(of: "t.order from x"), replacement: "t.order FROM x"))
        // Whitespace around the selected tokens stays outside the edit; whitespace alone is nothing to format.
        let gap = ns.range(of: "; ").location + 1
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: gap, length: ns.length - gap))?.range == second)
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: gap, length: 1)) == SQLFormatEdit(range: NSRange(location: gap, length: 1), replacement: " "))
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: 0, length: 10_000)) == nil)
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: -1, length: 2)) == nil)
    }

    // The case a selection may change is decided in the whole text: a fragment cannot recase a word that the script uses as
    // a name (here `rows`, after `.` in the full text once snapped).
    @Test func selectionChecksAllowOnlyMarkedCaseChanges() throws {
        let text = "select t.rows between 1 and 2 from t"
        let ns = text as NSString
        let edit = try #require(SQLFormatter.formatSelection(in: text, range: ns.range(of: "rows between 1 and 2")))
        #expect(edit.range == ns.range(of: "t.rows between 1 and 2"))
        #expect(edit.replacement == "t.rows BETWEEN 1 AND 2")
    }

    @Test func trailingSpacesOfLineCommentsAreKept() {
        #expect(format("select a -- note   \nfrom t") == "SELECT a -- note   \nFROM t")
    }

    @Test func aMegabyteScriptFormatsQuickly() throws {
        let statement = "select o.id, sum(o.amount) total, case when o.x > 1 then 'a' when o.x < 0 then 'b' else 'c' end k "
            + "from shop.orders o left join shop.customers c on o.customer_id = c.id and c.city in ('KL', 'PG') "
            + "where o.created_at between '2024-01-01' and '2024-12-31' and o.status = 'paid' group by o.id, k order by total desc limit 10;\n"
        let script = String(repeating: statement, count: 1_048_576 / statement.utf8.count + 1)
        let started = ContinuousClock.now
        let formatted = try #require(format(script))
        #expect(ContinuousClock.now - started < .seconds(20), "debug build bound; release is far faster")
        #expect(formatted.count > script.count)
    }

    // MARK: Review addendum

    // (1) The case-changeable words are reserved on every supported server (probed on MySQL 5.5–9.6, Percona 8.0 and
    // MariaDB 10.6–12.0, re-checked by the integration tests). DATABASE, SCHEMA and OPTION are names on MariaDB, PARTITION on
    // MySQL 5.5, WINDOW and LATERAL on MariaDB and 5.7: table names are case-sensitive on Linux servers.
    @Test func caseChangesOnlyForWordsEveryServerReserves() {
        #expect(format("select a from Database, Schema, Option, Partition, Window, Lateral")
            == "SELECT a\nFROM Database, Schema, Option, Partition, Window, Lateral")
        #expect(SQLKeywords.reservedEverywhere.isSubset(of: SQLKeywords.reserved))
        for word in ["DATABASE", "SCHEMA", "OPTION", "PARTITION", "WINDOW", "LATERAL", "ROW", "ROWS", "OVER", "RECURSIVE", "EXCEPT",
                     "INTERSECT", "FUNCTION", "GENERATED", "STORED", "VIRTUAL", "OFFSET", "RANK", "SYSTEM", "EMPTY", "OF", "GET",
                     "MASTER_BIND", "MASTER_SSL_VERIFY_SERVER_CERT"] {
            #expect(!SQLKeywords.reservedEverywhere.contains(word), "\(word)")
        }
        // Where they cannot be names, they change case by position.
        #expect(format("create database if not exists shop") == "CREATE DATABASE IF NOT EXISTS shop")
        #expect(format("drop schema shop") == "DROP SCHEMA shop")
        #expect(format("select database(), schema()") == "SELECT\n  database(),\n  schema()")
        #expect(format("select * from t partition (p0)") == "SELECT *\nFROM t partition (p0)")
    }

    // MySQL reads any word right after `.` as a name (`shop.order` is a table, `t.and` a column): never re-cased, never a
    // clause, and the whitespace around the dot is kept (`t. order` makes `order` a keyword again).
    @Test func wordsNextToADotAreNames() {
        #expect(format("select t.order, t.select, t.from from shop.order t where t.and = 1") == """
            SELECT
              t.order,
              t.select,
              t.from
            FROM shop.order t
            WHERE t.and = 1
            """)
        #expect(format("select t. order, t . a, b .c from t") == "SELECT\n  t. order,\n  t . a,\n  b .c\nFROM t")
        #expect(format("select f. (1), g.(2)") == "SELECT\n  f. (1),\n  g.(2)", "found by the fuzz test")
        #expect(format("select order.x from t") == "SELECT order.x\nFROM t")
    }

    // (5) Whitespace is never put between tokens that touch in the input, except next to punctuation, comments and
    // operators: `\N`, `0x1F`, `X'41'`, `_charset'…'`, `@'v'`, `@@x`, `1abc` and `name(` mean something else when split.
    @Test func touchingTokensStayTouching() {
        #expect(format("select 0xZZ, 0x1and, 1abc, x'41', _utf8mb4'a', N'b', @'v', @@x, @@@a, @a.b from t") == """
            SELECT
              0xZZ,
              0x1and,
              1abc,
              x'41',
              _utf8mb4'a',
              N'b',
              @'v',
              @@x,
              @@@a,
              @a.b
            FROM t
            """)
        #expect(format("select'a'from t") == "SELECT'a'\nFROM t")
        #expect(format("select*from t where a=-1") == "SELECT *\nFROM t\nWHERE a = -1")
        #expect(format("select a/*c*/from t") == "SELECT a /*c*/\nFROM t")
        #expect(format("select/*!40001 SQL_NO_CACHE*/a from t") == "SELECT/*!40001 SQL_NO_CACHE*/a\nFROM t")
        // `INSERT INTO count(a)` is a syntax error (COUNT( is the function); `count (a)` would insert into a table count.
        #expect(format("insert into count(a) values (1)") == "INSERT INTO count(a)\nVALUES (1)")
    }

    // Owner request: `COUNT (*)` is not `COUNT(*)` in MySQL (error 1064 on 8.4 without IGNORE_SPACE), so the gap is never
    // closed nor opened, wherever the call is (also checked on the real servers).
    @Test func countWithASpaceKeepsItsSpace() throws {
        #expect(format("SELECT COUNT (*) FROM t") == "SELECT COUNT (*)\nFROM t")
        #expect(format("select count (*) a, count(*) b from t having count (*) > 1") == """
            SELECT
              count (*) a,
              count(*) b
            FROM t
            HAVING count (*) > 1
            """)
        #expect(format("select count/*x*/(*)") == "SELECT count /*x*/ (*)")
        let text = "select x from t; select count (*) from u"
        let edit = try #require(SQLFormatter.formatSelection(in: text, range: (text as NSString).range(of: "select count (*) from u")))
        #expect(edit.replacement == "SELECT count (*)\nFROM u")
    }

    // (4) Comments on one line keep their order, also when the first one starts the line.
    @Test func commentsOnOneLineKeepTheirOrder() {
        #expect(format("select a\n/* one */ /* two */ from t") == "SELECT a\n/* one */ /* two */\nFROM t")
        #expect(format("select a\n/* one */ -- two\nfrom t") == "SELECT a\n/* one */ -- two\nFROM t")
        #expect(format("select a\n# one\n/* two */ /* three */ from t") == "SELECT a\n# one\n/* two */ /* three */\nFROM t")
    }

    // (6) Words that are keywords only by position change case only where they cannot be names.
    @Test func positionalKeywordsOnlyWhereProven() {
        // Names in positions the earlier rules took for keywords.
        #expect(format("insert row (a) values (1)") == "INSERT row (a)\nVALUES (1)", "INTO is optional")
        #expect(format("create table c (id int, foreign key (id) references row (id))")
            == "CREATE TABLE c (\n  id INT,\n  FOREIGN KEY (id) REFERENCES row (id)\n)")
        #expect(format("select less than from t") == "SELECT less than\nFROM t", "an alias")
        #expect(format("select a from t for update of nowait") == "SELECT a\nFROM t\nFOR UPDATE of nowait", "a table")
        #expect(format("select aggregate function from t") == "SELECT aggregate function\nFROM t")
        #expect(format("select generated always from t") == "SELECT generated always\nFROM t")
        #expect(format("create view v as select (a) virtual from t") == "CREATE VIEW v AS\nSELECT (a) virtual\nFROM t")
        #expect(format("replace view (a) values (1)") == "REPLACE view (a)\nVALUES (1)", "a table view")
        #expect(format("select case when a then end end from t") == "SELECT case when a then end end\nFROM t", "a column end: unproven")
        #expect(format("select a from t limit offset") == "SELECT a\nFROM t\nLIMIT offset", "a procedure variable")
        #expect(format("select (a) over from t") == "SELECT (a) over\nFROM t")
        #expect(format("select over.x from (select 1 x) over") == "SELECT over.x\nFROM (\n  SELECT 1 x\n) over")
        #expect(format("insert lateral (a) values (1)") == "INSERT lateral (a)\nVALUES (1)")
        #expect(format("insert except select 1") == "INSERT except\nSELECT 1")
        #expect(format("select a from t where (current row) and (rows between 1 and 2)")
            == "SELECT a\nFROM t\nWHERE (current row)\n  AND (rows BETWEEN 1 AND 2)")
        // Proven positions.
        #expect(format("select sum(a) over (order by preceding rows between 1 preceding and current row) from t")
            == "SELECT sum(a) OVER (ORDER BY preceding ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)\nFROM t")
        #expect(format("select sum(a) over (order by d range between interval 1 day preceding and unbounded following) from t")
            == "SELECT sum(a) OVER (ORDER BY d RANGE BETWEEN INTERVAL 1 day PRECEDING AND UNBOUNDED FOLLOWING)\nFROM t")
        #expect(format("select rank() over w, sum(a) over (w rows unbounded preceding) from t window w as (partition by b order by a)") == """
            SELECT
              rank() OVER w,
              sum(a) OVER (w ROWS UNBOUNDED PRECEDING)
            FROM t
            WINDOW w AS (PARTITION BY b ORDER BY a)
            """)
        #expect(format("select * from t, lateral (select 1) d") == "SELECT *\nFROM t, LATERAL (\n  SELECT 1\n) d")
        #expect(format("select a from t except select a from u") == "SELECT a\nFROM t\nEXCEPT\nSELECT a\nFROM u")
        #expect(format("create trigger tr before insert on t for each row set new.a = 1")
            == "CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET new.a = 1")
        #expect(format("create table t (a int, b int generated always as (a + 1) stored, c int as (a) virtual)")
            == "CREATE TABLE t (\n  a INT,\n  b INT GENERATED always AS (a + 1) STORED,\n  c INT AS (a) VIRTUAL\n)")
        #expect(format("create table t (a int) partition by hash (a) partitions 4") == "CREATE TABLE t (\n  a INT\n)\nPARTITION BY hash (a) partitions 4")
        #expect(format("create function f() returns int return 1; drop function if exists f")
            == "CREATE FUNCTION f() returns INT RETURN 1;\n\nDROP FUNCTION IF EXISTS f")
    }

    // (7) Indentation stops at a fixed depth, and a text that would still grow out of proportion is refused.
    @Test func indentationIsCappedAndRunawayGrowthRefused() throws {
        let depth = 30
        let nested = String(repeating: "select a from (", count: depth) + "select 1" + String(repeating: ") x", count: depth)
        let formatted = try #require(format(nested))
        let deepest = formatted.components(separatedBy: "\n").map { line in line.prefix { $0 == " " }.count }.max() ?? 0
        #expect(deepest == SQLFormatter.maxIndentLevel * 2)
        #expect(format(formatted) == formatted)
        // Thousands of nested subqueries at an indent of 8 would grow the text about 17-fold.
        let runaway = String(repeating: "(select ", count: 5_000) + "1" + String(repeating: ")", count: 5_000)
        #expect(format(runaway, SQLFormatOptions(indentWidth: 8)) == nil)
        let bounded = try #require(format(runaway))
        #expect(bounded.utf16.count <= SQLFormatter.maxOutputLength(forInputLength: runaway.utf16.count))
    }

    // (7) Formatting runs off the main actor and stops when its task is cancelled (the user typed meanwhile).
    @Test func cancelledFormattingStopsEarly() async {
        let script = String(repeating: "select a, b from t where x = 1 and y = 2;\n", count: 40_000)
        let started = ContinuousClock.now
        let task = Task.detached { SQLFormatter.format(script) }
        task.cancel()
        #expect(await task.value == nil)
        let selection = Task.detached { SQLFormatter.formatSelection(in: script, range: NSRange(location: 0, length: (script as NSString).length)) }
        selection.cancel()
        #expect(await selection.value == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: Final review

    // Number lexing matches the server (see the lexer tests): `1e2end` is `1e2` and an END, so with the alias `end` after
    // it the statement has two ends for one CASE and the CASE words stay as written (the label `end` keeps its case);
    // `1.5x` and `x'41'z` are aliased numbers and stay glued.
    @Test func numbersAreReadAsTheServerReadsThem() {
        #expect(format("select case when 1 then 1e2end end") == "SELECT case when 1 then 1e2end end")
        #expect(format("select case when 1 then 1e2end") == "SELECT CASE WHEN 1 THEN 1e2END")
        #expect(format("select 1.5x, 1e2x, x'41'z, 1e+x from t") == "SELECT\n  1.5x,\n  1e2x,\n  x'41'z,\n  1e + x\nFROM t")
        #expect(format("select 1.5from t") == "SELECT 1.5FROM t", "touching tokens stay touching")
    }

    // A literal the server rejects while lexing (`1.end`, `x'4'`) leaves the token boundaries after it to guesswork: the
    // formatter refuses, also for a selection that includes it. Other statements still format.
    @Test func malformedLiteralsAreRefused() throws {
        for sql in ["select 1.end", "select case when a then 1.end", "select .5e from t", "select 1.5ex", "select x'4' from t",
                    "select x'4g', a from t", "select b'12' from t", "select a from t where b = 1.e+"] {
            #expect(format(sql) == nil, "\(sql)")
        }
        let text = "select 1.e; select a,b from t"
        let ns = text as NSString
        #expect(SQLFormatter.formatSelection(in: text, range: ns.range(of: "select 1.e")) == nil)
        let edit = try #require(SQLFormatter.formatSelection(in: text, range: ns.range(of: "select a,b from t")))
        #expect(edit.replacement == "SELECT\n  a,\n  b\nFROM t")
    }

    // `\\N` is NULL on MariaDB and MySQL 5.x, which end it after the N (`\\Nlock` is NULL LOCK), and an error on MySQL 8:
    // text with a backslash outside strings, back-quoted names and comments is not formatted.
    @Test func backslashesOutsideStringsAreRefused() {
        for sql in ["select \\N", "select a from t where b is not \\Nlock in share mode", "select \\Ninto @v", "select 1 \\ 2"] {
            #expect(format(sql) == nil, "\(sql)")
        }
        #expect(format("select 'a\\\\b', `c\\d` from t -- \\N") == "SELECT\n  'a\\\\b',\n  `c\\d`\nFROM t -- \\N")
    }

    // Keywords are ASCII. `ſelect` (long s) and `lımıt` (dotless i) upper-case to SELECT and LIMIT in Unicode, and the
    // ligature `ﬁrst` to FIRST: names for the server, so never re-cased or laid out as keywords.
    @Test func onlyASCIIWordsAreKeywords() {
        #expect(format("select 1 ſelect") == "SELECT 1 ſelect")
        #expect(format("select a ﬁrst from t lımıt") == "SELECT a ﬁrst\nFROM t lımıt")
        #expect(format("ſelect a, b from t") == "ſelect a, b FROM t", "not a statement the formatter knows")
        // The equivalence check itself accepts only ASCII case changes, whatever is marked changeable.
        let lexer = SQLLexer("x ſa")
        let tokens = lexer.tokens()
        #expect(!SQLFormatter.equivalent(lexer: lexer, tokens: tokens, to: "x SA", caseChangeable: Set(tokens.indices), mode: .standard))
        #expect(SQLFormatter.equivalent(lexer: lexer, tokens: tokens, to: "X ſa", caseChangeable: Set(tokens.indices), mode: .standard))
    }

    // `user@host` is everyday MySQL (GRANT, CREATE USER, DEFINER=): the name and its `@host` stay glued.
    @Test func userAndHostStayGlued() {
        #expect(format("grant all on *.* to 'root'@'%'") == "GRANT ALL ON *.* TO 'root'@'%'")
        #expect(format("create definer='app'@'localhost' view v as select 1") == "CREATE definer = 'app'@'localhost' view v AS\nSELECT 1")
        #expect(format("create user `a`@`%`, \"b\"@localhost, c@'h'") == "CREATE user `a`@`%`, \"b\"@localhost, c@'h'")
        #expect(format("drop user 'a'@'h','b'@'h'") == "DROP user 'a'@'h', 'b'@'h'")
    }

    // A set operator needs a proven query after it. `except (x)` / `intersect (x)` after a derived table is its alias with
    // a column list (MySQL 8.0.19-8.0.30 read it so; aliases are case-sensitive on Linux): never re-cased or broken.
    @Test func setOperatorsNeedAQueryOperand() {
        #expect(format("select * from (select 1 a) except (x)") == "SELECT *\nFROM (\n  SELECT 1 a\n) except (x)")
        #expect(format("select * from (select 1 a) intersect (x)") == "SELECT *\nFROM (\n  SELECT 1 a\n) intersect (x)")
        #expect(format("select a from t except all (x)") == "SELECT a\nFROM t except ALL (x)")
        #expect(format("select a from t except (select a from u)") == "SELECT a\nFROM t\nEXCEPT (\n  SELECT a\n  FROM u\n)")
        #expect(format("select 1 intersect ((select 2))") == "SELECT 1\nINTERSECT ((\n  SELECT 2\n))")
        #expect(format("select 1 except all select 2") == "SELECT 1\nEXCEPT ALL\nSELECT 2")
        #expect(format("select 1 except distinct table t") == "SELECT 1\nEXCEPT DISTINCT TABLE t")
        #expect(format("select 1 intersect values row(1)") == "SELECT 1\nINTERSECT VALUES row(1)")
        #expect(format("select 1 except (with x as (select 1) select * from x)")
            == "SELECT 1\nEXCEPT (\n  WITH x AS (\n    SELECT 1\n  )\n  SELECT *\n  FROM x\n)")
        #expect(format("(select 1) except (select 2) order by 1") == "(\n  SELECT 1\n)\nEXCEPT (\n  SELECT 2\n)\nORDER BY 1")
    }

    // The options cannot make the formatter trap: an indent set after init is clamped like one given to init.
    @Test func optionsCannotTrap() {
        for (width, expected) in [(-1, 1), (0, 1), (Int.min, 1), (3, 3), (9, 8), (Int.max, 8)] {
            var options = SQLFormatOptions()
            options.indentWidth = width
            #expect(options.indentWidth == expected, "\(width)")
            #expect(SQLFormatOptions(indentWidth: width).indentWidth == expected, "\(width)")
            let indent = String(repeating: " ", count: expected)
            #expect(format("select a, b from t", options) == "SELECT\n\(indent)a,\n\(indent)b\nFROM t", "\(width)")
        }
    }

    // A comma that a line comment pushed to the start of a line takes the next item with it instead of standing alone.
    @Test func aCommaNeverStandsAloneAfterALineComment() {
        #expect(format("select a /* x */ -- y\n, b from t") == "SELECT\n  a /* x */ -- y\n  , b\nFROM t")
        #expect(format("select a -- y\n, b from t") == "SELECT\n  a -- y\n  , b\nFROM t")
        #expect(format("select 1 # c\n, 2") == "SELECT\n  1 # c\n  , 2")
        #expect(format("select a\n-- y\n, b, c from t") == "SELECT\n  a\n  -- y\n  , b,\n  c\nFROM t")
        #expect(format("create table t (a int -- c\n, b int)") == "CREATE TABLE t (\n  a INT -- c\n  , b INT\n)")
        #expect(format("insert into t values (1) -- c\n, (2)") == "INSERT INTO t\nVALUES\n  (1) -- c\n  , (2)")
    }

    // CRLF text stays CRLF. Line breaks inside strings are content and do not count; the `\r` that ends a `--` comment
    // belongs to the comment (the server ends it at `\n`), so the break after it adds only the `\n`.
    @Test func crlfTextStaysCrlf() throws {
        #expect(format("select a,\r\nb from t\r\n") == "SELECT\r\n  a,\r\n  b\r\nFROM t\r\n")
        #expect(format("select 1;\r\nselect 2") == "SELECT 1;\r\n\r\nSELECT 2")
        #expect(format("select 'x\r\ny', a from t") == "SELECT\n  'x\r\ny',\n  a\nFROM t")
        #expect(format("select a -- c\r\nfrom t\r\n") == "SELECT a -- c\r\nFROM t\r\n")
        #expect(format("select a, -- c\r\nb from t;\r\n# d\r\nselect 1") == "SELECT\r\n  a, -- c\r\n  b\r\nFROM t;\r\n\r\n# d\r\nSELECT 1")
        #expect(format("DELIMITER //\r\nselect a,b from t//\r\nDELIMITER ;\r\n") == "DELIMITER //\r\nSELECT\r\n  a,\r\n  b\r\nFROM t//\r\nDELIMITER ;\r\n")
        // A comment ending at a bare `\n` in CRLF text keeps it: a `\r` written before that `\n` would join the comment.
        #expect(format("select a, -- c\nb from t\r\n# d\n") == "SELECT\r\n  a, -- c\n  b\r\nFROM t\r\n  # d\n")
        for sql in ["select a,\r\nb from t\r\n", "select a, -- c\r\nb from t;\r\n# d\r\nselect 1", "select a, -- c\nb from t\r\n# d\n"] {
            let once = try #require(format(sql))
            #expect(format(once) == once, "\(sql)")
        }
        let text = "select 1;\r\nselect a,b from t"
        let edit = try #require(SQLFormatter.formatSelection(in: text, range: (text as NSString).range(of: "select a,b from t")))
        #expect(edit.replacement == "SELECT\r\n  a,\r\n  b\r\nFROM t")
    }

    // CASE structure needs a proof per statement: as many bare `end` words (every one, also next to `.`) as CASE keywords,
    // each closing the innermost CASE at its parenthesis depth. Token-by-token guesses whether an `end` is a name kept
    // regressing; when the proof fails, CASE, WHEN, THEN, ELSE and END stay exactly as written, with no CASE layout.
    @Test func caseStructureNeedsAStatementLevelProof() throws {
        #expect(format("select case when a then 1 when b then 2 end x, case when c then (case when d then 3 end) end from t") == """
            SELECT
              CASE
                WHEN a THEN 1
                WHEN b THEN 2
              END x,
              CASE WHEN c THEN (CASE WHEN d THEN 3 END) END
            FROM t
            """)
        // `end` as a column alias, a column, a table alias, a CTE and before `.`, next to CASE expressions.
        let unproven = [
            "select case when a then 1 else 2 end end from t": "SELECT case when a then 1 else 2 end end\nFROM t",
            "select case when a then end else 0 end from t": "SELECT case when a then end else 0 end\nFROM t",
            "select case when 1 = 1 then end.a else 0 end from (select 5 a) end":
                "SELECT case when 1 = 1 then end.a else 0 end\nFROM (\n  SELECT 5 a\n) end",
            "with end as (select 1 a) select case when a = 1 then 'x' when a = 2 then 'y' end from end":
                "WITH end AS (\n  SELECT 1 a\n)\nSELECT case when a = 1 then 'x' when a = 2 then 'y' end\nFROM end",
            "select end.x, case when a then 1 end from t end": "SELECT\n  end.x,\n  case when a then 1 end\nFROM t end",
            // An executable comment may hold a CASE or an END the lexer cannot see.
            "select case when a then 1 /*! end */ end from t": "SELECT case when a then 1 /*! end */ end\nFROM t",
            // An END outside the CASE's parentheses, a CASE left open.
            "select (case when a then 1) end from t": "SELECT (case when a then 1) end\nFROM t",
            "select case when a then 1": "SELECT case when a then 1",
        ]
        for (sql, expected) in unproven {
            #expect(format(sql) == expected, "\(sql)")
        }
        // A selection takes its statement's verdict: alone, `case … end` would be proven.
        let text = "select case when a then 1 else 2 end end from t"
        let edit = try #require(SQLFormatter.formatSelection(in: text, range: (text as NSString).range(of: "case when a then 1 else 2 end")))
        #expect(edit.replacement == "case when a then 1 else 2 end")
        // Statements are proven one by one.
        #expect(format("select case when a then 1 end; select end from t")
            == "SELECT CASE WHEN a THEN 1 END;\n\nSELECT end\nFROM t")
    }

    // Review #3: a CASE statement in a stored program holds `;`, so the proof is settled per statement as the splitter (and
    // the server) sees it, and the CASE words of compound statements and stored programs always stay as written: `END CASE`,
    // `END IF` and the bare `end` of BEGIN … END cannot be told from a CASE's END by counting. Here `end` is a table.
    @Test func caseWordsInStoredProgramsStayAsWritten() throws {
        let procedure = "DELIMITER //\nCREATE PROCEDURE p_end(v INT) BEGIN CASE v WHEN 1 THEN SELECT * FROM end; ELSE SELECT 2; END CASE; END//\nDELIMITER ;"
        let insert = "DELIMITER //\nCREATE PROCEDURE p_ins(v INT) BEGIN CASE v WHEN 1 THEN INSERT INTO end VALUES (1); ELSE SELECT 2; END CASE; END//\nDELIMITER ;"
        let block = "DELIMITER //\nCASE 1 WHEN 1 THEN SELECT * FROM end; END CASE//\nDELIMITER ;"
        for script in [procedure, insert, block] {
            let formatted = try #require(format(script), "\(script)")
            #expect(!formatted.contains("FROM END") && !formatted.contains("INTO END"), "\(formatted)")
            #expect(formatted.contains("CASE v WHEN 1 THEN") || formatted.contains("CASE 1 WHEN 1 THEN"), "\(formatted)")
            #expect(format(formatted) == formatted, "\(formatted)")
        }
        // Single-statement bodies of triggers, events and functions too.
        #expect(format("create trigger tr before insert on t for each row set new.a = case when new.b then 1 else 2 end")
            == "CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW SET new.a = case when new.b then 1 else 2 end")
        // A selection inside the procedure takes its statement's verdict, even without the BEGIN in it.
        let ns = procedure as NSString
        let edit = try #require(SQLFormatter.formatSelection(in: procedure, range: ns.range(of: "CASE v WHEN 1 THEN SELECT * FROM end")))
        #expect(edit.replacement.contains("FROM end") && edit.replacement.contains("CASE v WHEN 1 THEN"), "\(edit.replacement)")
        // Plain statements are still proven one by one.
        #expect(format("select case when a then 1 end x; select 2") == "SELECT CASE WHEN a THEN 1 END x;\n\nSELECT 2")
    }

    // Review #4: DELIMITER scripts are split as the session splits them: under NO_BACKSLASH_ESCAPES `'C:\'` ends at its
    // second quote, so the custom delimiters after it are delimiters.
    @Test func delimiterScriptsFollowTheSessionsBackslashMode() throws {
        let noEscapes = SQLFormatOptions(backslashEscapes: false)
        for script in ["DELIMITER ;;\nSELECT 'C:\\' AS d;;\nSELECT 2;;\nDELIMITER ;", "DELIMITER //\nSELECT 'C:\\' AS d//\nSELECT 2//\nDELIMITER ;"] {
            #expect(format(script, noEscapes) == script, "\(script)")
            #expect(SQLStatementSplitter.split(script, backslashEscapes: false).map(\.text) == ["SELECT 'C:\\' AS d", "SELECT 2"])
        }
        let edit = try #require(SQLFormatter.formatSelection(in: "select 'C:\\' as d; select a,b from t", range: NSRange(location: 0, length: 36),
                                                             options: noEscapes))
        #expect(edit.replacement == "SELECT 'C:\\' AS d;\n\nSELECT\n  a,\n  b\nFROM t")
    }

    // Review #5a: under ANSI_QUOTES `"…"` is a name in which a backslash does not escape; formatting must not touch the
    // string the server reads after it.
    @Test func ansiQuotesFollowTheSession() throws {
        let sql = "SELECT \"C:\\\" AS c, 'a\" ,   two  spaces'"
        #expect(format(sql, SQLFormatOptions(ansiQuotes: true)) == "SELECT\n  \"C:\\\" AS c,\n  'a\" ,   two  spaces'")
        #expect(format("select \"a  b\", 'c' from t", SQLFormatOptions(ansiQuotes: true)) == "SELECT\n  \"a  b\",\n  'c'\nFROM t")
        let lexer = SQLLexer("\"a\"\"b\"", ansiQuotes: true)
        #expect(lexer.tokens().map(\.kind) == [.quotedIdentifier])
        #expect(lexer.identifierValue(of: lexer.tokens()[0]) == "a\"b")
        #expect(SQLStatementSplitter.split("select \"a\\\"; select 2", ansiQuotes: true).count == 2)
        #expect(SQLStatementSplitter.split("select \"a\\\"; select 2").count == 1)
    }

    // Review #5b: before the session's sql_mode is known, text that some mode reads differently is not formatted; other
    // text is.
    @Test func anUnknownSessionModeRefusesModeDependentText() {
        let unknown = SQLFormatOptions(sessionModeKnown: false)
        for sql in ["select 'C:\\' as d, 1", "select \"a\" from t", "select `a\\b`, 'x' from t"] {
            #expect(SQLFormatter.dependsOnLexingMode(sql), "\(sql)")
            #expect(format(sql, unknown) == nil, "\(sql)")
            #expect(SQLFormatter.formatSelection(in: sql, range: NSRange(location: 0, length: 6), options: unknown) == nil, "\(sql)")
        }
        #expect(format("select 'it''s', `a`, b from t -- \"x\\", unknown) == "SELECT\n  'it''s',\n  `a`,\n  b\nFROM t -- \"x\\")
        #expect(!SQLFormatter.dependsOnLexingMode("select 'it''s', `a`, b from t -- \"x\\"))
        #expect(SQLLexingMode(sqlMode: "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES") == SQLLexingMode(backslashEscapes: false))
        #expect(SQLLexingMode(sqlMode: "REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI").ansiQuotes)
        #expect(SQLLexingMode(sqlMode: "ansi") == SQLLexingMode(ansiQuotes: true, unmodelledModes: ["ANSI"]), "ANSI also brings PIPES_AS_CONCAT")
        #expect(SQLLexingMode(sqlMode: "") == .standard)
    }

    // Review #5b, the proof: text that `dependsOnLexingMode` passes lexes and splits the same under every mode.
    @Test func textWithoutModeDependentTokensLexesTheSameInEveryMode() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["'", "\"", "`", "\\", "a", " ", ";", "--", " -- ", "#", "\n", "/*", "*/", "''", "\"\"", "x", "1"]
        var checked = 0
        for _ in 0..<20_000 {
            let text = (0..<Int.random(in: 1...14, using: &generator)).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined()
            guard !SQLFormatter.dependsOnLexingMode(text) else { continue }
            checked += 1
            let reference = SQLLexer(text).tokens()
            for mode in SQLLexingMode.all {
                #expect(SQLLexer(text, mode: mode).tokens().map(\.range) == reference.map(\.range), "\(text.debugDescription) \(mode)")
                #expect(SQLStatementSplitter.split(text, mode: mode).map(\.range) == SQLStatementSplitter.split(text).map(\.range),
                        "\(text.debugDescription) \(mode)")
            }
        }
        #expect(checked > 2_000)
    }

    // Final review A: sql_modes that change how SQL is read beyond NO_BACKSLASH_ESCAPES and ANSI_QUOTES (ORACLE, MSSQL,
    // PIPES_AS_CONCAT, IGNORE_SPACE, …) are not modelled: nothing is formatted while one is active.
    @Test func unmodelledSQLModesRefuseFormatting() {
        let oracle = SQLLexingMode(sqlMode: "PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ORACLE,NO_KEY_OPTIONS,NO_TABLE_OPTIONS,STRICT_TRANS_TABLES")
        #expect(oracle.unmodelledModes == ["IGNORE_SPACE", "ORACLE", "PIPES_AS_CONCAT"])
        #expect(oracle.ansiQuotes && oracle.backslashEscapes)
        var options = SQLFormatOptions()
        options.lexingMode = oracle
        #expect(options.unmodelledSQLModes == ["IGNORE_SPACE", "ORACLE", "PIPES_AS_CONCAT"])
        #expect(format("select a from t", options) == nil)
        #expect(SQLFormatter.formatSelection(in: "select a from t", range: NSRange(location: 0, length: 6), options: options) == nil)
        for mode in ["MSSQL", "DB2", "POSTGRESQL", "MAXDB", "ANSI", "HIGH_NOT_PRECEDENCE", "MYSQL40"] {
            #expect(!SQLLexingMode(sqlMode: "STRICT_TRANS_TABLES,\(mode)").unmodelledModes.isEmpty, "\(mode)")
        }
        #expect(SQLLexingMode(sqlMode: "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION").unmodelledModes.isEmpty)
        // MCP read-only sessions drop them all.
        #expect(SQLModes.affectsLexing("STRICT_TRANS_TABLES,ORACLE"))
        #expect(SQLModes.withoutLexerAffectingModes("PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ORACLE,NO_KEY_OPTIONS,STRICT_TRANS_TABLES")
            == "NO_KEY_OPTIONS,STRICT_TRANS_TABLES")
    }

    // Final review B: the app always sends UTF-8 and every connection is switched to utf8mb4; a session in another
    // character set (GBK, Shift-JIS: 0x5C can be the second byte of a character) reads the text differently, so nothing is
    // formatted. With the session state unknown, text that a character set or sql_mode could read differently (anything
    // outside ASCII, a backslash in a string, a double quote) is not formatted either.
    @Test func sessionCharsetsOtherThanUTF8RefuseFormatting() {
        for charset in ["utf8mb4", "UTF8MB3", "utf8", "ascii", "latin1"] {
            #expect(format("select a from t", SQLFormatOptions(sessionCharset: charset)) == "SELECT a\nFROM t", "\(charset)")
        }
        for charset in ["gbk", "sjis", "big5", "cp932", "gb18030", "utf16"] {
            #expect(format("select a from t", SQLFormatOptions(sessionCharset: charset)) == nil, "\(charset)")
        }
        let unknown = SQLFormatOptions(sessionModeKnown: false)
        #expect(format("select '中' from t", unknown) == nil)
        #expect(format("select `名` from t", unknown) == nil)
        #expect(format("select a from t -- 中", unknown) == "SELECT a\nFROM t -- 中")
    }

    // Review #6: only a real client DELIMITER command (start of a statement and a line, then its delimiter) makes a
    // DELIMITER script; a word `delimiter` elsewhere is a name, and formatting stays idempotent.
    @Test func onlyRealDelimiterCommandsCount() throws {
        let once = try #require(format("SELECT id\ndelimiter FROM t ;"))
        #expect(once == "SELECT id delimiter\nFROM t;")
        #expect(format(once) == once)
        #expect(!SQLStatementSplitter.usesDelimiterCommands("SELECT id\ndelimiter FROM t ;"))
        #expect(SQLStatementSplitter.usesDelimiterCommands("select 1;\nDELIMITER //\nselect 2//"))
    }

    // Look-aheads and nesting stay linear: unclosed parentheses, nested CASEs and an EXPLAIN prefix before thousands of
    // parentheses. The bound is for debug builds; `swift test -c release` checks the release bound.
    @Test func pathologicalNestingStaysLinear() throws {
        #if DEBUG
        let bound = Duration.seconds(10)
        #else
        let bound = Duration.milliseconds(500)
        #endif
        let inputs = [
            String(repeating: "select (", count: 50_000),
            "select " + String(repeating: "case when a then ", count: 20_000) + "1" + String(repeating: " end", count: 20_000),
            "explain " + String(repeating: "(", count: 20_000) + String(repeating: " select 1", count: 20_000),
            "select " + String(repeating: "f(a, ", count: 30_000) + "1" + String(repeating: ")", count: 30_000) + " from t",
        ]
        for input in inputs {
            let started = ContinuousClock.now
            _ = format(input)
            let elapsed = ContinuousClock.now - started
            #expect(elapsed < bound, "\(input.prefix(30))…: \(elapsed)")
        }
    }

    static let corpus = [
        "select a, b from t where x = 1 and y = 2 order by a",
        "select * from (select a from t) s where a in (select a from u)",
        "with x as (select 1), y as (select 2) select * from x join y on x.a = y.a",
        "select case when a then 1 when b then 2 else 3 end x from t; update t set a = 1, b = 2",
        "create table t (a int, b varchar(10), primary key (a)) engine=InnoDB partition by hash (a) partitions 4",
        "select 'a' -- c\n, b from t /* x */ where a between 1 and 2 and b = 1",
        "insert into t (a, b) values (1, 2), (3, 4) on duplicate key update b = values(b); delete from t where a = 1",
        "DELIMITER //\ncreate function f(x int) returns int deterministic begin return x + 1; end//\nDELIMITER ;\nselect f(1)",
        "select count (*), x'41', @'v', sum(a) over w from t window w as (order by a) for update",
    ]
}
