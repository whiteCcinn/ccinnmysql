import Foundation
import MySQLKit
import Testing
@testable import CcinnMysqlKit

/// Completion of table names while they are typed: the name at the cursor, table positions, ranking and narrowing
/// (fix-completion-accuracy).
@Suite("Completion accuracy")
struct CompletionAccuracyTests {
    static let tables = ["users", "user_orders", "user_profile", "orders", "order_items", "status_log", "user", "order",
                         "payment_record", "audit_user_session", "2024_report", "crm_contact", "crm_pipeline"]
    static let schema = SchemaSnapshot(
        currentDatabase: "shop", databases: ["shop", "ads"],
        objectsByDatabase: ["shop": tables.map { .init(name: $0, kind: .table) }, "ads": [.init(name: "impressions", kind: .table)]])

    /// `|` marks the cursor.
    static func complete(_ textWithCursor: String, schema: SchemaSnapshot = schema) -> CompletionResult {
        let cursor = (textWithCursor as NSString).range(of: "|").location
        let text = textWithCursor.replacingOccurrences(of: "|", with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, schema: schema)
    }

    static func labels(_ textWithCursor: String) -> [String] { complete(textWithCursor).items.map(\.label) }

    static func isTablePosition(_ textWithCursor: String) -> Bool {
        let result = complete(textWithCursor)
        return result.expectsObjectName && result.items.contains { $0.label == "users" }
    }

    // MARK: The name at the cursor

    @Test func aBackQuotedNameKeepsItsPrefixAndIsCompletedBackQuoted() throws {
        let result = Self.complete("SELECT * FROM `us|`")
        #expect(result.prefix == "us")
        #expect(result.replacementRange == 14..<18, "the whole name, both back-quotes included")
        let users = try #require(result.items.first { $0.label == "users" })
        #expect(users.insertText == "`users`")
        #expect(!result.items.contains { $0.label == "orders" })
    }

    @Test func anUnterminatedBackQuoteIsCompletedBackQuoted() throws {
        let result = Self.complete("SELECT * FROM `us|")
        #expect(result.prefix == "us")
        #expect(result.replacementRange == 14..<17)
        #expect(try #require(result.items.first { $0.label == "users" }).insertText == "`users`")
    }

    @Test func emptyBackQuotesListEveryTable() {
        let result = Self.complete("SELECT * FROM `|`")
        #expect(result.prefix.isEmpty)
        #expect(result.expectsObjectName)
        #expect(result.replacementRange == 14..<16)
        #expect(result.items.contains { $0.label == "orders" && $0.insertText == "`orders`" })
    }

    @Test func theWholeNameUnderTheCursorIsReplaced() {
        let result = Self.complete("SELECT * FROM us|ers WHERE id = 1")
        #expect(result.prefix == "us")
        #expect(result.replacementRange == 14..<19)
        #expect(result.items.first?.label == "user")
        #expect(!result.items.contains { $0.label == "orders" })
    }

    @Test func anAllDigitPrefixCompletesNamesOnlyWhereANameFollows() {
        #expect(Self.labels("SELECT * FROM 2024|") == ["2024_report"])
        #expect(Self.complete("SELECT * FROM 2024|").replacementRange == 14..<18)
        #expect(Self.complete("SELECT * FROM orders LIMIT 10|").items.isEmpty)
        #expect(Self.complete("SELECT * FROM orders WHERE id = 2024|").items.isEmpty)
    }

    // MARK: Table positions

    @Test func everyJoinIsATablePosition() {
        for text in ["SELECT * FROM orders o STRAIGHT_JOIN us|", "SELECT * FROM orders o LEFT OUTER JOIN us|",
                     "SELECT * FROM orders NATURAL JOIN us|", "SELECT * FROM orders o JOIN users u ON o.id = u.id JOIN us|"] {
            #expect(Self.isTablePosition(text), "\(text)")
        }
    }

