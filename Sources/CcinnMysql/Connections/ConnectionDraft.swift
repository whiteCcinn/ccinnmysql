import CcinnMysqlKit
import Foundation
import Observation
import MySQLKit

/// Editable copy of a connection profile plus its secrets, with "Test connection".
@MainActor
@Observable
final class ConnectionDraft {
    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    let profileID: UUID?
    var name: String
    var color: ProfileColor
    var isFavorite: Bool
    var host: String
    var port: Int
    var username: String
    var password: String
    var defaultDatabase: String
    var tlsMode: TLSMode
    var caCertificatePath: String
    var clientCertificatePath: String
    var clientCertificatePassphrase: String
    var allowLegacyTLS: Bool
    var allowCleartextPassword: Bool
    var allowPublicKeyRetrieval: Bool
    var serverPublicKeyPath: String
    var confirmMutations: Bool
    var connectTimeout: Double
    var mcpAccess: MCPAccess
    var sshEnabled: Bool
    var ssh: SSHTunnelConfiguration
    var sshSecret: String
    var testState: TestState = .idle

    private let original: ConnectionProfile?
    private var testTask: Task<Void, Never>?

    init(profile: ConnectionProfile?, store: ProfileStore) {
        original = profile
        profileID = profile?.id
        let base = profile ?? ConnectionProfile(color: .teal)
        name = base.name
        color = base.color
        isFavorite = base.isFavorite
        host = base.host
        port = base.port
        username = base.username
        password = profile.flatMap(store.password(for:)) ?? ""
        defaultDatabase = base.defaultDatabase ?? ""
        tlsMode = base.tlsMode
        caCertificatePath = base.caCertificatePath ?? ""
        clientCertificatePath = base.clientCertificatePath ?? ""
        clientCertificatePassphrase = profile.flatMap { store.repository.clientCertificatePassphrase(for: $0) } ?? ""
        allowLegacyTLS = base.allowLegacyTLS
        allowCleartextPassword = base.allowCleartextPassword
        allowPublicKeyRetrieval = base.allowPublicKeyRetrieval
        serverPublicKeyPath = base.serverPublicKeyPath ?? ""
        confirmMutations = base.confirmMutations
        connectTimeout = base.connectTimeout
        mcpAccess = base.mcpAccess
        sshEnabled = base.ssh != nil
        ssh = base.ssh ?? SSHTunnelConfiguration(host: "", username: NSUserName(), authentication: .agent)
        sshSecret = profile.flatMap(store.sshSecret(for:)) ?? ""
    }

    func makeProfile() -> ConnectionProfile {
        var profile = original ?? ConnectionProfile()
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.color = color
        profile.isFavorite = isFavorite
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = port
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.defaultDatabase = defaultDatabase.nilIfEmpty
        profile.tlsMode = tlsMode
        profile.caCertificatePath = caCertificatePath.nilIfEmpty
        profile.clientCertificatePath = clientCertificatePath.nilIfEmpty
        profile.allowLegacyTLS = allowLegacyTLS
        profile.allowCleartextPassword = allowCleartextPassword
        profile.allowPublicKeyRetrieval = allowPublicKeyRetrieval
        profile.serverPublicKeyPath = serverPublicKeyPath.nilIfEmpty
        profile.confirmMutations = confirmMutations
        profile.connectTimeout = min(max(connectTimeout, 1), 120)
        profile.mcpAccess = mcpAccess
        profile.ssh = sshEnabled ? ssh : nil
        return profile
    }

    var validationErrors: [String] { makeProfile().validationErrors }
    var isValid: Bool { validationErrors.isEmpty }

    func test() {
        testTask?.cancel()
        let profile = makeProfile()
        let password = password
        let sshSecret = sshEnabled && ssh.authentication != .agent ? sshSecret : nil
        let passphrase = clientCertificatePath.nilIfEmpty == nil ? nil : clientCertificatePassphrase
        testState = .running("Connecting to \(profile.endpoint)…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in
                if case .running = self.testState { self.testState = .running(status) }
            }
        }
        testTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret,
                                                             clientCertificatePassphrase: passphrase, progress: report)
                let info = client.serverInfo
                let schemas = (try? await client.schemas().count) ?? 0
                await client.close()
                guard !Task.isCancelled else { return }
                var message = "Connected to \(info.productDescription)"
                if info.isProxySQL { message += " through ProxySQL" }
                message += " · " + (info.tlsVersion.map { "encrypted (\($0))" } ?? "not encrypted")
                message += " · \(info.authPlugin) · \(schemas) schemas"
                if let user = info.currentUser { message += " · \(user)" }
                testState = .succeeded(message)
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
