import Foundation
import os
import Testing
@testable import CcinnMysqlKit
import MySQLKit

// MARK: - JSON and framing

@Suite("MCP JSON and framing")
struct MCPJSONTests {
    @Test func parsesAndSerializesOnOneLine() throws {
        let value = try JSONValue.parse(#"{"a":[1,2.5,"x\ny",true,null],"b":{"c":"é🙂"}}"#)
        #expect(value["a"]?[0] == .int(1))
        #expect(value["a"]?[1] == .double(2.5))
        #expect(value["a"]?[3] == .bool(true))
        #expect(value["a"]?[4] == .null)
        let text = value.serialized()
        #expect(!text.contains("\n"))
        #expect(try JSONValue.parse(text) == value)
    }

    @Test func escapesControlCharactersAndQuotes() {
        let text = JSONValue.string("a\"b\\c\u{01}\t").serialized()
        #expect(text == #""a\"b\\c\u0001\t""#)
    }

    @Test func rejectsDeeplyNestedJSONWithoutRecursing() {
        let deep = String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(deep) }
        #expect(!JSONValue.nestingExceeds(Data("{\"a\": \"[[[[[[\"}".utf8), limit: 2), "brackets inside strings do not count")
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: (any Error).self) { try JSONValue.parse("{nope") }
    }

    @Test func framerSplitsLinesAndBoundsLength() {
        var framer = LineFramer(maxLineBytes: 16)
        #expect(framer.append(Array("{\"a\":1}\n{\"b\"".utf8)) == [.line("{\"a\":1}")])
        #expect(framer.append(Array(":2}\r\n".utf8)) == [.line("{\"b\":2}")])
        // An oversized line is reported once and skipped up to the next newline.
        #expect(framer.append(Array(String(repeating: "x", count: 40).utf8)) == [.oversized])
        #expect(framer.append(Array("yyy\n{}\n".utf8)) == [.line("{}")])
        #expect(framer.append(Array("\n\n".utf8)).isEmpty)
    }
}

// MARK: - Protocol

private actor Transcript {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func messages() -> [JSONValue] { lines.compactMap { try? JSONValue.parse($0) } }
}

private struct FakeTools: MCPToolProvider {
    let calls = OSAllocatedUnfairLock(initialState: 0)

    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", title: "Echo", description: "Echoes", inputSchema: .object(["type": "object"]), readOnly: true),
         MCPTool(name: "slow", title: "Slow", description: "Sleeps", inputSchema: .object(["type": "object"]), readOnly: true)]
    }

    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        calls.withLock { $0 += 1 }
        switch name {
        case "echo": return .success(.object(["echo": arguments["text"] ?? .null]))
        case "slow":
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(.string("done"))
            } catch {
                return .failure("cancelled")
            }
        default: return .failure("Unknown tool \(name)")
        }
    }
}

@Suite("MCP protocol")
struct MCPServerTests {
    private func makeServer() -> (MCPServer, Transcript) {
        let transcript = Transcript()
        let server = MCPServer(info: MCPServerInfo(name: "test", title: "Test", version: "1.0.0", instructions: "Test server"),
                               provider: FakeTools(), send: { await transcript.append($0) })
        return (server, transcript)
    }