    @Test func tableListsOfLockAndFlush() {
        for text in ["LOCK TABLES us|", "LOCK TABLES orders READ, us|", "lock tables orders write, users read, |",
                     "FLUSH TABLES us|", "FLUSH TABLES orders, us|"] {
            #expect(Self.isTablePosition(text), "\(text)")
        }
        for text in ["SHOW TABLES |", "SHOW TABLES LIKE 'u%' |", "UNLOCK TABLES |"] {
            #expect(!Self.isTablePosition(text), "\(text)")
        }
    }

    @Test func onNamesATableInIndexTriggerAndGrantStatements() {
        for text in ["CREATE INDEX i ON us|", "CREATE UNIQUE INDEX i ON us|", "DROP INDEX i ON us|",
                     "CREATE TRIGGER t BEFORE INSERT ON us|", "GRANT SELECT ON us|", "REVOKE ALL ON us|"] {
            #expect(Self.isTablePosition(text), "\(text)")
        }
        for text in ["SELECT * FROM orders o JOIN users u ON |", "CREATE VIEW v AS SELECT * FROM orders o JOIN users u ON |"] {
            #expect(!Self.isTablePosition(text), "\(text)")
        }
    }

    // Review #3: `ON` names a table only in the header of CREATE/DROP INDEX and CREATE TRIGGER.
    @Test func onInAForeignKeyOrAJoinIsNotATablePosition() {
        for text in ["CREATE TABLE c (id INT, pid INT, INDEX idx_pid (pid), FOREIGN KEY (pid) REFERENCES parent (id) ON |",
                     "CREATE TRIGGER trg AFTER INSERT ON orders FOR EACH ROW UPDATE stock s JOIN items i ON |",
                     "CREATE TABLE t2 AS SELECT * FROM orders FORCE INDEX (p) JOIN items i ON |"] {
            #expect(!Self.complete(text).expectsObjectName, "\(text)")
        }
        #expect(Self.isTablePosition("CREATE INDEX i USING BTREE ON us|"))
        #expect(Self.isTablePosition("CREATE DEFINER = CURRENT_USER TRIGGER t BEFORE UPDATE ON us|"))
    }

    @Test func explainAndDescribeOfferTablesAndStatements() {
        #expect(Self.isTablePosition("EXPLAIN us|"))
        let labels = Self.labels("EXPLAIN |")
        #expect(labels.contains("users"))
        #expect(labels.contains("SELECT"))
        #expect(Self.labels("EXPLAIN SEL|").first == "SELECT")
        #expect(Self.labels("DESCRIBE us|").first == "user")
        #expect(!Self.isTablePosition("SELECT * FROM orders ORDER BY id DESC |"))
    }

    @Test func aNewNameFollowsRenameTo() {
        let result = Self.complete("RENAME TABLE orders TO |")
        #expect(!result.expectsObjectName)
        #expect(Set(result.items.map(\.label)) == ["shop", "ads"], "only databases, to qualify the new name")
        #expect(Self.complete("RENAME TABLE orders TO u|").items.isEmpty)
        #expect(Self.isTablePosition("RENAME TABLE orders TO new_orders, us|"))
    }

    @Test func fromInsideExtractOrTrimIsNotATablePosition() {
        for text in ["SELECT EXTRACT(YEAR FROM |", "SELECT TRIM(BOTH 'x' FROM |", "SELECT SUBSTRING(name FROM |",
                     "SELECT POSITION('a' IN name), EXTRACT(DAY FROM |"] {
            #expect(!Self.isTablePosition(text), "\(text)")
        }
        #expect(Self.isTablePosition("SELECT * FROM (SELECT * FROM us|"))
        #expect(Self.isTablePosition("SELECT EXTRACT(YEAR FROM created_at) FROM us|"))
        // Scope: the column inside EXTRACT is not a table.
        let scope = CompletionEngine.scopeTables(tokens: SQLLexer("SELECT EXTRACT(YEAR FROM created_at) FROM orders").tokens(),
                                                 lexer: SQLLexer("SELECT EXTRACT(YEAR FROM created_at) FROM orders"), schema: Self.schema)
        #expect(scope.map(\.table) == ["orders"])
    }

