import Foundation

/// Everything needed to open one authenticated MySQL-protocol session.
public struct ConnectionConfiguration: Sendable, Equatable {
    public var endpoint: Endpoint
    public var username: String
    public var password: String
    /// Initial schema (sent in the handshake), optional.
    public var database: String?
    public var connectTimeout: Double
    public var tls: TLSOptions
    /// Allows answering a server request for `mysql_clear_password` (LDAP/PAM users). Off by default.
    public var allowCleartextPassword: Bool
    /// Allows asking the server for its RSA public key during `caching_sha2_password` / `sha256_password`
    /// full authentication on a plaintext connection (the key itself is not authenticated). Off by default.
    public var allowPublicKeyRetrieval: Bool
    /// Pinned RSA public key (PEM) of the server for plaintext full authentication.
    public var serverPublicKeyPEM: String?
    public var applicationName: String
    /// Session variables set right after connecting (best effort: unknown variables are ignored).
    public var sessionVariables: [(name: String, value: String)]

    public init(endpoint: Endpoint, username: String, password: String = "", database: String? = nil, connectTimeout: Double = 10,
                tls: TLSOptions = TLSOptions(), allowCleartextPassword: Bool = false, allowPublicKeyRetrieval: Bool = false,
                serverPublicKeyPEM: String? = nil, applicationName: String = "CcinnMysql",
                sessionVariables: [(name: String, value: String)] = []) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.database = database
        self.connectTimeout = connectTimeout
        self.tls = tls
        self.allowCleartextPassword = allowCleartextPassword
        self.allowPublicKeyRetrieval = allowPublicKeyRetrieval
        self.serverPublicKeyPEM = serverPublicKeyPEM
        self.applicationName = applicationName
        self.sessionVariables = sessionVariables
    }

    public static func == (lhs: ConnectionConfiguration, rhs: ConnectionConfiguration) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.username == rhs.username && lhs.password == rhs.password && lhs.database == rhs.database
            && lhs.connectTimeout == rhs.connectTimeout && lhs.tls == rhs.tls && lhs.allowCleartextPassword == rhs.allowCleartextPassword
            && lhs.allowPublicKeyRetrieval == rhs.allowPublicKeyRetrieval && lhs.serverPublicKeyPEM == rhs.serverPublicKeyPEM
            && lhs.applicationName == rhs.applicationName
            && lhs.sessionVariables.map(\.name) == rhs.sessionVariables.map(\.name) && lhs.sessionVariables.map(\.value) == rhs.sessionVariables.map(\.value)
    }

    /// Same configuration pointed at another endpoint (used for SSH tunnels; TLS keeps the original host name).
    public func with(endpoint: Endpoint) -> ConnectionConfiguration {
        var copy = self
        if copy.tls.serverName.isEmpty { copy.tls.serverName = self.endpoint.host }
        copy.endpoint = endpoint
        return copy
    }
}
