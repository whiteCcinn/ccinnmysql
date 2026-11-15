import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// As root, every way to change state through `run_query` is refused and provably had no effect (design D10).
@Suite("MCP read-only defences as root", .enabled(if: IntegrationEnvironment.isEnabled && MCPProcess.binaryExists), .serialized)
struct MCPReadOnlyIntegrationTests {
    @Test(arguments: IntegrationEnvironment.targets.filter { ["MySQL 8.4", "MariaDB 11.4 Galera", "MariaDB 11.4"].contains($0.label) })
    func nothingChangesThroughRunQuery(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { await admin.close() } }
        _ = try await admin.execute("CREATE DATABASE IF NOT EXISTS ccinn_it")
        _ = try await admin.execute("CREATE TABLE IF NOT EXISTS ccinn_it.probe (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(50)) ENGINE=InnoDB")
        _ = try? await admin.execute("DROP PROCEDURE ccinn_it.sp_commit_insert")
        _ = try await admin.execute("CREATE PROCEDURE ccinn_it.sp_commit_insert() MODIFIES SQL DATA BEGIN INSERT INTO ccinn_it.probe (note) VALUES ('proc'); COMMIT; INSERT INTO ccinn_it.probe (note) VALUES ('after'); END")
        _ = try? await admin.execute("DROP FUNCTION ccinn_it.fn_insert")
        _ = try await admin.execute("CREATE FUNCTION ccinn_it.fn_insert() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN INSERT INTO ccinn_it.probe (note) VALUES ('fn'); RETURN 1; END")
        let rowsBefore = try await admin.execute("SELECT COUNT(*) FROM ccinn_it.probe").scalar
        let maxConnectionsBefore = try await admin.execute("SELECT @@GLOBAL.max_connections").scalar
        let fileDirectory = try await admin.execute("SELECT @@GLOBAL.secure_file_priv").scalar ?? ""
        let outFile = (fileDirectory.isEmpty ? "/tmp/" : fileDirectory) + "ccinn_it_out.txt"
        let modeBefore = try await admin.execute("SELECT @@GLOBAL.sql_mode").scalar ?? ""