    @Test func cteNamesAreTables() {
        #expect(Self.labels("WITH recent AS (SELECT 1 AS x) SELECT * FROM rec|").first == "recent")
        #expect(Self.labels("WITH RECURSIVE r AS (SELECT 1 AS n) SELECT * FROM |").contains("r"))
        #expect(Self.complete("WITH recent AS (SELECT 1 AS x) SELECT * FROM rec|").items.first?.detail == "CTE")
    }

    // MARK: Ranking

    @Test func prefixMatchesComeFirstShortestFirst() {
        #expect(Self.labels("SELECT * FROM us|") == ["user", "users", "user_orders", "user_profile", "audit_user_session"])
        #expect(Self.labels("SELECT * FROM ord|").prefix(4) == ["order", "orders", "order_items", "user_orders"])
    }

    @Test func scatteredLettersDoNotMatch() {
        #expect(!Self.labels("SELECT * FROM us|").contains("status_log"), "`us` inside `status` is not a match for two letters")
        #expect(Self.labels("SELECT * FROM ordit|") == ["order_items"], "letters in order from a word start still match")
        #expect(Self.labels("SELECT * FROM ecord|") == ["payment_record"], "a longer substring matches")
    }

    @Test func emptyPrefixKeepsNaturalOrder() {
        let schema = SchemaSnapshot(currentDatabase: "s", databases: ["s"],
                                    objectsByDatabase: ["s": ["t10", "t2", "t1", "a"].map { .init(name: $0, kind: .table) }])
        #expect(Self.complete("SELECT * FROM |", schema: schema).items.map(\.label) == ["a", "t1", "t2", "t10", "s"])
    }

