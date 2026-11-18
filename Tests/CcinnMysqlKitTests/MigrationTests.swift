import Foundation
import Testing
@testable import CcinnMysqlKit
import MySQLKit

/// Fast key derivation for tests (real backups use `SecretSealing.defaultIterations`).
private let testIterations = 1_000

@Suite("Migration: secrets")
struct SecretSealingTests {
    let secrets = ["A": ProfileSecrets(password: "p@ss", sshSecret: nil, clientCertificatePassphrase: "pkcs")]
    let header = Data("ccinnmysql-backup|1|A".utf8)

    @Test func roundTripsAndRejectsWrongPassphraseOrTampering() throws {
        let sealed = try SecretSealing.seal(secrets, passphrase: "correct horse", associatedData: header, iterations: testIterations)
        #expect(sealed.iterations == testIterations && sealed.salt.count == 16)
        #expect(try SecretSealing.open(sealed, passphrase: "correct horse", associatedData: header) == secrets)
        #expect(throws: MigrationError.self) { try SecretSealing.open(sealed, passphrase: "wrong horse", associatedData: header) }
        #expect(throws: MigrationError.self) { try SecretSealing.open(sealed, passphrase: "correct horse", associatedData: Data("other".utf8)) }
        var tampered = sealed
        tampered.box[tampered.box.count - 1] ^= 0x01
        #expect(throws: MigrationError.self) { try SecretSealing.open(tampered, passphrase: "correct horse", associatedData: header) }
        var slow = sealed
        slow.iterations = 1_000_000_000
        #expect(throws: MigrationError.self, "absurd work factors are refused, not run") {
            try SecretSealing.open(slow, passphrase: "correct horse", associatedData: header)
        }
        #expect(throws: MigrationError.self) { try SecretSealing.seal(secrets, passphrase: "short", associatedData: header) }
    }

    @Test func freshSaltEveryTime() throws {
        let first = try SecretSealing.seal(secrets, passphrase: "correct horse", associatedData: header, iterations: testIterations)
        let second = try SecretSealing.seal(secrets, passphrase: "correct horse", associatedData: header, iterations: testIterations)
        #expect(first.salt != second.salt && first.box != second.box)
    }
}

@Suite("Migration: paths")
struct PathRemapperTests {
    @Test func remapsTheOldHomeOnlyWhenTheTargetExists() {
        let existing: Set<String> = ["/Users/new/code/api", "/opt/shared"]
        let remapper = PathRemapper(sourceHome: "/Users/old", targetHome: "/Users/new") { existing.contains($0) }
        #expect(remapper.remap("/opt/shared") == .unchanged("/opt/shared"))
        #expect(remapper.remap("/Users/old/code/api") == .remapped("/Users/new/code/api"))
        #expect(remapper.remap("/Users/old/code/gone") == .missing("/Users/old/code/gone"))
        #expect(remapper.remap("/Users/older/code/api") == .missing("/Users/older/code/api"), "a prefix must end at a path separator")
        #expect(remapper.remap("~/certs/ca.pem") == .unchanged("~/certs/ca.pem"), "tilde paths resolve on the new Mac by themselves")
    }
}

@Suite("Migration: knowledge merge")
struct KnowledgeMergeTests {
    let key = KnowledgeKey(connectionID: UUID(), database: "ads")
    let old = Date(timeIntervalSince1970: 1_000)
    let new = Date(timeIntervalSince1970: 2_000)

    @Test func newerNotesWinButTheUserBeatsAnAI() {
        var local = KnowledgeBase(key: key)
        var incoming = KnowledgeBase(key: key)
        local.notes.tables["orders"] = TableNote(summary: "local, newer", author: .ai, updatedAt: new)
        incoming.notes.tables["orders"] = TableNote(summary: "incoming, older", author: .ai, updatedAt: old)
        local.notes.tables["users"] = TableNote(summary: "local AI", author: .ai, updatedAt: new)
        incoming.notes.tables["users"] = TableNote(summary: "incoming user", author: .user, updatedAt: old)
        incoming.notes.tables["dsp"] = TableNote(summary: "only incoming", author: .ai, updatedAt: old)
        incoming.notes.columns["orders"] = ["status": ColumnNote(note: "state", author: .user, updatedAt: old)]
        incoming.notes.glossary["ecpm"] = GlossaryTerm(term: "eCPM", definition: "x", author: .ai, updatedAt: old)
        local.notes.verdicts["e"] = RelationshipVerdict(status: .confirmed, reason: nil, author: .user, updatedAt: old)
        incoming.notes.verdicts["e"] = RelationshipVerdict(status: .rejected, reason: "x", author: .ai, updatedAt: new)
        let merged = KnowledgeMerge.merge(local: local, incoming: incoming)
        #expect(merged.notes.tables["orders"]?.summary == "local, newer")
        #expect(merged.notes.tables["users"]?.summary == "incoming user")
        #expect(merged.notes.tables["dsp"]?.summary == "only incoming")
        #expect(merged.notes.columns["orders"]?["status"]?.note == "state")
        #expect(merged.notes.glossary["ecpm"] != nil)
        #expect(merged.notes.verdicts["e"]?.status == .confirmed, "an AI verdict never replaces the user's")
    }

