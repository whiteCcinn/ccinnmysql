import Foundation
@testable import MySQLKit

/// Loads `scripts/seed-demo.sql` (with its DELIMITER blocks) into a server.
enum DemoSchema {
    static var scriptURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/seed-demo.sql")
    }

    /// Minimal DELIMITER-aware splitter for the seed script (the app has a full one in CcinnMysqlKit).
    static func statements() throws -> [String] {
        let text = try String(contentsOf: scriptURL, encoding: .utf8)
        var statements: [String] = []
        var delimiter = ";"
        var current = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("DELIMITER ") {
                delimiter = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("--") || (trimmed.isEmpty && current.isEmpty) { continue }
            current += line + "\n"
            if trimmed.hasSuffix(delimiter) {
                var statement = current.trimmingCharacters(in: .whitespacesAndNewlines)
                statement.removeLast(delimiter.count)
                statements.append(statement)
                current = ""
            }
        }
        return statements
    }

    /// Seeds once per server per test run.
    static func load(into client: MySQLClient) async throws {
        if try await client.execute("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'shop'").scalar == "1",
           try await client.execute("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'shop'").scalar.flatMap(Int.init) ?? 0 >= 10 {
            return
        }
        let session = client.openSession()
        defer { Task { await session.close() } }
        for statement in try statements() {
            _ = try await session.run(statement)
        }
    }
}
