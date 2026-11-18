import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Final review, item 9, per server version: the reviewed lists of native functions and privileges must fit the server.
/// A new version that adds a function to its help tables or a privilege to SHOW PRIVILEGES fails here until it is reviewed.
@Suite("Native functions and privileges of this server version", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct NativeFunctionIntegrationTests {
    private func session(_ target: IntegrationEnvironment.Target) async throws -> (MySQLClient, SQLSession) {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        try await DemoSchema.load(into: admin)
        return (admin, admin.openSession(database: "shop"))
    }

    // Every allowed name is a native here: `SELECT name()` inside a database does not look for a stored function (1305/1630).
    @Test(arguments: IntegrationEnvironment.targets)
    func allowedFunctionsAreNativeOnThisServer(target: IntegrationEnvironment.Target) async throws {
        let (admin, session) = try await session(target)
        var resolvedAsStored: [String] = []
        for name in SQLNativeFunctions.allowed(for: target.flavor).sorted() {
            do {
                _ = try await session.run("SELECT \(name)() AS r")
            } catch let error as MySQLError where [1305, 1630, 1046].contains(error.code ?? 0) {
                resolvedAsStored.append(name)
            } catch {
                // A native: wrong number of arguments, or a syntax error for a name the grammar parses.
            }
        }
        #expect(resolvedAsStored.isEmpty, "\(target.label): not native here: \(resolvedAsStored)")
        // Negative control: an unknown name does look for a stored function.
        let unknown = await #expect(throws: MySQLError.self) { _ = try await session.run("SELECT ccinn_no_such_function() AS r") }
        #expect(unknown?.code == 1305, "\(target.label): \(String(describing: unknown))")
        await session.close()
        await admin.close()
    }

    // Every function topic of this server's help tables is reviewed: allowed, denied or not callable.
    @Test(arguments: IntegrationEnvironment.targets)
    func helpTableFunctionsAreReviewed(target: IntegrationEnvironment.Target) async throws {
        let (admin, session) = try await session(target)
        let rows = try await session.run("""
            SELECT t.name FROM mysql.help_topic t JOIN mysql.help_category c USING (help_category_id)
            WHERE c.name LIKE '%Function%' OR c.name LIKE '%Operator%' OR c.name IN ('GTID', 'XML', 'WKT', 'MBR', 'Geographic Features', 'Components')
            """).flatMap(\.rows).compactMap { $0.first ?? nil }
        let names = Set(rows.compactMap(Self.functionName))
        #expect(names.count > 100, "\(target.label): help tables look empty (\(names.count))")
        let unreviewed = names.subtracting(SQLNativeFunctions.reviewed).sorted()
        #expect(unreviewed.isEmpty, "\(target.label): review these functions: \(unreviewed)")
        await session.close()
        await admin.close()
    }

    // Every privilege the server lists is reviewed (static, harmless or privileged).
    @Test(arguments: IntegrationEnvironment.targets)
    func privilegesAreReviewed(target: IntegrationEnvironment.Target) async throws {
        let (admin, session) = try await session(target)
        let names = Set(try await session.run("SHOW PRIVILEGES").flatMap(\.rows).compactMap { $0.first ?? nil }.map { $0.uppercased() })
        #expect(names.contains("SELECT"), "\(target.label): \(names)")
        let unreviewed = names.subtracting(AccountPrivileges.reviewedPrivileges).sorted()
        #expect(unreviewed.isEmpty, "\(target.label): review these privileges: \(unreviewed)")
        await session.close()
        await admin.close()
    }

    /// `IF FUNCTION`, `GROUP\_CONCAT` and `BINARY OPERATOR` as plain names; topics that are not a single name (`!=`, `IS NOT
    /// NULL`) are dropped.
    static func functionName(_ topic: String) -> String? {
        var name = topic.replacingOccurrences(of: "\\_", with: "_").trimmingCharacters(in: .whitespaces)
        for suffix in [" FUNCTION", " Function", " OPERATOR"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic),
              name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && $0.properties.isAlphabetic) || ("0"..."9").contains($0) }) else { return nil }
        return name.uppercased()
    }
}
