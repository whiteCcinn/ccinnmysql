import CommonCrypto
import CryptoKit
import Foundation
import MySQLKit
import Security

/// A failure of export or import, explained in plain language. Nothing is changed when it is thrown before writing.
public struct MigrationError: Error, LocalizedError, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - Bundle

/// Secrets of one connection.
public struct ProfileSecrets: Codable, Sendable, Equatable {
    public var password: String?
    public var sshSecret: String?
    public var clientCertificatePassphrase: String?

    public init(password: String?, sshSecret: String?, clientCertificatePassphrase: String?) {
        self.password = password
        self.sshSecret = sshSecret
        self.clientCertificatePassphrase = clientCertificatePassphrase
    }

    var isEmpty: Bool { [password, sshSecret, clientCertificatePassphrase].allSatisfy { $0?.isEmpty != false } }
}

/// Secrets encrypted with a passphrase: PBKDF2-HMAC-SHA256 derives an AES-256-GCM key; the bundle header is bound as
/// associated data, so the ciphertext cannot be moved to another bundle.
public struct SealedSecrets: Codable, Sendable, Equatable {
    public var kdf: String
    public var iterations: Int
    public var salt: Data
    /// AES-GCM nonce, ciphertext and tag.
    public var box: Data
}

/// One backup file: saved connections, optionally their encrypted secrets, and their knowledge bases.
public struct MigrationBundle: Codable, Sendable {
    public static let formatName = "ccinnmysql-backup"
    public static let currentVersion = 1
    public static let fileExtension = "ccinnmysql-backup"
    public static let maxBytes = 512 * 1_048_576

    public var format: String
    public var version: Int
    public var createdAt: Date
    public var appVersion: String
    /// Home folder of the exporting user, for path remapping.
    public var homeDirectory: String
    public var connections: [ConnectionProfile]
    public var secrets: SealedSecrets?
    public var knowledge: [KnowledgeBase]

    /// Binds secrets to this bundle's format and connections.
    var associatedData: Data {
        Data("\(format)|\(version)|\(connections.map(\.id.uuidString).sorted().joined(separator: ","))".utf8)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw MigrationError("Could not encode the backup: \(error.localizedDescription)")
        }
    }

    private struct Header: Decodable {
        let format: String?
        let version: Int?
    }

    /// Reads a backup file (size checked before reading).
    public static func read(from url: URL) throws -> MigrationBundle {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw MigrationError("\(url.lastPathComponent) is larger than \(maxBytes / 1_048_576) MB.") }
        do {
            return try decode(try Data(contentsOf: url))
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func decode(_ data: Data, maxBytes: Int = MigrationBundle.maxBytes) throws -> MigrationBundle {
        guard data.count <= maxBytes else { throw MigrationError("The backup is larger than \(maxBytes / 1_048_576) MB.") }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == formatName else {
            throw MigrationError("This file is not a CcinnMysql backup.")
        }
        guard let version = header.version, version <= currentVersion else {
            throw MigrationError("This backup was made by a newer version of CcinnMysql (format \(header.version.map(String.init) ?? "?")); update CcinnMysql to import it.")
        }
        let bundle: MigrationBundle
        do {
            bundle = try JSONDecoder().decode(MigrationBundle.self, from: data)
        } catch {
            throw MigrationError("The backup is damaged: \(error.localizedDescription)")
        }
        if let newer = bundle.knowledge.first(where: { $0.formatVersion > KnowledgeBase.currentFormatVersion }) {
            throw MigrationError("The knowledge base of “\(newer.database)” was written by a newer version of CcinnMysql; update CcinnMysql to import it.")
        }
        return bundle
    }
}

// MARK: - Secrets

public enum SecretSealing {
    public static let defaultIterations = 600_000
    static let maxIterations = 10_000_000
    public static let minimumPassphraseLength = 8

