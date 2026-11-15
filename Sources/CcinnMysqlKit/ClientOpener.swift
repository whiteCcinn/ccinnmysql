import Foundation
import MySQLKit

/// Opens a `MySQLClient` for a saved profile, through its SSH tunnel when configured.
/// Shared by the app and the MCP server.
public enum ClientOpener {
    /// `program_name` connection attribute of the app's own connections.
    public static let appApplicationName = "CcinnMysql"
    /// `program_name` of connections opened by the MCP server, so DBAs can tell AI sessions apart
    /// (`performance_schema.session_connect_attrs`).
    public static let mcpApplicationName = "CcinnMysql MCP"

    public static func open(profile: ConnectionProfile, password: String, sshSecret: String?, clientCertificatePassphrase: String? = nil,
                            poolSize: Int = 4, applicationName: String = appApplicationName,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MySQLClient {
        var configuration = try profile.configuration(password: password, clientCertificatePassphrase: clientCertificatePassphrase)
        configuration.applicationName = applicationName
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
