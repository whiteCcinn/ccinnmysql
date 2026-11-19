import Foundation
import MySQLKit
import Testing
@testable import CcinnMysqlKit

private typealias F = BackupFixtures
private typealias L = Legacy15

private func expectError(_ expected: BackupError, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected \(expected)")
    } catch let error as BackupError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

/// A 1.5 profile: no `updatedAt` (1.5 did not have it), paths under the old home.
private func legacyProfile(name: String = "prod", host: String = "db.prod") -> ConnectionProfile {
    var profile = F.certificateProfile(name: name, clientPath: "/Users/old/certs/client.p12", keyPath: "/Users/old/certs/server-key.pem")
    profile.host = host
    profile.caCertificatePath = "/Users/old/certs/ca.pem"
    profile.ssh = SSHTunnelConfiguration(host: "bastion.example", username: "ops", authentication: .privateKey, privateKeyPath: "/Users/old/.ssh/id")
    profile.mcpAccess = .readOnly
    profile.aiAllowsPrivilegedAccount = true
    profile.updatedAt = nil
    return profile
}

private let allSecrets = L.ProfileSecrets(password: F.password, sshSecret: F.sshSecret, clientCertificatePassphrase: F.certificatePassphrase)

// MARK: - Versions

@Suite("Backup format 1 (CcinnMysql 1.5): versions")
struct BackupLegacyVersionTests {
    // What 1.5.x does with a file this version writes: it refuses it before reading anything from it. Its reader parses
    // the whole file as one JSON document to read `format` and `version`; a format 2 file is two documents, so 1.5 calls it
    // "not a CcinnMysql backup" rather than misreading it. (It never reaches its version check, which would have refused
    // the header line alone as newer: that line has no `version` key.)
    @Test func the15ReaderRefusesAFormat2File() throws {
        let profile = F.profile(name: "prod", host: "db.prod")
        let data = try BackupFormat.encode(BackupPayload(profiles: [profile]), appVersion: "1.6.0", createdAt: F.referenceDate)
        #expect(throws: L.Failure.notABackup) { try L.decode(data) }
        let header = try F.requireLines(data).header
        #expect(throws: L.Failure.newerVersion(nil)) { try L.decode(header) }
    }