    public static func seal(_ secrets: [String: ProfileSecrets], passphrase: String, associatedData: Data,
                            iterations: Int = defaultIterations) throws -> SealedSecrets {
        guard passphrase.count >= minimumPassphraseLength else {
            throw MigrationError("Use a passphrase of at least \(minimumPassphraseLength) characters.")
        }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { throw MigrationError("Could not generate a random salt (\(status)).") }
        let key = try deriveKey(passphrase, salt: salt, iterations: iterations)
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(secrets)
        } catch {
            throw MigrationError("Could not encode the secrets: \(error.localizedDescription)")
        }
        do {
            guard let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData).combined else {
                throw MigrationError("Could not encrypt the secrets.")
            }
            return SealedSecrets(kdf: "pbkdf2-hmac-sha256", iterations: iterations, salt: salt, box: box)
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError("Could not encrypt the secrets: \(error.localizedDescription)")
        }
    }

    public static func open(_ sealed: SealedSecrets, passphrase: String, associatedData: Data) throws -> [String: ProfileSecrets] {
        guard sealed.kdf == "pbkdf2-hmac-sha256", (1...maxIterations).contains(sealed.iterations), sealed.salt.count >= 8 else {
            throw MigrationError("The backup's passwords use an unsupported encryption setting.")
        }
        let key = try deriveKey(passphrase, salt: sealed.salt, iterations: sealed.iterations)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed.box), using: key, authenticating: associatedData)
        } catch {
            throw MigrationError("The passphrase is wrong, or the backup was changed; nothing was imported.")
        }
        do {
            return try JSONDecoder().decode([String: ProfileSecrets].self, from: plaintext)
        } catch {
            throw MigrationError("The backup's passwords are damaged.")
        }
    }

    /// PBKDF2-HMAC-SHA256 of the passphrase in NFC (the same text typed on another Mac gives the same key).
    static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        guard !password.isEmpty else { throw MigrationError("Enter the passphrase.") }
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedCount = derived.count
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBufferPointer { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(clamping: iterations), output.baseAddress, derivedCount)
                }
            }
        }
        guard status == kCCSuccess else { throw MigrationError("Could not derive the encryption key (\(status)).") }
        return SymmetricKey(data: derived)
    }
}

// MARK: - Paths

/// Maps absolute paths under the exporting user's home folder to this user's, when the result exists.
public struct PathRemapper: Sendable {
    public enum Outcome: Equatable, Sendable {
        case unchanged(String)
        case remapped(String)
        case missing(String)

        public var path: String {
            switch self {
            case let .unchanged(path), let .remapped(path), let .missing(path): path
            }
        }
    }

    public let sourceHome: String
    public let targetHome: String
    let exists: @Sendable (String) -> Bool

    public init(sourceHome: String, targetHome: String, exists: @escaping @Sendable (String) -> Bool) {
        self.sourceHome = sourceHome.hasSuffix("/") && sourceHome.count > 1 ? String(sourceHome.dropLast()) : sourceHome
        self.targetHome = targetHome.hasSuffix("/") && targetHome.count > 1 ? String(targetHome.dropLast()) : targetHome
        self.exists = exists
    }

    public func remap(_ path: String) -> Outcome {
        // `~/…` resolves on the new Mac by itself.
        if path.hasPrefix("~") || exists(path) { return .unchanged(path) }
        if !sourceHome.isEmpty, sourceHome != targetHome, path == sourceHome || path.hasPrefix(sourceHome + "/") {
            let candidate = targetHome + path.dropFirst(sourceHome.count)
            if exists(candidate) { return .remapped(candidate) }
        }
        return .missing(path)
    }
}

// MARK: - Knowledge merge

/// Merges a knowledge base from a backup into the local one (design: per-item newer wins, the user's annotations
/// over an AI's, linked folders by path, schema facts from the more recent build).
public enum KnowledgeMerge {
    public static func merge(local: KnowledgeBase, incoming: KnowledgeBase) -> KnowledgeBase {
        var merged = local
        for project in incoming.projects where !merged.projects.contains(where: { $0.path == project.path || $0.id == project.id }) {
            var added = project
            var suffix = 2
            while merged.projects.contains(where: { $0.name.caseInsensitiveCompare(added.name) == .orderedSame }) {
                added.name = "\(project.name)-\(suffix)"
                suffix += 1
            }
            merged.projects.append(added)
        }
        let localBuilt = local.snapshot == nil ? nil : local.build?.builtAt ?? .distantPast
        let incomingBuilt = incoming.snapshot == nil ? nil : incoming.build?.builtAt ?? .distantPast
        if let incomingBuilt, localBuilt.map({ incomingBuilt > $0 }) ?? true {
            merged.snapshot = incoming.snapshot
            merged.computed = incoming.computed
            merged.references = incoming.references
            merged.build = incoming.build
        }
        merged.notes.tables = pick(local.notes.tables, incoming.notes.tables) { ($0.author, $0.updatedAt) }
        var columns = local.notes.columns
        for (table, notes) in incoming.notes.columns {
            columns[table] = pick(columns[table] ?? [:], notes) { ($0.author, $0.updatedAt) }
        }
        merged.notes.columns = columns
        merged.notes.glossary = pick(local.notes.glossary, incoming.notes.glossary) { ($0.author, $0.updatedAt) }
        merged.notes.relationships = pick(local.notes.relationships, incoming.notes.relationships) { ($0.author, $0.updatedAt) }
        merged.notes.verdicts = pick(local.notes.verdicts, incoming.notes.verdicts) { ($0.author, $0.updatedAt) }
        merged.updatedAt = max(local.updatedAt, incoming.updatedAt)
        return merged
    }

