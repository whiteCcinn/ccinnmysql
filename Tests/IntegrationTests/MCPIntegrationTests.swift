import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Drives the real `CcinnMysql mcp` subprocess over stdio against the test containers.
/// Requires `swift build` first (the test uses `.build/debug/CcinnMysql`).
@Suite("MCP server subprocess", .enabled(if: IntegrationEnvironment.isEnabled && MCPProcess.binaryExists), .serialized)
struct MCPIntegrationTests {
    @Test(arguments: IntegrationEnvironment.targets.filter { ["MySQL 8.4", "MySQL 8.0", "MariaDB 10.11", "MySQL 5.7"].contains($0.label) })
    func fullSessionOverStdio(target: IntegrationEnvironment.Target) async throws {
        // Fixtures: demo schema plus a stored function that writes (must fail inside the read-only transaction).
        let admin = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        try await DemoSchema.load(into: admin)
        _ = try await admin.execute("CREATE DATABASE IF NOT EXISTS ccinn_it")
        _ = try await admin.execute("CREATE TABLE IF NOT EXISTS ccinn_it.writes (id INT AUTO_INCREMENT PRIMARY KEY, at DATETIME)")
        _ = try? await admin.execute("DROP FUNCTION ccinn_it.fn_write")
        _ = try await admin.execute("CREATE FUNCTION ccinn_it.fn_write() RETURNS INT DETERMINISTIC MODIFIES SQL DATA BEGIN INSERT INTO ccinn_it.writes (at) VALUES (NOW()); RETURN 1; END")
        let writesBefore = try await admin.execute("SELECT COUNT(*) FROM ccinn_it.writes").scalar
        await admin.close()

        let process = try MCPProcess(target: target)
        defer { process.terminate() }

        let initialize = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        #expect(initialize["result"]?["serverInfo"]?["name"] == .string("ccinnmysql"))
        #expect(initialize["result"]?["protocolVersion"] == .string("2025-06-18"))
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let tools = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("run_query") && names.contains("get_innodb_status") && names.contains("explain_query"))
        #expect(!names.contains("execute_statement"), "the test profile is read-only")

        let info = try await process.call(id: 3, "server_info", [:])
        #expect(info["flavor"] == .string(target.flavor.rawValue))

        let tables = try await process.call(id: 4, "list_tables", ["database": "shop"])
        let kinds = Dictionary((tables["objects"]?.arrayValue ?? []).compactMap { object -> (String, String)? in
            guard let name = object["name"]?.stringValue, let kind = object["kind"]?.stringValue else { return nil }
            return (name, kind)
        }, uniquingKeysWith: { first, _ in first })
        #expect(kinds["orders"] == "table")
        #expect(kinds["v_paid_orders"] == "view")
        #expect(kinds["sp_orders_by_city"] == "procedure")

        let described = try await process.call(id: 5, "describe_table", ["database": "shop", "table": "orders", "include_ddl": false])
        let findings = described["findings"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        #expect(findings.contains("Redundant index idx_customer"))

        let query = try await process.call(id: 6, "run_query", ["sql": "SELECT * FROM orders", "database": "shop", "limit": 25])
        #expect(query["row_count"] == .int(25))
        #expect(query["truncated"] == .bool(true))
        #expect(query["limit_applied"] == .bool(true))

        let rejected = try await process.request(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                  "params": ["name": "run_query", "arguments": ["sql": "DELETE FROM shop.orders"]]])
        #expect(rejected["result"]?["isError"] == .bool(true))