    @Test func negotiatesKnownAndUnknownVersions() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":"two","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["id"] == .int(1))
        #expect(messages[0]["result"]?["protocolVersion"] == .string("2025-03-26"))
        #expect(messages[0]["result"]?["capabilities"]?["tools"] != nil)
        #expect(messages[0]["result"]?["serverInfo"]?["name"] == .string("test"))
        #expect(messages[1]["id"] == .string("two"))
        #expect(messages[1]["result"]?["protocolVersion"] == .string(MCPServer.latestProtocolVersion))
    }

    @Test func listsAndCallsTools() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        await server.waitForIdle()
        let messages = await transcript.messages()
        #expect(messages.count == 3, "notifications get no response")
        let tools = messages[1]["result"]?["tools"]
        #expect(tools?[0]?["name"] == .string("echo"))
        #expect(tools?[0]?["annotations"]?["readOnlyHint"] == .bool(true))
        let call = messages[2]["result"]
        #expect(call?["isError"] == .bool(false))
        #expect(call?["structuredContent"]?["echo"] == .string("hi"))
        let text = call?["content"]?[0]?["text"]?.stringValue ?? ""
        #expect(try JSONValue.parse(text)["echo"] == .string("hi"))
    }

    @Test func toolFailuresAreResultsNotErrors() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"missing"}}"#)
        await server.waitForIdle()
        let message = try #require(await transcript.messages().first)
        #expect(message["result"]?["isError"] == .bool(true))
        #expect(message["error"] == nil)
    }

    @Test func protocolErrors() async throws {
        let (server, transcript) = makeServer()
        await server.receive("{not json")
        await server.receive(#"{"jsonrpc":"2.0","id":7,"method":"no/such"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"arguments":{}}}"#)
        await server.receive(#"[{"jsonrpc":"2.0","id":9,"method":"ping"}]"#)
        await server.receive(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":11,"method":"resources/list"}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["error"]?["code"] == .int(-32700))
        #expect(messages[0]["id"] == .null)
        #expect(messages[1]["error"]?["code"] == .int(-32601))
        #expect(messages[2]["error"]?["code"] == .int(-32602))
        #expect(messages[3]["error"]?["code"] == .int(-32600))
        #expect(messages[4]["result"] == .object([:]))
        #expect(messages[5]["result"]?["resources"] == .array([]))
    }

    @Test func cancelledCallsGetNoResponse() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}"#)
        await server.waitForIdle()
        #expect(await transcript.messages().isEmpty)
    }
}

// MARK: - Read-only guard

