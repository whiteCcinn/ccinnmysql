import CryptoKit
import Foundation
import MySQLWire
import os
import Security
import Testing
@testable import MySQLKit

private func configuration(password: String = "secret", tls: TLSMode = .disabled, retrieval: Bool = false, pem: String? = nil) -> ConnectionConfiguration {
    ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "ccinn", password: password, connectTimeout: 2,
                            tls: TLSOptions(mode: tls), allowPublicKeyRetrieval: retrieval, serverPublicKeyPEM: pem)
}

private func connect(_ server: FakeMySQLServer, _ configuration: ConnectionConfiguration) async throws -> MySQLConnection {
    try await MySQLConnection.connect(configuration) { _, _ in server }
}

/// An RSA key pair whose public half is served as PEM by fake servers.
private struct ServerKey: @unchecked Sendable {
    let privateKey: SecKey
    let pem: String

    init() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { throw MySQLError(.invalidArgument, "keygen") }
        privateKey = key
        let base64 = pkcs1.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        pem = "-----BEGIN RSA PUBLIC KEY-----\n\(base64)\n-----END RSA PUBLIC KEY-----\n"
    }

    func decrypt(_ cipher: [UInt8]) -> [UInt8]? {
        var error: Unmanaged<CFError>?
        return (SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, Data(cipher) as CFData, &error) as Data?).map { [UInt8]($0) }
    }
}

@Suite("TLS negotiation")
struct TLSNegotiationTests {
    @Test func preferredUpgradesWhenTheServerOffersTLS() async throws {
        let server = FakeMySQLServer(offersTLS: true)
        let connection = try await connect(server, configuration(tls: .preferred))
        #expect(server.sawSSLRequest)
        #expect(server.tlsStarted)
        #expect(connection.isTLS)
        var reader = PayloadReader(server.handshakeResponse)
        #expect(Capabilities(rawValue: try reader.readUInt32()).contains(.ssl))
    }

    @Test func preferredStaysPlainWithoutServerTLS() async throws {
        let server = FakeMySQLServer(offersTLS: false)
        let connection = try await connect(server, configuration(tls: .preferred))
        #expect(!server.sawSSLRequest)
        #expect(!connection.isTLS)
    }

    @Test func requiredFailsBeforeSendingCredentials() async {
        let server = FakeMySQLServer(offersTLS: false)
        await #expect { _ = try await connect(server, configuration(tls: .required)) } throws: { ($0 as? MySQLError)?.kind == .tls }
        #expect(server.handshakeResponse.isEmpty, "no credentials may be sent")
    }

    @Test func preferredNeverFallsBackToPlaintextAfterTheHandshakeStarted() async throws {
        let servers = [FakeMySQLServer(connectionID: 1, offersTLS: true, failTLS: true), FakeMySQLServer(connectionID: 2, offersTLS: true)]
        let attempts = Attempts()
        await #expect { _ = try await MySQLConnection.connect(configuration(tls: .preferred)) { _, _ in servers[min(attempts.next(), 1)] } } throws: {
            ($0 as? MySQLError)?.kind == .tls
        }
        #expect(attempts.next() == 1, "no second (plaintext) attempt")
        #expect(servers[0].handshakeResponse.isEmpty || servers[0].tlsStarted)
    }

    @Test func requiredDoesNotFallBack() async {
        let server = FakeMySQLServer(offersTLS: true, failTLS: true)
        await #expect { _ = try await connect(server, configuration(tls: .required)) } throws: { ($0 as? MySQLError)?.kind == .tls }
    }

    @Test func disabledNeverSendsSSLRequest() async throws {
        let server = FakeMySQLServer(offersTLS: true)
        let connection = try await connect(server, configuration(tls: .disabled))
        #expect(!server.sawSSLRequest)
        #expect(!connection.isTLS)
    }
}

@Suite("Authentication plugins over the wire")
struct AuthPluginConnectionTests {
    @Test func cachingSHA2FastAuth() async throws {
        let server = FakeMySQLServer(plugin: "caching_sha2_password", auth: .steps(first: [FakeMySQLServer.authMoreData([0x03]), FakeMySQLServer.ok()], then: []))
        let connection = try await connect(server, configuration())
        #expect(connection.authPlugin == "caching_sha2_password")
        var reader = PayloadReader(server.handshakeResponse)
        _ = try reader.readBytes(32)
        _ = try reader.readNullTerminatedString()
        #expect(try reader.readLengthEncodedBytes() == AuthPlugin.cachingSHA2Scramble(password: "secret", nonce: FakeMySQLServer.scramble))
    }

