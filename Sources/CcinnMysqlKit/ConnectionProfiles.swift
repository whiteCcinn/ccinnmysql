import Foundation
import os
import Security
import MySQLKit

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// Whether AI clients may use a connection through the built-in MCP server.
public enum MCPAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case readOnly
    case readWrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: "Off"
        case .readOnly: "Read-only"
        case .readWrite: "Read & write"
        }
    }
}

/// A saved connection. Never contains secrets: passwords live in a `SecretStore` (the Keychain).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var isFavorite: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var defaultDatabase: String?
    public var ssh: SSHTunnelConfiguration?
    public var tlsMode: TLSMode
    /// PEM/DER CA certificate used by the verifying TLS modes (path on disk).
    public var caCertificatePath: String?
    /// PKCS#12 client certificate (`REQUIRE X509` accounts); its passphrase is in the Keychain.
    public var clientCertificatePath: String?
    public var allowLegacyTLS: Bool
    public var allowCleartextPassword: Bool
    public var allowPublicKeyRetrieval: Bool
    /// Pinned RSA public key (PEM file) for plaintext caching_sha2/sha256 full authentication.
    public var serverPublicKeyPath: String?
    /// Ask before running statements that change data or schema.
    public var confirmMutations: Bool
    public var connectTimeout: Double
    /// AI access through the MCP server (off unless the user opts in).
    public var mcpAccess: MCPAccess
    /// Read-only AI tools also run for an account that can reach server files, server state, credentials or other
    /// sessions' statements through functions or views (FILE, SUPER, PROCESS, `*_ADMIN`, …; see `AccountPrivileges`). Off by default: the
    /// tools refuse such an account.
    public var aiAllowsPrivilegedAccount: Bool
    public var createdAt: Date
    public var lastConnectedAt: Date?
    /// Set on every save; backups use it to tell which side of a conflict is newer.
    public var updatedAt: Date?
    /// Whether an AI may write knowledge (notes, relationships, glossary) for this connection's databases. Knowledge is
    /// local to this Mac and never changes the server, so it is allowed on read-only AI access too.
    public var mcpKnowledgeWrites: Bool = true

    public init(id: UUID = UUID(), name: String = "", host: String = "127.0.0.1", port: Int = 3306, username: String = "root",
                defaultDatabase: String? = nil, color: ProfileColor = .none, isFavorite: Bool = false, ssh: SSHTunnelConfiguration? = nil,
                tlsMode: TLSMode = .preferred, caCertificatePath: String? = nil, clientCertificatePath: String? = nil, allowLegacyTLS: Bool = false,
                allowCleartextPassword: Bool = false, allowPublicKeyRetrieval: Bool = false, serverPublicKeyPath: String? = nil,
                confirmMutations: Bool = false, connectTimeout: Double = 10, mcpAccess: MCPAccess = .disabled,
                aiAllowsPrivilegedAccount: Bool = false, createdAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.defaultDatabase = defaultDatabase
        self.color = color
        self.isFavorite = isFavorite
        self.ssh = ssh
        self.tlsMode = tlsMode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.allowLegacyTLS = allowLegacyTLS
        self.allowCleartextPassword = allowCleartextPassword
        self.allowPublicKeyRetrieval = allowPublicKeyRetrieval
        self.serverPublicKeyPath = serverPublicKeyPath
        self.confirmMutations = confirmMutations
        self.connectTimeout = connectTimeout
        self.mcpAccess = mcpAccess
        self.aiAllowsPrivilegedAccount = aiAllowsPrivilegedAccount
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? container.decodeIfPresent(ProfileColor.self, forKey: .color)) ?? .none
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 3306
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? "root"
        defaultDatabase = try container.decodeIfPresent(String.self, forKey: .defaultDatabase)
        ssh = try container.decodeIfPresent(SSHTunnelConfiguration.self, forKey: .ssh)
        tlsMode = (try? container.decodeIfPresent(TLSMode.self, forKey: .tlsMode)) ?? .preferred
        caCertificatePath = try container.decodeIfPresent(String.self, forKey: .caCertificatePath)
        clientCertificatePath = try container.decodeIfPresent(String.self, forKey: .clientCertificatePath)
        allowLegacyTLS = try container.decodeIfPresent(Bool.self, forKey: .allowLegacyTLS) ?? false
        allowCleartextPassword = try container.decodeIfPresent(Bool.self, forKey: .allowCleartextPassword) ?? false
        allowPublicKeyRetrieval = try container.decodeIfPresent(Bool.self, forKey: .allowPublicKeyRetrieval) ?? false
        serverPublicKeyPath = try container.decodeIfPresent(String.self, forKey: .serverPublicKeyPath)
        confirmMutations = try container.decodeIfPresent(Bool.self, forKey: .confirmMutations) ?? false
        connectTimeout = try container.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 10
        mcpAccess = (try? container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess)) ?? .disabled
        aiAllowsPrivilegedAccount = try container.decodeIfPresent(Bool.self, forKey: .aiAllowsPrivilegedAccount) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        mcpKnowledgeWrites = (try? container.decodeIfPresent(Bool.self, forKey: .mcpKnowledgeWrites)) ?? true
    }

    public static func recents(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    public var endpoint: Endpoint { Endpoint(host: host.trimmingCharacters(in: .whitespaces), port: port) }

    public var hostSummary: String {
        let base = "\(username)@\(endpoint)"
        if let ssh { return "\(base) via \(ssh.host)" }
        return base
    }

    public var displayName: String { name.isEmpty ? endpoint.description : name }

    /// Builds the connection configuration, reading the certificate and key files the profile points at.
    public func configuration(password: String, clientCertificatePassphrase: String? = nil) throws -> ConnectionConfiguration {
        var tls = TLSOptions(mode: tlsMode, serverName: host.trimmingCharacters(in: .whitespaces), allowLegacyProtocols: allowLegacyTLS)
        if let path = caCertificatePath?.nilIfBlank {
            tls.caCertificates = [try Self.readFile(path, what: "CA certificate")]
        }
        if let path = clientCertificatePath?.nilIfBlank {
            tls.clientIdentity = try Self.readFile(path, what: "client certificate")
            tls.clientIdentityPassphrase = clientCertificatePassphrase
        }
        let publicKey = try serverPublicKeyPath?.nilIfBlank.map { String(decoding: try Self.readFile($0, what: "server public key"), as: UTF8.self) }
        return ConnectionConfiguration(endpoint: endpoint, username: username, password: password, database: defaultDatabase?.nilIfBlank,
                                       connectTimeout: connectTimeout, tls: tls, allowCleartextPassword: allowCleartextPassword,
                                       allowPublicKeyRetrieval: allowPublicKeyRetrieval, serverPublicKeyPEM: publicKey)
    }

    static func readFile(_ path: String, what: String) throws -> Data {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 1_048_576 else { throw MySQLError(.invalidArgument, "The \(what) file is larger than 1 MB") }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw MySQLError(.invalidArgument, "Could not read the \(what) file \(url.path): \(error.localizedDescription)")
        }
    }

    /// Problems that prevent connecting, for inline form validation.
    public var validationErrors: [String] {
        var errors: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the server host") }
        if !(1...65_535).contains(port) { errors.append("Port must be between 1 and 65535") }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter a user name") }
        if let ssh {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the SSH host") }
            if ssh.authentication == .privateKey, (ssh.privateKeyPath ?? "").isEmpty { errors.append("Choose an SSH private key") }
        }
        return errors
    }

    /// Plain-language warnings about risky settings (shown in the editor).
    public var securityWarnings: [String] {
        var warnings: [String] = []
        let tunnelled = ssh != nil
        if tlsMode == .disabled, !tunnelled, !Self.isLoopback(host) {
            warnings.append("TLS is disabled: the connection, including queries and results, is not encrypted.")
        }
        if allowCleartextPassword, tlsMode == .disabled || tlsMode == .preferred, !tunnelled {
            warnings.append("Clear-text passwords are only safe with TLS required or an SSH tunnel.")
        }
        if allowPublicKeyRetrieval, tlsMode == .disabled {
            warnings.append("Retrieving the server's RSA key over a plaintext connection can be intercepted; prefer TLS or a pinned key.")
        }
        return warnings
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case password
        case sshSecret
        case clientCertificatePassphrase
    }

    public let profileID: UUID
    public let kind: Kind

    public init(profileID: UUID, kind: Kind) {
        self.profileID = profileID
        self.kind = kind
    }

    var account: String { "\(profileID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil or empty.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnmysql.connections") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError(message: "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnMysql connection secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(message: "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw SecretStoreError(message: "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value?.isEmpty == false ? value : nil }
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    /// `CCINNMYSQL_PROFILE_DIR` overrides the location (used by tests and for portable setups).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CCINNMYSQL_PROFILE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnMysql", isDirectory: true)
    }

    /// Secrets come from the Keychain, unless the TEST-ONLY variable `CCINNMYSQL_TEST_INSECURE_SECRETS_FILE` names a
    /// JSON file (`{"<profile uuid>": {"password": "…"}}`) — used by the MCP subprocess integration test only.
    public static func defaultSecretStore(environment: [String: String] = ProcessInfo.processInfo.environment) -> any SecretStore {
        if let path = environment[InsecureFileSecretStore.environmentVariable], !path.isEmpty {
            return InsecureFileSecretStore(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        return KeychainSecretStore()
    }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = ProfileRepository.defaultSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func storeSecrets(for profile: ConnectionProfile, password: String?, sshSecret: String?, clientCertificatePassphrase: String? = nil) throws {
        try secrets.setSecret(password, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(sshSecret, for: SecretKey(profileID: profile.id, kind: .sshSecret))
        try secrets.setSecret(clientCertificatePassphrase, for: SecretKey(profileID: profile.id, kind: .clientCertificatePassphrase))
    }

    public func clientCertificatePassphrase(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .clientCertificatePassphrase))
    }

    public func password(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .password))
    }

    public func sshSecret(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func delete(_ profile: ConnectionProfile) throws {
        try deleteSecrets(of: profile.id)
    }

    /// Removes every secret of a profile (password, SSH secret, client certificate passphrase) from the Keychain.
    public func deleteSecrets(of profileID: UUID) throws {
        for kind in SecretKey.Kind.allCases {
            try secrets.setSecret(nil, for: SecretKey(profileID: profileID, kind: kind))
        }
    }
}

/// TEST ONLY: secrets read from a JSON file named by `CCINNMYSQL_TEST_INSECURE_SECRETS_FILE`. Never used unless
/// that variable is set (documented in the README as test-only); writes are ignored.
public struct InsecureFileSecretStore: SecretStore {
    public static let environmentVariable = "CCINNMYSQL_TEST_INSECURE_SECRETS_FILE"
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func secret(for key: SecretKey) throws -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return nil }
        return object[key.profileID.uuidString]?[key.kind.rawValue] ?? object[key.profileID.uuidString.lowercased()]?[key.kind.rawValue]
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {}
}