        // A write hidden in a stored function is stopped by the server-side READ ONLY transaction.
        let hidden = try await process.request(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                                                "params": ["name": "run_query", "arguments": ["sql": "SELECT ccinn_it.fn_write()"]]])
        #expect(hidden["result"]?["isError"] == .bool(true), "\(hidden)")

        let plan = try await process.call(id: 9, "explain_query", ["sql": "SELECT * FROM shop.orders WHERE amount > 100 ORDER BY created_at"])
        #expect(plan["warnings"]?.arrayValue?.contains(.string("Full table scan")) == true)

        _ = try await process.call(id: 10, "get_processlist", [:])
        _ = try await process.call(id: 11, "get_innodb_status", [:])
        _ = try await process.call(id: 12, "get_replication_status", [:])
        let statements = try await process.request(["jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": ["name": "get_top_statements", "arguments": [:]]])
        #expect(statements["result"] != nil)

        // Cancelling a long query must stop it on the server and produce no response for that id.
        try process.send(["jsonrpc": "2.0", "id": 14, "method": "tools/call",
                          "params": ["name": "run_query", "arguments": ["sql": "SELECT COUNT(*) AS ccinn_cancel_me FROM shop.orders a, shop.orders b, shop.orders c WHERE a.amount + b.amount + c.amount > a.id",
                                                                         "timeout_seconds": 60]]])
        try await Task.sleep(for: .milliseconds(1_200))
        try process.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 14]])
        let ping = try await process.request(["jsonrpc": "2.0", "id": 15, "method": "ping"])
        #expect(ping["result"] == .object([:]))
        try await Task.sleep(for: .seconds(3))
        #expect(process.responses(for: 14).isEmpty, "\(process.responses(for: 14))")
        let check = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        let running = try await check.processList().processes.filter { $0.statement?.contains("ccinn_cancel_me") == true && $0.command?.lowercased() == "query" }
        #expect(running.isEmpty, "the cancelled statement was killed on the server")
        #expect(try await check.execute("SELECT COUNT(*) FROM ccinn_it.writes").scalar == writesBefore, "no write happened")
        await check.close()

        // Audit log: every call recorded, file private.
        let audit = try String(contentsOf: process.directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        #expect(audit.contains("\"tool\":\"run_query\""))
        let permissions = try FileManager.default.attributesOfItem(atPath: process.directory.appendingPathComponent("mcp-audit.jsonl").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}

/// A running MCP server subprocess with a temporary profile directory and a test-only secrets file.
final class MCPProcess: @unchecked Sendable {
    static var binary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CcinnMysql")
    }

    static var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let directory: URL
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [JSONValue] = []

    init(target: IntegrationEnvironment.Target, access: MCPAccess = .readOnly) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = ConnectionProfile(name: "IT \(target.label)", host: target.endpoint.host, port: target.endpoint.port, username: "root",
                                        defaultDatabase: "shop", connectTimeout: 30, mcpAccess: access)
        try ProfileRepository(directory: directory, secrets: InMemorySecretStore()).save([profile])
        let secrets = directory.appendingPathComponent("secrets.json")
        let json = "{\"\(profile.id.uuidString)\": {\"password\": \"\(IntegrationEnvironment.rootPassword)\"}}"
        FileManager.default.createFile(atPath: secrets.path, contents: Data(json.utf8), attributes: [.posixPermissions: 0o600])

        process.executableURL = Self.binary
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["CCINNMYSQL_PROFILE_DIR"] = directory.path
        environment[InsecureFileSecretStore.environmentVariable] = secrets.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let message = try? JSONValue.parse(Data(line)) { self.messages.append(message) }
            }
            self.lock.unlock()
        }
        try process.run()
    }

    func send(_ message: JSONValue) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((message.serialized() + "\n").utf8))
    }

    func responses(for id: Int64) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0["id"] == .int(id) }
    }

    func request(_ message: JSONValue, timeout: Duration = .seconds(90)) async throws -> JSONValue {
        try send(message)
        guard let id = message["id"]?.intValue else { return .null }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let response = responses(for: id).first { return response }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MCPToolError("No response to request \(id)")
    }

    /// Calls a tool and returns its structured result, failing the test on tool errors.
    func call(id: Int64, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let response = try await request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]])
        let result = response["result"]
        if result?["isError"] == .bool(true) {
            throw MCPToolError("\(name) failed: \(result?["content"]?[0]?["text"]?.stringValue ?? "?")")
        }
        return result?["structuredContent"] ?? .null
    }

    func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
