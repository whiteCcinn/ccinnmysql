import Foundation
import MySQLWire
import os
@testable import MySQLKit

/// Identity a fake server reports for `CONNECTION_ID()` queries.
struct FakeIdentity: Sendable {
    var uuid: String? = "3e11fa47-71ca-11e1-9e33-c80aa9429562"
    var hostname = "db-1"
    var port = 3306
    var serverID: Int64 = 1
}

/// In-memory MySQL server speaking just enough protocol for connection tests (TLS is simulated: the
/// SSLRequest is checked and `startTLS` recorded, bytes stay plaintext).
final class FakeMySQLServer: ByteTransport, @unchecked Sendable {
    /// One scripted reaction to a client packet during authentication.
    struct AuthStep: Sendable {
        let check: @Sendable ([UInt8]) -> Bool
        let reply: [[UInt8]]

        init(check: @escaping @Sendable ([UInt8]) -> Bool = { _ in true }, reply: [[UInt8]]) {
            self.check = check
            self.reply = reply
        }
    }

    enum AuthFlow: Sendable {
        case accept
        case reject(code: UInt16, message: String)
        case switchTo(plugin: String)
        /// After the HandshakeResponse, each client packet is answered by the next step.
        case steps(first: [[UInt8]], then: [AuthStep])
    }

    enum Reply: Sendable {
        case packets([[UInt8]])
        /// Never answers (until the transport is closed or the query is interrupted).
        case hang
        /// Answers after a delay (or earlier with an "interrupted" error when killed).
        case delayed([[UInt8]], seconds: Double)
    }

    private struct State {
        var outbox: [UInt8] = []
        var receiver: CheckedContinuation<[UInt8], any Error>?
        var closed = false
        var framer = PacketFramer()
        var phase = 0 // 0 = awaiting HandshakeResponse/SSLRequest, 1 = scripted auth, 2 = commands
        var handshakeResponse: [UInt8] = []
        var authPackets: [[UInt8]] = []
        var remainingSteps: [AuthStep] = []
        var sawSSLRequest = false
        var tlsStarted = false
        var queries: [String] = []
        var queryGeneration = 0
        var pendingQuery = false
        var pings = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let auth: AuthFlow
    let connectionID: UInt32
    let threadID: UInt32
    let identity: FakeIdentity
    private let handler: @Sendable (String) -> Reply
    private let failTLS: Bool
    private let identityFails: Bool

    init(connectionID: UInt32 = 7, threadID: UInt32? = nil, version: String = "8.0.33", offersTLS: Bool = false, failTLS: Bool = false,
         plugin: String = "mysql_native_password", status: UInt16 = 0x0002, identity: FakeIdentity = FakeIdentity(), identityFails: Bool = false,
         auth: AuthFlow = .accept, handler: @escaping @Sendable (String) -> Reply = { _ in .packets([FakeMySQLServer.ok()]) }) {
        self.auth = auth
        self.connectionID = connectionID
        self.threadID = threadID ?? connectionID
        self.identity = identity
        self.handler = handler
        self.failTLS = failTLS
        self.identityFails = identityFails
        self.status = status
        enqueue([Self.greeting(connectionID: connectionID, version: version, offersTLS: offersTLS, plugin: plugin)], firstSequence: 0)
    }

    private let status: UInt16

    var queries: [String] { state.withLockUnchecked { $0.queries } }
    var handshakeResponse: [UInt8] { state.withLockUnchecked { $0.handshakeResponse } }
    var authPackets: [[UInt8]] { state.withLockUnchecked { $0.authPackets } }
    var authSwitchReply: [UInt8] { authPackets.first ?? [] }
    var sawSSLRequest: Bool { state.withLockUnchecked { $0.sawSSLRequest } }
    var tlsStarted: Bool { state.withLockUnchecked { $0.tlsStarted } }
    var isClosed: Bool { state.withLockUnchecked { $0.closed } }
    var pings: Int { state.withLockUnchecked { $0.pings } }

    // MARK: ByteTransport

    func send(_ bytes: [UInt8]) async throws {
        var packets: [PacketFramer.Packet] = []
        let failTLS = failTLS
        try state.withLockUnchecked { state in
            guard !state.closed else {
                throw failTLS && state.tlsStarted ? MySQLError(.tls, "TLS handshake failed (simulated)") : MySQLError(.connectionClosed, "closed")
            }
            state.framer.append(bytes)
            while let packet = try state.framer.nextPacket() { packets.append(packet) }
        }
        for packet in packets { handle(packet) }
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            state.withLockUnchecked { state in
                if !state.outbox.isEmpty {
                    let bytes = state.outbox
                    state.outbox.removeAll()
                    continuation.resume(returning: bytes)
                } else if state.closed {
                    continuation.resume(throwing: MySQLError(.connectionClosed, "closed"))
                } else {
                    state.receiver = continuation
                }
            }
        }
    }