@Suite("Read-only SQL guard")
struct ReadOnlySQLGuardTests {
    @Test(arguments: [
        "SELECT 1", "  select * from shop.orders -- comment", "WITH a AS (SELECT 1) SELECT * FROM a", "show index from shop.orders",
        "DESC shop.orders", "explain format=tree select * from t", "SHOW CREATE PROCEDURE shop.p", "SHOW PROCEDURE STATUS", "(SELECT 1) UNION (SELECT 2)",
        "SELECT 'DELETE FROM t'", "select `insert` from t", "SHOW PRIVILEGES",
    ])
    func allowsReads(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    // Final review E: SHOW ENGINE INNODB STATUS prints other sessions' statements (latest deadlock) with their literals; the
    // get_innodb_status tool returns them with credentials redacted.
    @Test func innodbStatusGoesThroughItsTool() {
        #expect(ReadOnlySQLGuard.check("SHOW ENGINE INNODB STATUS") != nil)
    }

    // SHOW GRANTS prints the account's own password hash on MariaDB (`IDENTIFIED BY PASSWORD '*…'`), SHOW CREATE USER on
    // both servers: account definitions stay out of read-only mode in every form.
    @Test(arguments: ["SHOW GRANTS", "show grants", "SHOW GRANTS FOR CURRENT_USER()", "SHOW GRANTS FOR CURRENT_USER", "SHOW GRANTS FOR 'root'@'localhost'",
                      "SHOW GRANTS FOR CURRENT_USER() USING `r`", "SHOW /* x */ Grants", "SHOW CREATE USER CURRENT_USER()", "show create user root"])
    func accountDefinitionsAreRefused(sql: String) {
        let message = ReadOnlySQLGuard.check(sql)
        #expect(message?.contains("password hashes") == true, "\(sql): \(message ?? "allowed")")
        #expect(message?.contains("are not available in read-only mode") == true, "\(sql)")
    }

    // MariaDB's SHOW EXPLAIN / SHOW ANALYZE FOR <id> and EXPLAIN FOR CONNECTION <id> (also MySQL) print another session's
    // plan with its literals (`attached_condition: … 'card-4111-…'`), bypassing the tools that replace them with `?`.
    @Test(arguments: ["SHOW EXPLAIN FOR 5", "show explain format=json for 5", "SHOW ANALYZE FOR 5", "SHOW ANALYZE FORMAT=JSON FOR 5",
                      "EXPLAIN FOR CONNECTION 5", "EXPLAIN FORMAT=JSON FOR CONNECTION 5", "explain format=tree for connection 5",
                      "EXPLAIN EXTENDED FOR CONNECTION 5", "DESCRIBE FOR CONNECTION 5", "DESC FORMAT=JSON FOR CONNECTION 5",
                      "EXPLAIN /* x */ FOR /* y */ CONNECTION 5", "SHOW /* x */ EXPLAIN FOR 5"])
    func otherSessionsPlansAreRefused(sql: String) {
        let message = ReadOnlySQLGuard.check(sql)
        #expect(message?.contains("another session's") == true, "\(sql): \(message ?? "allowed")")
        #expect(message?.contains("are not available in read-only mode") == true, "\(sql)")
    }

    @Test func analyzeForAConnectionIsRefused() {
        #expect(ReadOnlySQLGuard.check("ANALYZE FORMAT=JSON FOR CONNECTION 5") != nil)
        #expect(ReadOnlySQLGuard.check("ANALYZE FOR CONNECTION 5") != nil)
    }

    @Test(arguments: [
        "DELETE FROM t", "insert into t values (1)", "SELECT 1; DROP TABLE t", "UPDATE t SET a = 1", "SET global x = 1",
        "WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a", "SELECT * FROM t INTO OUTFILE 's3://bucket/x'",
        "EXPLAIN ANALYZE INSERT INTO t SELECT 1", "KILL 5", "", "  -- only a comment", "SHOW TABLES WHERE SLEEP(5)",
        "OPTIMIZE TABLE t", "CREATE TABLE t (a int)", "USE shop", "SHOW TABLES; DROP TABLE t",
    ])
    func rejectsEverythingElse(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }
}

// MARK: - Profiles and results

@Suite("MCP profiles and results")
struct MCPProfileTests {
    private static let profiles = [
        ConnectionProfile(name: "Prod", host: "prod", mcpAccess: .readOnly),
        ConnectionProfile(name: "Dev", host: "dev", mcpAccess: .readWrite),
        ConnectionProfile(name: "Secret", host: "secret"),
    ]

    @Test func legacyProfilesDecodeWithMCPDisabled() throws {
        let json = #"[{"id":"7B0A9E6C-3C3A-4B8E-9C5B-1D6F2E0A4A11","name":"Old","color":"none","isFavorite":false,"host":"h","port":3306,"username":"root","allowCleartextPassword":false,"confirmMutations":false,"connectTimeout":10,"createdAt":0}]"#
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        #expect(decoded.first?.mcpAccess == .disabled)
        #expect(decoded.first?.name == "Old")
    }

    @Test func resolvesExplicitDefaultAndSingleProfile() throws {
        let resolver = MCPProfileResolver(profiles: Self.profiles, defaultProfile: nil, forceReadOnly: false)
        #expect(try resolver.resolve("prod").profile.name == "Prod")
        #expect(try resolver.resolve(Self.profiles[1].id.uuidString).access == .readWrite)
        #expect(throws: MCPToolError.self) { try resolver.resolve(nil) } // two enabled → ambiguous
        #expect(throws: MCPToolError.self) { try resolver.resolve("Secret") } // disabled
        #expect(throws: MCPToolError.self) { try resolver.resolve("nope") }
        #expect(resolver.enabledProfiles.map(\.name) == ["Dev", "Prod"])

        let withDefault = MCPProfileResolver(profiles: Self.profiles, defaultProfile: "Dev", forceReadOnly: true)
        let resolved = try withDefault.resolve(nil)
        #expect(resolved.profile.name == "Dev")
        #expect(resolved.access == .readOnly, "--read-only caps write access")
        #expect(!withDefault.anyWritable)

        let single = MCPProfileResolver(profiles: [Self.profiles[0], Self.profiles[2]], defaultProfile: nil, forceReadOnly: false)
        #expect(try single.resolve(nil).profile.name == "Prod")
    }

