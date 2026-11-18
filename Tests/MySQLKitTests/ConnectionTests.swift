import Foundation
import MySQLWire
import Testing
@testable import MySQLKit

private func configuration(password: String = "secret", database: String? = "shop", allowCleartext: Bool = false) -> ConnectionConfiguration {
    ConnectionConfiguration(endpoint: Endpoint(host: "fake", port: 3306), username: "ccinn", password: password, database: database,
                            connectTimeout: 2, allowCleartextPassword: allowCleartext)
}

private func connect(_ server: FakeMySQLServer, configuration: ConnectionConfiguration = configuration()) async throws -> MySQLConnection {
    try await MySQLConnection.connect(configuration) { _, _ in server }
}

@Suite("MySQL connection")
struct ConnectionTests {
    // Final review, item 7: a handshake string ends at NUL, and the encoder dropped it, so `information_\0schema` reached the
    // server as information_schema after the read-only guard had checked another name. The handshake now refuses a user or
    // database name holding NUL before it writes anything (no SSL request, no handshake response).
    @Test(arguments: [("ccinn", "information_\u{0}schema"), ("ccinn", "information_schema\u{0}"), ("ccinn", "\u{0}shop"), ("cc\u{0}inn", "shop")])
    func namesWithNULAreRefusedBeforeAnythingIsSent(user: String, database: String) async {
        for offersTLS in [false, true] {
            let server = FakeMySQLServer(offersTLS: offersTLS)
            let settings = ConnectionConfiguration(endpoint: Endpoint(host: "fake", port: 3306), username: user, password: "secret",
                                                   database: database, connectTimeout: 2)
            let error = await #expect(throws: MySQLError.self) { _ = try await connect(server, configuration: settings) }
            #expect(error?.kind == .invalidArgument, "\(user.debugDescription) \(database.debugDescription): \(String(describing: error))")
            #expect(server.handshakeResponse.isEmpty && !server.sawSSLRequest && server.queries.isEmpty)
        }
    }

    @Test func handshakeSendsCredentialsAndDatabase() async throws {
        let server = FakeMySQLServer(connectionID: 99)
        let connection = try await connect(server)
        #expect(connection.connectionID == 99)
        #expect(connection.protocolVersion == "8.0.33")

        var reader = PayloadReader(server.handshakeResponse)
        let capabilities = Capabilities(rawValue: try reader.readUInt32())
        #expect(capabilities.contains(.connectWithDB))
        #expect(!capabilities.contains(.deprecateEOF), "classic EOF framing is requested for maximum compatibility")
        _ = try reader.readBytes(4 + 1 + 23)
        #expect(try reader.readNullTerminatedString() == "ccinn")
        let token = try #require(try reader.readLengthEncodedBytes())
        #expect(token == AuthPlugin.nativePassword(password: "secret", scramble: Array(1...20)))
        #expect(try reader.readNullTerminatedString() == "shop")
        #expect(try reader.readNullTerminatedString() == "mysql_native_password")
    }