    func close() {
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            state.closed = true
            defer { state.receiver = nil }
            return state.receiver
        }
        receiver?.resume(throwing: MySQLError(.connectionClosed, "closed"))
    }

    func startTLS(_ options: TLSOptions) throws {
        state.withLockUnchecked { $0.tlsStarted = true }
        if failTLS {
            // Simulates a TLS handshake failure surfacing on the next read.
            let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
                state.closed = true
                defer { state.receiver = nil }
                return state.receiver
            }
            receiver?.resume(throwing: MySQLError(.tls, "TLS handshake failed (simulated)"))
        }
    }

    /// Simulates `KILL QUERY` from another connection: the running statement fails with 1317.
    func interrupt() {
        let pending = state.withLockUnchecked { state -> Bool in
            defer { state.pendingQuery = false }
            return state.pendingQuery
        }
        if pending { enqueue([Self.error(code: 1317, state: "70100", message: "Query execution was interrupted")], firstSequence: 1) }
    }

    // MARK: Protocol

    private func handle(_ packet: PacketFramer.Packet) {
        let phase = state.withLockUnchecked { $0.phase }
        switch phase {
        case 0:
            if packet.payload.count == 32, let flags = try? PayloadReader(packet.payload).peekUInt32(),
               Capabilities(rawValue: flags).contains(.ssl) {
                state.withLockUnchecked { $0.sawSSLRequest = true }
                return
            }
            if failTLS, state.withLockUnchecked({ $0.tlsStarted }) { return }
            state.withLockUnchecked {
                $0.handshakeResponse = packet.payload
                $0.phase = 2
            }
            switch auth {
            case .accept:
                enqueue([Self.ok(status: status)], firstSequence: packet.sequence &+ 1)
            case let .reject(code, message):
                enqueue([Self.error(code: code, state: "28000", message: message)], firstSequence: packet.sequence &+ 1)
            case let .switchTo(plugin):
                state.withLockUnchecked {
                    $0.phase = 1
                    $0.remainingSteps = [AuthStep(reply: [Self.ok(status: status)])]
                }
                enqueue([Self.authSwitch(plugin: plugin, nonce: Array(repeating: 5, count: 20))], firstSequence: packet.sequence &+ 1)
            case let .steps(first, then):
                state.withLockUnchecked {
                    $0.phase = then.isEmpty ? 2 : 1 // no further auth packets: commands follow
                    $0.remainingSteps = then
                }
                enqueue(first, firstSequence: packet.sequence &+ 1)
            }
        case 1:
            let step = state.withLockUnchecked { state -> AuthStep? in
                state.authPackets.append(packet.payload)
                guard !state.remainingSteps.isEmpty else { return nil }
                let step = state.remainingSteps.removeFirst()
                if state.remainingSteps.isEmpty { state.phase = 2 }
                return step
            }
            guard let step else { return }
            if step.check(packet.payload) {
                enqueue(step.reply, firstSequence: packet.sequence &+ 1)
            } else {
                state.withLockUnchecked { $0.phase = 2 }
                enqueue([Self.error(code: 1045, state: "28000", message: "Access denied (fake check failed)")], firstSequence: packet.sequence &+ 1)
            }
        default:
            guard let command = packet.payload.first else { return }
            switch command {
            case 0x03:
                let sql = String(decoding: packet.payload.dropFirst(), as: UTF8.self)
                state.withLockUnchecked { $0.queries.append(sql) }
                // Session setup issued by every connection.
                if sql.uppercased().hasPrefix("SET ") {
                    enqueue([Self.ok()], firstSequence: 1)
                    return
                }
                if sql.contains("CONNECTION_ID()") {
                    if identityFails {
                        enqueue([Self.error(code: 1193, message: "Unknown system variable 'hostname'")], firstSequence: 1)
                    } else {
                        enqueue(identityResult(includeUUID: sql.contains("server_uuid")), firstSequence: 1)
                    }
                    return
                }
                let generation = state.withLockUnchecked { state -> Int in
                    state.queryGeneration += 1
                    state.pendingQuery = true
                    return state.queryGeneration
                }
                switch handler(sql) {
                case let .packets(packets):
                    state.withLockUnchecked { $0.pendingQuery = false }
                    enqueue(packets, firstSequence: 1)
                case .hang:
                    break
                case let .delayed(packets, seconds):
                    Task {
                        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                        let stillPending = self.state.withLockUnchecked { state -> Bool in
                            guard state.pendingQuery, state.queryGeneration == generation else { return false }
                            state.pendingQuery = false
                            return true
                        }
                        if stillPending { self.enqueue(packets, firstSequence: 1) }
                    }
                }
            case 0x0E:
                state.withLockUnchecked { $0.pings += 1 }
                enqueue([Self.ok()], firstSequence: 1)
            case 0x1F:
                enqueue([Self.ok()], firstSequence: 1)
            case 0x01:
                close()
            default:
                enqueue([Self.error(code: 1047, state: "08S01", message: "Unknown command")], firstSequence: 1)
            }
        }
    }

    private func identityResult(includeUUID: Bool) -> [[UInt8]] {
        var columns: [(String, ColumnType)] = [("thread_id", .longLong), ("hostname", .varString), ("port", .longLong), ("server_id", .longLong)]
        var values: [String?] = [String(threadID), identity.hostname, String(identity.port), String(identity.serverID)]
        if includeUUID {
            columns.append(("server_uuid", .varString))
            values.append(identity.uuid)
        }
        return Self.resultSet(columns, [values], status: status)
    }

    private func enqueue(_ payloads: [[UInt8]], firstSequence: UInt8) {
        var bytes: [UInt8] = []
        var sequence = firstSequence
        for payload in payloads {
            bytes += PacketCodec.frame(payload, sequence: sequence)
            sequence &+= 1
        }
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            if let receiver = state.receiver {
                state.receiver = nil
                return receiver
            }
            state.outbox += bytes
            return nil
        }
        receiver?.resume(returning: bytes)
    }

    // MARK: Packet builders

    static func greeting(connectionID: UInt32, version: String = "8.0.33", offersTLS: Bool = false, plugin: String = "mysql_native_password") -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(10)
        writer.writeNullTerminated(version)
        writer.writeUInt32(connectionID)
        writer.writeBytes(Array(1...8))
        writer.writeUInt8(0)
        var capabilities = Capabilities.client.union(.deprecateEOF)
        if offersTLS { capabilities.insert(.ssl) }
        writer.writeUInt16(UInt16(truncatingIfNeeded: capabilities.rawValue))
        writer.writeUInt8(33)
        writer.writeUInt16(2)
        writer.writeUInt16(UInt16(truncatingIfNeeded: capabilities.rawValue >> 16))
        writer.writeUInt8(21)
        writer.writeBytes([UInt8](repeating: 0, count: 10))
        writer.writeBytes(Array(9...20) + [0])
        writer.writeNullTerminated(plugin)
        return writer.bytes
    }

    static let scramble: [UInt8] = Array(1...20)

    static func authSwitch(plugin: String, nonce: [UInt8]) -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(0xFE)
        writer.writeNullTerminated(plugin)
        writer.writeBytes(nonce + [0])
        return writer.bytes
    }

    static func authMoreData(_ data: [UInt8]) -> [UInt8] { [0x01] + data }

    static func ok(affectedRows: UInt64 = 0, status: UInt16 = 0x0002, info: String = "") -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(0)
        writer.writeLengthEncoded(affectedRows)
        writer.writeLengthEncoded(0)
        writer.writeUInt16(status)
        writer.writeUInt16(0)
        writer.writeBytes(Array(info.utf8))
        return writer.bytes
    }

    static func error(code: UInt16, state: String = "HY000", message: String) -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(0xFF)
        writer.writeUInt16(code)
        writer.writeBytes(Array(("#" + state).utf8))
        writer.writeBytes(Array(message.utf8))
        return writer.bytes
    }

    static func eof(status: UInt16 = 0x0002) -> [UInt8] {
        [0xFE, 0, 0, UInt8(truncatingIfNeeded: status), UInt8(truncatingIfNeeded: status >> 8)]
    }

    static func column(_ name: String, _ type: ColumnType, table: String = "t", flags: UInt16 = 0) -> [UInt8] {
        var writer = PayloadWriter()
        for part in ["def", "shop", table, table, name, name] { writer.writeLengthEncodedString(part) }
        writer.writeLengthEncoded(0x0C)
        writer.writeUInt16(33)
        writer.writeUInt32(255)
        writer.writeUInt8(type.rawValue)
        writer.writeUInt16(flags)
        writer.writeUInt8(0)
        writer.writeUInt16(0)
        return writer.bytes
    }

    static func row(_ values: [String?]) -> [UInt8] {
        var writer = PayloadWriter()
        for value in values {
            if let value { writer.writeLengthEncodedString(value) } else { writer.writeUInt8(0xFB) }
        }
        return writer.bytes
    }

    /// Classic (non-DEPRECATE_EOF) text result set.
    static func resultSet(_ columns: [(String, ColumnType)], _ rows: [[String?]], moreResults: Bool = false, status: UInt16 = 0x0002) -> [[UInt8]] {
        var writer = PayloadWriter()
        writer.writeLengthEncoded(UInt64(columns.count))
        var packets = [writer.bytes]
        packets += columns.map { column($0.0, $0.1) }
        packets.append(eof())
        packets += rows.map(row)
        packets.append(eof(status: moreResults ? status | 0x0008 : status))
        return packets
    }
}

extension PayloadReader {
    func peekUInt32() throws -> UInt32 {
        var copy = self
        return try copy.readUInt32()
    }
}
