import Foundation
import MySQLKit

/// Opens a `MySQLClient` for a saved profile, through its SSH tunnel when configured.
/// Shared by the app and the MCP server.
public enum ClientOpener {
    public static func open(profile: ConnectionProfile, password: String, sshSecret: String?, clientCertificatePassphrase: String? = nil,
                            poolSize: Int = 4, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MySQLClient {
        let configuration = try profile.configuration(password: password, clientCertificatePassphrase: clientCertificatePassphrase)
        var tunnel: SSHTunnel?
        if let ssh = profile.ssh {
            progress("Opening SSH tunnel through \(ssh.host)…")
            tunnel = try await SSHTunnel.open(configuration: ssh, secret: sshSecret, remote: configuration.endpoint)
        }
        if Task.isCancelled {
            tunnel?.close()
            throw MySQLError.cancelled()
        }
        progress("Connecting to \(profile.endpoint) as \(profile.username)…")
        do {
            return try await MySQLClient.connect(configuration, poolSize: poolSize, tunnel: tunnel)
        } catch {
            tunnel?.close()
            throw error
        }
    }
}