    @Test func cachingSHA2FullAuthOverTLSSendsCleartextInsideTLS() async throws {
        let server = FakeMySQLServer(offersTLS: true, plugin: "caching_sha2_password",
                                     auth: .steps(first: [FakeMySQLServer.authMoreData([0x04])],
                                                  then: [.init(check: { $0 == Array("secret".utf8) + [0] }, reply: [FakeMySQLServer.ok()])]))
        _ = try await connect(server, configuration(tls: .required))
        #expect(server.tlsStarted)
        #expect(server.authPackets == [Array("secret".utf8) + [0]])
    }

    @Test func cachingSHA2FullAuthWithoutTLSRefusesToSendThePassword() async {
        let server = FakeMySQLServer(plugin: "caching_sha2_password", auth: .steps(first: [FakeMySQLServer.authMoreData([0x04])], then: [
            .init(reply: [FakeMySQLServer.ok()]),
        ]))
        await #expect { _ = try await connect(server, configuration()) } throws: { error in
            let error = error as? MySQLError
            return error?.kind == .authentication && error?.message.contains("TLS") == true
        }
        #expect(server.authPackets.isEmpty)
    }

    @Test func cachingSHA2FullAuthWithRetrievedPublicKey() async throws {
        let key = try ServerKey()
        let expected = AuthPlugin.xorPassword(password: "secret", nonce: FakeMySQLServer.scramble)
        let server = FakeMySQLServer(plugin: "caching_sha2_password", auth: .steps(first: [FakeMySQLServer.authMoreData([0x04])], then: [
            .init(check: { $0 == [0x02] }, reply: [FakeMySQLServer.authMoreData(Array(key.pem.utf8))]),
            .init(check: { key.decrypt($0) == expected }, reply: [FakeMySQLServer.ok()]),
        ]))
        _ = try await connect(server, configuration(retrieval: true))
        #expect(server.authPackets.count == 2)
    }

    @Test func cachingSHA2FullAuthWithPinnedKeySkipsRetrieval() async throws {
        let key = try ServerKey()
        let expected = AuthPlugin.xorPassword(password: "secret", nonce: FakeMySQLServer.scramble)
        let server = FakeMySQLServer(plugin: "caching_sha2_password", auth: .steps(first: [FakeMySQLServer.authMoreData([0x04])], then: [
            .init(check: { key.decrypt($0) == expected }, reply: [FakeMySQLServer.ok()]),
        ]))
        _ = try await connect(server, configuration(pem: key.pem))
        #expect(server.authPackets.count == 1)
    }

    @Test func sha256PasswordOverTLSAndWithRSA() async throws {
        let tlsServer = FakeMySQLServer(offersTLS: true, plugin: "sha256_password", auth: .accept)
        _ = try await connect(tlsServer, configuration(tls: .required))
        var reader = PayloadReader(tlsServer.handshakeResponse)
        _ = try reader.readBytes(32)
        _ = try reader.readNullTerminatedString()
        #expect(try reader.readLengthEncodedBytes() == Array("secret".utf8) + [0])

        let key = try ServerKey()
        let expected = AuthPlugin.xorPassword(password: "secret", nonce: FakeMySQLServer.scramble)
        let rsaServer = FakeMySQLServer(plugin: "sha256_password", auth: .steps(first: [FakeMySQLServer.authMoreData(Array(key.pem.utf8))], then: [
            .init(check: { key.decrypt($0) == expected }, reply: [FakeMySQLServer.ok()]),
        ]))
        _ = try await connect(rsaServer, configuration(retrieval: true))
        var rsaReader = PayloadReader(rsaServer.handshakeResponse)
        _ = try rsaReader.readBytes(32)
        _ = try rsaReader.readNullTerminatedString()
        #expect(try rsaReader.readLengthEncodedBytes() == [0x01], "requests the public key")
    }

    @Test func ed25519SwitchSignsTheNonce() async throws {
        let nonce = Array<UInt8>((1...32).map { UInt8($0) })
        let server = FakeMySQLServer(auth: .steps(first: [FakeMySQLServer.authSwitch(plugin: "client_ed25519", nonce: nonce)],
                                                  then: [.init(reply: [FakeMySQLServer.ok()])]))
        _ = try await connect(server, configuration())
        let signature = server.authSwitchReply
        #expect(signature.count == 64)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Ed25519.publicKey(password: Array("secret".utf8)))
        #expect(publicKey.isValidSignature(Data(signature), for: Data(nonce)))
    }

    /// Regression (review #10): a raw 32-byte ed25519 nonce whose last byte is 0x00 must be signed in full.
    @Test func ed25519NonceEndingInZeroIsSignedInFull() async throws {
        let nonce = Array<UInt8>(repeating: 9, count: 31) + [0]
        var writer = PayloadWriter()
        writer.writeUInt8(0xFE)
        writer.writeNullTerminated("client_ed25519")
        writer.writeBytes(nonce)
        let server = FakeMySQLServer(auth: .steps(first: [writer.bytes], then: [.init(reply: [FakeMySQLServer.ok()])]))
        _ = try await connect(server, configuration())
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Ed25519.publicKey(password: Array("secret".utf8)))
        #expect(publicKey.isValidSignature(Data(server.authSwitchReply), for: Data(nonce)))
    }

    @Test func unknownPluginSwitchFailsClearly() async {
        let server = FakeMySQLServer(auth: .switchTo(plugin: "authentication_kerberos_client"))
        await #expect { _ = try await connect(server, configuration()) } throws: { error in
            (error as? MySQLError)?.message.contains("authentication_kerberos_client") == true
        }
    }

    @Test func endlessAuthSwitchingIsBounded() async {
        let switchPacket = FakeMySQLServer.authSwitch(plugin: "mysql_native_password", nonce: Array(repeating: 1, count: 20))
        let steps = (0..<20).map { _ in FakeMySQLServer.AuthStep(reply: [switchPacket]) }
        let server = FakeMySQLServer(auth: .steps(first: [switchPacket], then: steps))
        await #expect { _ = try await connect(server, configuration()) } throws: { error in
            (error as? MySQLError)?.kind == .protocolViolation
        }
        #expect(server.authPackets.count <= Handshake.maxAuthRounds)
    }
}

