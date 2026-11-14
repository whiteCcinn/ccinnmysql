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
    ///
    /// Chains are validated with the basic X.509 policy (signatures, validity, CA constraints) like the
    /// `mysql` client does, not with Apple's TLS server policy: that policy also demands SANs, serverAuth EKUs
    /// and short lifetimes, which the certificates MySQL and MariaDB generate never have. The host name is
    /// then checked against the SAN DNS/IP entries, or the common name when the certificate has no SANs.
    public static func evaluate(_ trust: SecTrust, options: TLSOptions) -> String? {
        guard options.mode.verifiesCertificate else { return nil }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
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
        guard SecTrustEvaluateWithError(trust, &error) else {
            return error.map { CFErrorCopyDescription($0) as String } ?? "The server certificate is not trusted"
        }
        guard options.mode == .verifyIdentity else { return nil }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return "The server sent no certificate"
        }
        let names = subjectNames(of: leaf)
        let host = options.serverName.trimmingCharacters(in: .whitespaces)
        if HostnameMatcher.matches(host: host, names: names) { return nil }
        let shown = (names.dns + names.ip).prefix(5).joined(separator: ", ")
        return "The certificate is for \(shown.isEmpty ? (names.commonName ?? "an unnamed host") : shown), not \(host)"
    }

    /// DNS and IP subject alternative names plus the common name of a certificate.
    static func subjectNames(of certificate: SecCertificate) -> HostnameMatcher.Names {
        var dns: [String] = []
        var ip: [String] = []
        let keys = [kSecOIDSubjectAltName] as CFArray
        if let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
           let san = values[kSecOIDSubjectAltName as String] as? [String: Any],
           let entries = san[kSecPropertyKeyValue as String] as? [[String: Any]] {
            for entry in entries.prefix(256) {
                guard let label = entry[kSecPropertyKeyLabel as String] as? String else { continue }
                let value = entry[kSecPropertyKeyValue as String]
                if label == "DNS Name", let name = value as? String { dns.append(name) }
                if label == "IP Address" {
                    if let address = value as? String { ip.append(address) } else if let data = value as? Data { ip.append(HostnameMatcher.format(ip: [UInt8](data))) }
                }
            }
        }
        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        return HostnameMatcher.Names(dns: dns, ip: ip, commonName: commonName as String?)
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

/// RFC 6125-style host name matching (wildcards only as the whole left-most label).
public enum HostnameMatcher {
    public struct Names: Sendable, Equatable {
        public var dns: [String]
        public var ip: [String]
        public var commonName: String?

        public init(dns: [String] = [], ip: [String] = [], commonName: String? = nil) {
            self.dns = dns
            self.ip = ip
            self.commonName = commonName
        }
    }

    public static func matches(host rawHost: String, names: Names) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        guard !host.isEmpty else { return false }
        if isIPAddress(host) {
            return names.ip.contains { $0.lowercased() == host } || (names.ip.isEmpty && names.dns.isEmpty && names.commonName?.lowercased() == host)
        }
        if !names.dns.isEmpty { return names.dns.contains { matches(host: host, pattern: $0) } }
        guard names.ip.isEmpty, let commonName = names.commonName else { return false }
        return matches(host: host, pattern: commonName)
    }

    static func matches(host: String, pattern rawPattern: String) -> Bool {
        let pattern = rawPattern.lowercased().trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        let hostLabels = host.split(separator: ".", omittingEmptySubsequences: false)
        let patternLabels = pattern.split(separator: ".", omittingEmptySubsequences: false)
        guard hostLabels.count == patternLabels.count else { return false }
        for (index, (hostLabel, patternLabel)) in zip(hostLabels, patternLabels).enumerated() {
            if index == 0, patternLabel == "*", patternLabels.count >= 3 { continue }
            if hostLabel != patternLabel { return false }
        }
        return true
    }

    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }

    static func format(ip bytes: [UInt8]) -> String {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        guard bytes.count == 16 else { return "" }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