    /// Per key: the user's over an AI's, else the newer (the local one on a tie).
    static func pick<Value>(_ local: [String: Value], _ incoming: [String: Value], _ provenance: (Value) -> (KnowledgeAuthor, Date)) -> [String: Value] {
        var result = local
        for (key, candidate) in incoming {
            guard let existing = result[key] else {
                result[key] = candidate
                continue
            }
            let (existingAuthor, existingDate) = provenance(existing)
            let (candidateAuthor, candidateDate) = provenance(candidate)
            if existingAuthor != candidateAuthor {
                if candidateAuthor == .user { result[key] = candidate }
            } else if candidateDate > existingDate {
                result[key] = candidate
            }
        }
        return result
    }
}

// MARK: - Export

public enum MigrationExporter {
    /// A bundle of `profiles` with their knowledge bases; secrets only when `passphrase` is given.
    public static func bundle(profiles: [ConnectionProfile], repository: ProfileRepository, store: KnowledgeStore?, passphrase: String?,
                              appVersion: String, homeDirectory: String = NSHomeDirectory(),
                              iterations: Int = SecretSealing.defaultIterations) throws -> (bundle: MigrationBundle, warnings: [String]) {
        var warnings: [String] = []
        var knowledge: [KnowledgeBase] = []
        if let store {
            for profile in profiles {
                for listing in store.list(connectionID: profile.id) {
                    if let base = listing.knowledge {
                        knowledge.append(base)
                    } else {
                        warnings.append("Skipped the unreadable knowledge base \(profile.displayName)/\(listing.database ?? listing.fileURL.lastPathComponent): \(listing.error ?? "unknown error")")
                    }
                }
            }
        }
        var bundle = MigrationBundle(format: MigrationBundle.formatName, version: MigrationBundle.currentVersion, createdAt: Date(),
                                     appVersion: appVersion, homeDirectory: homeDirectory, connections: profiles, secrets: nil,
                                     knowledge: knowledge)
        if let passphrase {
            var secrets: [String: ProfileSecrets] = [:]
            for profile in profiles {
                let entry = ProfileSecrets(password: repository.password(for: profile), sshSecret: repository.sshSecret(for: profile),
                                           clientCertificatePassphrase: repository.clientCertificatePassphrase(for: profile))
                if !entry.isEmpty { secrets[profile.id.uuidString] = entry }
            }
            bundle.secrets = try SecretSealing.seal(secrets, passphrase: passphrase, associatedData: bundle.associatedData, iterations: iterations)
        }
        return (bundle, warnings)
    }
}

// MARK: - Import

/// Imports a bundle by merging (see `MigrationBundle`). Everything that can fail is checked before the first write.
public struct MigrationImporter: Sendable {
    public struct Options: Sendable {
        public var replaceExisting: Bool
        public var passphrase: String?

        public init(replaceExisting: Bool = false, passphrase: String? = nil) {
            self.replaceExisting = replaceExisting
            self.passphrase = passphrase
        }
    }

    public struct Report: Sendable, Equatable {
        public var added: [String] = []
        public var updated: [String] = []
        public var skipped: [String] = []
        public var secretsRestored = 0
        /// The backup had passwords but no passphrase was given.
        public var secretsSkipped = false
        public var knowledgeCreated: [String] = []
        public var knowledgeMerged: [String] = []
        public var remapped: [String] = []
        public var missing: [String] = []
        public var warnings: [String] = []
    }

    public let repository: ProfileRepository
    public let store: KnowledgeStore
    public let homeDirectory: String
    let fileExists: @Sendable (String) -> Bool

