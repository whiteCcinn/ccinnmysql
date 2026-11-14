import Foundation
import MySQLWire
import Testing
@testable import MySQLKit

@Suite("Protocol against real servers", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct ProtocolIntegrationTests {
    typealias Target = IntegrationEnvironment.Target

    private func root(_ target: Target, tls: TLSMode = .preferred) async throws -> MySQLClient {
        try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target, tls: tls), poolSize: 2)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func connectsAndDetectsFlavor(target: Target) async throws {
        let client = try await root(target)
        defer { Task { await client.close() } }
        let info = client.serverInfo
        #expect(info.flavor == target.flavor, "\(info.versionString) / \(info.versionComment)")
        #expect(info.isTLS == target.offersTLS, "TLS: \(info.tlsVersion ?? "none"), fallback: \(info.tlsFallbackReason ?? "-")")
        if info.isTLS { #expect(info.tlsVersion?.hasPrefix("TLSv1") == true) }
        #expect(info.identity.hostname != nil)
        let rows = try await client.execute("SELECT 1 AS one, NULL AS nothing, 'é😀' AS text").first
        #expect(rows?.int("one") == 1)
        #expect(rows?.text("nothing") == nil)
        #expect(rows?.text("text") == "é😀")
    }

    @Test(arguments: IntegrationEnvironment.targets.filter(\.offersTLS))
    func tlsModesAndCertificateVerification(target: Target) async throws {
        let required = try await MySQLConnection.connect(IntegrationEnvironment.rootConfiguration(target, tls: .required))
        #expect(required.isTLS)
        let cipher = try await required.execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first?.text("Value")
        #expect(cipher?.isEmpty == false, "the server sees an encrypted session")
        await required.close()

        // The auto-generated server certificate is signed by the container's CA but does not name 127.0.0.1.
        if let ca = try? IntegrationEnvironment.copyFromContainer(target.container, path: "/var/lib/mysql/ca.pem") {
            var verifyCA = IntegrationEnvironment.rootConfiguration(target, tls: .verifyCA)
            verifyCA.tls.caCertificates = [ca]
            let verified = try await MySQLConnection.connect(verifyCA)
            #expect(verified.isTLS)
            await verified.close()

            var verifyIdentity = verifyCA
            verifyIdentity.tls.mode = .verifyIdentity
            await #expect { _ = try await MySQLConnection.connect(verifyIdentity) } throws: { ($0 as? MySQLError)?.kind == .tls }
        }
        // System roots do not trust a self-signed CA.
        await #expect { _ = try await MySQLConnection.connect(IntegrationEnvironment.rootConfiguration(target, tls: .verifyCA)) } throws: {
            ($0 as? MySQLError)?.kind == .tls
        }
    }

    @Test(arguments: IntegrationEnvironment.targets.filter { !$0.offersTLS })
    func requiredTLSFailsAgainstPlainServers(target: Target) async throws {
        await #expect { _ = try await MySQLConnection.connect(IntegrationEnvironment.rootConfiguration(target, tls: .required)) } throws: {
            ($0 as? MySQLError)?.kind == .tls
        }
        let preferred = try await MySQLConnection.connect(IntegrationEnvironment.rootConfiguration(target, tls: .preferred))
        #expect(!preferred.isTLS)
        await preferred.close()
    }

    @Test(arguments: IntegrationEnvironment.targets.filter(\.isMySQL8OrLater))
    func cachingSHA2FullAndFastAuthentication(target: Target) async throws {
        let admin = try await root(target)
        defer { Task { await admin.close() } }
        _ = try await admin.execute("DROP USER IF EXISTS 'it_sha2'@'%'")
        _ = try await admin.execute("CREATE USER 'it_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY 'Sha2-pw!'")
        _ = try await admin.execute("FLUSH PRIVILEGES")

        var configuration = IntegrationEnvironment.rootConfiguration(target, tls: .disabled)
        configuration.username = "it_sha2"
        configuration.password = "Sha2-pw!"
        // Empty cache + plaintext + no key retrieval: refuse to send the password.
        await #expect { _ = try await MySQLConnection.connect(configuration) } throws: { error in
            let error = error as? MySQLError
            return error?.kind == .authentication && error?.message.contains("TLS") == true
        }
        // Full authentication with the server's RSA key.
        configuration.allowPublicKeyRetrieval = true
        let rsa = try await MySQLConnection.connect(configuration)
        #expect(rsa.authPlugin == "caching_sha2_password")
        await rsa.close()
        // Full authentication over TLS after clearing the cache.
        _ = try await admin.execute("FLUSH PRIVILEGES")
        configuration.allowPublicKeyRetrieval = false
        configuration.tls.mode = .required
        let full = try await MySQLConnection.connect(configuration)
        #expect(full.isTLS)
        await full.close()
        // Fast authentication (cache populated) also works in plaintext.
        configuration.tls.mode = .disabled
        let fast = try await MySQLConnection.connect(configuration)
        #expect(!fast.isTLS)
        await fast.close()
        // A wrong password misses the cache, so it needs full authentication: over TLS the server says 1045.
        configuration.password = "wrong"
        configuration.tls.mode = .required
        await #expect { _ = try await MySQLConnection.connect(configuration) } throws: { ($0 as? MySQLError)?.code == 1045 }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func legacyPluginsWhereAvailable(target: Target) async throws {
        let admin = try await root(target)
        defer { Task { await admin.close() } }
        let plugins = Set(try await admin.execute("SELECT PLUGIN_NAME FROM information_schema.PLUGINS WHERE PLUGIN_STATUS = 'ACTIVE'")
            .rows.compactMap { $0.first ?? nil })
        var configuration = IntegrationEnvironment.rootConfiguration(target, tls: .disabled)
        if plugins.contains("mysql_native_password") {
            _ = try await admin.execute("DROP USER IF EXISTS 'it_native'@'%'")
            if target.flavor == .mariadb {
                _ = try await admin.execute("CREATE USER 'it_native'@'%' IDENTIFIED BY 'Native-pw1'")
            } else if target.label.hasPrefix("MySQL 5.5") || target.label.hasPrefix("MySQL 5.6") {
                _ = try await admin.execute("CREATE USER 'it_native'@'%' IDENTIFIED BY 'Native-pw1'")
            } else {
                _ = try await admin.execute("CREATE USER 'it_native'@'%' IDENTIFIED WITH mysql_native_password BY 'Native-pw1'")
            }
            configuration.username = "it_native"
            configuration.password = "Native-pw1"
            let native = try await MySQLConnection.connect(configuration)
            #expect(native.authPlugin == "mysql_native_password")
            await native.close()
        }
        if plugins.contains("sha256_password") {
            _ = try await admin.execute("DROP USER IF EXISTS 'it_sha256'@'%'")
            _ = try await admin.execute("CREATE USER 'it_sha256'@'%' IDENTIFIED WITH sha256_password BY 'Sha256-pw1'")
            configuration.username = "it_sha256"
            configuration.password = "Sha256-pw1"
            configuration.allowPublicKeyRetrieval = true
            let rsa = try await MySQLConnection.connect(configuration)
            #expect(rsa.authPlugin == "sha256_password")
            await rsa.close()
            if target.offersTLS {
                configuration.allowPublicKeyRetrieval = false
                configuration.tls.mode = .required
                let overTLS = try await MySQLConnection.connect(configuration)
                #expect(overTLS.isTLS)
                await overTLS.close()
            }
        }
    }

    @Test(arguments: IntegrationEnvironment.targets.filter { $0.flavor == .mariadb })
    func mariaDBEd25519(target: Target) async throws {
        let admin = try await root(target)
        defer { Task { await admin.close() } }
        let installed = try await admin.execute("SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'ed25519' AND PLUGIN_STATUS = 'ACTIVE'").scalar
        if installed == "0" { _ = try await admin.execute("INSTALL SONAME 'auth_ed25519'") }
        _ = try await admin.execute("DROP USER IF EXISTS 'it_ed'@'%'")
        _ = try await admin.execute("CREATE USER 'it_ed'@'%' IDENTIFIED VIA ed25519 USING PASSWORD('Ed-pw-25519')")
        var configuration = IntegrationEnvironment.rootConfiguration(target, tls: .disabled)
        configuration.username = "it_ed"
        configuration.password = "Ed-pw-25519"
        let connection = try await MySQLConnection.connect(configuration)
        #expect(connection.authPlugin == "client_ed25519")
        #expect(try await connection.execute("SELECT CURRENT_USER()").scalar?.hasPrefix("it_ed@") == true)
        await connection.close()
        configuration.password = "wrong"
        await #expect { _ = try await MySQLConnection.connect(configuration) } throws: { ($0 as? MySQLError)?.kind == .authentication }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func cancelKillsTheRunningStatement(target: Target) async throws {
        let client = try await root(target)
        defer { Task { await client.close() } }
        let session = client.openSession()
        let started = ContinuousClock.now
        let running = Task { try await session.run("SELECT SLEEP(30)") }
        try await Task.sleep(for: .milliseconds(500))
        await session.cancel(graceSeconds: 5)
        let outcome = await running.result
        #expect(ContinuousClock.now - started < .seconds(10))
        switch outcome {
        case .success(let results):
            // SLEEP() returns 1 when interrupted on some versions instead of raising an error.
            #expect(results.last?.scalar == "1")
        case .failure(let error):
            #expect((error as? MySQLError)?.kind == .cancelled)
        }
        // The session stays usable after a KILL QUERY.
        #expect(try await session.run("SELECT 7").last?.scalar == "7")
        await session.close()
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func lostTransactionIsReported(target: Target) async throws {
        let client = try await root(target)
        defer { Task { await client.close() } }
        _ = try await client.execute("CREATE DATABASE IF NOT EXISTS ccinn_it")
        _ = try await client.execute("CREATE TABLE IF NOT EXISTS ccinn_it.tx (id INT PRIMARY KEY, v INT) ENGINE=InnoDB")
        _ = try await client.execute("REPLACE INTO ccinn_it.tx VALUES (1, 0)")
        let session = client.openSession(database: "ccinn_it")
        _ = try await session.run("START TRANSACTION")
        _ = try await session.run("UPDATE tx SET v = v + 1 WHERE id = 1")
        #expect(await session.isInTransaction)
        let threadID = try #require(try await session.run("SELECT CONNECTION_ID()").last?.scalar.flatMap { UInt32($0) })
        try await client.killConnection(KillTarget(threadID: threadID, identity: client.serverInfo.identity))
        try await Task.sleep(for: .milliseconds(300))
        var sawLoss = false
        for _ in 0..<2 {
            do {
                _ = try await session.run("SELECT 1")
                break
            } catch let error as MySQLError {
                if error.kind == .transactionLost { sawLoss = true }
            }
        }
        #expect(sawLoss)
        #expect(try await session.run("SELECT v FROM tx WHERE id = 1").last?.scalar == "0", "the update was rolled back")
        await session.close()
    }
}