    // 1.5's version check refuses a single-document file with a higher version as newer, and so does this reader.
    @Test func aSingleDocumentOfAHigherVersionIsNewer() throws {
        let newer = Data(#"{"format":"ccinnmysql-backup","version":2,"connections":[]}"#.utf8)
        #expect(throws: L.Failure.newerVersion(2)) { try L.decode(newer) }
        expectError(.newerFormat(2)) { _ = try BackupFormat.decode(newer) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data(#"{"format":"ccinnmysql-backup","version":0}"#.utf8)) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data(#"{"format":"ccinnmysql-backup"}"#.utf8)) }
        expectError(.notABackup) { _ = try BackupFormat.decode(Data(#"{"format":"ccinnpsql-backup","version":1}"#.utf8)) }
    }

    @Test func the15ReaderReadsWhatTheRebuiltWriterWrites() throws {
        let data = try L.file(connections: [legacyProfile()], secrets: [UUID(): allSecrets], passphrase: F.passphrase)
        let bundle = try L.decode(data)
        #expect(bundle.version == 1 && bundle.connections.count == 1 && bundle.secrets != nil)
        #expect(data.firstIndex(of: 0x0A) == nil, "1.5 wrote one line")
    }
}

// MARK: - Profiles and secrets

@Suite("Backup format 1 (CcinnMysql 1.5): profiles and secrets")
struct BackupLegacyProfileTests {
    @Test func aFileWithoutPasswordsIsReadAsUnverified() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile])
        let bundle = try BackupFormat.decode(data)
        #expect(bundle.isLegacyFormat && bundle.header.formatVersion == 1)
        #expect(bundle.header.appVersion == "1.5.1" && bundle.header.createdAt == F.referenceDate)
        #expect(bundle.header.sections == ["profiles"])
        #expect(!bundle.isAuthenticated && !bundle.containsSecrets && bundle.secrets.isEmpty)
        #expect(bundle.warnings == [.legacyFormat])
        let imported = try #require(bundle.payload.profiles.first)
        #expect(imported.id == profile.id && imported.host == "db.prod" && imported.tlsMode == .verifyIdentity)
        #expect(imported.caCertificatePath == "~/certs/ca.pem", "paths under the exporting user's home travel as ~/…")
        #expect(imported.clientCertificatePath == "~/certs/client.p12")
        #expect(imported.serverPublicKeyPath == "~/certs/server-key.pem")
        #expect(imported.ssh?.privateKeyPath == "~/.ssh/id")
        #expect(imported.aiAllowsPrivilegedAccount, "the file says so; the planner decides (it never grants it from an unverified file)")
        #expect(imported.updatedAt == nil)
        #expect(bundle.payload.knowledge == nil && bundle.payload.settings == nil && bundle.payload.history == nil)
    }

    @Test func thePassphraseOpensAllThreeSecretsButVerifiesNothing() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile], secrets: [profile.id: allSecrets], passphrase: F.passphrase)
        #expect(!data.contains(F.password) && !data.contains(F.sshSecret) && !data.contains(F.certificatePassphrase))

        let opened = try BackupFormat.decode(data, passphrase: F.passphrase)
        #expect(opened.secrets == [profile.id: BackupProfileSecrets(password: F.password, sshSecret: F.sshSecret,
                                                                    clientCertificatePassphrase: F.certificatePassphrase)])
        #expect(!opened.isAuthenticated, "1.5 sealed the passwords, not the connections they belong to")
        #expect(opened.containsSecrets)
        #expect(opened.warnings == [.legacyFormat, .legacySecretsUnverified])

        let locked = try BackupFormat.decode(data)
        #expect(locked.containsSecrets && locked.secrets.isEmpty)
        #expect(locked.warnings.contains(.secretsNotImported))
        let noSecrets = try BackupFormat.decode(try L.file(connections: [profile]), passphrase: F.passphrase)
        #expect(noSecrets.warnings.contains(.noSecretsInBackup))
    }

    @Test func aShortPassphraseFrom15StillOpens() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile], secrets: [profile.id: allSecrets], passphrase: "8 chars!")
        #expect(try BackupFormat.decode(data, passphrase: "8 chars!").secrets[profile.id]?.password == F.password)
    }

    @Test func aWrongPassphraseOrAChangedConnectionListOpensNothing() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile], secrets: [profile.id: allSecrets], passphrase: F.passphrase)
        expectError(.wrongPassphraseOrModified) { _ = try BackupFormat.decode(data, passphrase: "incorrect horse battery") }
        // 1.5 bound the secrets to the connection ids: another id breaks the seal.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: profile.id.uuidString, with: UUID().uuidString)
        expectError(.wrongPassphraseOrModified) { _ = try BackupFormat.decode(Data(text.utf8), passphrase: F.passphrase) }
    }

    // The 1.5 seal does not cover the host: a redirected profile still opens. That is why the file is never verified and
    // the planner keeps the local profile, and never grants the privileged opt-in, as for any unverified file.
    @Test func aRedirectedHostOpensButIsTreatedAsUnverified() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile], secrets: [profile.id: allSecrets], passphrase: F.passphrase)
        let redirected = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"db.prod\"", with: "\"evil.example\"").utf8)
        let bundle = try BackupFormat.decode(redirected, passphrase: F.passphrase)
        #expect(bundle.payload.profiles.first?.host == "evil.example" && !bundle.isAuthenticated)

        var local = profile
        local.updatedAt = F.date(10)
        local.caCertificatePath = "~/certs/ca.pem"
        local.clientCertificatePath = "~/certs/client.p12"
        local.serverPublicKeyPath = "~/certs/server-key.pem"
        local.ssh?.privateKeyPath = "~/.ssh/id"
        let item = try #require(F.plan(bundle, local: F.localState(profiles: [local], secrets: [local.id: BackupProfileSecrets(password: F.password)]))
            .profiles.first)
        #expect(item.flags.contains(.endpointChanged))
        #expect(item.resolution == .keepMine, "the local password never follows the profile to the new host by default")
        #expect(!item.imported.aiAllowsPrivilegedAccount, "another server never inherits the opt-in")
    }

    @Test func hostileSettingsAreRefusedBeforeDerivingAKey() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile], secrets: [profile.id: allSecrets], passphrase: F.passphrase)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sealed = try #require(object["secrets"] as? [String: Any])
        sealed["iterations"] = 50_000_000
        object["secrets"] = sealed
        let costly = try JSONSerialization.data(withJSONObject: object)
        expectError(.unsupportedEncryption("pbkdf2-hmac-sha256 × 50000000")) { _ = try BackupFormat.decode(costly, passphrase: F.passphrase) }
        sealed["iterations"] = 600_000
        sealed["kdf"] = "md5"
        object["secrets"] = sealed
        expectError(.unsupportedEncryption("md5")) { _ = try BackupFormat.decode(try JSONSerialization.data(withJSONObject: object), passphrase: F.passphrase) }
        sealed["kdf"] = "pbkdf2-hmac-sha256"
        sealed["salt"] = Data([1, 2, 3]).base64EncodedString()
        object["secrets"] = sealed
        expectError(.invalid("the encrypted passwords are damaged")) {
            _ = try BackupFormat.decode(try JSONSerialization.data(withJSONObject: object), passphrase: F.passphrase)
        }
    }

    @Test func invalidProfilesAreRefusedAsInFormat2() throws {
        let profile = legacyProfile()
        let data = try L.file(connections: [profile])
        let text = String(decoding: data, as: UTF8.self)
        let cases = [("\"db.prod\"", "\"-oProxyCommand=evil\""), ("\"db.prod\"", "\"db\\u0007prod\""), ("/Users/old/certs/client.p12", "certs/client.p12"),
                     ("/Users/old/certs/server-key.pem", "/Users/old/../../etc/key.pem"), ("\"port\":3306", "\"port\":0")]
        for (from, to) in cases {
            #expect(text.contains(from), "\(from)")
            #expect(throws: BackupError.self, "\(to)") { try BackupFormat.decode(Data(text.replacingOccurrences(of: from, with: to).utf8)) }
        }
        let twice = try L.file(connections: [profile, profile])
        #expect(throws: BackupError.self) { try BackupFormat.decode(twice) }
        #expect(throws: BackupError.self) { try BackupFormat.decode(Data(#"{"format":"ccinnmysql-backup","version":1,"connections":"x"}"#.utf8)) }
    }

    @Test func aConvertedFileImportsAndASecondImportChangesNothing() throws {
        let profile = legacyProfile()
        var base = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        base.notes.tables["report"] = L.TableNote(summary: "revenue in USD", author: "user", updatedAt: F.date(5))
        let data = try L.file(connections: [profile], secrets: [profile.id: allSecrets], passphrase: F.passphrase, knowledge: [base])
        let target = BackupTestMac(home: F.newHome)
        defer { target.remove() }
        let existing: Set<String> = ["/Users/new/.ssh/id", "/Users/new/certs/ca.pem", "/Users/new/certs/client.p12", "/Users/new/certs/server-key.pem"]
        let plan = target.plan(try BackupFormat.decode(data, passphrase: F.passphrase), existing: existing)
        let item = try #require(plan.profiles.first)
        #expect(item.status == .new && item.flags == [.aiAccessChanged, .privilegedOptInReset])
        let report = target.applier().apply(plan, now: F.date(100))
        #expect(report.succeeded, "\(report.failureMessage ?? "")")
        #expect(report.secretsWritten == 3 && report.databasesMerged == 1)
        #expect(target.profiles.first?.aiAllowsPrivilegedAccount == false)
        for kind in SecretKey.Kind.allCases {
            #expect(try target.secrets.secret(for: SecretKey(profileID: profile.id, kind: kind)) != nil, "\(kind.rawValue)")
        }
        let key = DatabaseKey(cluster: ClusterKey(profile: profile), catalog: "def", database: "adx")
        #expect(try target.knowledge.database(key)?.notes.map(\.text) == ["revenue in USD"])

        let again = target.plan(try BackupFormat.decode(data, passphrase: F.passphrase), existing: existing)
        #expect(again.profiles.first?.status == .unchanged)
        #expect(again.isUnchanged, "converted ids are stable, so the same 1.5 file merges into what it made")
    }
}

