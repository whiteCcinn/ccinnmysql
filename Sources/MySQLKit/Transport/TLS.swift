import Foundation
import Security

/// How a connection uses TLS (design D2; names follow the `mysql` client's `--ssl-mode`).
public enum TLSMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// Never encrypt.
    case disabled
    /// Encrypt when the server offers TLS; no certificate verification; plaintext if the TLS handshake fails.
    case preferred
    /// Always encrypt; fail when the server has no TLS. No certificate verification.
    case required
    /// Encrypt and verify the certificate chain (system roots or the configured CA); host name not checked.
    case verifyCA
    /// Encrypt, verify the chain and the host name.
    case verifyIdentity

    public var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .preferred: "Preferred"
        case .required: "Required"
        case .verifyCA: "Verify CA"
        case .verifyIdentity: "Verify identity"
        }
    }

    public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyIdentity }
    public var requiresTLS: Bool { self != .disabled && self != .preferred }
}

/// TLS parameters for one connection.
public struct TLSOptions: Sendable, Equatable {
    public var mode: TLSMode
    /// DER or PEM CA certificate(s) the server certificate must chain to (verify modes). Empty = system roots.
    public var caCertificates: [Data]
    /// Host name checked in `verifyIdentity` mode (the profile's host, also when tunnelled through SSH).
    public var serverName: String
    /// Client certificate as PKCS#12 data plus its passphrase (for `REQUIRE X509` accounts).
    public var clientIdentity: Data?
    public var clientIdentityPassphrase: String?
    /// Accept TLS 1.0/1.1 (old yaSSL/OpenSSL 1.0 servers). Off by default.
    public var allowLegacyProtocols: Bool

    public init(mode: TLSMode = .preferred, caCertificates: [Data] = [], serverName: String = "", clientIdentity: Data? = nil,
                clientIdentityPassphrase: String? = nil, allowLegacyProtocols: Bool = false) {
        self.mode = mode
        self.caCertificates = caCertificates
        self.serverName = serverName
        self.clientIdentity = clientIdentity
        self.clientIdentityPassphrase = clientIdentityPassphrase
        self.allowLegacyProtocols = allowLegacyProtocols
    }

    public static let disabled = TLSOptions(mode: .disabled)
}

/// Certificate parsing and server-trust evaluation, independent of the transport (unit-testable).
public enum TLSTrust {
    /// Certificates from DER or PEM data (several PEM blocks allowed). Throws when nothing parses.
    public static func certificates(from data: Data) throws -> [SecCertificate] {
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) { return [certificate] }
        let text = String(decoding: data, as: UTF8.self)
        var certificates: [SecCertificate] = []
        var body: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                body = ""
            } else if line.hasPrefix("-----END CERTIFICATE") {
                if let encoded = body, let der = Data(base64Encoded: encoded), let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                    certificates.append(certificate)
                }
                body = nil
            } else if body != nil {
                body? += line
            }
            if certificates.count >= 64 { break }
        }
        guard !certificates.isEmpty else { throw MySQLError(.tls, "The CA file does not contain a PEM or DER certificate") }
        return certificates
    }

    /// `nil` when the trust is acceptable for `options`, otherwise the reason it is not.
    public static func evaluate(_ trust: SecTrust, options: TLSOptions) -> String? {
        guard options.mode.verifiesCertificate else { return nil }
        let hostName: CFString? = options.mode == .verifyIdentity ? options.serverName as CFString : nil
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, hostName))
        if !options.caCertificates.isEmpty {
            do {
                let anchors = try options.caCertificates.flatMap { try certificates(from: $0) }
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            } catch {
                return (error as? MySQLError)?.message ?? "The CA certificate could not be read"
            }
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        return error.map { CFErrorCopyDescription($0) as String } ?? "The server certificate is not trusted"
    }

    /// Identity from PKCS#12 data.
    public static func identity(pkcs12: Data, passphrase: String?) throws -> SecIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase ?? ""] as CFDictionary
        let status = SecPKCS12Import(pkcs12 as CFData, options, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
              let value = first[kSecImportItemIdentity as String] else {
            throw MySQLError(.tls, status == errSecAuthFailed ? "Wrong passphrase for the client certificate" : "The client certificate could not be imported (\(status))")
        }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == SecIdentityGetTypeID() else {
            throw MySQLError(.tls, "The client certificate file does not contain an identity")
        }
        return unsafeDowncast(object, to: SecIdentity.self)
    }
}
