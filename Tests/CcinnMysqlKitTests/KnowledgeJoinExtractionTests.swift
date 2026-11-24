import Foundation
import Testing
@testable import CcinnMysqlKit

// Equi-joins of MySQL statements. Relationships from history and definitions are in KnowledgeHistoryMiningTests.swift.

private func describe(_ pair: JoinPair) -> String {
    func side(_ reference: TableReference, _ columns: [String]) -> String {
        (reference.database.map { $0 + "." } ?? "") + reference.table + "(" + columns.joined(separator: ",") + ")"
    }
    return side(pair.left, pair.leftColumns) + "=" + side(pair.right, pair.rightColumns)
}

/// Joins of `sql` as `db.table(columns)=table(columns)`; `columns` keys are `table` or `db.table` as written.
private func joins(_ sql: String, columns: [String: [String]] = [:]) -> [String] {
    SQLJoinExtractor.joins(in: sql, columnsOf: { (reference: TableReference) -> [String]? in
        columns[(reference.database.map { $0 + "." } ?? "") + reference.table]
    }).map(describe)
}

/// A small deterministic generator for the fuzz test (SplitMix64).
private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite("Knowledge inference: JOIN extraction")
struct KnowledgeInferenceJoinExtractorTests {
    @Test func onConditions() {
        #expect(joins("SELECT * FROM report r JOIN dsp d ON r.dsp_id = d.id") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report AS r LEFT OUTER JOIN dsp AS d ON d.id = r.dsp_id AND d.status = 1 WHERE r.dt = '2026-11-01'")
            == ["dsp(id)=report(dsp_id)"])
        #expect(joins("SELECT * FROM report JOIN dsp ON report.dsp_id = dsp.id") == ["report(dsp_id)=dsp(id)"], "unaliased tables")
        #expect(joins("SELECT * FROM a JOIN b ON a.x <=> b.y") == ["a(x)=b(y)"], "null-safe equality")
    }

    @Test func usingNeedsExactlyOnePriorTable() {
        #expect(joins("SELECT * FROM a JOIN b USING (k1, k2)") == ["a(k1,k2)=b(k1,k2)"])
        #expect(joins("SELECT * FROM a JOIN b USING (x) JOIN c USING (y)") == ["a(x)=b(x)"])
        #expect(joins("SELECT * FROM a, b JOIN c USING (k)").isEmpty)
        #expect(joins("SELECT * FROM (SELECT 1 AS k) d JOIN b USING (k)").isEmpty, "derived side")
    }

    @Test func implicitJoinsInWhere() {
        #expect(joins("SELECT * FROM report r, dsp d WHERE r.dsp_id = d.id AND r.dt = '2026-11-01'") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report r WHERE r.dsp_id = r.app_id").isEmpty, "one table")
    }

    @Test func compositeConditionsBecomeOnePair() {
        #expect(joins("SELECT * FROM report_crm_hour h JOIN report_crm_day d ON h.dt = d.dt AND d.app_id = h.app_id AND h.dt = d.dt")
            == ["report_crm_hour(dt,app_id)=report_crm_day(dt,app_id)"])
        #expect(joins("SELECT * FROM a JOIN b ON (a.x = b.y AND ((a.z) = (b.w)))") == ["a(x,z)=b(y,w)"])
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.x JOIN c ON a.y = c.y AND b.z = c.z") == ["a(x)=b(x)", "a(y)=c(y)", "b(z)=c(z)"])
    }

    @Test func aliasesAndQuotedNames() {
        #expect(joins("SELECT * FROM `crm`.`report` AS `r` JOIN dsp AS d ON `r`.`dsp_id` = d.`id`") == ["crm.report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM emp e JOIN emp m ON e.manager_id = m.id") == ["emp(manager_id)=emp(id)"], "self join")
    }

    @Test func databaseQualifiedNames() {
        #expect(joins("SELECT * FROM crm.report r JOIN admin.dsp d ON r.dsp_id = d.id") == ["crm.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM crm.report JOIN admin.dsp ON crm.report.dsp_id = admin.dsp.id") == ["crm.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM crm.report JOIN admin.dsp ON report.dsp_id = dsp.id") == ["crm.report(dsp_id)=admin.dsp(id)"])
    }

    @Test func eachSubqueryResolvesItsOwnAliases() {
        let nested = "SELECT * FROM report r WHERE r.dsp_id IN (SELECT d.id FROM dsp d JOIN dsp_owner r ON d.owner_id = r.id)"
        #expect(joins(nested) == ["dsp(owner_id)=dsp_owner(id)"])
        #expect(joins("SELECT * FROM report r WHERE EXISTS (SELECT 1 FROM dsp d WHERE d.id = r.dsp_id)") == ["dsp(id)=report(dsp_id)"],
                "a correlated condition reaches the enclosing query")
        #expect(joins("SELECT * FROM (SELECT r.dsp_id FROM report r JOIN dsp d ON r.dsp_id = d.id) x") == ["report(dsp_id)=dsp(id)"])
    }

    @Test func cteAndDerivedSidesAreSkipped() {
        #expect(joins("WITH t AS (SELECT dsp_id FROM report) SELECT * FROM t JOIN dsp d ON t.dsp_id = d.id").isEmpty)
        #expect(joins("WITH t AS (SELECT r.dsp_id FROM report r JOIN dsp d ON r.dsp_id = d.id) SELECT * FROM t") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM (SELECT dsp_id FROM report) x JOIN dsp d ON x.dsp_id = d.id").isEmpty)
        #expect(joins("CREATE VIEW v AS WITH c AS (SELECT * FROM a) SELECT * FROM c JOIN b ON c.x = b.y").isEmpty)
        #expect(joins("SELECT * FROM (WITH c AS (SELECT 1 AS x) SELECT * FROM c JOIN b ON c.x = b.y) q").isEmpty, "a nested CTE")
    }

    @Test func onlyColumnEqualitiesCount() {
        #expect(joins("SELECT * FROM a JOIN b ON a.x = 5").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = '5'").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = @v").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = NULL").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x > b.y").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y + 1").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y OR a.z = b.w").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON NOT a.x = b.y").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON CAST(a.x AS BIGINT) = b.y").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.dt BETWEEN b.start_dt AND b.end_dt AND a.id = b.a_id") == ["a(id)=b(a_id)"])
        #expect(joins("SELECT * FROM a JOIN b ON left(a.code, 2) = b.prefix AND a.id = b.a_id") == ["a(id)=b(a_id)"])
    }

    @Test func unqualifiedColumnsNeedExactlyOneOwner() {
        let known = ["report": ["dsp_id", "dt"], "dsp": ["id", "name"], "a": ["k"], "b": ["k", "k2"]]
        #expect(joins("SELECT * FROM report r JOIN dsp d ON dsp_id = id", columns: known) == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report r, dsp d WHERE dsp_id = d.id", columns: known) == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM a JOIN b ON k = b.k2", columns: known).isEmpty, "two tables have k")
        #expect(joins("SELECT * FROM a JOIN u ON k = u.k2", columns: known).isEmpty, "u's columns are unknown")
        #expect(joins("SELECT * FROM report r JOIN dsp d ON dsp_id = id").isEmpty, "nothing known")
    }

    @Test func commentsHintsAndDroppedCharacters() {
        #expect(joins("SELECT * FROM report r -- JOIN x ON r.a = x.b\nJOIN /* hint */ dsp d ON r.dsp_id /* = x.y */ = d.id")
            == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT /*!40001 SQL_NO_CACHE */ * FROM a /*! STRAIGHT_JOIN */ JOIN b ON a.x = b.y") == ["a(x)=b(y)"], "executable comments are not read")
        #expect(joins("SELECT * FROM a # JOIN x ON a.p = x.q\nJOIN b ON a.x = b.y") == ["a(x)=b(y)"], "# comments out the rest of the line in MySQL")
        #expect(joins("SELECT * FROM t$$ x JOIN b ON x.id = b.t_id WHERE x.s = '$$'") == ["t$$(id)=b(t_id)"])
    }

    @Test func everyStatementOfAScript() {
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y; SELECT * FROM c, d WHERE c.k = d.k;") == ["a(x)=b(y)", "c(k)=d(k)"])
        #expect(joins("INSERT INTO t SELECT * FROM a JOIN b ON a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("INSERT INTO t (c1, c2) SELECT a.x, b.y FROM a, b WHERE a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y WHERE a.k IN (SELECT a.k FROM a JOIN b ON a.x = b.y)") == ["a(x)=b(y)"],
                "repeated pairs once per statement")
        #expect(joins("SHOW TABLES; UPDATE t SET x = 1").isEmpty)
    }

    @Test func deepNestingIsIgnoredNotWalked() {
        let deep = String(repeating: "(SELECT * FROM a JOIN b ON a.x = b.y WHERE a.k IN ", count: 3_000) + String(repeating: ")", count: 3_000)
        #expect(joins("SELECT 1 FROM t WHERE t.k IN " + deep).isEmpty)
        let nested = "SELECT * FROM a WHERE a.k IN " + String(repeating: "(SELECT b.k FROM b JOIN c ON b.x = c.y WHERE b.k IN ", count: 20)
            + "(1)" + String(repeating: ")", count: 20)
        #expect(joins(nested) == ["b(x)=c(y)"])
    }

    @Test func hostileInputNeverCrashes() async {
        let found = await onDedicatedThread { () -> Int in
            var generator = SplitMix(state: 0x5EED)
            let vocabulary = [
                "SELECT", "FROM", "JOIN", "LEFT", "ON", "USING", "WHERE", "AND", "OR", "BETWEEN", "WITH", "AS", "IN", "EXISTS",
                "(", ")", "(", ")", ",", ";", ".", "=", "<=>", "a", "b", "t", "x.y", "a.x", "b.y", "`q`", "db.t", "5", "'s'",
                "--c\n", "/*", "*/", "[broadcast]", "[", "]", "#", "\\", "$$", "NULL", "*", "+", "\"", "`", "RECURSIVE",
                "SELECT * FROM a JOIN b ON a.x = b.y", "FROM a, b WHERE a.x = b.y", "USING (", "WITH c AS (",
            ]
            var total = 0
            for _ in 0..<600 {
                let length = Int(generator.next() % 80)
                var parts: [String] = []
                for _ in 0..<length { parts.append(vocabulary[Int(generator.next() % UInt64(vocabulary.count))]) }
                total += SQLJoinExtractor.joins(in: parts.joined(separator: " "), columnsOf: { (_: TableReference) -> [String]? in ["x", "y"] }).count
            }
            return total
        }
        #expect(found > 0)
    }
}

@Suite("JOIN extraction from MySQL-printed definitions")
struct MySQLPrintedDefinitionTests {
    // information_schema.VIEWS prints every join in parentheses, with backquoted, database-qualified names.
    @Test func parenthesisedJoinTrees() {
        let definition = "select `r`.`dt` AS `dt`,`d`.`name` AS `dsp_name` from (`kb_demo`.`report_crm_hour` `r` join `kb_demo`.`dsp` `d` "
            + "on((`r`.`dsp_id` = `d`.`id`))) group by `r`.`dt`,`d`.`name`"
        #expect(joins(definition) == ["kb_demo.report_crm_hour(dsp_id)=kb_demo.dsp(id)"])
        let nested = "select 1 AS `1` from ((`a` join `b` on((`a`.`x` = `b`.`y`))) join `c` on((`b`.`z` = `c`.`z`)))"
        #expect(joins(nested) == ["a(x)=b(y)", "b(z)=c(z)"])
    }
}
