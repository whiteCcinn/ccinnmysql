import CcinnMysqlKit
import Foundation
import MySQLKit
import Testing
@testable import CcinnMysql

/// Drives connection attempts from the test: each attempt waits until released, then reports progress late and fails,
/// as a slow SSH tunnel or a server timing out does.
private actor ConnectScript {
    enum Event: Equatable {
        case started(String)
        case cancelled(String)
        case finished(String)
    }

    private(set) var events: [Event] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    /// Records the start and waits for `release` (atomically: the gate exists as soon as the start is visible).
    func arrive(_ name: String) async {
        await withCheckedContinuation { gate in
            events.append(.started(name))
            gates[name] = gate
        }
    }

    func record(_ event: Event) { events.append(event) }

    func release(_ name: String) { gates.removeValue(forKey: name)?.resume() }

    func has(_ event: Event) -> Bool { events.contains(event) }

    nonisolated var opener: WindowSession.Opener {
        { profile, _, _, _, progress in
            let name = profile.name
            await withTaskCancellationHandler {
                await self.arrive(name)
            } onCancel: {
                Task { await self.record(.cancelled(name)) }
            }
            progress("\(name): tunnel up")
            await MainActor.run {} // the progress hop (enqueued first on the main actor) has run
            await self.record(.finished(name))
            throw MySQLError(.network, "\(name) failed")
        }
    }
}

@Suite("Window connect", .serialized)
@MainActor
struct WindowSessionTests {
    private func store() -> ProfileStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-window-\(UUID().uuidString)")
        return ProfileStore(repository: ProfileRepository(directory: directory, secrets: InMemorySecretStore()))
    }

    /// Waits (bounded) until `condition` holds.
    @discardableResult
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func connecting(_ session: WindowSession) -> (name: String, status: String)? {
        if case let .connecting(name, status) = session.phase { return (name, status) }
        return nil
    }

    // A second Connect (double-click, another profile) while one is in flight: the first is cancelled, and its late
    // progress and failure never reach the window, which shows only the attempt in progress.
    @Test func aConnectInFlightIsCancelledAndCannotOverwriteTheNewOne() async throws {
        let script = ConnectScript()
        let session = WindowSession(opener: script.opener)
        let store = store()
        session.connect(profile: ConnectionProfile(name: "first"), store: store, password: "pw")
        #expect(await eventually { await script.has(.started("first")) })
        session.connect(profile: ConnectionProfile(name: "second"), store: store, password: "pw")
        #expect(await eventually { await script.has(.started("second")) })
        #expect(await eventually { await script.has(.cancelled("first")) }, "starting a connect cancels the one in flight")

        await script.release("first")
        #expect(await eventually { await script.has(.finished("first")) })
        try await Task.sleep(for: .milliseconds(100)) // its failure path runs on the main actor
        #expect(connecting(session)?.name == "second")
        #expect(connecting(session)?.status == "Connecting…", "progress of the cancelled attempt is ignored")
        #expect(session.connectError == nil, "the cancelled attempt's failure is ignored")

        // The current attempt still reports.
        await script.release("second")
        #expect(await eventually { session.connectError != nil })
        #expect(session.connectError == "second failed")
        #expect(connecting(session) == nil)
    }

    // Cancel (and Disconnect) leave the window on the connection screen, whatever the abandoned attempt reports later.
    @Test func aCancelledConnectStaysCancelled() async throws {
        let script = ConnectScript()
        let session = WindowSession(opener: script.opener)
        session.connect(profile: ConnectionProfile(name: "first"), store: store(), password: "pw")
        #expect(await eventually { await script.has(.started("first")) })
        session.cancelConnecting()
        await script.release("first")
        #expect(await eventually { await script.has(.finished("first")) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(connecting(session) == nil)
        #expect(session.connectError == nil)
    }
}