// MARK: - Knowledge

@Suite("Backup format 1 (CcinnMysql 1.5): knowledge")
struct BackupLegacyKnowledgeTests {
    private let profile = legacyProfile()
    private var key: DatabaseKey { DatabaseKey(cluster: ClusterKey(profile: profile), catalog: "def", database: "adx") }

    private func convert(_ bases: [L.KnowledgeBase], connections: [ConnectionProfile]? = nil) throws -> BackupBundle {
        try BackupFormat.decode(try L.file(connections: connections ?? [profile], knowledge: bases))
    }

    private func onlyDatabase(_ bundle: BackupBundle) throws -> DatabaseKnowledge {
        try #require(bundle.payload.knowledge?.databases.count == 1 ? bundle.payload.knowledge?.databases.first : nil)
    }

    @Test func notesBecomeDescriptionsWithTheirAuthors() throws {
        var base = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        base.notes.tables["report"] = L.TableNote(summary: "  hourly revenue  ", author: "ai", updatedAt: F.date(5),
                                                   evidence: [L.Evidence(kind: "query", detail: "SELECT COUNT(*) …")])
        base.notes.columns["report"] = ["status": L.ColumnNote(note: "lifecycle", values: ["3": "paused", "1": "active"], author: "user",
                                                                updatedAt: F.date(6)),
                                        "empty": L.ColumnNote(note: nil, author: "user", updatedAt: F.date(6))]
        let database = try onlyDatabase(try convert([base]))
        #expect(database.key == key)
        #expect(database.tables.isEmpty && database.relationships.isEmpty, "structure is rebuilt by the next refresh")
        let table = try #require(database.notes.first { $0.column == nil })
        #expect(table.table == "report" && table.kind == .description && table.text == "hourly revenue")
        #expect(table.by == "ai:unknown" && table.at == F.date(5))
        #expect(table.evidence.first?.source == .ai && table.evidence.first?.rationale == "query: SELECT COUNT(*) …")
        let column = try #require(database.notes.first { $0.column == "status" })
        #expect(column.text == "lifecycle\nValues: 1 = active, 3 = paused")
        #expect(column.by == "user")
        #expect(database.notes.count == 2, "a column note with neither text nor values is nothing to keep")
        #expect(table.id.hasPrefix("n") && table.id.count == 17)
    }