    @Test func projectsUniteByPathAndFactsComeFromTheNewerBuild() {
        var local = KnowledgeBase(key: key)
        var incoming = KnowledgeBase(key: key)
        local.projects = [LinkedProject(name: "api", path: "/Users/new/code/api")]
        incoming.projects = [LinkedProject(name: "api", path: "/Users/new/code/api"), LinkedProject(name: "api", path: "/Users/new/other/api"),
                             LinkedProject(name: "web", path: "/Users/new/code/web")]
        local.snapshot = KnowledgeSnapshot(tables: [table("t", [col("id")])])
        local.build = BuildInfo(builtAt: old, durationSeconds: 1, codeScanned: true, projects: [], changes: nil, warnings: [])
        incoming.snapshot = KnowledgeSnapshot(tables: [table("t", [col("id")]), table("u", [col("id")])])
        incoming.build = BuildInfo(builtAt: new, durationSeconds: 1, codeScanned: true, projects: [], changes: nil, warnings: [])
        let merged = KnowledgeMerge.merge(local: local, incoming: incoming)
        #expect(merged.projects.map(\.path) == ["/Users/new/code/api", "/Users/new/other/api", "/Users/new/code/web"])
        #expect(Set(merged.projects.map(\.name)).count == 3, "names stay unique")
        #expect(merged.snapshot?.tables.count == 2)
        let reversed = KnowledgeMerge.merge(local: incoming, incoming: local)
        #expect(reversed.snapshot?.tables.count == 2, "an older build never replaces a newer one")
    }
}

@Suite("Migration: export and import")
struct MigrationRoundTripTests {
    /// One Mac: a profile folder with an in-memory keychain and a knowledge store.
    final class Mac: @unchecked Sendable {
        let directory = TemporaryDirectory()
        let secrets = InMemorySecretStore()
        let repository: ProfileRepository
        let store: KnowledgeStore

        init() {
            repository = ProfileRepository(directory: directory.url, secrets: secrets)
            store = KnowledgeStore(root: directory.url.appendingPathComponent("Knowledge"))
        }
    }

