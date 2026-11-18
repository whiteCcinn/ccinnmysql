import Foundation
import MySQLWire

/// A dedicated connection for one SQL editor: keeps session state (`USE`, session `SET`s), reconnects
/// lazily (restoring them, design D9), refuses to continue silently after a transaction was lost, and
/// cancels the running statement with a pinned `KILL QUERY` (design D6).
public actor SQLSession {
    private let client: MySQLClient
    private var connection: MySQLConnection?
    public private(set) var database: String?
    /// Kill target of the statement currently running, if any.
    public private(set) var runningTarget: KillTarget?
    /// Increases with every statement, so a late cancel never touches a newer run on the same connection.
    private var runGeneration: UInt64 = 0
    private var cancelledGeneration: UInt64?
    /// A run is in progress (connecting, waiting for an earlier kill, or executing).
    public private(set) var isBusy = false
    /// The statement on the wire: its generation and connection (set together with `runningTarget`).
    private var runningStatement: (generation: UInt64, connection: MySQLConnection)?
    /// The current run's statement has reached the server (Stop then kills or closes it instead of preventing it).
    public var isStatementRunning: Bool { runningStatement != nil }
    /// Stop was pressed while the current run had not reached the server yet (waiting for an earlier kill
    /// or reconnecting). The run then stops before sending its statement instead of ignoring the request.
    private var cancelRequestedBeforeStart = false
    /// A `KILL QUERY` still on its way; the next statement waits for it so it cannot be hit by a late kill.
    private var pendingKill: Task<Void, Never>?
    /// The server reported an open transaction after the last statement.
    public private(set) var isInTransaction = false
    /// Session-level `SET` statements replayed after a reconnect (bounded, memory only).
    private var sessionSettings: [String] = []
    private static let maxSessionSettings = 64
    /// Idle sessions are pinged before the next statement so a dropped socket reconnects transparently.
    private static let validateAfterSeconds: Double = 60

    init(client: MySQLClient, database: String?) {
        self.client = client
        self.database = database
    }

    /// Runs one statement and returns all of its results.
    public func run(_ sql: String, limits: RowLimits = RowLimits()) async throws -> [ResultSet] {
        // One statement at a time; a rejected second run must not touch the running one's state.
        guard !isBusy else { throw MySQLError(.busy, "This editor is already running a statement") }
        isBusy = true
        cancelRequestedBeforeStart = false
        defer { isBusy = false }
        return try await execute(sql, limits: limits)
    }

    /// Runs one statement; the caller holds `isBusy`.
    private func execute(_ sql: String, limits: RowLimits = RowLimits()) async throws -> [ResultSet] {
        if let pendingKill {
            await pendingKill.value
            self.pendingKill = nil
        }
        let connection = try await ensureConnection()
        runGeneration &+= 1
        let generation = runGeneration
        let target = await connection.killTarget
        // No suspension between this check and `runningStatement`: a cancel either sees the flag or the statement.
        if cancelRequestedBeforeStart { throw MySQLError.cancelled() }
        runningTarget = target
        runningStatement = (generation, connection)
        defer {
            if runGeneration == generation {
                runningTarget = nil
                runningStatement = nil
            }
        }
        do {
            let results = try await connection.query(sql, limits: limits)
            if await connection.isBroken {
                // An oversized result was abandoned: drop the socket and stop the server-side work.
                if self.connection === connection { self.connection = nil }
                if let target { client.killInBackground(target) }
            } else {
                isInTransaction = await connection.status.contains(.inTransaction)
            }
            noteContextChange(sql)
            return results
        } catch let error as MySQLError {
            if await connection.isBroken {
                if self.connection === connection { self.connection = nil }
                if error.kind == .cancelled, let target { client.killInBackground(target) }
            } else {
                isInTransaction = await connection.status.contains(.inTransaction)
            }
            if cancelledGeneration == generation, error.isQueryInterrupted || error.kind == .connectionClosed || error.kind == .network {
                throw MySQLError.cancelled()
            }
            throw error
        }
    }

    /// Asks the server to stop the running statement (`KILL QUERY`). If that statement is still
    /// running after `graceSeconds`, its socket is closed.
    public func cancel(graceSeconds: Double = 5) async {
        guard isBusy else { return }
        guard let (generation, connection) = runningStatement else {
            // The statement has not reached the server yet: stop it before it is sent.
            cancelRequestedBeforeStart = true
            return
        }
        cancelledGeneration = generation
        guard let target = runningTarget else {
            // The server could not be identified, so no KILL may be sent (it could hit another server's
            // thread): closing the socket stops the statement.
            if self.connection === connection { connection.forceClose() }
            return
        }
        let client = client
        let kill = Task { () -> Bool in
            do {
                try await client.killQuery(target)
                return true
            } catch {
                return false
            }
        }
        pendingKill = Task { _ = await kill.value }
        guard await kill.value else {
            if runGeneration == generation, self.connection === connection { connection.forceClose() }
            return
        }
        let grace = graceSeconds.isFinite ? min(max(0, graceSeconds), 60) : 5
        try? await Task.sleep(for: .milliseconds(Int(grace * 1000)))
        if runGeneration == generation, runningTarget == target, self.connection === connection {
            connection.forceClose()
        }
    }

    /// Clears temporary tables, user variables and session settings (COM_RESET_CONNECTION, or a reconnect).
    public func resetSession() async throws {
        guard !isBusy else { throw MySQLError(.busy, "This editor is running a statement") }
        sessionSettings.removeAll()
        isInTransaction = false
        if let connection, client.serverInfo.supportsResetConnection, !client.serverInfo.isProxySQL {
            do {
                try await connection.resetSession()
                if let database { _ = try await connection.execute(try SQLText.useStatement(database)) }
                return
            } catch let error as MySQLError where error.kind == .server {
                // fall through to a reconnect
            }
        }
        await connection?.close()
        connection = nil
    }

    public func close() async {
        await connection?.close()
        connection = nil
    }

    public var connectionID: UInt32? { connection?.connectionID }

    /// The session's connection runs with NO_BACKSLASH_ESCAPES (literals must double quotes only).
    public var noBackslashEscapes: Bool {
        get async { await connection?.status.contains(.noBackslashEscapes) ?? false }
    }

    /// Applies a generated row UPDATE on this session's own connection (same time zone, character set and
    /// sql_mode as the result it came from) inside a transaction, committing only when exactly one row matched.
    public func applyRowEdit(_ statement: String) async throws {
        guard !isBusy else { throw MySQLError(.busy, "This editor is running a statement") }
        guard !isInTransaction else {
            throw MySQLError(.invalidArgument, "This editor has an open transaction. COMMIT or ROLLBACK it before editing cells.")
        }
        // Busy for the whole edit, so no other statement can run inside this transaction.
        isBusy = true
        defer { isBusy = false }
        _ = try await execute("START TRANSACTION")
        do {
            let result = try await execute(statement).last
            let matched = Self.matchedRows(info: result?.info ?? "", affectedRows: result?.affectedRows ?? 0)
            guard matched == 1 else {
                _ = try? await execute("ROLLBACK")
                throw MySQLError(.server, matched == 0
                    ? "No row matched: it was changed or deleted by someone else. Nothing was saved; reload the result."
                    : "\(matched) rows matched the key; nothing was saved.")
            }
            _ = try await execute("COMMIT")
        } catch {
            if isInTransaction { _ = try? await execute("ROLLBACK") }
            throw error
        }
    }

    /// Rows matched by an UPDATE, from its OK packet info (`Rows matched: 1  Changed: 0  Warnings: 0`).
    static func matchedRows(info: String, affectedRows: UInt64) -> UInt64 {
        if let match = info.firstMatch(of: /Rows matched:\s*(\d+)/), let value = UInt64(match.output.1.prefix(19)) { return value }
        return affectedRows
    }

    private func ensureConnection() async throws -> MySQLConnection {
        if let connection, await !connection.isBroken {
            if await connection.idleSeconds < Self.validateAfterSeconds { return connection }
            do {
                try await Deadline.run(seconds: 5, timeoutError: { MySQLError(.timeout, "COM_PING timed out") }) {
                    try await connection.ping()
                }
                return connection
            } catch {
                connection.forceClose()
                if Task.isCancelled { throw MySQLError.cancelled() }
            }
        }
        connection = nil
        if isInTransaction {
            // Never continue on a fresh connection as if the transaction were still open.
            isInTransaction = false
            throw MySQLError(.transactionLost, "The connection was lost while a transaction was open. The server rolled the transaction back; run its statements again.")
        }
        let fresh = try await client.makeSessionConnection(database: database)
        // Restore session variables the user set before the reconnect (best effort).
        for setting in sessionSettings {
            _ = try? await fresh.execute(setting)
        }
        connection = fresh
        return fresh
    }

    /// Tracks `USE db` and session `SET`s so a reconnect restores them.
    private func noteContextChange(_ sql: String) {
        guard let change = SessionContextChange.parse(sql) else { return }
        switch change {
        case let .use(newDatabase):
            database = newDatabase
        case let .sessionVariable(statement):
            sessionSettings.append(statement)
            if sessionSettings.count > Self.maxSessionSettings { sessionSettings.removeFirst(sessionSettings.count - Self.maxSessionSettings) }
        }
    }
}

