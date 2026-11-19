import CryptoKit
import Foundation

/// CcinnMysql 1.5's backup (format 1), read and converted into a `BackupBundle` so 1.5 backups stay importable.
///
/// A format 1 file is one JSON document (default `JSONEncoder` dates and data):
/// `{"format":"ccinnmysql-backup","version":1,"createdAt":…,"appVersion":…,"homeDirectory":…,"connections":[…],
/// "secrets":{"kdf","iterations","salt","box"}?,"knowledge":[…]}`.
///
/// Its secrets were sealed with AES-256-GCM under the PBKDF2-HMAC-SHA256 output itself (no key check), authenticating
/// only `"<format>|<version>|<sorted connection ids>"`: the passphrase proves the passwords but not the connections they
/// belong to, nor the knowledge. A format 1 file is therefore never authenticated, even when its passwords open.
enum BackupLegacyFormat {
    static let formatVersion = 1
    /// Salts the 1.5 writer could have produced (it wrote 16 bytes and accepted 8 or more).
    static let acceptedSaltLengths = 8...64

    /// The `version` of a single-document file whose `format` is ours, or `nil` when it is not one.
    static func version(of data: Data) -> Int? {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data), probe.format == BackupHeader.formatName else { return nil }
        return probe.version
    }

    /// Decodes, checks and converts a format 1 file. With a passphrase its passwords are opened the 1.5 way.
    static func decode(_ data: Data, version: Int, passphrase: String?) throws -> BackupBundle {
        guard version <= formatVersion else { throw BackupError.newerFormat(version) }
        guard version == formatVersion else { throw BackupError.notABackup }
        let file: LegacyFile
        do {
            file = try JSONDecoder().decode(LegacyFile.self, from: data)
        } catch {
            throw BackupError.malformed(BackupFormat.describe(error))
        }
        try BackupValidation.validateProfiles(file.connections)
        var warnings: [BackupWarning] = [.legacyFormat]
        // Paths under the exporting Mac's home travel as `~/…`, as format 2 writes them.
        let profiles = file.connections.map { (profile: ConnectionProfile) -> ConnectionProfile in
            BackupImportPlanner.withPortablePaths(profile, home: file.homeDirectory)
        }
        let secrets = try openSecrets(file, passphrase: passphrase, profiles: Set(profiles.map(\.id)), warnings: &warnings)
        let knowledge = BackupLegacyKnowledge.convert(file.knowledge, profiles: profiles, sourceHome: file.homeDirectory, warnings: &warnings)
        let payload = BackupPayload(profiles: profiles, knowledge: knowledge)
        try BackupValidation.validate(payload)
        // The same guarantee as format 2's payload: no control characters anywhere but in free text's tabs and newlines.
        let encoded: Data
        do {
            encoded = try BackupFormat.payloadEncoder.encode(payload)
        } catch {
            throw BackupError.malformed("the converted content cannot be encoded")
        }
        guard !BackupValidation.jsonContainsForbiddenControlCharacter(encoded) else { throw BackupError.invalid("text with control characters") }

        var header = BackupHeader(createdAt: file.createdAt, appVersion: file.appVersion, sections: payload.sections.map(\.rawValue),
                                  payloadBytes: data.count, payloadSHA256: BackupFormat.sha256Hex(data), secrets: nil)
        header.formatVersion = version
        try BackupValidation.validateHeader(header)
        return BackupBundle(header: header, payload: payload, secrets: secrets, isAuthenticated: false, containsSecrets: file.secrets != nil,
                            warnings: warnings)
    }

    // MARK: Secrets

    /// The 1.5 secrets, by profile id. A wrong passphrase and a changed file look alike in this format.
    private static func openSecrets(_ file: LegacyFile, passphrase: String?, profiles: Set<UUID>,
                                    warnings: inout [BackupWarning]) throws -> [UUID: BackupProfileSecrets] {
        guard let sealed = file.secrets else {
            if passphrase != nil { warnings.append(.noSecretsInBackup) }
            return [:]
        }
        guard let passphrase else {
            warnings.append(.secretsNotImported)
            return [:]
        }
        guard sealed.kdf == BackupCrypto.kdfName else { throw BackupError.unsupportedEncryption(sealed.kdf) }
        guard BackupCrypto.acceptedIterations.contains(sealed.iterations) else {
            throw BackupError.unsupportedEncryption("\(BackupCrypto.kdfName) × \(sealed.iterations)")
        }
        let hasSalt: Bool = acceptedSaltLengths.contains(sealed.salt.count)
        let hasBox: Bool = sealed.box.count >= BackupCrypto.minimumSealedLength
        guard hasSalt && hasBox else { throw BackupError.invalid("the encrypted passwords are damaged") }

        let key = try BackupCrypto.DerivedKeys.master(passphrase: passphrase, salt: Array(sealed.salt), iterations: sealed.iterations)
        var plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.box)
            plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData(file))
        } catch {
            throw BackupError.wrongPassphraseOrModified
        }
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard let decoded = try? JSONDecoder().decode([String: LegacySecrets].self, from: plaintext) else {
            throw BackupError.invalid("the encrypted passwords do not decode")
        }
        var secrets: [UUID: BackupProfileSecrets] = [:]
        for (name, item) in decoded.sorted(by: { $0.key < $1.key }) {
            guard let id = UUID(uuidString: name) else { continue }
            guard profiles.contains(id) else {
                warnings.append(.secretsForUnknownProfile(id))
                continue
            }
            guard secrets[id] == nil else { throw BackupError.invalid("passwords appear twice for one connection") }
            let value = BackupProfileSecrets(password: item.password, sshSecret: item.sshSecret,
                                             clientCertificatePassphrase: item.clientCertificatePassphrase)
            if !value.isEmpty { secrets[id] = value }
        }
        if !secrets.isEmpty { warnings.append(.legacySecretsUnverified) }
        return secrets
    }

    /// What 1.5 bound its secrets to: the format, the version and the sorted connection ids.
    static func associatedData(_ file: LegacyFile) -> Data {
        let ids = file.connections.map(\.id.uuidString).sorted().joined(separator: ",")
        return Data("\(file.format)|\(file.version)|\(ids)".utf8)
    }

    // MARK: Shapes

    private struct Probe: Decodable {
        let format: String?
        let version: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try? container.decodeIfPresent(String.self, forKey: .format)
            version = try? container.decodeIfPresent(Int.self, forKey: .version)
        }

        enum CodingKeys: String, CodingKey {
            case format, version
        }
    }

    /// The 1.5 `MigrationBundle`, as far as it is used.
    struct LegacyFile: Decodable {
        var format: String
        var version: Int
        var createdAt: Date
        var appVersion: String
        var homeDirectory: String
        var connections: [ConnectionProfile]
        var secrets: LegacySealedSecrets?
        var knowledge: [BackupLegacyKnowledge.Base]

        enum CodingKeys: String, CodingKey {
            case format, version, createdAt, appVersion, homeDirectory, connections, secrets, knowledge
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(String.self, forKey: .format)
            version = try container.decode(Int.self, forKey: .version)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            appVersion = try container.decode(String.self, forKey: .appVersion)
            homeDirectory = try container.decodeIfPresent(String.self, forKey: .homeDirectory) ?? ""
            connections = try container.decode([ConnectionProfile].self, forKey: .connections)
            secrets = try container.decodeIfPresent(LegacySealedSecrets.self, forKey: .secrets)
            knowledge = try container.decodeIfPresent([BackupLegacyKnowledge.Base].self, forKey: .knowledge) ?? []
        }
    }

    /// 1.5's `SealedSecrets`: `salt` and `box` (nonce ‖ ciphertext ‖ tag) in base64.
    struct LegacySealedSecrets: Decodable {
        var kdf: String
        var iterations: Int
        var salt: Data
        var box: Data
    }

    /// 1.5's `ProfileSecrets`.
    private struct LegacySecrets: Decodable {
        var password: String?
        var sshSecret: String?
        var clientCertificatePassphrase: String?
    }
}