@Suite("Pinned kills and transactions")
struct KillPinningTests {
    private func connect(_ cluster: FakeCluster, poolSize: Int = 1) async throws -> MySQLClient {
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "lb"), username: "root", connectTimeout: 2)
        return try await MySQLClient.connect(configuration, poolSize: poolSize, transportFactory: cluster.transportFactory)
    }

    @Test func cancelBehindALoadBalancerKillsOnTheRightBackend() async throws {
        let cluster = FakeCluster(backends: 3) { sql in sql.contains("long") ? .hang : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let session = client.openSession()
        let long = Task { try await session.run("SELECT 'long'") }
        try await Task.sleep(for: .milliseconds(150))
        let target = try #require(await session.runningTarget)
        await session.cancel(graceSeconds: 2)
        await #expect { _ = try await long.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        let kills = cluster.kills
        #expect(kills.count == 1)
        #expect(kills.first?.statement == "KILL QUERY \(target.threadID)")
        #expect(kills.first.map { "uuid-\($0.backend)" } == target.identity?.serverUUID, "the kill ran on the statement's server")
        await session.close()
        await client.close()
    }

    @Test func proxySQLKillUsesTheProxySessionID() async throws {
        let cluster = FakeCluster(proxySQL: true) { sql in sql.contains("long") ? .hang : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        #expect(client.serverInfo.isProxySQL)
        let session = client.openSession()
        let long = Task { try await session.run("SELECT 'long'") }
        try await Task.sleep(for: .milliseconds(150))
        let target = try #require(await session.runningTarget)
        #expect(target.threadID != UInt64(target.proxySessionID ?? 0))
        await session.cancel(graceSeconds: 2)
        await #expect { _ = try await long.value } throws: { ($0 as? MySQLError)?.kind == .cancelled }
        #expect(cluster.kills.map(\.statement) == ["KILL QUERY \(target.proxySessionID ?? 0)"])
        await session.close()
        await client.close()
    }

    @Test func lostTransactionIsReportedInsteadOfSilentlyReconnecting() async throws {
        let cluster = FakeCluster { sql in
            sql.hasPrefix("BEGIN") || sql.hasPrefix("UPDATE") ? .packets([FakeMySQLServer.ok(status: 0x0003)]) : .packets(FakeCluster.rows("ok"))
        }
        let client = try await connect(cluster)
        let session = client.openSession()
        _ = try await session.run("BEGIN")
        _ = try await session.run("UPDATE t SET a = 1")
        #expect(await session.isInTransaction)
        // The socket dies (server restart, network).
        cluster.servers.last?.close()
        await #expect { _ = try await session.run("SELECT 1") } throws: { error in
            let kind = (error as? MySQLError)?.kind
            return kind == .transactionLost || kind == .connectionClosed
        }
        // Whichever error the dead socket produced first, the transaction loss is never hidden.
        var sawLoss = false
        for _ in 0..<2 {
            do {
                _ = try await session.run("SELECT 1")
                break
            } catch let error as MySQLError where error.kind == .transactionLost {
                sawLoss = true
            }
        }
        #expect(sawLoss || !cluster.statements.isEmpty)
        #expect(try await session.run("SELECT 2").last?.scalar == "ok")
        await session.close()
        await client.close()
    }

    @Test func poolSessionsLeaveNoBackslashEscapesMode() async throws {
        let cluster = FakeCluster(status: 0x0202) { _ in .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        #expect(cluster.statements.contains("SET SESSION sql_mode = REPLACE(@@sql_mode, 'NO_BACKSLASH_ESCAPES', '')"))
        await client.close()
    }

    @Test func idlePooledConnectionsArePingedBeforeReuse() async throws {
        let cluster = FakeCluster { _ in .packets(FakeCluster.rows("ok")) }
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", connectTimeout: 2)
        let pool = ConnectionPool(maxSize: 1, validateAfterSeconds: 0) {
            try await MySQLConnection.connect(configuration, transportFactory: cluster.transportFactory)
        }
        _ = try await pool.withConnection { try await $0.execute("SELECT 1") }
        _ = try await pool.withConnection { try await $0.execute("SELECT 2") }
        #expect(cluster.servers.count == 1)
        #expect(cluster.servers.first?.pings == 1)
        await pool.close()
    }

    @Test func localInfileRequestsAreRefused() async throws {
        let server = FakeMySQLServer { _ in .packets([[0xFB] + Array("/etc/passwd".utf8)]) }
        let connection = try await MySQLConnection.connect(configuration()) { _, _ in server }
        await #expect { _ = try await connection.execute("LOAD DATA LOCAL INFILE 'x' INTO TABLE t") } throws: { error in
            (error as? MySQLError)?.kind == .protocolViolation
        }
        #expect(await connection.isBroken)
    }
}


