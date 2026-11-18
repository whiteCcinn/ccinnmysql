import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Final review A, B, D, E against real servers, through the `CcinnMysql mcp` subprocess.
@Suite("MCP accounts, modes and character sets", .enabled(if: IntegrationEnvironment.isEnabled && MCPProcess.binaryExists), .serialized)
struct MCPAccountIntegrationTests {
    static let targets = IntegrationEnvironment.targets.filter { ["MySQL 8.4", "MariaDB 10.11"].contains($0.label) }

    private func initialize(_ process: MCPProcess) async throws {
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
    }

    /// The tool's error text, or nil when it succeeded.
    private func failure(_ process: MCPProcess, id: Int64, _ tool: String, _ arguments: JSONValue) async throws -> String? {
        let response = try await process.request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                                  "params": ["name": .string(tool), "arguments": arguments]])
        guard response["result"]?["isError"] == .bool(true) else { return nil }
        return response["result"]?["content"]?[0]?["text"]?.stringValue ?? "?"
    }

    // D: read-only tools refuse root (FILE, SUPER, global ALL…) unless the connection allows it, accept a plain account,
    // and refuse a plain account that holds a privileged role. E: secrets stay refused even when allowed.
    @Test(arguments: targets)
    func privilegedAccountsAreRefusedByDefault(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        await IntegrationEnvironment.sweepLeftovers(admin, target: target)
        try await DemoSchema.load(into: admin)
        let user = "ccinn_ai_\(UInt16.random(in: 0...UInt16.max))"
        let role = "\(user)_r"
        let password = "Ai-pw-\(UInt32.random(in: 0...UInt32.max))x"
        _ = try await admin.execute("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'")
        _ = try await admin.execute("GRANT SELECT ON shop.* TO '\(user)'@'%'")
        do {
            try await checkAccounts(target, user: user, password: password, role: role, admin: admin)
        } catch {
            Issue.record(error)
        }
        // Awaited here: a cleanup task in a defer could still be running when the client closes.
        _ = try? await admin.execute("DROP USER '\(user)'@'%'")
        _ = try? await admin.execute("DROP ROLE '\(role)'")
    }

    private func checkAccounts(_ target: IntegrationEnvironment.Target, user: String, password: String, role: String,
                               admin: MySQLClient) async throws {

        // Root, not allowed: every read-only tool that touches the database refuses, with the reasons.
        let root = try MCPProcess(target: target, allowsPrivilegedAccount: false)
        defer { root.terminate() }
        try await initialize(root)
        let refused = try await failure(root, id: 2, "run_query", ["sql": "SELECT 1"])
        #expect(refused?.contains("can write or read server files") == true, "\(target.label): \(refused ?? "allowed")")
        #expect(try await failure(root, id: 3, "list_tables", ["database": "shop"])?.contains("AI settings") == true)
        #expect(try await failure(root, id: 4, "explain_query", ["sql": "SELECT 1"]) != nil)

        // Root, allowed for this connection: queries run, secrets still do not.
        let allowed = try MCPProcess(target: target, allowsPrivilegedAccount: true)
        defer { allowed.terminate() }
        try await initialize(allowed)
        #expect(try await failure(allowed, id: 2, "run_query", ["sql": "SELECT 1 AS one"]) == nil)
        for (offset, sql) in ["SELECT user, authentication_string FROM mysql.user", "SELECT * FROM performance_schema.events_statements_history",
                              "SHOW FULL PROCESSLIST", "SELECT info FROM information_schema.PROCESSLIST", "SELECT user FROM `MySQL`.`USER`",
                              "SHOW GRANTS", "EXPLAIN FORMAT=JSON FOR CONNECTION 1", "SHOW EXPLAIN FOR 1", "SHOW ANALYZE FOR 1"].enumerated() {
            let message = try await failure(allowed, id: Int64(10 + offset), "run_query", ["sql": .string(sql)])
            #expect(message?.contains("are not available in read-only mode") == true, "\(target.label): \(sql) → \(message ?? "allowed")")
        }

        // A plain account with SELECT on one schema: allowed.
        let plain = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
        defer { plain.terminate() }
        try await initialize(plain)
        let rows = try await plain.call(id: 2, "run_query", ["sql": "SELECT COUNT(*) AS n FROM orders", "database": "shop"])
        #expect(rows["row_count"] == .int(1), "\(target.label): \(rows)")
        #expect(try await failure(plain, id: 3, "list_tables", ["database": "shop"]) == nil)

        // The same account with PROCESS: refused by default (views over the process list show other sessions' statements),
        // allowed with the opt-in.
        _ = try await admin.execute("GRANT PROCESS ON *.* TO '\(user)'@'%'")
        let monitor = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
        defer { monitor.terminate() }
        try await initialize(monitor)
        let viaProcess = try await failure(monitor, id: 2, "run_query", ["sql": "SELECT 1"])
        #expect(viaProcess?.contains("PROCESS") == true, "\(target.label): \(viaProcess ?? "allowed")")
        let optedIn = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: true)
        defer { optedIn.terminate() }
        try await initialize(optedIn)
        #expect(try await failure(optedIn, id: 2, "run_query", ["sql": "SELECT 1 AS one"]) == nil)
        _ = try await admin.execute("REVOKE PROCESS ON *.* FROM '\(user)'@'%'")

        // The same account holding a role with FILE: refused (its own grants alone would pass).
        _ = try await admin.execute("CREATE ROLE '\(role)'")
        _ = try await admin.execute("GRANT FILE ON *.* TO '\(role)'")
        _ = try await admin.execute("GRANT '\(role)' TO '\(user)'@'%'")
        _ = try await admin.execute(target.flavor == .mariadb ? "SET DEFAULT ROLE '\(role)' FOR '\(user)'@'%'" : "SET DEFAULT ROLE '\(role)' TO '\(user)'@'%'")
        let withRole = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
        defer { withRole.terminate() }
        try await initialize(withRole)
        let viaRole = try await failure(withRole, id: 2, "run_query", ["sql": "SELECT 1"])
        #expect(viaRole?.contains("FILE") == true, "\(target.label): \(viaRole ?? "allowed")")
    }

    // Final review, item 1: database-level grants are LIKE patterns. `%`, `my%`, `m_sql` and an escaped `performance\_schema`
    // cover secret schemas (through invoker-rights views they returned password hashes and other sessions' SQL_TEXT), so the
    // account is privileged; a pattern that matches none of them is not.
    @Test(arguments: targets)
    func wildcardDatabaseGrantsArePrivileged(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        await IntegrationEnvironment.sweepLeftovers(admin, target: target)
        try await DemoSchema.load(into: admin)
        let user = "ccinn_wild_\(UInt16.random(in: 0...UInt16.max))"
        let password = "Wild-pw-\(UInt32.random(in: 0...UInt32.max))x"
        _ = try await admin.execute("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'")
        do {
            try await checkPatterns(target, user: user, password: password, admin: admin)
        } catch {
            Issue.record(error)
        }
        _ = try? await admin.execute("DROP USER '\(user)'@'%'")
    }

    private func checkPatterns(_ target: IntegrationEnvironment.Target, user: String, password: String, admin: MySQLClient) async throws {
        let configuration = ConnectionConfiguration(endpoint: target.endpoint, username: user, password: password, database: nil, connectTimeout: 20,
                                                    tls: TLSOptions(mode: .preferred, serverName: "127.0.0.1"))
        for (pattern, privileged) in [("`%`", true), ("`my%`", true), ("`m_sql`", true), ("`performance\\_schema`", true), ("`performance%`", true),
                                      ("`perform_nce\\_schema`", true), ("`sho_`", false)] {
            _ = try await admin.execute("GRANT SELECT ON \(pattern).* TO '\(user)'@'%'")
            let account = try await MySQLClient.connect(configuration, poolSize: 1)
            let shown = (try? await account.query("SHOW GRANTS").flatMap(\.rows).compactMap { $0.first ?? nil }) ?? []
            var isPrivileged: Bool?
            do {
                isPrivileged = try await AccountPrivileges.load(flavor: target.flavor) { try await account.query($0) }.isPrivileged
            } catch {
                Issue.record("\(target.label) \(pattern): \(error)")
            }
            await account.close()
            #expect(isPrivileged == privileged, "\(target.label) \(pattern): \(shown)")
            _ = try await admin.execute("REVOKE SELECT ON \(pattern).* FROM '\(user)'@'%'")
        }
        // End to end: the MCP server refuses the `%` grant by default and names it.
        _ = try await admin.execute("GRANT SELECT ON `%`.* TO '\(user)'@'%'")
        let process = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
        defer { process.terminate() }
        try await initialize(process)
        let refused = try await failure(process, id: 2, "run_query", ["sql": "SELECT 1"])
        #expect(refused?.contains("SELECT ON %.*") == true, "\(target.label): \(refused ?? "allowed")")
    }

    // Final review, items 6 and 7, through the MCP binary with privileged accounts allowed (only the guard decides): names the
    // servers fold to ASCII (ı, İ, ſ) and database arguments with NUL are refused. Negative control: the server itself
    // resolves a folded spelling to PROCESSLIST. A NUL database never leaves the client: the handshake refuses it.
    @Test(arguments: targets)
    func foldedAndControlCharacterNamesAreRefused(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        var resolved: [String] = []
        for name in ["information_schema.processlıst", "information_schema.PROCESSLİST", "information_schema.proceſſlist"] {
            if (try? await admin.query("SELECT COUNT(*) FROM \(name)")) != nil { resolved.append(name) }
        }
        #expect(!resolved.isEmpty, "\(target.label): no folded spelling resolves, so this test proves nothing")

        let process = try MCPProcess(target: target, allowsPrivilegedAccount: true)
        defer { process.terminate() }
        try await initialize(process)
        let attempts: [(sql: String, database: String?)] = [
            ("SELECT ID, INFO FROM information_schema.processlıst", nil), ("SELECT ID, INFO FROM information_schema.PROCESSLİST", nil),
            ("SELECT ID, INFO FROM information_schema.proceſſlist", nil), ("SELECT ID, INFO FROM ınformation_schema.PROCESSLIST", nil),
            ("SELECT ID, INFO FROM `information_ſchema`.PROCESSLIST", nil), ("SELECT * FROM performance_ſchema.threads", nil),
            ("SHOW TABLES FROM performance_ſchema", nil), ("SELECT LOAD_FıLE('/etc/hosts')", nil), ("SELECT ſleep(1)", nil),
            ("SELECT * FROM information_schema.processlíst", nil), ("SHOW REPLICA STATUS", nil),
            ("SELECT ID, INFO FROM processlist", "ınformation_schema"), ("SELECT ID, INFO FROM processlist", "information_\u{0}schema"),
            ("SELECT ID, INFO FROM processlist", "information_schema\u{0}"), ("SELECT ID, INFO FROM processlist", "\u{0}information_schema"),
        ]
        for (offset, attempt) in attempts.enumerated() {
            var arguments: [String: JSONValue] = ["sql": .string(attempt.sql)]
            if let database = attempt.database { arguments["database"] = .string(database) }
            let message = try await failure(process, id: Int64(10 + offset), "run_query", .object(arguments))
            #expect(message != nil, "\(target.label): \(attempt.sql) in \(attempt.database?.debugDescription ?? "-") ran")
        }
        #expect(try await failure(process, id: 50, "run_query", ["sql": "SELECT 'ı' AS s, 1 AS café"]) == nil, "\(target.label)")

        // Sessions (run_query's path) take the database in their handshake, which refuses NUL before sending anything.
        let session = admin.openSession(database: "information_\u{0}schema")
        let error = await #expect(throws: MySQLError.self) { _ = try await session.run("SELECT DATABASE()") }
        #expect(error?.kind == .invalidArgument, "\(target.label): \(String(describing: error))")
        await session.close()
    }

    // Cross-port (StarRocks): with NO_BACKSLASH_ESCAPES in a session, a quote escaped as \' ends the string, and a name in
    // metadata SQL could inject. Two layers, both checked live: the app's pool sessions (where metadata SQL runs) drop
    // NO_BACKSLASH_ESCAPES even when the account or connection sets it, and the app's literals double quotes, so they hold
    // in a session that keeps it. Negative control: an escaper writing \' does inject in that session.
    @Test(arguments: targets)
    func metadataLiteralsHoldWithoutBackslashEscapes(target: IntegrationEnvironment.Target) async throws {
        var settings = IntegrationEnvironment.rootConfiguration(target)
        settings.sessionVariables = [(name: "sql_mode", value: "NO_BACKSLASH_ESCAPES")]
        let names = ["x' UNION SELECT 0x69 -- ", "x\\' UNION SELECT 'i' -- ", "\\'"]

        let client = try await MySQLClient.connect(settings, poolSize: 1)
        defer { Task { await client.close() } }
        let poolMode = try await client.query("SELECT @@SESSION.sql_mode AS m").flatMap(\.rows).first?.first ?? nil
        #expect(poolMode?.contains("NO_BACKSLASH_ESCAPES") == false, "\(target.label): pool sessions drop it: \(poolMode ?? "nil")")
        for name in names {
            let listing = try await client.objects(schema: name)
            #expect(listing.objects.isEmpty, "\(target.label) \(name.debugDescription): \(listing.objects.map(\.name))")
            #expect(try await client.columns(schema: "shop", table: name).isEmpty, "\(target.label) \(name.debugDescription)")
        }

        let connection = try await MySQLConnection.connect(settings)
        let mode = try await connection.query("SELECT @@SESSION.sql_mode AS m").flatMap(\.rows).first?.first ?? nil
        #expect(mode?.contains("NO_BACKSLASH_ESCAPES") == true, "\(target.label): \(mode ?? "nil")")
        func tables(_ literal: String) async throws -> [String?] {
            try await connection.query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(literal)").flatMap(\.rows).map { $0.first ?? nil }
        }
        let naive = try await tables("'" + names[0].replacingOccurrences(of: "'", with: "\\'") + "'")
        #expect(naive == ["i"], "\(target.label): the negative control should inject: \(naive)")
        for name in names {
            let rows = try await tables(SQLText.literal(name))
            #expect(rows.isEmpty, "\(target.label) \(name.debugDescription): \(rows)")
        }
        await connection.close()
    }

    // Final review, item 5: MariaDB shows an account the grants of its own roles only, not of roles those roles hold, so a
    // nested role fails closed with a message that says so; MySQL expands nested roles (SHOW GRANTS … USING).
    @Test(arguments: targets)
    func nestedRolesFailClosedOnMariaDB(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        await IntegrationEnvironment.sweepLeftovers(admin, target: target)
        try await DemoSchema.load(into: admin)
        let user = "ccinn_nest_\(UInt16.random(in: 0...UInt16.max))"
        let (outer, inner) = ("\(user)_o", "\(user)_i")
        let password = "Nest-pw-\(UInt32.random(in: 0...UInt32.max))x"
        do {
            _ = try await admin.execute("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'")
            _ = try await admin.execute("CREATE ROLE '\(outer)'")
            _ = try await admin.execute("CREATE ROLE '\(inner)'")
            _ = try await admin.execute("GRANT SELECT ON shop.* TO '\(inner)'")
            _ = try await admin.execute("GRANT '\(inner)' TO '\(outer)'")
            _ = try await admin.execute("GRANT '\(outer)' TO '\(user)'@'%'")
            _ = try await admin.execute(target.flavor == .mariadb ? "SET DEFAULT ROLE '\(outer)' FOR '\(user)'@'%'" : "SET DEFAULT ROLE '\(outer)' TO '\(user)'@'%'")
            let process = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
            defer { process.terminate() }
            try await initialize(process)
            let message = try await failure(process, id: 2, "run_query", ["sql": "SELECT COUNT(*) AS n FROM orders", "database": "shop"])
            if target.flavor == .mariadb {
                #expect(message?.contains("nested roles can't be inspected") == true, "\(target.label): \(message ?? "allowed")")
            } else {
                #expect(message == nil, "\(target.label): plain nested roles are expanded: \(message ?? "")")
            }
        } catch {
            Issue.record(error)
        }
        _ = try? await admin.execute("DROP USER '\(user)'@'%'")
        _ = try? await admin.execute("DROP ROLE '\(outer)'")
        _ = try? await admin.execute("DROP ROLE '\(inner)'")
    }

    // Final review, item 9, live as a plain account: loadable, component and stored functions are refused, natives run
    // (REPLACE(), INSERT() and TRUNCATE() as functions included), and a dynamic privilege without the _ADMIN suffix
    // (INNODB_REDO_LOG_ARCHIVE, MySQL) makes the account privileged.
    @Test(arguments: targets)
    func onlyReviewedNativesAreCalled(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        await IntegrationEnvironment.sweepLeftovers(admin, target: target)
        try await DemoSchema.load(into: admin)
        let user = "ccinn_fn_\(UInt16.random(in: 0...UInt16.max))"
        let password = "Fn-pw-\(UInt32.random(in: 0...UInt32.max))x"
        do {
            _ = try await admin.execute("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'")
            _ = try await admin.execute("GRANT SELECT ON shop.* TO '\(user)'@'%'")
            let plain = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
            defer { plain.terminate() }
            try await initialize(plain)
            let refusedCalls = ["SELECT mysqlx_generate_document_id()", "SELECT audit_api_message_emit_udf('x')", "SELECT sys_get('PATH')",
                                "SELECT innodb_redo_log_archive_start('rvlabel', 'mcp')", "SELECT shop.fn_order_total(1)", "SELECT fn_order_total(1)",
                                "SELECT COUNT (*) FROM orders", "SELECT `abs`(1)"]
            for (offset, sql) in refusedCalls.enumerated() {
                let message = try await failure(plain, id: Int64(10 + offset), "run_query", ["sql": .string(sql), "database": "shop"])
                #expect(message?.contains("reviewed built-in") == true, "\(target.label): \(sql) → \(message ?? "ran")")
            }
            let functions = try await plain.call(id: 30, "run_query", ["sql": "SELECT REPLACE('hello', 'l', 'L') AS r, INSERT('abcdef', 2, 3, 'X') AS i, TRUNCATE(3.14159, 2) AS t"])
            let row = functions["rows"]?[0]
            #expect(row?[0]?.stringValue == "heLLo" && row?[1]?.stringValue == "aXef" && row?[2]?.stringValue == "3.14", "\(target.label): \(functions)")
            let analytics = try await plain.call(id: 31, "run_query", ["sql": """
                WITH m (customer, total) AS (SELECT customer_id, SUM(1) FROM orders GROUP BY customer_id)
                SELECT COUNT(*) AS n, CAST(SUM(total) AS DECIMAL(10,2)) AS s, MAX(customer) AS c FROM m
                """, "database": "shop"])
            #expect(analytics["row_count"] == .int(1), "\(target.label): \(analytics)")
            let table = try await plain.call(id: 32, "run_query", ["sql": """
                SELECT jt.v FROM orders o, JSON_TABLE('[1, 2]', '$[*]' COLUMNS (v INT PATH '$')) AS jt ORDER BY jt.v LIMIT 1
                """, "database": "shop"])
            #expect(table["rows"]?[0]?[0]?.intValue == 1, "\(target.label): \(table)")
            if target.flavor != .mariadb {
                _ = try await admin.execute("GRANT INNODB_REDO_LOG_ARCHIVE ON *.* TO '\(user)'@'%'")
                let archive = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
                defer { archive.terminate() }
                try await initialize(archive)
                let message = try await failure(archive, id: 2, "run_query", ["sql": "SELECT 1"])
                #expect(message?.contains("INNODB_REDO_LOG_ARCHIVE") == true, "\(target.label): \(message ?? "allowed")")
            }
        } catch {
            Issue.record(error)
        }
        _ = try? await admin.execute("DROP USER IF EXISTS '\(user)'@'%'")
    }

    // Definer-rights routines of a privileged definer are reported, not refused; other sessions' statements come back from
    // get_processlist with every literal as `?`.
    @Test(arguments: targets)
    func definerRightsAreReportedAndStatementsRedacted(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        defer { Task { await admin.close() } }
        await IntegrationEnvironment.sweepLeftovers(admin, target: target)
        try await DemoSchema.load(into: admin)
        let suffix = UInt16.random(in: 0...UInt16.max)
        let user = "ccinn_def_\(suffix)"
        let function = "ccinn_fn_definer_\(suffix)"
        let password = "Def-pw-\(UInt32.random(in: 0...UInt32.max))x"
        _ = try await admin.execute("CREATE FUNCTION shop.\(function)() RETURNS INT DETERMINISTIC RETURN 1")
        _ = try await admin.execute("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'")
        _ = try await admin.execute("GRANT SELECT ON shop.* TO '\(user)'@'%'")
        _ = try await admin.execute("GRANT EXECUTE ON FUNCTION shop.\(function) TO '\(user)'@'%'")
        do {
            let plain = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: false)
            defer { plain.terminate() }
            try await initialize(plain)
            let response = try await plain.request(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                    "params": ["name": "run_query", "arguments": ["sql": "SELECT 1 AS one"]]])
            #expect(response["result"]?["isError"] != .bool(true), "\(target.label): \(response)")
            let notice = response["result"]?["structuredContent"]?["notice"]?.stringValue ?? ""
            #expect(notice.contains("definer-rights") && notice.contains(function), "\(target.label): \(notice)")
            // Calling it is a stored-function call: refused without the connection's allowance (item 9), reported with it.
            let refused = try await failure(plain, id: 4, "run_query", ["sql": .string("SELECT shop.\(function)() AS one")])
            #expect(refused?.contains("shop.\(function)") == true, "\(target.label): \(refused ?? "allowed")")
            let allowed = try MCPProcess(target: target, username: user, password: password, allowsPrivilegedAccount: true)
            defer { allowed.terminate() }
            try await initialize(allowed)
            let ran = try await allowed.request(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                                 "params": ["name": "run_query", "arguments": ["sql": .string("SELECT shop.\(function)() AS one")]]])
            #expect(ran["result"]?["isError"] != .bool(true), "\(target.label): reported, not refused: \(ran)")
            #expect(ran["result"]?["structuredContent"]?["notice"]?.stringValue?.contains(function) == true, "\(target.label): \(ran)")
            let info = try await plain.call(id: 3, "server_info", [:])
            #expect(info["definer_rights"]?.arrayValue?.contains { $0.stringValue?.contains(function) == true } == true, "\(info)")

            // Another session's statement with a secret literal, seen through get_processlist (root, allowed).
            let secret = "hunter2-\(suffix)"
            let busy = Task { _ = try? await admin.query("SELECT SLEEP(4) AS s, '\(secret)' AS secret") }
            let root = try MCPProcess(target: target, allowsPrivilegedAccount: true)
            defer { root.terminate() }
            try await initialize(root)
            var statements: [String] = []
            for attempt in 0..<30 where !statements.contains(where: { $0.contains("SLEEP") }) {
                try await Task.sleep(for: .milliseconds(100))
                let sessions = try await root.call(id: Int64(10 + attempt), "get_processlist", [:])
                statements = sessions["sessions"]?.arrayValue?.compactMap { $0["statement"]?.stringValue } ?? []
            }
            let sleeping = statements.first { $0.contains("SLEEP") } ?? ""
            #expect(sleeping.contains("SLEEP(?)") && !sleeping.contains(secret), "\(target.label): \(statements)")
            await busy.value
        } catch {
            Issue.record(error)
        }
        _ = try? await admin.execute("DROP USER '\(user)'@'%'")
        _ = try? await admin.execute("DROP FUNCTION shop.\(function)")
    }

    // B: every connection is utf8mb4, whatever the handshake or init_connect did.
    @Test(arguments: targets)
    func connectionsAreUTF8MB4(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        let row = try await session.run("SELECT @@character_set_client, @@character_set_connection, @@character_set_results").last?.rows.first
        #expect(row == ["utf8mb4", "utf8mb4", "utf8mb4"], "\(target.label)")
        // A session switched away is refused before a guarded statement.
        _ = try await session.run("SET NAMES latin1")
        await #expect(throws: MCPToolError.self) { try await MySQLMCPTools.requireUTF8MB4(session) }
    }

    // F: execute_statement (read & write) splits with the session's own sql_mode: under NO_BACKSLASH_ESCAPES
    // `SELECT 'x\', ';' AS y` is one statement and `SELECT 'a\';' AS d` two; an unmodelled mode refuses.
    @Test(arguments: targets)
    func executeStatementSplitsWithTheSessionsMode(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        let before = try await admin.execute("SELECT @@GLOBAL.sql_mode").scalar ?? ""
        _ = try await admin.execute("SET GLOBAL sql_mode = CONCAT_WS(',', NULLIF(@@GLOBAL.sql_mode, ''), 'NO_BACKSLASH_ESCAPES')")
        let process = try MCPProcess(target: target, access: .readWrite)
        do {
            try await initialize(process)
            let one = try await process.call(id: 2, "execute_statement", ["sql": "SELECT 'x\\', ';' AS y"])
            #expect(one["rows"]?[0]?[0]?.stringValue == "x\\" && one["rows"]?[0]?[1]?.stringValue == ";", "\(target.label): \(one)")
            let two = try await failure(process, id: 3, "execute_statement", ["sql": "SELECT 'a\\';' AS d"])
            #expect(two?.contains("exactly one statement") == true, "\(target.label): \(two ?? "allowed")")
            if target.flavor == .mariadb {
                _ = try await admin.execute("SET GLOBAL sql_mode = 'ORACLE'")
                let oracle = try MCPProcess(target: target, access: .readWrite)
                try await initialize(oracle)
                let refused = try await failure(oracle, id: 2, "execute_statement", ["sql": "SELECT 1"])
                #expect(refused?.contains("ORACLE") == true, "\(refused ?? "allowed")")
                oracle.terminate()
            }
        } catch {
            Issue.record(error)
        }
        process.terminate()
        _ = try await admin.execute("SET GLOBAL sql_mode = \(SQLText.literal(before))")
    }

    // A: an unmodelled sql_mode on the server (MariaDB ORACLE: another grammar, ANSI_QUOTES, PIPES_AS_CONCAT) is stripped
    // from read-only sessions, so the guard's reading is the server's.
    @Test(arguments: targets.filter { $0.flavor == .mariadb })
    func oracleModeIsStrippedFromReadOnlySessions(target: IntegrationEnvironment.Target) async throws {
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await admin.close() } }
        let before = try await admin.execute("SELECT @@GLOBAL.sql_mode").scalar ?? ""
        _ = try await admin.execute("SET GLOBAL sql_mode = 'ORACLE'")
        let process = try MCPProcess(target: target)
        do {
            try await initialize(process)
            let mode = try await process.call(id: 2, "run_query", ["sql": "SELECT @@SESSION.sql_mode AS m"])
            let effective = mode["rows"]?[0]?[0]?.stringValue ?? "?"
            #expect(!SQLModes.affectsLexing(effective), "\(target.label): \(effective)")
            #expect(!effective.contains("ORACLE") && !effective.contains("ANSI_QUOTES") && !effective.contains("PIPES_AS_CONCAT"), "\(effective)")
            // Read as the guard reads it: `"a"` is a string here, not a name.
            let quoted = try await process.call(id: 3, "run_query", ["sql": "SELECT \"a\" || 'b' AS x"])
            #expect(quoted["rows"]?[0]?[0]?.intValue == 0, "|| is OR, not concatenation: \(quoted)")
        } catch {
            Issue.record(error)
        }
        process.terminate()
        _ = try await admin.execute("SET GLOBAL sql_mode = \(SQLText.literal(before))")
    }
}
