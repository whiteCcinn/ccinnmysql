import Foundation

/// Bounded pool of connections to one server endpoint.
///
/// Invariants (all mutated only inside the actor):
/// - `openCount` counts idle + checked-out + being-created connections and never exceeds `maxSize`.
/// - A waiter is resumed exactly once: with a connection, with `nil` (permission to create), or with an error.
public actor ConnectionPool {
    public typealias Factory = @Sendable () async throws -> MySQLConnection

    public nonisolated let maxSize: Int
    private let factory: Factory
    /// Idle connections older than this are checked with COM_PING before reuse (servers and NATs drop idle sockets).
    private let validateAfterSeconds: Double

    private var idle: [MySQLConnection] = []
    private var openCount = 0
    /// Server connection ids of every connection this pool owns (idle or checked out).
    private var liveConnectionIDs: Set<UInt32> = []
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<MySQLConnection?, any Error>)] = []
    private var nextWaiterID: UInt64 = 0
    private var isClosed = false

    public init(maxSize: Int, validateAfterSeconds: Double = 30, factory: @escaping Factory) {
        self.maxSize = max(1, maxSize)
        self.validateAfterSeconds = validateAfterSeconds.isFinite ? max(0, validateAfterSeconds) : 30
        self.factory = factory
    }

    public var statistics: (open: Int, idle: Int, waiting: Int) { (openCount, idle.count, waiters.count) }

    /// Connection ids owned by this pool, used to hide the app's own metadata queries from activity views.
    public var connectionIDs: Set<UInt32> { liveConnectionIDs }

    /// Runs `body` with an exclusively checked-out connection and always returns it to the pool.
    public nonisolated func withConnection<T: Sendable>(_ body: (MySQLConnection) async throws -> T) async throws -> T {
        let connection = try await checkout()
        do {
            let result = try await body(connection)
            await checkin(connection)
            return result
        } catch {
            await checkin(connection)
            throw error
        }
    }

    public func checkout() async throws -> MySQLConnection {
        guard !isClosed else { throw Self.closedError() }
        // A cancelled caller must not reserve a slot for a connection nobody will use.
        if Task.isCancelled { throw MySQLError.cancelled() }
        while let connection = idle.popLast() {
            if await !connection.isBroken, await isHealthy(connection) { return connection }
            liveConnectionIDs.remove(connection.connectionID)
            openCount -= 1
            connection.forceClose()
        }
        if openCount < maxSize {
            return try await createConnection()
        }
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        let handedOver: MySQLConnection? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((waiterID, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        if let handedOver { return handedOver }
        // A slot was freed for us; `openCount` was already reserved by the releaser.
        return try await createConnection(slotReserved: true)
    }

    public func checkin(_ connection: MySQLConnection) async {
        let broken = await connection.isBroken
        if isClosed || broken {
            if !broken { await connection.close() }
            liveConnectionIDs.remove(connection.connectionID)
            openCount -= 1
            handOffFreedSlot()
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: connection)
            return
        }
        idle.append(connection)
    }

    /// Closes idle connections now and checked-out ones when they are returned.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let toClose = idle
        idle.removeAll()
        openCount -= toClose.count
        for connection in toClose {
            liveConnectionIDs.remove(connection.connectionID)
            await connection.close()
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: Self.closedError()) }
    }

    // MARK: Private

    /// Pings connections that sat idle for a while; a dead one is replaced instead of failing the caller.
    private func isHealthy(_ connection: MySQLConnection) async -> Bool {
        guard await connection.idleSeconds >= validateAfterSeconds else { return true }
        do {
            try await Deadline.run(seconds: 5, timeoutError: { MySQLError(.timeout, "COM_PING timed out") }) {
                try await connection.ping()
            }
            return true
        } catch {
            return false
        }
    }

    private static func closedError() -> MySQLError {
        MySQLError(.connectionClosed, "The connection pool is closed")
    }

    private func createConnection(slotReserved: Bool = false) async throws -> MySQLConnection {
        if !slotReserved { openCount += 1 }
        let connection: MySQLConnection
        do {
            connection = try await factory()
        } catch {
            openCount -= 1
            handOffFreedSlot()
            throw error
        }
        if isClosed {
            await connection.close()
            openCount -= 1
            throw Self.closedError()
        }
        liveConnectionIDs.insert(connection.connectionID)
        return connection
    }

    /// Gives a freed slot to the oldest waiter, which will then create its own connection.
    private func handOffFreedSlot() {
        guard !waiters.isEmpty, openCount < maxSize, !isClosed else { return }
        let waiter = waiters.removeFirst()
        openCount += 1
        waiter.continuation.resume(returning: nil)
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: MySQLError.cancelled())
    }
}
