import Foundation
import Testing
@testable import MySQLKit

/// A MySQL-protocol server whose TLS stack only speaks TLS 1.0 (like old yaSSL builds of MySQL 5.6/5.7),
/// run with the system Python (LibreSSL) so the real `URLSessionStreamTask` TLS path is exercised.
@Suite("TLS 1.0-only servers", .enabled(if: LegacyTLSServer.isAvailable), .serialized)
struct LegacyTLSServerTests {
    @Test func withoutTheLegacyToggleTheErrorNamesTheCause() async throws {
        let server = try await LegacyTLSServer.start()
        for mode in [TLSMode.preferred, .required] {
            let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: server.port), username: "u", password: "p",
                                                        connectTimeout: 3, tls: TLSOptions(mode: mode, allowLegacyProtocols: false))
            let started = ContinuousClock.now
            await #expect { _ = try await MySQLConnection.connect(configuration) } throws: { error in
                guard let error = error as? MySQLError else { return false }
                return error.kind == .tls && error.message.contains("TLS 1.0/1.1") && error.message.contains("SSH tunnel")
                    && error.message.contains("within 3 s") && error.message.contains("not responding")
            }
            // The 3 s deadline fired instead of a hang; the bound leaves room for a busy CI runner.
            #expect(ContinuousClock.now - started < .seconds(20))
        }
        #expect(await server.stop() == 0, "credentials never travel in plaintext, not even in preferred mode")
    }

    @Test func withTheLegacyToggleTLS10IsNegotiated() async throws {
        let server = try await LegacyTLSServer.start()
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: server.port), username: "u", password: "p",
                                                    connectTimeout: 5, tls: TLSOptions(mode: .required, allowLegacyProtocols: true))
        // The fake answers the (encrypted) handshake response with "Access denied": TLS itself worked.
        await #expect { _ = try await MySQLConnection.connect(configuration) } throws: { ($0 as? MySQLError)?.code == 1045 }
        await server.stop()
    }
}

/// Spawns `/usr/bin/python3` with a tiny fake: greeting with CLIENT_SSL, read SSLRequest, TLS 1.0 only, then ERR 1045.
final class LegacyTLSServer: @unchecked Sendable {
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") && FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")
    }

    static let script = #"""
    import socket, ssl, struct, sys
    cert, key, portfile = sys.argv[1], sys.argv[2], sys.argv[3]
    def packet(seq, payload): return struct.pack('<I', len(payload))[:3] + bytes([seq]) + payload
    caps = 0x1 | 0x4 | 0x200 | 0x800 | 0x2000 | 0x8000 | 0x80000 | 0x200000
    greeting = bytes([10]) + b'5.6.20\0' + struct.pack('<I', 9) + bytes(range(1, 9)) + b'\0' + struct.pack('<H', caps & 0xFFFF) \
        + bytes([33]) + struct.pack('<H', 2) + struct.pack('<H', caps >> 16) + bytes([21]) + bytes(10) + bytes(range(9, 21)) + b'\0' \
        + b'mysql_native_password\0'
    srv = socket.socket(); srv.bind(('127.0.0.1', 0)); srv.listen(5)
    open(portfile, 'w').write(str(srv.getsockname()[1]))
    while True:
        conn, _ = srv.accept()
        try:
            conn.sendall(packet(0, greeting))
            request = conn.recv(36)
            if len(request) != 36:
                print('plaintext-handshake', flush=True)
                conn.close(); continue
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLSv1)
            ctx.load_cert_chain(cert, key)
            tls = ctx.wrap_socket(conn, server_side=True)
            tls.recv(4096)
            tls.sendall(packet(3, b'\xff\x15\x04#28000Access denied'))
            tls.close()
        except Exception as error:
            print('error', error, flush=True)
            conn.close()
    """#

    let port: Int
    private let process: Process
    private let output: Pipe
    private let directory: URL

    private init(port: Int, process: Process, output: Pipe, directory: URL) {
        self.port = port
        self.process = process
        self.output = output
        self.directory = directory
    }

    /// Starts the fake. Every wait is `async`: blocking a thread here (`waitUntilExit`, `Thread.sleep`) starves
    /// the Swift concurrency pool, which has only 3 threads on GitHub's macOS runners, and hung the whole test run.
    static func start() async throws -> LegacyTLSServer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-legacytls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=legacy", "-days", "1",
                             "-keyout", directory.appendingPathComponent("key.pem").path, "-out", directory.appendingPathComponent("cert.pem").path]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try await runToCompletion(openssl)
        guard openssl.terminationStatus == 0 else { throw MySQLError(.network, "openssl could not create the test certificate") }
        let scriptURL = directory.appendingPathComponent("fake.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let portFile = directory.appendingPathComponent("port")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, directory.appendingPathComponent("cert.pem").path, directory.appendingPathComponent("key.pem").path, portFile.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var port = 0
        for _ in 0..<200 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let value = Int(text) {
                port = value
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let server = LegacyTLSServer(port: port, process: process, output: output, directory: directory)
        guard port > 0 else {
            await server.stop()
            throw MySQLError(.network, "fake TLS server did not start")
        }
        return server
    }

    /// Runs a short-lived process and resumes when it exits, without blocking a thread.
    private static func runToCompletion(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Stops the fake and returns how many clients sent their handshake response without TLS
    /// (`nil` if the fake would not stop, so a test expecting 0 cannot pass by accident).
    @discardableResult
    func stop() async -> Int? {
        if process.isRunning { process.terminate() }
        for _ in 0..<100 {
            guard process.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard !process.isRunning else { return nil }
        // The writer has exited, so reading to the end returns at once.
        let data = (try? output.fileHandleForReading.readToEnd()) ?? nil
        let text = String(decoding: data ?? Data(), as: UTF8.self)
        return text.components(separatedBy: "plaintext-handshake").count - 1
    }
}