    public init(repository: ProfileRepository, store: KnowledgeStore, homeDirectory: String = NSHomeDirectory(),
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.repository = repository
        self.store = store
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
    }

    public func run(_ bundle: MigrationBundle, options: Options) async throws -> Report {
        var report = Report()
        // 1. Everything that can fail without side effects.
        var secrets: [String: ProfileSecrets] = [:]
        if let sealed = bundle.secrets {
            if let passphrase = options.passphrase, !passphrase.isEmpty {
                secrets = try SecretSealing.open(sealed, passphrase: passphrase, associatedData: bundle.associatedData)
            } else {
                report.secretsSkipped = true
            }
        }
        let existing = try repository.load()
        let remapper = PathRemapper(sourceHome: bundle.homeDirectory, targetHome: homeDirectory, exists: fileExists)
        var remappedPaths = Set<String>()
        var missingPaths = Set<String>()
        func remap(_ path: String?) -> String? {
            guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return path }
            let outcome = remapper.remap(path)
            switch outcome {
            case .unchanged: break
            case let .remapped(new): remappedPaths.insert("\(path) → \(new)")
            case .missing: missingPaths.insert(path)
            }
            return outcome.path
        }

        var profiles = existing
        var restore: [ConnectionProfile] = []
        var seen = Set<UUID>()
        for incoming in bundle.connections where seen.insert(incoming.id).inserted {
            var profile = incoming
            profile.caCertificatePath = remap(profile.caCertificatePath)
            profile.clientCertificatePath = remap(profile.clientCertificatePath)
            profile.serverPublicKeyPath = remap(profile.serverPublicKeyPath)
            if var ssh = profile.ssh {
                ssh.privateKeyPath = remap(ssh.privateKeyPath)
                profile.ssh = ssh
            }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                if options.replaceExisting {
                    profiles[index] = profile
                    report.updated.append(profile.displayName)
                    restore.append(profile)
                } else {
                    report.skipped.append(profile.displayName)
                }
            } else {
                profiles.append(profile)
                report.added.append(profile.displayName)
                restore.append(profile)
            }
        }
        let names = Dictionary(profiles.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(bundle.connections.map(\.id))
        var knowledge: [(KnowledgeBase, isNew: Bool)] = []
        for var base in bundle.knowledge {
            guard incomingIDs.contains(base.connectionID), !base.database.isEmpty else {
                report.warnings.append("Ignored a knowledge base of an unknown connection (\(base.database)).")
                continue
            }
            for index in base.projects.indices { base.projects[index].path = remap(base.projects[index].path) ?? base.projects[index].path }
            do {
                knowledge.append((base, try store.load(base.key) == nil))
            } catch {
                report.warnings.append("Skipped the knowledge base \(names[base.connectionID] ?? "?")/\(base.database): the local one cannot be read (\((error as? KnowledgeError)?.message ?? error.localizedDescription)).")
            }
        }

        // 2. Writes.
        try Task.checkCancellation()
        do {
            try repository.save(profiles)
        } catch {
            throw MigrationError("Could not save the connections: \(error.localizedDescription)")
        }
        for profile in restore {
            guard let entry = secrets[profile.id.uuidString] else { continue }
            do {
                try repository.storeSecrets(for: profile, password: entry.password, sshSecret: entry.sshSecret,
                                            clientCertificatePassphrase: entry.clientCertificatePassphrase)
                report.secretsRestored += 1
            } catch {
                report.warnings.append("Could not store the password of \(profile.displayName) in the Keychain: \(error.localizedDescription)")
            }
        }
        for (base, isNew) in knowledge {
            let label = "\(names[base.connectionID] ?? base.connectionID.uuidString)/\(base.database)"
            do {
                try await store.update(base.key) { local in
                    local = isNew && local.snapshot == nil && local.projects.isEmpty && local.notes.count == 0
                        ? base
                        : KnowledgeMerge.merge(local: local, incoming: base)
                }
                if isNew { report.knowledgeCreated.append(label) } else { report.knowledgeMerged.append(label) }
            } catch {
                report.warnings.append("Could not import the knowledge base \(label): \((error as? KnowledgeError)?.message ?? error.localizedDescription)")
            }
        }
        report.remapped = remappedPaths.sorted()
        report.missing = missingPaths.sorted()
        return report
    }
}