    @Test func encodesRowsWithTypesAndTruncatesBySize() {
        let columns = [ColumnInfoLite(name: "id", kind: .integer), ColumnInfoLite(name: "total", kind: .decimal), ColumnInfoLite(name: "city", kind: .text)]
        let rows: [[String?]] = (0..<5_000).map { [String($0), "12.50", String(repeating: "k", count: 100)] }
        let encoded = MCPResultEncoder.rows(columns: columns, rows: rows, truncatedByServer: false, maxBytes: 64 * 1024)
        #expect(encoded["truncated"] == .bool(true))
        let returned = encoded["rows"]?.arrayValue ?? []
        #expect(returned.count < 5_000 && !returned.isEmpty)
        #expect(returned.first?[0] == .int(0))
        #expect(returned.first?[1] == .string("12.50"), "decimals stay exact strings")
        #expect(encoded.serialized().utf8.count <= 64 * 1024 + 512)
    }
}

// MARK: - MySQL tool provider

/// Counts connection attempts; every open fails, so a test proves which calls never contact a server.
private final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("MySQL MCP tools")
struct MySQLMCPToolTests {
    private static let readOnly = ConnectionProfile(name: "Prod", host: "prod", mcpAccess: .readOnly)
    private static let readWrite = ConnectionProfile(name: "Dev", host: "dev", mcpAccess: .readWrite)

    private func provider(_ profiles: [ConnectionProfile], forceReadOnly: Bool = false, opens: OpenCounter = OpenCounter(),
                          audit: MCPAuditLog? = nil) -> MySQLMCPTools {
        let registry = MCPClientRegistry { _ in
            opens.increment()
            throw MySQLError(.network, "no server in unit tests")
        }
        return MySQLMCPTools(resolver: MCPProfileResolver(profiles: profiles, defaultProfile: nil, forceReadOnly: forceReadOnly),
                             registry: registry, audit: audit)
    }

    @Test func toolSchemasAreStrictAndAnnotated() async {
        let tools = await provider([Self.readOnly]).tools()
        let names = tools.map(\.name)
        #expect(names.contains("run_query") && names.contains("get_innodb_status") && names.contains("explain_query"))
        #expect(!names.contains("execute_statement"))
        for tool in tools {
            #expect(tool.inputSchema["type"] == "object", "\(tool.name)")
            #expect(tool.inputSchema["additionalProperties"] == .bool(false), "\(tool.name)")
            #expect(tool.readOnly && !tool.destructive, "\(tool.name)")
        }
        let writable = await provider([Self.readWrite]).tools()
        let execute = writable.first { $0.name == "execute_statement" }
        #expect(execute?.destructive == true && execute?.readOnly == false)
        #expect(await !provider([Self.readWrite], forceReadOnly: true).tools().contains { $0.name == "execute_statement" })
    }

    @Test func rejectedStatementsNeverOpenAConnection() async {
        let opens = OpenCounter()
        let tools = provider([Self.readOnly], opens: opens)
        for sql in ["DELETE FROM shop.orders", "SELECT * FROM t FOR UPDATE", "SELECT 1; SELECT 2", "/*!50000 DROP TABLE t */"] {
            let result = await tools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(result.isError, "\(sql)")
        }
        let explain = await tools.call(name: "explain_query", arguments: ["sql": "DELETE FROM t"])
        #expect(explain.isError)
        let write = await tools.call(name: "execute_statement", arguments: ["sql": "DELETE FROM t"])
        #expect(write.isError, "execute_statement does not exist for read-only profiles")
        #expect(opens.value == 0)
    }

