import CcinnMysqlKit
import Foundation
import Observation
import MySQLKit

/// Opens a MySQL client for a profile (optionally through an SSH tunnel).
enum ConnectionOpener {
    static func open(profile: ConnectionProfile, password: String, sshSecret: String?, clientCertificatePassphrase: String? = nil,
                     progress: @escaping @Sendable (String) -> Void) async throws -> MySQLClient {
        try await ClientOpener.open(profile: profile, password: password, sshSecret: sshSecret,
                                    clientCertificatePassphrase: clientCertificatePassphrase, progress: progress)
    }
}

/// State of one window: choosing a connection, connecting, or connected to a workspace.
@MainActor
@Observable
final class WindowSession {
    enum Phase {
        case connections
        case connecting(name: String, status: String)
        case connected(WorkspaceModel)
    }

    var phase: Phase = .connections {
        didSet { DebugLog.write("phase -> \(phaseName)") }
    }
    var connectError: String?

    private var phaseName: String {
        switch phase {
        case .connections: "connections"
        case let .connecting(name, status): "connecting(\(name), \(status))"
        case .connected: "connected"
        }
    }
    private var connectTask: Task<Void, Never>?

    var workspace: WorkspaceModel? {
        if case let .connected(model) = phase { return model }
        return nil
    }

    func connect(profile: ConnectionProfile, store: ProfileStore, password overridePassword: String? = nil,
                 then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        connectError = nil
        let name = profile.displayName
        let password = overridePassword ?? store.password(for: profile) ?? ""
        let sshSecret = profile.ssh.map { $0.authentication == .agent } == false ? store.sshSecret(for: profile) : nil
        let passphrase = profile.clientCertificatePath != nil ? store.repository.clientCertificatePassphrase(for: profile) : nil
        phase = .connecting(name: name, status: "Connecting…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in self.updateStatus(name: name, status: status) }
        }
        connectTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret,
                                                             clientCertificatePassphrase: passphrase, progress: report)
                if Task.isCancelled {
                    await client.close()
                    return
                }
                store.markConnected(profile.id)
                let workspace = WorkspaceModel(profile: profile, client: client)
                self.phase = .connected(workspace)
                workspace.start()
                then?(workspace)
            } catch {
                DebugLog.write("connect failed: \(error) cancelled=\(Task.isCancelled)")
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .connections
            }
        }
    }

    private func updateStatus(name: String, status: String) {
        guard case .connecting = phase else { return }
        phase = .connecting(name: name, status: status)
    }

    /// Connects a window opened by a request of this process. Without a handed-off connection (no request, or a
    /// request macOS restored after a relaunch) nothing happens and the caller takes the File ▸ New Window path.
    /// - Returns: whether the request carried a connection (now opening).
    @discardableResult
    func connect(_ request: WindowRequest?, store: ProfileStore) -> Bool {
        guard let connection = Self.handoff.take(request) else { return false }
        connect(profile: connection.profile, store: store, password: connection.password)
        return true
    }

    /// A request for another window connected like this one: the same profile and the password in use, so unsaved
    /// connections and passwords not in the Keychain work too. Nil while not connected.
    func duplicateRequest() -> WindowRequest? {
        guard let workspace else { return nil }
        let connection = WindowConnection(profile: workspace.profile, password: workspace.client.configuration.password)
        return Self.handoff.request(profileID: workspace.profile.id, payload: connection)
    }

    /// A request for a new window that connects to a saved profile, reading its secrets from the Keychain as
    /// Connect does.
    static func request(opening profile: ConnectionProfile) -> WindowRequest {
        handoff.request(profileID: profile.id, payload: WindowConnection(profile: profile, password: nil))
    }

    /// Connections handed to windows this process opens (see `WindowHandoff`).
    private static let handoff = WindowHandoff<WindowConnection>()

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .connections
    }

    func disconnect() {
        DebugLog.write("disconnect()")
        // A connect still in flight would otherwise finish later and leave a live client/tunnel behind.
        connectTask?.cancel()
        connectTask = nil
        workspace?.shutdown()
        phase = .connections
    }
}

/// The connection a new window opens: a profile and, when duplicating, the password in use (`nil` = Keychain).
/// The SSH secret and the client-certificate passphrase always come from the Keychain: only saved profiles have them.
struct WindowConnection {
    let profile: ConnectionProfile
    let password: String?
}

/// User-facing text for any error.
func describe(_ error: any Error) -> String {
    if let error = error as? MySQLError {
        if let code = error.code { return "\(error.message) (error \(code))" }
        return error.message
    }
    return error.localizedDescription
}

/// `CCINNMYSQL_DEBUG=1` writes lifecycle events to stderr (development aid).
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["CCINNMYSQL_DEBUG"] == "1"

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[ccinnmysql] \(message())\n".utf8))
    }
}