    @Test func rejectedCredentialsSurfaceAsAuthenticationError() async {
        let server = FakeMySQLServer(auth: .reject(code: 1045, message: "Access denied for user 'ccinn'"))
        await #expect {
            _ = try await connect(server)
        } throws: { error in
            let error = error as? MySQLError
            return error?.kind == .authentication && error?.code == 1045
        }
        #expect(server.isClosed)
    }

    @Test func clearPasswordSwitchRequiresOptIn() async throws {
        let refused = FakeMySQLServer(auth: .switchTo(plugin: "mysql_clear_password"))
        await #expect(throws: MySQLError.self) { _ = try await connect(refused) }

        let allowed = FakeMySQLServer(auth: .switchTo(plugin: "mysql_clear_password"))
        _ = try await connect(allowed, configuration: configuration(allowCleartext: true))
        #expect(allowed.authSwitchReply == Array("secret".utf8) + [0])
    }

    @Test func nativePasswordSwitchUsesTheNewScramble() async throws {
        let server = FakeMySQLServer(auth: .switchTo(plugin: "mysql_native_password"))
        _ = try await connect(server)
        #expect(server.authSwitchReply == AuthPlugin.nativePassword(password: "secret", scramble: Array(repeating: 5, count: 20)))
    }

    @Test func readsRowsWithNullsAndNameLookup() async throws {
        let server = FakeMySQLServer { _ in
            .packets(FakeMySQLServer.resultSet([("TABLE_NAME", .varString), ("TABLE_ROWS", .longLong)],
                                               [["orders", "20000"], ["v_paid", nil]]))
        }
        let connection = try await connect(server)
        let result = try await connection.execute("SELECT 1")
        #expect(result.columnNames == ["TABLE_NAME", "TABLE_ROWS"])
        #expect(result.rows.count == 2)
        let records = result.records
        #expect(records[0].text("table_name") == "orders")
        #expect(records[0].int("TABLE_ROWS") == 20000)
        #expect(records[1].int("TABLE_ROWS") == nil)
        #expect(records[1].text("missing", "TABLE_NAME") == "v_paid")
        #expect(!result.isTruncated)
    }

    @Test func setsSessionVariablesAfterConnecting() async throws {
        let server = FakeMySQLServer()
        var configuration = configuration()
        configuration.sessionVariables = [("sql_mode", "ANSI"), ("bad name;", "x")]
        _ = try await connect(server, configuration: configuration)
        #expect(server.queries == ["SET NAMES utf8mb4", "SET SESSION sql_mode = 'ANSI'", "SET SESSION badname = 'x'"])
    }

    // Final review B: a server can switch a new connection to GBK or Shift-JIS after the handshake (init_connect), where
    // 0x5C can be part of a character. Every connection, and every reset, goes back to utf8mb4 first.
    @Test func everyConnectionAndResetSwitchesToUTF8MB4() async throws {
        let server = FakeMySQLServer()
        let connection = try await connect(server)
        #expect(server.queries == ["SET NAMES utf8mb4"])
        try await connection.resetSession()
        #expect(server.queries == ["SET NAMES utf8mb4", "SET NAMES utf8mb4"])
    }

    @Test func okPacketReportsAffectedRows() async throws {
        let server = FakeMySQLServer { _ in .packets([FakeMySQLServer.ok(affectedRows: 42)]) }
        let connection = try await connect(server)
        let result = try await connection.execute("DELETE FROM t")
        #expect(!result.hasRowSet)
        #expect(result.affectedRows == 42)
    }

    @Test func serverErrorKeepsConnectionUsable() async throws {
        let server = FakeMySQLServer { sql in
            sql.contains("bad")
                ? .packets([FakeMySQLServer.error(code: 1064, state: "42000", message: "Getting syntax error")])
                : .packets(FakeMySQLServer.resultSet([("x", .longLong)], [["1"]]))
        }
        let connection = try await connect(server)
        await #expect {
            _ = try await connection.execute("bad sql")
        } throws: { ($0 as? MySQLError)?.kind == .server && ($0 as? MySQLError)?.sqlState == "42000" }
        #expect(await !connection.isBroken)
        #expect(try await connection.execute("SELECT 1").scalar == "1")
    }

    @Test func errorInsideRowStreamIsReported() async throws {
        let server = FakeMySQLServer { _ in
            var packets = FakeMySQLServer.resultSet([("x", .longLong)], [["1"]])
            packets.removeLast()
            packets.append(FakeMySQLServer.error(code: 1317, message: "Query cancelled"))
            return .packets(packets)
        }
        let connection = try await connect(server)
        await #expect { _ = try await connection.execute("SELECT x") } throws: { ($0 as? MySQLError)?.isQueryInterrupted == true }
        #expect(await !connection.isBroken)
    }

    @Test func multipleResultsAreCollected() async throws {
        let server = FakeMySQLServer { _ in
            .packets(FakeMySQLServer.resultSet([("a", .longLong)], [["1"]], moreResults: true)
                + [FakeMySQLServer.ok(affectedRows: 3, status: 0x000A)]
                + FakeMySQLServer.resultSet([("b", .varString)], [["x"], ["y"]]))
        }
        let connection = try await connect(server)
        let results = try await connection.query("SELECT 1; DELETE ...; SELECT 'x'")
        #expect(results.count == 3)
        #expect(results[1].affectedRows == 3)
        #expect(results[2].rows.count == 2)
    }

    @Test func rowLimitTruncatesAndDrainsSmallOverflow() async throws {
        let rows = (0..<50).map { [String($0)] as [String?] }
        let server = FakeMySQLServer { _ in .packets(FakeMySQLServer.resultSet([("n", .longLong)], rows)) }
        let connection = try await connect(server)
        let result = try await connection.execute("SELECT n", limits: RowLimits(maxRows: 10, drainRows: 100))
        #expect(result.rows.count == 10)
        #expect(result.isTruncated)
        #expect(await !connection.isBroken, "a small overflow is drained so the connection stays reusable")
    }

    @Test func hugeOverflowAbandonsTheConnection() async throws {
        let rows = (0..<50).map { [String($0)] as [String?] }
        let server = FakeMySQLServer { _ in .packets(FakeMySQLServer.resultSet([("n", .longLong)], rows)) }
        let connection = try await connect(server)
        let result = try await connection.execute("SELECT n", limits: RowLimits(maxRows: 10, drainRows: 5))
        #expect(result.rows.count == 10)
        #expect(result.isTruncated)
        #expect(await connection.isBroken)
        #expect(server.isClosed)
    }

    @Test func cancellationClosesTheSocket() async throws {
        let server = FakeMySQLServer { _ in .hang }
        let connection = try await connect(server)
        let task = Task { try await connection.execute("SELECT sleep(100)") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect { _ = try await task.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        #expect(await connection.isBroken)
        #expect(server.isClosed)
    }

    @Test func overlappingStatementsFailFast() async throws {
        let server = FakeMySQLServer { _ in .hang }
        let connection = try await connect(server)
        let first = Task { try await connection.execute("SELECT sleep(100)") }
        try await Task.sleep(for: .milliseconds(50))
        await #expect { _ = try await connection.execute("SELECT 1") } throws: { ($0 as? MySQLError)?.kind == .busy }
        first.cancel()
        _ = try? await first.value
    }

    @Test func handshakeTimeoutIsReported() async {
        // A server that accepts TCP but never sends a greeting.
        let silent = SilentTransport()
        let config = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "u", connectTimeout: 1)
        let started = ContinuousClock.now
        await #expect {
            _ = try await MySQLConnection.connect(config) { _, _ in silent }
        } throws: { ($0 as? MySQLError)?.kind == .timeout }
        // The 1 s deadline fired instead of the connect hanging. Generous bound: wall-clock time on a busy CI
        // runner includes waiting for a thread while other tests run.
        #expect(ContinuousClock.now - started < .seconds(15))
    }
}

private final class SilentTransport: ByteTransport, Sendable {
    func send(_ bytes: [UInt8]) async throws {}
    func startTLS(_ options: TLSOptions) throws {}
    func receive() async throws -> [UInt8] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
    func close() {}
}

@Suite("Connection attributes")
struct ConnectionAttributeTests {
    @Test func programNameFollowsTheApplicationName() {
        var configuration = ConnectionConfiguration(endpoint: Endpoint(host: "db", port: 3306), username: "u")
        #expect(Handshake.attributes(configuration).contains { $0 == ("program_name", "CcinnMysql") })
        configuration.applicationName = "CcinnMysql MCP"
        let attributes = Handshake.attributes(configuration)
        #expect(attributes.contains { $0 == ("program_name", "CcinnMysql MCP") })
        #expect(attributes.contains { $0 == ("_client_name", "CcinnMysql MCP") })
        #expect(attributes.contains { $0 == ("_pid", String(ProcessInfo.processInfo.processIdentifier)) }, "like libmysqlclient, for DBAs")
        configuration.applicationName = String(repeating: "x", count: 300)
        #expect(Handshake.attributes(configuration).allSatisfy { $0.1.count <= 64 }, "attribute values stay bounded")
    }
}
