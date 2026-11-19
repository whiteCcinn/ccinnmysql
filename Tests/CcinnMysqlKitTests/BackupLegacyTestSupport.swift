import CommonCrypto
import CryptoKit
import Foundation
@testable import CcinnMysqlKit

/// CcinnMysql 1.5's backup (format 1), rebuilt from `Sources/CcinnMysqlKit/Migration/Migration.swift` and
/// `Knowledge/KnowledgeModels.swift` as they were in 1.5.1 (8ab948f): the writer, to make real 1.5 files, and the reader,
/// to check how 1.5 treats a format 2 file. Field names and encodings are 1.5's (default `JSONEncoder`: dates as seconds
/// since 2001, data as base64; `.sortedKeys, .withoutEscapingSlashes`).
enum Legacy15 {
    static let formatName = "ccinnmysql-backup"
    static let currentVersion = 1
    static let maxBytes = 512 * 1_048_576
    static let defaultIterations = 600_000

    // MARK: Bundle

    struct ProfileSecrets: Codable {
        var password: String?
        var sshSecret: String?
        var clientCertificatePassphrase: String?
    }

    struct SealedSecrets: Codable {
        var kdf: String
        var iterations: Int
        var salt: Data
        var box: Data
    }

    struct Bundle: Codable {
        var format = Legacy15.formatName
        var version = Legacy15.currentVersion
        var createdAt: Date
        var appVersion: String
        var homeDirectory: String
        var connections: [ConnectionProfile]
        var secrets: SealedSecrets?
        var knowledge: [KnowledgeBase]

        /// 1.5's `associatedData`.
        var associatedData: Data {
            Data("\(format)|\(version)|\(connections.map(\.id.uuidString).sorted().joined(separator: ","))".utf8)
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    /// 1.5's `MigrationExporter.bundle`: secrets keyed by profile id string, sealed only with a passphrase.
    static func file(connections: [ConnectionProfile], secrets: [UUID: ProfileSecrets] = [:], passphrase: String? = nil,
                     knowledge: [KnowledgeBase] = [], homeDirectory: String = BackupFixtures.oldHome,
                     iterations: Int = BackupFixtures.testIterations) throws -> Data {
        var bundle = Bundle(createdAt: BackupFixtures.referenceDate, appVersion: "1.5.1", homeDirectory: homeDirectory, connections: connections,
                            secrets: nil, knowledge: knowledge)
        if let passphrase {
            var byID: [String: ProfileSecrets] = [:]
            for (id, value) in secrets { byID[id.uuidString] = value }
            bundle.secrets = try seal(byID, passphrase: passphrase, associatedData: bundle.associatedData, iterations: iterations)
        }
        return try bundle.encoded()
    }

    // MARK: Secrets (1.5's SecretSealing)

    static func seal(_ secrets: [String: ProfileSecrets], passphrase: String, associatedData: Data, iterations: Int) throws -> SealedSecrets {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(passphrase, salt: salt, iterations: iterations)
        let plaintext = try JSONEncoder().encode(secrets)
        guard let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData).combined else { throw CocoaError(.coderInvalidValue) }
        return SealedSecrets(kdf: "pbkdf2-hmac-sha256", iterations: iterations, salt: salt, box: box)
    }

    static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedCount = derived.count
        let status = password.withUnsafeBytes { (passwordBytes: UnsafeRawBufferPointer) -> Int32 in
            salt.withUnsafeBytes { (saltBytes: UnsafeRawBufferPointer) -> Int32 in
                derived.withUnsafeMutableBufferPointer { (output: inout UnsafeMutableBufferPointer<UInt8>) -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(clamping: iterations), output.baseAddress, derivedCount)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw CocoaError(.coderInvalidValue) }
        return SymmetricKey(data: derived)
    }

    // MARK: Reader (1.5's MigrationBundle.decode, up to where it would import)

    enum Failure: Error, Equatable {
        /// "This file is not a CcinnMysql backup."
        case notABackup
        /// "This backup was made by a newer version of CcinnMysql (format …)".
        case newerVersion(Int?)
        /// "The backup is damaged: …"
        case damaged
    }

    private struct Header: Decodable {
        let format: String?
        let version: Int?
    }

    static func decode(_ data: Data) throws -> Bundle {
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == formatName else { throw Failure.notABackup }
        guard let version = header.version, version <= currentVersion else { throw Failure.newerVersion(header.version) }
        _ = version
        do {
            return try JSONDecoder().decode(Bundle.self, from: data)
        } catch {
            throw Failure.damaged
        }
    }

    // MARK: Knowledge (1.5's KnowledgeModels, as encoded)

    struct KnowledgeBase: Codable {
        var formatVersion = 1
        var connectionID: UUID
        var database: String
        var projects: [LinkedProject] = []
        var snapshot: Snapshot?
        var computed: [Relationship] = []
        var references: [String: [CodeReference]] = [:]
        var notes = Notes()
        var updatedAt = BackupFixtures.referenceDate
    }

    struct Snapshot: Codable {
        var tables: [[String: String]] = []
        var takenAt = BackupFixtures.referenceDate
    }

    struct CodeReference: Codable {
        var project: String
        var path: String
        var line: Int
        var count: Int
        var sql: Bool
    }

    struct LinkedProject: Codable {
        var id = UUID()
        var name: String
        var path: String
        var addedAt = BackupFixtures.referenceDate
    }

    struct Evidence: Codable, Equatable {
        var kind: String
        var project: String?
        var path: String?
        var line: Int?
        var detail: String?
    }

    struct End: Codable, Equatable {
        var table: String
        var columns: [String]

        var label: String { "\(table)(\(columns.joined(separator: ", ")))" }
    }

    struct Relationship: Codable {
        var from: End
        var to: End
        var sources: [String]
        var confidence: Double
        var cardinality: String
        var evidence: [Evidence] = []
        var occurrences = 0

        var id: String { "\(from.label)->\(to.label)" }
        var pairID: String { [from.label, to.label].sorted().joined(separator: "<->") }
    }

    struct TableNote: Codable {
        var summary: String
        var author: String
        var updatedAt: Date
        var evidence: [Evidence] = []
    }

    struct ColumnNote: Codable {
        var note: String?
        var values: [String: String] = [:]
        var author: String
        var updatedAt: Date
        var evidence: [Evidence] = []
    }

    struct GlossaryTerm: Codable {
        var term: String
        var definition: String
        var tables: [String] = []
        var sql: String?
        var author: String
        var updatedAt: Date
    }

    struct Verdict: Codable {
        var status: String
        var reason: String?
        var author: String
        var updatedAt: Date
        var ends: [End] = []
    }

    struct AnnotatedRelationship: Codable {
        var relationship: Relationship
        var note: String?
        var author: String
        var updatedAt: Date
    }

    struct Notes: Codable {
        var tables: [String: TableNote] = [:]
        var columns: [String: [String: ColumnNote]] = [:]
        var glossary: [String: GlossaryTerm] = [:]
        var relationships: [String: AnnotatedRelationship] = [:]
        var verdicts: [String: Verdict] = [:]
    }
}
