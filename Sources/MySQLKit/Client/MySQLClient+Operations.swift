import Foundation

/// Server operations: sessions, InnoDB locking, statements, replication/topology, variables, status, accounts.
extension MySQLClient {
    // MARK: Processlist and kill

    /// `SHOW FULL PROCESSLIST` read on one pooled connection together with that server's identity, so kills
    /// from this list reach the same server even behind a load balancer.
    public func processList() async throws -> ProcessListSnapshot {
        let own = Set(await ownConnectionIDs().map(UInt64.init))
        let viaProxy = serverInfo.isProxySQL
        return try await withConnection { connection in
            let identity = viaProxy ? nil : try? await Self.identify(connection).identity
            let result = try await connection.execute("SHOW FULL PROCESSLIST")
            let ownThread = await connection.killTarget?.threadID
            var ownIDs = own
            if let ownThread { ownIDs.insert(ownThread) }
            return ProcessListSnapshot(identity: identity, processes: result.records.compactMap(SessionProcess.init(record:)),
                                       ownConnectionIDs: ownIDs)
        }
    }

    public func kill(_ process: SessionProcess, in snapshot: ProcessListSnapshot, connection: Bool) async throws {
        let target = snapshot.target(for: process, viaProxy: serverInfo.isProxySQL)
        if connection { try await killConnection(target) } else { try await killQuery(target) }
    }

    // MARK: InnoDB

    /// Running transactions, lock waits (with the blocking session) and the latest deadlock, all read on one pooled
    /// connection together with that server's identity, so "kill blocker" reaches the right server.
    public func innoDBActivity() async throws -> InnoDBActivity {
        let lockWaitsQuery = lockWaitsQuery
        let viaProxy = serverInfo.isProxySQL
        return try await withConnection { connection in
            func attempt(_ sql: String) async throws -> Result<ResultSet, MySQLError> {
                do {
                    return .success(try await connection.execute(sql))
                } catch let error as MySQLError where error.kind == .server || error.kind == .authentication {
                    return .failure(error)
                }
            }
            var activity = InnoDBActivity()
            activity.identity = viaProxy ? nil : try? await Self.identify(connection).identity
            switch try await attempt("""
                SELECT trx_id, trx_state, trx_started, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_seconds, \
                TIMESTAMPDIFF(SECOND, trx_wait_started, NOW()) AS wait_seconds, trx_mysql_thread_id, trx_query, trx_operation_state, \
                trx_tables_locked, trx_rows_locked, trx_rows_modified, trx_isolation_level \
                FROM information_schema.INNODB_TRX ORDER BY trx_started LIMIT 1000
                """) {
            case let .success(result): activity.transactions = result.records.map(InnoDBTransaction.init(record:))
            case let .failure(error): activity.unavailable["Transactions"] = error.message
            }
            switch try await attempt(lockWaitsQuery) {
            case let .success(result): activity.lockWaits = result.records.map(LockWait.init(record:))
            case let .failure(error): activity.unavailable["Lock waits"] = error.message
            }
            switch try await attempt("SHOW ENGINE INNODB STATUS") {
            case let .success(result):
                activity.latestDeadlock = result.first?.text("Status").flatMap(Self.latestDeadlock(inInnoDBStatus:))
            case let .failure(error): activity.unavailable["Deadlocks"] = error.message
            }
            return activity
        }
    }

    /// MySQL 8.0+: `performance_schema.data_lock_waits`; MySQL ≤ 5.7 and MariaDB: `information_schema.INNODB_LOCK_WAITS`.
    var lockWaitsQuery: String {
        if serverInfo.hasDataLocks {
            return """
                SELECT w.REQUESTING_ENGINE_TRANSACTION_ID AS waiting_trx_id, rt.trx_mysql_thread_id AS waiting_thread, rt.trx_query AS waiting_query, \
                TIMESTAMPDIFF(SECOND, rt.trx_wait_started, NOW()) AS wait_seconds, w.BLOCKING_ENGINE_TRANSACTION_ID AS blocking_trx_id, \
                bt.trx_mysql_thread_id AS blocking_thread, bt.trx_query AS blocking_query, rl.LOCK_MODE AS lock_mode, rl.LOCK_TYPE AS lock_type, \
                CONCAT(rl.OBJECT_SCHEMA, '.', rl.OBJECT_NAME) AS locked_table, rl.INDEX_NAME AS locked_index, rl.LOCK_DATA AS lock_data \
                FROM performance_schema.data_lock_waits w \
                JOIN performance_schema.data_locks rl ON rl.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID \
                LEFT JOIN information_schema.INNODB_TRX rt ON rt.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID \
                LEFT JOIN information_schema.INNODB_TRX bt ON bt.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID LIMIT 1000
                """
        }
        return """
            SELECT w.requesting_trx_id AS waiting_trx_id, rt.trx_mysql_thread_id AS waiting_thread, rt.trx_query AS waiting_query, \
            TIMESTAMPDIFF(SECOND, rt.trx_wait_started, NOW()) AS wait_seconds, w.blocking_trx_id AS blocking_trx_id, \
            bt.trx_mysql_thread_id AS blocking_thread, bt.trx_query AS blocking_query, l.lock_mode AS lock_mode, l.lock_type AS lock_type, \
            l.lock_table AS locked_table, l.lock_index AS locked_index, l.lock_data AS lock_data \
            FROM information_schema.INNODB_LOCK_WAITS w \
            JOIN information_schema.INNODB_LOCKS l ON l.lock_id = w.requested_lock_id \
            LEFT JOIN information_schema.INNODB_TRX rt ON rt.trx_id = w.requesting_trx_id \
            LEFT JOIN information_schema.INNODB_TRX bt ON bt.trx_id = w.blocking_trx_id LIMIT 1000
            """
    }