    @Test func topKMatchesAFullSort() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let values = (0..<Int.random(in: 0...300, using: &generator)).map { _ in Int.random(in: 0...60, using: &generator) }
            for k in [0, 1, 7, 200, 400] {
                #expect(TopK.select(values, count: k, by: <) == Array(values.sorted().prefix(k)))
            }
        }
    }

    @Test func rankingStaysLinear() async {
        let growth = await measureGrowth(size: 4_000, make: { count -> CompletionResult in
            let objects = (0..<count).map { SchemaSnapshot.ObjectEntry(name: "tbl_\($0 % 97)_report_\($0)", kind: .table) }
            let schema = SchemaSnapshot(currentDatabase: "big", databases: ["big"], objectsByDatabase: ["big": objects])
            return CompletionEngine.complete(text: "SELECT * FROM ", cursor: 14, schema: schema)
        }, run: { result in result.narrowed(in: "SELECT * FROM t" as NSString, cursor: 15)?.items.count ?? 0 })
        #expect(growth.isLinear, "\(growth)")
    }

    // MARK: Narrowing

    @Test func narrowingRanksTheWholePoolForTheNameAtTheCursor() throws {
        var objects = (0..<5_000).map { SchemaSnapshot.ObjectEntry(name: "tbl_\($0)", kind: .table) }
        objects.append(.init(name: "zz_last", kind: .table))
        let schema = SchemaSnapshot(currentDatabase: "big", databases: ["big"], objectsByDatabase: ["big": objects])
        let opened = CompletionEngine.complete(text: "SELECT * FROM ", cursor: 14, schema: schema)
        #expect(opened.items.count == CompletionEngine.defaultLimit)
        #expect(!opened.items.contains { $0.label == "zz_last" })
        let narrowed = try #require(opened.narrowed(in: "SELECT * FROM zz" as NSString, cursor: 16))
        #expect(narrowed.items.map(\.label) == ["zz_last"], "items beyond the first 200 are still candidates")
        #expect(narrowed.prefix == "zz")
        #expect(narrowed.replacementRange == 14..<16)
        let deeper = try #require(opened.narrowed(in: "SELECT * FROM tbl_499" as NSString, cursor: 21))
        #expect(deeper.items.first?.label == "tbl_499")
    }

    // Review #2: digits typed where a value goes are a number, also when the list was opened before them.
    @Test func narrowingKeepsDigitsANumberWhereAValueGoes() throws {
        let columns = ["col_2024", "ret_7d", "x"].enumerated().map {
            ColumnInfo(name: $1, ordinal: $0 + 1, dataType: "int", columnType: "int", isNullable: true)
        }
        let schema = SchemaSnapshot(currentDatabase: "shop", databases: ["shop"], objectsByDatabase: ["shop": [.init(name: "t", kind: .table)]],
                                    columnsByTable: [TableKey(database: "shop", table: "t"): columns])
        let opened = Self.complete("SELECT * FROM t WHERE x = |", schema: schema)
        for typed in ["20", "7", "2024"] {
            let text = "SELECT * FROM t WHERE x = \(typed)" as NSString
            #expect(opened.narrowed(in: text, cursor: text.length)?.items.isEmpty == true, "\(typed)")
        }
        let table = Self.complete("SELECT * FROM |")
        #expect(table.narrowed(in: "SELECT * FROM 2024" as NSString, cursor: 18)?.items.map(\.label) == ["2024_report"])
    }

    @Test func aShiftedResultNarrowsInTheWholeText() throws {
        let statement = Self.complete("SELECT * FROM |")
        let prefix = "SELECT 1;\n"
        let shifted = statement.shifted(by: (prefix as NSString).length)
        #expect(shifted.replacementRange == 24..<24)
        let narrowed = try #require(shifted.narrowed(in: (prefix + "SELECT * FROM crm_p") as NSString, cursor: 29))
        #expect(narrowed.replacementRange == 24..<29)
        #expect(narrowed.items.map(\.label) == ["crm_pipeline"])
    }

    @Test func narrowingFollowsBackspaceAndEndsWithTheName() throws {
        let opened = Self.complete("SELECT * FROM crm|")
        let shorter = try #require(opened.narrowed(in: "SELECT * FROM cr" as NSString, cursor: 16))
        #expect(shorter.items.contains { $0.label == "crm_contact" })
        #expect(opened.narrowed(in: "SELECT * FROM " as NSString, cursor: 14)?.items.contains { $0.label == "orders" } == true,
                "back to an empty name where a table must follow: every table")
        #expect(opened.narrowed(in: "SELECT * FROM" as NSString, cursor: 13) == nil, "the cursor left the name")
        #expect(opened.narrowed(in: "SELECT * FROM crm " as NSString, cursor: 18) == nil, "a space ended the name")
        #expect(opened.narrowed(in: "SELECT * FROM crm." as NSString, cursor: 18) == nil, "a dot starts a member name")
    }

    @Test func narrowingReplacesTheWholeNameIncludingTheRestAfterTheCursor() throws {
        let opened = Self.complete("SELECT * FROM |")
        let narrowed = try #require(opened.narrowed(in: "SELECT * FROM crm_pcon WHERE 1" as NSString, cursor: 19))
        #expect(narrowed.prefix == "crm_p")
        #expect(narrowed.replacementRange == 14..<22)
        #expect(narrowed.items.map(\.label) == ["crm_pipeline"])
    }

    @Test func narrowingInsideBackQuotes() throws {
        let opened = Self.complete("SELECT * FROM `|`")
        let narrowed = try #require(opened.narrowed(in: "SELECT * FROM `crm_p`" as NSString, cursor: 20))
        #expect(narrowed.prefix == "crm_p")
        #expect(narrowed.replacementRange == 14..<21)
        #expect(narrowed.items.map(\.insertText) == ["`crm_pipeline`"])
        #expect(opened.narrowed(in: "SELECT * FROM crm" as NSString, cursor: 17) == nil, "the back-quote was deleted")
    }

    @Test func aPlainNameDoesNotNarrowIntoABackQuotedOne() {
        let opened = Self.complete("SELECT * FROM |")
        #expect(opened.narrowed(in: "SELECT * FROM `us" as NSString, cursor: 17) == nil, "a back-quote starts a new kind of name")
    }
}
