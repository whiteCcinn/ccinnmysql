import Foundation
import Testing
@testable import CcinnMysqlKit

/// The Data tab's row filter: a condition that can only narrow the rows (add-data-paging-and-sort).
@Suite("Table filter")
struct TableFilterTests {
    private func accepted(_ text: String) throws -> TableFilter {
        guard case let .success(filter?) = TableFilter.parse(text) else { throw Failure(text) }
        return filter
    }

    private func refusal(_ text: String) -> String? {
        if case let .failure(error) = TableFilter.parse(text) { return error.message }
        return nil
    }

    private struct Failure: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    @Test func conditionsAreKeptAsTyped() throws {
        #expect(try accepted("geo = 'US'").condition == "geo = 'US'")
        #expect(try accepted("  WHERE  geo = 'US' and channel_id in (33, 52) ").condition == "geo = 'US' and channel_id in (33, 52)")
        #expect(try accepted("name LIKE '%;%'").condition == "name LIKE '%;%'", "a semicolon in a string is text")
        #expect(try accepted("id IN (SELECT id FROM t2 WHERE x > 1 ORDER BY id LIMIT 3)").condition.hasPrefix("id IN"),
                "clauses inside parentheses belong to a subquery")
        #expect(try accepted("`order` = 1 OR status = 'paid'").sql == "(`order` = 1 OR status = 'paid')")
        #expect(try accepted("lock = 1 AND for_date > '2026-01-01'").condition.hasPrefix("lock"), "LOCK alone may be a column")
    }

    @Test func aTrailingLineCommentEndsBeforeTheClosingParenthesis() throws {
        #expect(try accepted("a = 1 -- only paid").sql == "(a = 1 -- only paid\n)")
        #expect(try accepted("a = 1 # note").sql == "(a = 1 # note\n)")
    }

    @Test func nothingTypedIsNoFilter() {
        for text in ["", "   ", "\n", "WHERE", " where "] {
            guard case .success(nil) = TableFilter.parse(text) else {
                Issue.record("\(text.debugDescription) should be no filter")
                continue
            }
        }
    }

    @Test func whatCouldChangeTheQueryIsRefused() {
        let refused = ["1=1; DROP TABLE t", "a = 1) OR (1=1", "(a = 1", "a = 1)", "a = 1 ORDER BY id", "a = 1 LIMIT 5",
                       "a = 1 UNION SELECT 1", "a = 'x", "a = 1 /* x", "/*!50000 1=1*/", "a = 1 INTO OUTFILE '/tmp/x'",
                       "a = 1 FOR UPDATE", "a = 1 GROUP BY a", "a = 1 HAVING a > 0", "a = 1 LOCK IN SHARE MODE", "a = `x",
                       "a = 1 WINDOW w AS ()"]
        for text in refused {
            #expect(refusal(text) != nil, "\(text)")
        }
        #expect(refusal("1=1; DROP TABLE t")?.contains(";") == true)
        #expect(refusal("a = 1 ORDER BY id")?.contains("ORDER") == true)
    }
}
