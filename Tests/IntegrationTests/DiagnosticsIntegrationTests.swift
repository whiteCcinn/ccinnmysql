import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Real MySQL / MariaDB error messages, through the app's own client, mark the text the user wrote.
@Suite("Error diagnostics integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct DiagnosticsIntegrationTests {
    /// Statements as written, the expected marker between ⟦ ⟧. Run with `shop` as the session database.
    static let cases: [String] = [
        "SELECT 1 FORM ⟦shop⟧.orders",
        "SELECT 1 FROM shop.orders ⟦WHERE⟧",
        "SELECT * FROM shop.orders WHERE id = ⟦=⟧ 1",
        "SELECT 1 FROM shop.orders WHERE id = 1 ⟦1⟧",
        "SELECT COUNT(1 ⟦FROM⟧ shop.orders",
        "SELECT id,\n  status\nFROM shop.orders\nWHER ⟦id⟧ = 1",
        "SELECT 'a\nb' FORM ⟦t⟧",
        "SELECT 1 FROM shop.orders\r\nWHER ⟦id⟧ = 1",
        "SELECT 1" + String(repeating: "\n", count: 1500) + "FORM ⟦shop⟧.orders",
        "SELECT '🇲🇾', 1 FORM ⟦shop⟧.orders",
        "SELECT 1 FORM ⟦ab🇲🇲🇲⟧",
        "SELECT 1 FORM ⟦" + String(repeating: "吉", count: 40) + "⟧",
        "SELECT 1 FORM ⟦col0⟧ " + (1..<40).map { "col\($0)" }.joined(separator: " "),
        "SELECT 1 ⟦/*⟧ x",
        "SELECT * FROM shop.orders ⟦/*⟧ note",
        "SELECT ⟦'abc FROM shop.orders⟧",
        "SELECT ⟦nosuch⟧ FROM shop.orders",
        "SELECT ⟦吉⟧ FROM shop.orders",
        "SELECT ⟦`nosuch col`⟧ FROM shop.orders",
        "SELECT * FROM shop.orders o WHERE ⟦o.nosuch⟧ = 1",
        "SELECT ⟦id⟧ FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id",
        "SELECT o.id FROM shop.orders o JOIN shop.customers c ON c.id = o.customer_id WHERE ⟦id⟧ = 1",
        "SELECT status FROM shop.orders GROUP BY ⟦nosuch⟧",
        "SELECT * FROM ⟦shop.nosuch_table⟧",
        "SELECT * FROM ⟦nosuch_table⟧",
        "SELECT ⟦nosuch_fn⟧(1)",
        "CALL ⟦shop.nosuch_proc⟧()",
        "SELECT ⟦shop.fn_order_total⟧()",
        "SELECT ⟦@@nosuch_var⟧",
        "ALTER TABLE shop.orders ADD INDEX (⟦nosuch⟧)",
    ]

    /// The statement without the markers, and the marked UTF-16 range.
    static func parse(_ marked: String) -> (sql: String, range: Range<Int>) {
        let open = (marked as NSString).range(of: "⟦").location
        let sql = marked.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
        let close = (marked as NSString).range(of: "⟧").location - 1
        return (sql, open..<close)
    }

    private func failure(_ session: SQLSession, _ sql: String) async -> (message: String, code: Int?)? {
        do {
            _ = try await session.run(sql)
            return nil
        } catch let error as MySQLError {
            return (error.message, error.code)
        } catch {
            return nil
        }
    }

    private func marked(_ text: String, _ range: Range<Int>?) -> String? {
        guard let range else { return nil }
        return String(decoding: Array(text.utf16)[range], as: UTF16.self)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func locatesRealErrors(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { await client.close() } }
        try await DemoSchema.load(into: client)
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        for annotated in Self.cases {
            let (sql, expected) = Self.parse(annotated)
            let (message, code) = try #require(await failure(session, sql), "\(sql.prefix(60)) should fail")
            let range = SQLErrorLocator.range(in: sql, error: SQLServerError.parse(message, code: code))
            #expect(range == expected, "\(target.label): \(sql.prefix(70)) → \(message) marked \(marked(sql, range) ?? "nothing")")
        }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func mapsExplainAndAutoLimitBack(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { await client.close() } }
        try await DemoSchema.load(into: client)
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }

        let source = "SELECT 1 FORM shop.orders"
        for prefix in ["EXPLAIN FORMAT=JSON ", "EXPLAIN "] {
            let (message, code) = try #require(await failure(session, prefix + source))
            let mapping = SQLExecutedTextMapping(prefixLength: prefix.utf16.count)
            #expect(marked(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: mapping,
                                                         error: SQLServerError.parse(message, code: code))) == "shop")
        }

        // The LIMIT lands right after WHERE, where the server reports the error.
        let unfinished = "SELECT 1 FROM shop.orders WHERE -- todo"
        let limited = AutoLimit.apply(to: unfinished, limit: 1000)
        let (message, code) = try #require(await failure(session, limited.sql))
        #expect(marked(unfinished, SQLErrorLocator.range(in: unfinished, executed: limited.sql,
                                                         mapping: SQLExecutedTextMapping(insertion: limited.insertion),
                                                         error: SQLServerError.parse(message, code: code))) == "WHERE")
    }
}