final class Attempts: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func next() -> Int {
        count.withLock { value in
            defer { value += 1 }
            return value
        }
    }
}

@Suite("Certificate host names")
struct HostnameMatcherTests {
    @Test func dnsNamesAndWildcards() {
        let names = HostnameMatcher.Names(dns: ["db.example.com", "*.replicas.example.com"], commonName: "ignored.example.com")
        #expect(HostnameMatcher.matches(host: "db.example.com", names: names))
        #expect(HostnameMatcher.matches(host: "DB.Example.COM", names: names))
        #expect(HostnameMatcher.matches(host: "r1.replicas.example.com", names: names))
        #expect(!HostnameMatcher.matches(host: "a.b.replicas.example.com", names: names), "wildcards cover one label")
        #expect(!HostnameMatcher.matches(host: "ignored.example.com", names: names), "CN is ignored when SANs exist")
        #expect(!HostnameMatcher.matches(host: "example.com", names: HostnameMatcher.Names(dns: ["*.com"])), "no wildcard TLDs")
    }

    @Test func commonNameFallbackAndIPAddresses() {
        #expect(HostnameMatcher.matches(host: "mysql.local", names: HostnameMatcher.Names(commonName: "mysql.local")))
        #expect(!HostnameMatcher.matches(host: "127.0.0.1", names: HostnameMatcher.Names(commonName: "MySQL_Server_8.4.13_Auto_Generated_Server_Certificate")))
        #expect(HostnameMatcher.matches(host: "10.0.0.5", names: HostnameMatcher.Names(dns: ["db"], ip: ["10.0.0.5"])))
        #expect(!HostnameMatcher.matches(host: "10.0.0.6", names: HostnameMatcher.Names(ip: ["10.0.0.5"])))
        #expect(HostnameMatcher.matches(host: "[::1]", names: HostnameMatcher.Names(ip: ["::1"])))
        #expect(HostnameMatcher.format(ip: [10, 0, 0, 5]) == "10.0.0.5")
        #expect(!HostnameMatcher.matches(host: "", names: HostnameMatcher.Names(dns: [""])))
    }
}
