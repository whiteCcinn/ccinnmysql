import Foundation
import os
import Security

/// `ByteTransport` over `URLSessionStreamTask` (design D1): plaintext until `startTLS`, then TLS on the
/// same socket. Reads use no URLSession timeout; deadlines and cancellation belong to the connection layer,
/// which calls `close()`.
final class StreamTaskTransport: ByteTransport, @unchecked Sendable {
    // URLSessionStreamTask is thread-safe; mutable state lives behind `state`.
    private let task: URLSessionStreamTask
    private let session: URLSession
    private let endpoint: Endpoint
    private let delegate: TrustDelegate
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var tlsStarted = false
        /// No decrypted byte has arrived since `startTLS`: transport errors are TLS handshake failures.
        var tlsPending = false
        var closed = false
    }

    /// One session per connection: TLS sessions must never be resumed across connections with different
    /// trust policies (a resumed session skips certificate evaluation).
    private static func makeSession(legacy: Bool, delegate: TrustDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = legacy ? (tls_protocol_version_t(rawValue: 0x0301) ?? .TLSv12) : .TLSv12
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 365 * 86_400
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private init(task: URLSessionStreamTask, session: URLSession, endpoint: Endpoint, delegate: TrustDelegate) {
        self.task = task
        self.session = session
        self.endpoint = endpoint
        self.delegate = delegate
    }

    /// Creates the stream; the TCP connection is established by the first read (bounded by the caller's deadline).
    static func connect(to endpoint: Endpoint, options: TransportOptions, legacyTLS: Bool = false) throws -> StreamTaskTransport {
        if Task.isCancelled { throw MySQLError.cancelled() }
        guard (1...65_535).contains(endpoint.port) else { throw MySQLError(.invalidArgument, "Invalid port \(endpoint.port)") }
        let host = endpoint.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw MySQLError(.invalidArgument, "Enter a host name") }
        let delegate = TrustDelegate()
        let session = makeSession(legacy: legacyTLS, delegate: delegate)
        let task = session.streamTask(withHostName: host, port: endpoint.port)
        let transport = StreamTaskTransport(task: task, session: session, endpoint: endpoint, delegate: delegate)
        task.resume()
        return transport
    }

    func startTLS(_ options: TLSOptions) throws {
        try state.withLock { state in
            guard !state.closed else { throw MySQLError(.connectionClosed, "The connection to \(endpoint) is closed") }
            guard !state.tlsStarted else { return }
            state.tlsStarted = true
            state.tlsPending = true
        }
        try delegate.configure(options)
        task.startSecureConnection()
    }

    func send(_ bytes: [UInt8]) async throws {
        do {
            try await task.write(Data(bytes), timeout: 0)
        } catch {
            throw describe(error, receiving: false)
        }
    }

    func receive() async throws -> [UInt8] {
        let data: Data?
        let atEOF: Bool
        do {
            (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: 0)
        } catch {
            throw describe(error, receiving: true)
        }
        if let data, !data.isEmpty {
            state.withLock { $0.tlsPending = false }
            return [UInt8](data)
        }
        if atEOF {
            if state.withLock({ $0.tlsPending }) {
                throw MySQLError(.tls, "\(endpoint) closed the connection during the TLS handshake\(delegate.failureSuffix)")
            }
            throw MySQLError(.connectionClosed, "\(endpoint) closed the connection")
        }
        throw MySQLError(.network, "Connection to \(endpoint) returned no data")
    }

    func close() {
        let first = state.withLock { state -> Bool in
            defer { state.closed = true }
            return !state.closed
        }
        if first {
            task.cancel()
            // Releases the session's strong reference to its delegate.
            session.invalidateAndCancel()
        }
    }

    deinit {
        task.cancel()
        session.invalidateAndCancel()
    }

    private func describe(_ error: any Error, receiving: Bool) -> MySQLError {
        let (closed, tlsPending) = state.withLock { ($0.closed, $0.tlsPending) }
        if closed { return Task.isCancelled ? MySQLError.cancelled() : MySQLError(.connectionClosed, "The connection to \(endpoint) was closed") }
        let nsError = error as NSError
        if tlsPending || Self.isTLSError(nsError) {
            if let reason = delegate.trustFailure {
                return MySQLError(.tls, "The server certificate of \(endpoint) was rejected: \(reason)")
            }
            return MySQLError(.tls, "TLS handshake with \(endpoint) failed: \(nsError.localizedDescription)")
        }
        return Self.describeConnectionError(nsError, endpoint: endpoint)
    }

    static func isTLSError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            return [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                    NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot,
                    NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired].contains(error.code)
        }
        return error.domain == NSOSStatusErrorDomain && (-9899 ... -9800).contains(error.code)
    }

    static func describeConnectionError(_ error: NSError, endpoint: Endpoint) -> MySQLError {
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ECONNREFUSED: return MySQLError(.network, "Connection refused by \(endpoint). Is the server running and listening on port \(endpoint.port)?")
            case ETIMEDOUT: return MySQLError(.timeout, "Timed out connecting to \(endpoint)")
            case EHOSTUNREACH, ENETUNREACH: return MySQLError(.network, "\(endpoint) is unreachable from this network")
            case ECONNRESET, EPIPE: return MySQLError(.connectionClosed, "\(endpoint) reset the connection")
            default: break
            }
        }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return MySQLError(.dns, "Could not resolve host \(endpoint.host)")
            case NSURLErrorTimedOut: return MySQLError(.timeout, "Timed out talking to \(endpoint)")
            case NSURLErrorCannotConnectToHost: return MySQLError(.network, "Could not connect to \(endpoint)")
            case NSURLErrorNetworkConnectionLost: return MySQLError(.connectionClosed, "The connection to \(endpoint) was lost")
            case NSURLErrorCancelled: return MySQLError(.connectionClosed, "The connection to \(endpoint) was closed")
            default: break
            }
        }
        if error.domain == (kCFErrorDomainCFNetwork as String) {
            return MySQLError(.dns, "Could not resolve host \(endpoint.host)")
        }
        return MySQLError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)")
    }
}

/// Per-task URLSession delegate: evaluates server trust for the connection's TLS mode and offers the client identity.
final class TrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Configuration {
        var options = TLSOptions.disabled
        var identity: SecIdentity?
        var trustFailure: String?
    }

    private let configuration = OSAllocatedUnfairLock<Configuration>(uncheckedState: Configuration())

    func configure(_ options: TLSOptions) throws {
        var identity: SecIdentity?
        if let data = options.clientIdentity {
            identity = try TLSTrust.identity(pkcs12: data, passphrase: options.clientIdentityPassphrase)
        }
        configuration.withLockUnchecked {
            $0.options = options
            $0.identity = identity
        }
    }

    var trustFailure: String? { configuration.withLockUnchecked { $0.trustFailure } }
    var failureSuffix: String { trustFailure.map { ": \($0)" } ?? "" }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            let options = configuration.withLockUnchecked { $0.options }
            if let failure = TLSTrust.evaluate(trust, options: options) {
                configuration.withLockUnchecked { $0.trustFailure = failure }
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
            return
        }
        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = configuration.withLockUnchecked({ $0.identity }) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