    private func source() async throws -> (Mac, ConnectionProfile) {
        let mac = Mac()
        var profile = ConnectionProfile(name: "Prod", host: "db.internal", username: "report", mcpAccess: .readOnly)
        profile.caCertificatePath = "/Users/old/certs/ca.pem"
        profile.ssh = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: .privateKey, privateKeyPath: "/Users/old/.ssh/id_ed25519")
        try mac.repository.save([profile])
        try mac.repository.storeSecrets(for: profile, password: "s3cret-pw", sshSecret: "key-pass")
        let key = KnowledgeKey(connectionID: profile.id, database: "ads")
        try await mac.store.update(key) { kb in
            kb.projects = [LinkedProject(name: "api", path: "/Users/old/code/api")]
            kb.snapshot = KnowledgeSnapshot(tables: [table("orders", [col("id")])])
            kb.notes.tables["orders"] = TableNote(summary: "One row per order", author: .user)
        }
        return (mac, profile)
    }

    private func importer(_ mac: Mac, existing: Set<String>) -> MigrationImporter {
        MigrationImporter(repository: mac.repository, store: mac.store, homeDirectory: "/Users/new") { existing.contains($0) }
    }

    @Test func movesConnectionsSecretsAndKnowledgeToANewMac() async throws {
        let (from, profile) = try await source()
        let bundle = try MigrationExporter.bundle(profiles: try from.repository.load(), repository: from.repository, store: from.store,
                                                  passphrase: "correct horse", appVersion: "1.4.0", homeDirectory: "/Users/old",
                                                  iterations: testIterations).bundle
        let data = try bundle.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("s3cret-pw") == false, "secrets only as ciphertext")

        let to = Mac()
        let existing: Set<String> = ["/Users/new/code/api", "/Users/new/certs/ca.pem"]
        let report = try await importer(to, existing: existing).run(try MigrationBundle.decode(data),
                                                                    options: .init(passphrase: "correct horse"))
        #expect(report.added == ["Prod"] && report.secretsRestored == 1 && report.knowledgeCreated == ["Prod/ads"])
        #expect(report.remapped.contains("/Users/old/code/api → /Users/new/code/api"))
        #expect(report.missing == ["/Users/old/.ssh/id_ed25519"])
        let imported = try #require(try to.repository.load().first)
        #expect(imported.id == profile.id && imported.host == "db.internal" && imported.mcpAccess == .readOnly)
        #expect(imported.caCertificatePath == "/Users/new/certs/ca.pem")
        #expect(to.repository.password(for: imported) == "s3cret-pw" && to.repository.sshSecret(for: imported) == "key-pass")
        let knowledge = try #require(try to.store.load(KnowledgeKey(connectionID: profile.id, database: "ads")))
        #expect(knowledge.projects.first?.path == "/Users/new/code/api")
        #expect(knowledge.notes.tables["orders"]?.author == .user)
    }

    @Test func existingConnectionsAreKeptUnlessReplacing() async throws {
        let (from, _) = try await source()
        let bundle = try MigrationExporter.bundle(profiles: try from.repository.load(), repository: from.repository, store: from.store,
                                                  passphrase: nil, appVersion: "1.4.0", homeDirectory: "/Users/old").bundle
        #expect(bundle.secrets == nil)
        let to = Mac()
        _ = try await importer(to, existing: []).run(bundle, options: .init())
        var local = try #require(try to.repository.load().first)
        local.host = "changed.local"
        try to.repository.save([local])
        let kept = try await importer(to, existing: []).run(bundle, options: .init())
        #expect(kept.skipped == ["Prod"] && kept.knowledgeMerged == ["Prod/ads"])
        #expect(try to.repository.load().first?.host == "changed.local")
        let replaced = try await importer(to, existing: []).run(bundle, options: .init(replaceExisting: true))
        #expect(replaced.updated == ["Prod"])
        #expect(try to.repository.load().first?.host == "db.internal")
        #expect(try to.repository.load().count == 1)
    }

    @Test func wrongPassphraseChangesNothing() async throws {
        let (from, _) = try await source()
        let bundle = try MigrationExporter.bundle(profiles: try from.repository.load(), repository: from.repository, store: from.store,
                                                  passphrase: "correct horse", appVersion: "1.4.0", homeDirectory: "/Users/old",
                                                  iterations: testIterations).bundle
        let to = Mac()
        await #expect(throws: MigrationError.self) {
            try await importer(to, existing: []).run(bundle, options: .init(passphrase: "wrong horse"))
        }
        #expect(try to.repository.load().isEmpty)
        #expect(to.store.list(connectionID: bundle.connections[0].id).isEmpty)
        // Without a passphrase, everything but the secrets is imported.
        let report = try await importer(to, existing: []).run(bundle, options: .init())
        #expect(report.secretsRestored == 0 && report.secretsSkipped && report.added == ["Prod"])
    }

    @Test func refusesForeignNewerAndOversizedFiles() throws {
        #expect(throws: MigrationError.self) { try MigrationBundle.decode(Data("{not json".utf8)) }
        #expect(throws: MigrationError.self) { try MigrationBundle.decode(Data(#"{"format":"something-else","version":1}"#.utf8)) }
        #expect(throws: MigrationError.self) {
            try MigrationBundle.decode(Data(#"{"format":"ccinnmysql-backup","version":99,"connections":[]}"#.utf8))
        }
        #expect(throws: MigrationError.self) { try MigrationBundle.decode(Data(repeating: 0x20, count: 65), maxBytes: 64) }
    }

    @Test func knowledgeOfUnknownConnectionsIsIgnored() async throws {
        let (from, _) = try await source()
        var bundle = try MigrationExporter.bundle(profiles: try from.repository.load(), repository: from.repository, store: from.store,
                                                  passphrase: nil, appVersion: "1.4.0", homeDirectory: "/Users/old").bundle
        var stray = KnowledgeBase(key: KnowledgeKey(connectionID: UUID(), database: "x"))
        stray.notes.tables["t"] = TableNote(summary: "x", author: .ai)
        bundle.knowledge.append(stray)
        let to = Mac()
        let report = try await importer(to, existing: []).run(bundle, options: .init())
        #expect(report.warnings.contains { $0.contains("unknown connection") })
        #expect(to.store.list(connectionID: stray.connectionID).isEmpty)
    }

    @Test func backupFilesArePrivate() throws {
        let directory = TemporaryDirectory()
        let file = directory.url.appendingPathComponent("all.ccinnmysql-backup")
        try PrivateFile.write(Data("{}".utf8), to: file)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        try PrivateFile.write(Data("{\"a\":1}".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("{\"a\":1}".utf8), "replaces atomically")
    }
}