    @Test func unknownToolsAndArgumentsAreErrorResults() async {
        let tools = provider([Self.readOnly])
        let unknownTool = await tools.call(name: "drop_everything", arguments: [:])
        #expect(unknownTool.isError)
        let unknownArgument = await tools.call(name: "list_databases", arguments: ["catalog": "x"])
        #expect(unknownArgument.isError)
        #expect(unknownArgument.payload.stringValue?.contains("catalog") == true)
        let missing = await tools.call(name: "describe_table", arguments: ["database": "shop"])
        #expect(missing.isError)
    }

    // Final review, item 7: names reach the server as given, while the handshake and identifier quoting cannot carry NUL
    // (`database: "information_\u{0}schema"` reached MySQL as information_schema). Every argument but the SQL is refused
    // when it holds a control character, before a connection is opened, for every tool and access level.
    @Test func controlCharactersInArgumentsAreRefusedBeforeConnecting() async {
        let opens = OpenCounter()
        let tools = provider([Self.readOnly, Self.readWrite], opens: opens)
        let calls: [(String, [String: JSONValue])] = [
            ("run_query", ["sql": "SELECT ID, INFO FROM processlist", "database": .string("information_\u{0}schema")]),
            ("run_query", ["sql": "SELECT 1", "database": .string("\u{0}information_schema")]),
            ("explain_query", ["sql": "SELECT 1", "database": .string("my\u{0}sql")]),
            ("list_tables", ["database": .string("performance_\u{0}schema")]),
            ("describe_table", ["database": "shop", "table": .string("t\u{85}")]),
            ("execute_statement", ["connection": "Dev", "sql": "SELECT 1", "database": .string("shop\u{7F}")]),
            ("list_tables", ["connection": .string("Prod\u{1}"), "database": "shop"]),
        ]
        for (tool, arguments) in calls {
            let result = await tools.call(name: tool, arguments: arguments)
            #expect(result.isError && result.payload.stringValue?.contains("control character") == true, "\(tool): \(result.payload)")
        }
        #expect(opens.value == 0)
    }

    @Test func connectionFailuresAreReportedAsResults() async {
        let opens = OpenCounter()
        let result = await provider([Self.readOnly], opens: opens).call(name: "run_query", arguments: ["sql": "SELECT 1"])
        #expect(result.isError)
        #expect(result.payload.stringValue?.contains("no server") == true)
        #expect(opens.value == 1)
    }

    @Test func listConnectionsNeverContainsSecrets() async {
        let result = await provider([Self.readOnly, ConnectionProfile(name: "Hidden", host: "h")]).call(name: "list_connections", arguments: [:])
        let text = result.payload.serialized()
        #expect(text.contains("Prod"))
        #expect(!text.contains("Hidden"), "disabled profiles are not listed")
        #expect(!text.lowercased().contains("password"))
    }

    @Test func auditLogRedactsAndIsPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = MCPAuditLog(directory: directory)
        let tools = provider([Self.readWrite], audit: audit)
        _ = await tools.call(name: "execute_statement", arguments: ["sql": "ALTER USER x IDENTIFIED BY 'pw-secret'"])
        let text = try String(contentsOf: audit.fileURL, encoding: .utf8)
        #expect(text.contains("IDENTIFIED BY '***'"))
        #expect(!text.contains("pw-secret"))
        let permissions = try FileManager.default.attributesOfItem(atPath: audit.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func planEncodingIsBounded() throws {
        var root = PlanNode(id: 0, title: "root")
        root.children = (1...2_000).map { PlanNode(id: $0, title: "child \($0)") }
        let plan = ExplainPlan(root: root, format: .tree, totalCost: nil, isAnalyzed: false)
        let encoded = MySQLMCPTools.encode(plan: plan)
        #expect((encoded["inputs"]?.arrayValue?.count ?? 0) < 500)
        #expect(encoded["truncated"] == .bool(true))
    }
}

@Suite("MCP connection identity")
struct MCPConnectionIdentityTests {
    @Test func mcpConnectionsAreTaggedDistinctly() {
        #expect(ClientOpener.mcpApplicationName != ClientOpener.appApplicationName)
        #expect(ClientOpener.mcpApplicationName.utf8.count <= 64)
    }
}