        let process = try MCPProcess(target: target, database: nil)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])

        var attempts = [
            "SELECT 1 INTO OUTFILE '\(outFile)'",
            "SELECT LOAD_FILE('/etc/passwd')",
            "/*!50000 SET GLOBAL max_connections = 77 */",
            "SELECT 1 /*!, LOAD_FILE('/etc/passwd') */",
            "CALL ccinn_it.sp_commit_insert()",
            "SELECT GET_LOCK('ccinn_it_lock', 0)",
            "SELECT * FROM ccinn_it.probe FOR UPDATE",
            "SELECT * FROM ccinn_it.probe LOCK IN SHARE MODE",
            "XA START 'ccinn_it'",
            "SET autocommit = 0",
            "SET GLOBAL max_connections = 77",
            "SET @@global.max_connections = 77",
            "START TRANSACTION",
            "DO GET_LOCK('ccinn_it_lock', 0)",
            "HANDLER ccinn_it.probe OPEN",
            "LOAD DATA INFILE '/etc/passwd' INTO TABLE ccinn_it.probe",
            "KILL 1",
            "FLUSH TABLES",
            "SELECT 1 #\r'\nINTO OUTFILE '\(outFile)' -- '",
            "SELECT `LOAD_FILE`('/etc/passwd')",
            "SELECT /*+ MAX_EXECUTION_TIME(0) */ 1",
            "SELECT ccinn_it.fn_insert()",
        ]
        if target.flavor != .mariadb { attempts.append("SET PERSIST max_connections = 77") }
        for (offset, sql) in attempts.enumerated() {
            let response = try await process.request(["jsonrpc": "2.0", "id": .int(Int64(100 + offset)), "method": "tools/call",
                                                      "params": ["name": "run_query", "arguments": ["sql": .string(sql)]]])
            #expect(response["result"]?["isError"] == .bool(true), "\(target.label): \(sql.debugDescription) → \(response)")
        }

        // Lexer-affecting sql_mode on the server: the MCP session normalises it, so guard and server agree.
        _ = try await admin.execute("SET GLOBAL sql_mode = CONCAT(@@GLOBAL.sql_mode, ',NO_BACKSLASH_ESCAPES,ANSI_QUOTES')")
        let smuggle = try await process.request(["jsonrpc": "2.0", "id": 900, "method": "tools/call",
                                                 "params": ["name": "run_query", "arguments": ["sql": "SELECT 'a\\' INTO @x, @y FROM (SELECT 1, 2) t #'"]]])
        _ = try await admin.execute("SET GLOBAL sql_mode = \(SQLText.literal(modeBefore))")
        if smuggle["result"]?["isError"] != .bool(true) {
            let value = smuggle["result"]?["structuredContent"]?["rows"]?[0]?[0]?.stringValue
            #expect(value?.hasPrefix("a' INTO @x") == true, "read as one string literal, not as SELECT … INTO: \(smuggle)")
        }

        // Nothing happened.
        #expect(try await admin.execute("SELECT COUNT(*) FROM ccinn_it.probe").scalar == rowsBefore)
        #expect(try await admin.execute("SELECT @@GLOBAL.max_connections").scalar == maxConnectionsBefore)
        #expect(try await admin.execute("SELECT IS_FREE_LOCK('ccinn_it_lock')").scalar == "1")
        #expect(try await admin.execute("SELECT LOAD_FILE(\(SQLText.literal(outFile))) IS NULL").scalar == "1", "no file was written")
        // Scoped to this MCP process's own sessions (program_name + _pid attributes), so suites running in parallel
        // (including another MCP process) don't interfere.
        let mcpSessions = """
            SELECT p.PROCESSLIST_ID FROM performance_schema.session_connect_attrs p \
            JOIN performance_schema.session_connect_attrs n ON n.PROCESSLIST_ID = p.PROCESSLIST_ID \
            WHERE p.ATTR_NAME = '_pid' AND p.ATTR_VALUE = '\(process.pid)' \
            AND n.ATTR_NAME = 'program_name' AND n.ATTR_VALUE = \(SQLText.literal(ClientOpener.mcpApplicationName))
            """
        let liveMCPSessions = Int(try await admin.execute("SELECT COUNT(*) FROM (\(mcpSessions)) s").scalar ?? "") ?? 0
        #expect(liveMCPSessions >= 1, "the MCP process's pooled connection identifies itself")
        #expect(try await admin.execute("SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_mysql_thread_id IN (\(mcpSessions))").scalar == "0",
                "no transaction left open")
        let busy = try await admin.execute("SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID IN (\(mcpSessions)) AND COMMAND <> 'Sleep'").scalar
        #expect(busy == "0", "MCP sessions are idle or closed")
        #expect(try await admin.execute("SELECT @@GLOBAL.autocommit").scalar == "1")
    }

    /// The guard cannot see inside an existing stored function, so `SELECT fn()` that takes a named lock is allowed —
    /// but each MCP call runs in its own session that is closed afterwards, so the lock does not outlive the call.
    @Test(arguments: IntegrationEnvironment.targets.filter { ["MySQL 8.4", "MariaDB 11.4 Galera", "MariaDB 11.4"].contains($0.label) })
    func sessionStateDoesNotOutliveACall(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        _ = try await admin.execute("CREATE DATABASE IF NOT EXISTS ccinn_it")
        _ = try? await admin.execute("DROP FUNCTION ccinn_it.fn_lock")
        _ = try await admin.execute("CREATE FUNCTION ccinn_it.fn_lock() RETURNS INT NOT DETERMINISTIC NO SQL RETURN GET_LOCK('ccinn_it_fn_lock', 0)")
        defer { Task { _ = try? await admin.execute("DROP FUNCTION ccinn_it.fn_lock") } }

        let process = try MCPProcess(target: target, database: nil)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        #expect(ReadOnlySQLGuard.check("SELECT ccinn_it.fn_lock() AS locked") == nil)
        let response = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                  "params": ["name": "run_query", "arguments": ["sql": "SELECT ccinn_it.fn_lock() AS locked"]]])
        #expect(response["result"]?["isError"] != .bool(true), "\(target.label): \(response)")
        #expect(response["result"]?["structuredContent"]?["rows"]?[0]?[0]?.intValue == 1, "the function took the lock inside the call: \(response)")

        // The server releases a closed session's locks asynchronously after COM_QUIT; allow it a moment.
        var free = try await admin.execute("SELECT IS_FREE_LOCK('ccinn_it_fn_lock')").scalar
        for _ in 0..<20 where free != "1" {
            try await Task.sleep(nanoseconds: 100_000_000)
            free = try await admin.execute("SELECT IS_FREE_LOCK('ccinn_it_fn_lock')").scalar
        }
        #expect(free == "1", "\(target.label): the named lock was released with the call's session")
    }
}
