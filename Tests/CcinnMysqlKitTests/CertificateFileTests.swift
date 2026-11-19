import Darwin
import Foundation
import MySQLKit
import Testing
@testable import CcinnMysqlKit

/// The CA certificate, client certificate and pinned server key a profile names (possibly an imported one) are read only
/// when they are bounded regular files, and `~/…` (as imported profiles store paths under home) names this Mac's home.
@Suite("Certificate and key files")
struct CertificateFileTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-cert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aDeviceIsRefusedWithoutReadingIt() {
        let started = ContinuousClock.now
        #expect(throws: MySQLError.self) { try ConnectionProfile.readFile("/dev/zero", what: "CA certificate") }
        var profile = ConnectionProfile(name: "x")
        profile.caCertificatePath = "/dev/zero"
        #expect(throws: MySQLError.self) { try profile.configuration(password: "") }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func aPipeIsRefusedWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("client.p12").path
        #expect(mkfifo(fifo, 0o600) == 0)
        // No writer ever opens it; a blocking open would hang here.
        #expect(throws: MySQLError.self) { try ConnectionProfile.readFile(fifo, what: "client certificate") }
        var profile = ConnectionProfile(name: "x")
        profile.serverPublicKeyPath = fifo
        #expect(throws: MySQLError.self) { try profile.configuration(password: "") }
    }

    @Test func aDirectoryOrAnOversizedFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: MySQLError.self) { try ConnectionProfile.readFile(directory.path, what: "CA certificate") }
        let large = directory.appendingPathComponent("large.pem")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ConnectionProfile.maximumKeyFileBytes) + 1)
        try handle.close()
        #expect(throws: MySQLError.self) { try ConnectionProfile.readFile(large.path, what: "CA certificate") }
        #expect(throws: MySQLError.self) { try ConnectionProfile.readFile(directory.appendingPathComponent("missing.pem").path, what: "CA certificate") }
    }

    @Test func aSmallFileIsReadThroughASymbolicLink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("server-key.pem")
        let pem = Data("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n".utf8)
        try pem.write(to: file)
        let link = directory.appendingPathComponent("link.pem")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try ConnectionProfile.readFile(link.path, what: "server public key") == pem)
        var profile = ConnectionProfile(name: "x")
        profile.serverPublicKeyPath = " \(link.path) "
        #expect(try profile.configuration(password: "").serverPublicKeyPEM == String(decoding: pem, as: UTF8.self))
    }

    @Test func aTildePathNamesThisMacsHome() {
        let name = "ccinnmysql-missing-\(UUID().uuidString).pem"
        do {
            _ = try ConnectionProfile.readFile("~/" + name, what: "CA certificate")
            Issue.record("a missing file was read")
        } catch {
            #expect(String(describing: error).contains(NSHomeDirectory() + "/" + name), "the error names the expanded path")
        }
    }
}