    /// Extracts the `LATEST DETECTED DEADLOCK` section (bounded to 64 KB).
    static func latestDeadlock(inInnoDBStatus status: String) -> String? {
        guard let start = status.range(of: "LATEST DETECTED DEADLOCK") else { return nil }
        let rest = status[start.upperBound...]
        // Sections are delimited by a dashed line, a title line and another dashed line.
        let lines = rest.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        var body: [Substring] = []
        var index = lines.startIndex
        if index < lines.endIndex, lines[index].hasPrefix("---") { index = lines.index(after: index) }
        while index < lines.endIndex {
            let line = lines[index]
            let next = lines.index(after: index)
            if line.hasPrefix("------"), next < lines.endIndex, lines[next].uppercased() == lines[next], !lines[next].isEmpty,
               lines.index(after: next) < lines.endIndex, lines[lines.index(after: next)].hasPrefix("---") {
                break
            }
            body.append(line)
            index = next
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(64 * 1024))
    }

    // MARK: Statements

    /// Statement digests ranked by `order`. Throws a server error with an explanation when the
    /// Performance Schema is disabled or the account may not read it.
    public func topStatements(order: StatementOrder = .totalLatency, limit: Int = 100, schema: String? = nil) async throws -> [StatementDigest] {
        guard serverInfo.performanceSchemaEnabled else {
            throw MySQLError(.server, "The Performance Schema is disabled on this server. Start the server with performance_schema=ON to collect statement statistics.")
        }
        var sql = "SELECT * FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST_TEXT IS NOT NULL"
        if let schema { sql += " AND SCHEMA_NAME = \(SQLText.literal(schema))" }
        sql += " ORDER BY \(order.column) DESC LIMIT \(max(1, min(limit, 1_000)))"
        return try await execute(sql).records.map(StatementDigest.init(record:))
    }

    // MARK: Replication and topology