    @Test func glossaryTermsKeepTheirSQLInTheDefinition() throws {
        var base = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        base.notes.glossary["fill rate"] = L.GlossaryTerm(term: "Fill rate", definition: "Filled over requested.", tables: ["report", "bad\u{7}name"],
                                                          sql: "SELECT SUM(fill)/SUM(req) FROM report", author: "user", updatedAt: F.date(7))
        let term = try #require(try onlyDatabase(try convert([base])).terms.first)
        #expect(term.term == "Fill rate" && term.by == "user" && term.at == F.date(7))
        #expect(term.definition == "Filled over requested.\n\nSQL: SELECT SUM(fill)/SUM(req) FROM report")
        #expect(term.mapsTo == [Term.Mapping(table: "report")], "names with control characters are left out")
        #expect(term.id.hasPrefix("g"))
    }

    @Test func addedRelationshipsAndVerdictsCarryTheirEvidence() throws {
        var base = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        base.projects = [L.LinkedProject(name: "adx-server", path: "/Users/old/code/adx")]
        let order = L.End(table: "orders", columns: ["user_id"])
        let user = L.End(table: "users", columns: ["id"])
        let added = L.Relationship(from: order, to: user, sources: ["ai"], confidence: 0.8, cardinality: "manyToOne",
                                   evidence: [L.Evidence(kind: "code", project: "adx-server", path: "src/Orders.swift", line: 42, detail: "join"),
                                              L.Evidence(kind: "query", detail: "no orphans")])
        base.notes.relationships[added.id] = L.AnnotatedRelationship(relationship: added, note: "orders belong to users", author: "ai",
                                                                     updatedAt: F.date(8))
        // The user confirmed the AI's relationship, and rejected a computed one.
        base.notes.verdicts[added.pairID] = L.Verdict(status: "confirmed", reason: nil, author: "user", updatedAt: F.date(9), ends: [order, user])
        let naming = L.Relationship(from: L.End(table: "orders", columns: ["dt"]), to: L.End(table: "report", columns: ["dt"]), sources: ["naming"],
                                    confidence: 0.4, cardinality: "unknown")
        base.computed = [naming]
        base.notes.verdicts[naming.pairID] = L.Verdict(status: "rejected", reason: "a date, not a key", author: "user", updatedAt: F.date(10))
        let bundle = try convert([base])
        let database = try onlyDatabase(bundle)
        #expect(database.relationships.count == 2)

        let confirmed = try #require(database.relationships.first { $0.from.table == "orders" && $0.to.table == "users" })
        #expect(confirmed.id == Relationship.id(from: .init(table: "orders", columns: ["user_id"]), to: .init(table: "users", columns: ["id"])))
        #expect(confirmed.kind == .manyToOne && confirmed.status == .confirmed)
        #expect(RelationshipConfidence.status(confirmed) == .confirmed)
        let ai = try #require(confirmed.evidence.first { $0.source == .ai })
        #expect(ai.by == "ai:unknown" && ai.rationale == "orders belong to users; query: no orphans")
        let code = try #require(confirmed.evidence.first { $0.source == .code })
        let projectID = try #require(bundle.payload.knowledge?.index.projects.first?.id)
        #expect(code.project == projectID && code.path == "src/Orders.swift" && code.line == 42 && code.rationale == "join")
        #expect(confirmed.evidence.contains { $0.source == .user && $0.verdict == .assert && $0.by == "user" })

        let rejected = try #require(database.relationships.first { $0.to.table == "report" })
        #expect(rejected.status == .rejected && RelationshipConfidence.score(rejected) == 0)
        #expect(rejected.evidence.map(\.rationale) == ["a date, not a key"])
    }

