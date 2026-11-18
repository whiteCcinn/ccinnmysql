import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Final review B, end to end: a server whose `init_connect` switches new connections to GBK (it skips accounts with
/// SUPER, so it hits exactly the least-privileged accounts recommended for AI). In GBK, the 0x5C after `中` (E4 B8 AD)
/// is part of a character, so `'中\\'` ends one character later than the app and the read-only guard see it.
///
/// Runs against a throwaway container only:
/// `docker run -d --name ccinnmysql-it-gbk -p 127.0.0.1:13398:3306 -e MYSQL_ROOT_PASSWORD=ccinn-root-pw mysql:8.4 --init-connect='SET NAMES gbk'`,
/// then `CCINNMYSQL_IT=1 CCINNMYSQL_IT_GBK_PORT=13398 swift test --filter GBKCharsetIntegrationTests`, then remove it.
@Suite("GBK init_connect (throwaway container)",
       .enabled(if: ProcessInfo.processInfo.environment["CCINNMYSQL_IT_GBK_PORT"] != nil && MCPProcess.binaryExists), .serialized)
struct GBKCharsetIntegrationTests {
    static var target: IntegrationEnvironment.Target {
        let port = Int(ProcessInfo.processInfo.environment["CCINNMYSQL_IT_GBK_PORT"] ?? "") ?? 13398
        return IntegrationEnvironment.Target(label: "MySQL 8.4 init_connect GBK", port: port, flavor: .mysql, offersTLS: true,
                                             container: "ccinnmysql-it-gbk")
    }

    /// Two strings to the guard; in GBK one string, then INTO @v and a comment.
    static let intoPayload = "SELECT '中\\\\' , ' INTO @v -- '"
    /// Two comparisons to the guard; in GBK a locking read.
    static let lockPayload = "SELECT * FROM gbk_it.t WHERE b <> '中\\\\' OR b = ' FOR SHARE -- '"

    @Test func gbkConnectionsAreSwitchedToUTF8MB4() async throws {
        let target = Self.target
        let root = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await root.close() } }
        #expect(try await root.execute("SELECT @@GLOBAL.init_connect").scalar == "SET NAMES gbk", "the container must set init_connect")
        _ = try await root.execute("CREATE DATABASE IF NOT EXISTS gbk_it")
        _ = try await root.execute("CREATE TABLE IF NOT EXISTS gbk_it.t (b VARCHAR(20))")
        _ = try await root.execute("DELETE FROM gbk_it.t")
        _ = try await root.execute("INSERT INTO gbk_it.t VALUES ('x')")
        let password = "Gbk-pw-\(UInt32.random(in: 0...UInt32.max))x"
        _ = try await root.execute("DROP USER IF EXISTS 'ccinn_gbk'@'%'")
        _ = try await root.execute("CREATE USER 'ccinn_gbk'@'%' IDENTIFIED BY '\(password)'")
        _ = try await root.execute("GRANT SELECT ON gbk_it.* TO 'ccinn_gbk'@'%'")
        defer { Task { _ = try? await root.execute("DROP USER 'ccinn_gbk'@'%'") } }
        #expect(ReadOnlySQLGuard.check(Self.intoPayload) == nil && ReadOnlySQLGuard.check(Self.lockPayload) == nil, "two strings to the guard")

        var configuration = IntegrationEnvironment.rootConfiguration(target)
        configuration.username = "ccinn_gbk"
        configuration.password = password
        let plain = try await MySQLClient.connect(configuration, poolSize: 1)
        defer { Task { await plain.close() } }

        // The threat: in GBK (what init_connect sets) the server runs the INTO.
        let gbk = plain.openSession(database: nil)
        _ = try await gbk.run("SET NAMES gbk")
        _ = try await gbk.run("SET @v = 'untouched'")
        _ = try? await gbk.run(Self.intoPayload)
        #expect(try await gbk.run("SELECT @v = 'untouched' AS same").last?.scalar == "0", "GBK reads `INTO @v`")
        await #expect(throws: MCPToolError.self) { try await MySQLMCPTools.requireUTF8MB4(gbk) }
        await gbk.close()

        // The fix: every connection is utf8mb4 after init_connect, and the payload is two strings again.
        let session = plain.openSession(database: nil)
        defer { Task { await session.close() } }
        let charsets = try await session.run("SELECT @@character_set_client, @@character_set_connection, @@character_set_results").last?.rows.first
        #expect(charsets == ["utf8mb4", "utf8mb4", "utf8mb4"])
        _ = try await session.run("SET @v = 'untouched'")
        let strings = try await session.run(Self.intoPayload).last?.rows.first
        #expect(strings == ["中\\", " INTO @v -- "], "two strings")
        #expect(try await session.run("SELECT @v").last?.scalar == "untouched")

        // Through the MCP binary with the plain account: both payloads run as the plain reads the guard saw.
        let process = try MCPProcess(target: target, database: "gbk_it", username: "ccinn_gbk", password: password, allowsPrivilegedAccount: false)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        let into = try await process.call(id: 2, "run_query", ["sql": .string(Self.intoPayload)])
        #expect(into["rows"]?[0]?[1]?.stringValue == " INTO @v -- ", "\(into)")
        let lock = try await process.call(id: 3, "run_query", ["sql": .string(Self.lockPayload)])
        #expect(lock["row_count"] == .int(1), "a plain read: \(lock)")
        let charset = try await process.call(id: 4, "run_query", ["sql": "SELECT @@character_set_client AS c"])
        #expect(charset["rows"]?[0]?[0]?.stringValue == "utf8mb4")
    }
}