    public func replicationOverview() async throws -> ReplicationOverview {
        var overview = ReplicationOverview()
        let info = serverInfo
        // Replica channels.
        let channelQueries: [String] = info.isMariaDB
            ? (info.usesReplicaVocabulary ? ["SHOW ALL REPLICAS STATUS", "SHOW ALL SLAVES STATUS"] : ["SHOW ALL SLAVES STATUS", "SHOW SLAVE STATUS"])
            : (info.usesReplicaVocabulary ? ["SHOW REPLICA STATUS", "SHOW SLAVE STATUS"] : ["SHOW SLAVE STATUS"])
        if let result = try await firstAccepted(channelQueries, section: "Replica status", into: &overview.unavailable) {
            overview.channels = result.records.map(ReplicaChannel.init(record:))
        }
        // This server as a source.
        let binlogQueries = info.isMariaDB ? ["SHOW BINLOG STATUS", "SHOW MASTER STATUS"] : ["SHOW BINARY LOG STATUS", "SHOW MASTER STATUS"]
        if let row = try await firstAccepted(binlogQueries, section: "Binary log", into: &overview.unavailable)?.first {
            overview.binlogFile = row.text("File")
            overview.binlogPosition = row.int("Position")
            overview.executedGTIDSet = row.text("Executed_Gtid_Set")
        }
        let replicaQueries = info.isMariaDB ? ["SHOW REPLICA HOSTS", "SHOW SLAVE HOSTS"] : ["SHOW REPLICAS", "SHOW SLAVE HOSTS"]
        if let result = try await firstAccepted(replicaQueries, section: "Replicas", into: &overview.unavailable) {
            overview.connectedReplicas = result.records.map(Self.dictionary)
        }
        let gtidVariable = info.isMariaDB ? "@@gtid_current_pos" : "@@gtid_mode"
        if let value = try await tolerant("SELECT \(gtidVariable) AS g")?.scalar {
            if info.isMariaDB { overview.executedGTIDSet = overview.executedGTIDSet ?? value } else { overview.gtidMode = value }
        }
        // Group Replication / InnoDB Cluster.
        if !info.isMariaDB, let members = try await tolerant("SELECT * FROM performance_schema.replication_group_members") {
            let all = members.records.map(GroupMember.init(record:))
            // Without a running group the table holds a single OFFLINE row (or none).
            overview.groupMembers = all.contains { ($0.state ?? "OFFLINE").uppercased() != "OFFLINE" } ? all : []
            if !overview.groupMembers.isEmpty {
                overview.groupName = try await tolerant("SELECT @@group_replication_group_name AS g")?.scalar
            }
        }
        if !info.isMariaDB, !overview.groupMembers.isEmpty,
           let instances = try await tolerant("SELECT * FROM mysql_innodb_cluster_metadata.instances LIMIT 100") {
            overview.innoDBClusterInstances = instances.records.map(Self.dictionary)
        }
        // Galera.
        if info.galeraEnabled, let status = try await tolerant("SHOW GLOBAL STATUS LIKE 'wsrep\\_%'") {
            for record in status.records {
                if let name = record.text("Variable_name") { overview.galera[name] = record.raw("Value") ?? "" }
            }
        }
        return overview
    }

    /// Result of the first statement the server accepts; the last rejection is recorded under `section`.
    func firstAccepted(_ statements: [String], section: String, into unavailable: inout [String: String]) async throws -> ResultSet? {
        var lastError: MySQLError?
        for statement in statements {
            switch try await attempt(statement) {
            case let .success(result): return result
            case let .failure(error): lastError = error
            }
        }
        if let lastError { unavailable[section] = lastError.message }
        return nil
    }

    static func dictionary(_ record: Record) -> [String: String] {
        var dictionary: [String: String] = [:]
        for (index, name) in record.lookupNames.enumerated() where index < record.values.count {
            dictionary[name] = record.values[index] ?? "NULL"
        }
        return dictionary
    }

    // MARK: Variables, status, accounts

    public func variables(global: Bool = true) async throws -> [ServerVariable] {
        try await execute(global ? "SHOW GLOBAL VARIABLES" : "SHOW SESSION VARIABLES").records.compactMap(Self.variable)
    }

    public func status(global: Bool = true) async throws -> [ServerVariable] {
        try await execute(global ? "SHOW GLOBAL STATUS" : "SHOW SESSION STATUS").records.compactMap(Self.variable)
    }

    static func variable(_ record: Record) -> ServerVariable? {
        guard let name = record.text("Variable_name") ?? (record.values.first ?? nil) else { return nil }
        return ServerVariable(name: name, value: record.raw("Value") ?? (record.values.count > 1 ? record.values[1] ?? "" : ""))
    }

    /// Accounts from `mysql.user` (never the authentication string), with the columns this version has.
    public func accounts() async throws -> [AccountInfo] {
        let variants = [
            "SELECT User, Host, plugin, account_locked, password_expired, password_last_changed, is_role FROM mysql.user",
            "SELECT User, Host, plugin, account_locked, password_expired, password_last_changed FROM mysql.user",
            "SELECT User, Host, plugin, password_expired FROM mysql.user",
            "SELECT User, Host FROM mysql.user",
        ]
        var unavailable: [String: String] = [:]
        guard let result = try await firstAccepted(variants, section: "Accounts", into: &unavailable) else {
            throw MySQLError(.server, unavailable["Accounts"] ?? "Reading accounts requires SELECT on mysql.user")
        }
        return result.records.compactMap { record in
            guard let user = record.raw("User"), let host = record.raw("Host") else { return nil }
            return AccountInfo(user: user, host: host, plugin: record.text("plugin"), isLocked: record.bool("account_locked"),
                               passwordExpired: record.bool("password_expired"), passwordLastChanged: record.text("password_last_changed"),
                               isRole: record.bool("is_role"))
        }.sorted { ($0.user, $0.host) < ($1.user, $1.host) }
    }

    /// `SHOW GRANTS` lines for an account (credential literals are redacted by the caller before display).
    public func grants(for account: AccountInfo) async throws -> [String] {
        try await execute("SHOW GRANTS FOR \(account.accountName)").rows.compactMap { $0.first ?? nil }
    }
}