    @Test func aVerdictOnARelationshipTheBackupDoesNotDescribeIsReported() throws {
        var base = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        base.notes.verdicts["a(x)<->b(y)"] = L.Verdict(status: "rejected", reason: "no", author: "user", updatedAt: F.date(1))
        base.notes.tables["a"] = L.TableNote(summary: "kept", author: "user", updatedAt: F.date(1))
        let bundle = try convert([base])
        #expect(try onlyDatabase(bundle).relationships.isEmpty)
        #expect(bundle.warnings.contains { (warning: BackupWarning) -> Bool in
            if case let .legacyKnowledgeNotConverted(detail) = warning { return detail.contains("verdict") }
            return false
        })
    }

    @Test func linkedFoldersBecomeProjectsLinkedToEachDatabase() throws {
        var adx = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        adx.projects = [L.LinkedProject(name: "adx", path: "/Users/old/code/adx"), L.LinkedProject(name: "tools", path: "/opt/tools")]
        var ssp = L.KnowledgeBase(connectionID: profile.id, database: "ssp")
        ssp.projects = [L.LinkedProject(name: "adx", path: "/Users/old/code/adx"), L.LinkedProject(name: "bad", path: "relative/path"),
                        L.LinkedProject(name: "everything", path: "/"), L.LinkedProject(name: "home", path: "/Users/old")]
        let bundle = try convert([adx, ssp])
        let knowledge = try #require(bundle.payload.knowledge)
        #expect(knowledge.index.projects.map(\.path) == ["~/code/adx", "/opt/tools"], "one project per folder, ~/… under the old home")
        #expect(knowledge.index.projects.first?.id == KnowledgeMCP.projectID(path: "~/code/adx"), "the id linking the folder here would give it")
        #expect(knowledge.index.links.count == 3)
        #expect(knowledge.index.databases.map(\.key.database) == ["adx", "ssp"], "listed for their links, though they hold no notes")
        #expect(knowledge.index.clusters.map(\.key) == [key.cluster])
        #expect(knowledge.databases.isEmpty, "nothing to write for databases without notes")
        let unusable = bundle.warnings.compactMap { (warning: BackupWarning) -> String? in
            if case let .legacyKnowledgeNotConverted(detail) = warning, detail.contains("linked folder") { return detail }
            return nil
        }
        #expect(unusable.count == 3, "a relative path, / and the home folder itself are no project folders")
    }

    @Test func factsUnknownConnectionsAndNewerFormatsAreReported() throws {
        var facts = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        facts.snapshot = L.Snapshot()
        facts.notes.tables["report"] = L.TableNote(summary: "kept", author: "user", updatedAt: F.date(1))
        let stranger = L.KnowledgeBase(connectionID: UUID(), database: "other")
        var newer = L.KnowledgeBase(connectionID: profile.id, database: "future")
        newer.formatVersion = 2
        let bundle = try convert([facts, stranger, newer])
        #expect(try onlyDatabase(bundle).notes.map(\.text) == ["kept"])
        let details = bundle.warnings.compactMap { (warning: BackupWarning) -> String? in
            if case let .legacyKnowledgeNotConverted(detail) = warning { return detail }
            return nil
        }
        #expect(details.count == 3)
        #expect(details.contains { $0.contains("newer CcinnMysql") })
        #expect(details.contains { $0.contains("not in the backup") })
        #expect(details.contains { $0.contains("refresh") })
    }

    @Test func twoUsersOfOneServerMergeIntoOneDatabase() throws {
        var other = legacyProfile(name: "prod admin")
        other.id = UUID()
        other.username = "admin"
        var first = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        first.notes.tables["report"] = L.TableNote(summary: "older", author: "user", updatedAt: F.date(1))
        var second = L.KnowledgeBase(connectionID: other.id, database: "adx")
        second.notes.tables["report"] = L.TableNote(summary: "newer", author: "user", updatedAt: F.date(2))
        second.notes.tables["users"] = L.TableNote(summary: "people", author: "user", updatedAt: F.date(2))
        let database = try onlyDatabase(try convert([first, second], connections: [profile, other]))
        #expect(database.notes.map(\.text).sorted() == ["newer", "people"], "the same note id: the newer one wins")
    }

    @Test func controlCharactersInFreeTextAreCleanedNotRefused() throws {
        var base = L.KnowledgeBase(connectionID: profile.id, database: "adx")
        base.notes.tables["report"] = L.TableNote(summary: "esc\u{1B}aped\nsecond line", author: "user", updatedAt: F.date(1))
        base.notes.tables["bad\u{7}table"] = L.TableNote(summary: "dropped", author: "user", updatedAt: F.date(1))
        let bundle = try convert([base])
        #expect(try onlyDatabase(bundle).notes.map(\.text) == ["escaped\nsecond line"])
    }
}