/// Recognises statements that change the session's schema or session variables.
public enum SessionContextChange: Equatable, Sendable {
    case use(database: String)
    /// A session-scoped `SET` (variables, `SET NAMES`, `SET ROLE`) worth replaying after a reconnect.
    case sessionVariable(String)

    public static func parse(_ sql: String) -> SessionContextChange? {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast() }
        let lowered = text.lowercased()
        if lowered.hasPrefix("use ") || lowered.hasPrefix("use`") {
            let parts = identifierPath(String(text.dropFirst(3)))
            return parts.count == 1 ? .use(database: parts[0]) : nil
        }
        if lowered.hasPrefix("set ") {
            // Global, persisted and account-level settings live on the server and must not be replayed;
            // SET TRANSACTION only affects the next transaction.
            let words = lowered.split(whereSeparator: { $0.isWhitespace || $0 == "=" })
            let second = words.count > 1 ? String(words[1]) : ""
            let excluded = ["global", "persist", "persist_only", "password", "default", "transaction", "resource"]
            if excluded.contains(second) || lowered.contains("@@global.") || lowered.contains("@@persist") { return nil }
            if text.utf8.count > 4_096 { return nil }
            return .sessionVariable(text)
        }
        return nil
    }

    /// Splits `a.b`, `` `a`.`b` `` (with doubled back-quotes) into parts; empty on anything unexpected.
    static func identifierPath(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "`" {
                    if index + 1 < characters.count, characters[index + 1] == "`" {
                        current.append("`")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "`" {
                quoted = true
            } else if character == "." {
                parts.append(current)
                current = ""
            } else if character.isWhitespace {
                return []
            } else {
                current.append(character)
            }
            index += 1
        }
        guard !quoted else { return [] }
        parts.append(current)
        return parts.contains(where: \.isEmpty) ? [] : parts
    }
}
