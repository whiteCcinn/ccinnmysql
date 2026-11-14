import Foundation

/// One row of `SHOW FULL PROCESSLIST`.
public struct SessionProcess: Sendable, Hashable, Identifiable {
    public let id: UInt64
    public let user: String?
    public let host: String?
    public let database: String?
    public let command: String?
    public let timeSeconds: Int64?
    public let state: String?
    public let statement: String?
    /// MariaDB `Progress` (0–100) for long ALTER/LOAD statements.
    public let progress: Double?

    public init(id: UInt64, user: String? = nil, host: String? = nil, database: String? = nil, command: String? = nil, timeSeconds: Int64? = nil,
                state: String? = nil, statement: String? = nil, progress: Double? = nil) {
        self.id = id
        self.user = user
        self.host = host
        self.database = database
        self.command = command
        self.timeSeconds = timeSeconds
        self.state = state
        self.statement = statement
        self.progress = progress
    }

    public init?(record: Record) {
        guard let id = record.raw("Id", "ID", "SessionID").flatMap({ UInt64($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        self.init(id: id, user: record.text("User", "user"), host: record.text("Host", "host", "cli_host"), database: record.text("db", "DB"),
                  command: record.text("Command", "command"), timeSeconds: record.int("Time"),
                  state: record.text("State", "state"), statement: record.text("Info", "info"), progress: record.double("Progress"))
    }

    /// Sessions that are executing something (not idle, not daemon/replication threads).
    public var isRunningStatement: Bool {
        guard let command = command?.lowercased() else { return false }
        return !["sleep", "daemon", "binlog dump", "binlog dump gtid", "connect", "killed"].contains(command) && statement != nil
    }

    public var isSystemThread: Bool {
        let user = user?.lowercased() ?? ""
        return user == "system user" || user == "event_scheduler" || command?.lowercased() == "daemon"
    }
}

/// A processlist read from one server, with that server's identity so kills are pinned to it (design D6).
public struct ProcessListSnapshot: Sendable {
    public let identity: ServerIdentity?
    public let processes: [SessionProcess]
    public let ownConnectionIDs: Set<UInt64>
    public let takenAt: Date

    public init(identity: ServerIdentity?, processes: [SessionProcess], ownConnectionIDs: Set<UInt64> = [], takenAt: Date = Date()) {
        self.identity = identity
        self.processes = processes
        self.ownConnectionIDs = ownConnectionIDs
        self.takenAt = takenAt
    }

    public func target(for process: SessionProcess, viaProxy: Bool) -> KillTarget {
        KillTarget(threadID: process.id, proxySessionID: viaProxy ? UInt32(exactly: process.id) : nil, identity: viaProxy ? nil : identity)
    }
}

public struct InnoDBTransaction: Sendable, Hashable, Identifiable {
    public let id: String
    public let state: String
    public let started: String?
    public let ageSeconds: Int64?
    public let threadID: UInt64?
    public let query: String?
    public let operationState: String?
    public let tablesLocked: Int64?
    public let rowsLocked: Int64?
    public let rowsModified: Int64?
    public let isolationLevel: String?
    public let waitStartedSeconds: Int64?

    public init(record: Record) {
        id = record.text("trx_id") ?? "?"
        state = record.text("trx_state") ?? "?"
        started = record.text("trx_started")
        ageSeconds = record.int("age_seconds")
        threadID = record.raw("trx_mysql_thread_id").flatMap { UInt64($0) }
        query = record.text("trx_query")
        operationState = record.text("trx_operation_state")
        tablesLocked = record.int("trx_tables_locked")
        rowsLocked = record.int("trx_rows_locked")
        rowsModified = record.int("trx_rows_modified")
        isolationLevel = record.text("trx_isolation_level")
        waitStartedSeconds = record.int("wait_seconds")
    }

    public var isWaiting: Bool { state.uppercased() == "LOCK WAIT" }
}

/// A blocked transaction and the one blocking it.
public struct LockWait: Sendable, Hashable, Identifiable {
    public let waitingTransaction: String
    public let waitingThread: UInt64?
    public let waitingQuery: String?
    public let waitSeconds: Int64?
    public let blockingTransaction: String
    public let blockingThread: UInt64?
    public let blockingQuery: String?
    public let lockMode: String?
    public let lockType: String?
    public let lockedTable: String?
    public let lockedIndex: String?
    public let lockData: String?

    public init(record: Record) {
        waitingTransaction = record.text("waiting_trx_id") ?? "?"
        waitingThread = record.raw("waiting_thread").flatMap { UInt64($0) }
        waitingQuery = record.text("waiting_query")
        waitSeconds = record.int("wait_seconds")
        blockingTransaction = record.text("blocking_trx_id") ?? "?"
        blockingThread = record.raw("blocking_thread").flatMap { UInt64($0) }
        blockingQuery = record.text("blocking_query")
        lockMode = record.text("lock_mode")
        lockType = record.text("lock_type")
        lockedTable = record.text("locked_table")
        lockedIndex = record.text("locked_index")
        lockData = record.text("lock_data")
    }

    public var id: String { "\(waitingTransaction)<-\(blockingTransaction)" }
}

public struct InnoDBActivity: Sendable {
    public var transactions: [InnoDBTransaction] = []
    public var lockWaits: [LockWait] = []
    /// `LATEST DETECTED DEADLOCK` section of `SHOW ENGINE INNODB STATUS`, if any.
    public var latestDeadlock: String?
    public var unavailable: [String: String] = [:]
    public var identity: ServerIdentity?

    public init() {}
}

/// Ordering for the top statements view.
public enum StatementOrder: String, Sendable, CaseIterable, Identifiable {
    case totalLatency, executions, averageLatency, rowsExamined, errors, noIndexUsed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .totalLatency: "Total time"
        case .executions: "Executions"
        case .averageLatency: "Average time"
        case .rowsExamined: "Rows examined"
        case .errors: "Errors"
        case .noIndexUsed: "Full scans"
        }
    }

    var column: String {
        switch self {
        case .totalLatency: "SUM_TIMER_WAIT"
        case .executions: "COUNT_STAR"
        case .averageLatency: "AVG_TIMER_WAIT"
        case .rowsExamined: "SUM_ROWS_EXAMINED"
        case .errors: "SUM_ERRORS"
        case .noIndexUsed: "SUM_NO_INDEX_USED"
        }
    }
}

/// One statement digest from `performance_schema.events_statements_summary_by_digest`.
public struct StatementDigest: Sendable, Hashable, Identifiable {
    public let schema: String?
    public let digest: String
    public let text: String
    public let executions: Int64
    /// Seconds (performance_schema timers are picoseconds).
    public let totalSeconds: Double
    public let averageSeconds: Double
    public let maxSeconds: Double
    public let rowsExamined: Int64
    public let rowsSent: Int64
    public let rowsAffected: Int64
    public let errors: Int64
    public let warnings: Int64
    public let noIndexUsed: Int64
    public let temporaryDiskTables: Int64
    public let sortRows: Int64
    public let firstSeen: String?
    public let lastSeen: String?
    public let sample: String?

    public init(record: Record) {
        schema = record.text("SCHEMA_NAME")
        digest = record.text("DIGEST") ?? UUID().uuidString
        text = record.text("DIGEST_TEXT") ?? "(no digest text)"
        executions = record.int("COUNT_STAR") ?? 0
        totalSeconds = Self.seconds(record.double("SUM_TIMER_WAIT"))
        averageSeconds = Self.seconds(record.double("AVG_TIMER_WAIT"))
        maxSeconds = Self.seconds(record.double("MAX_TIMER_WAIT"))
        rowsExamined = record.int("SUM_ROWS_EXAMINED") ?? 0
        rowsSent = record.int("SUM_ROWS_SENT") ?? 0
        rowsAffected = record.int("SUM_ROWS_AFFECTED") ?? 0
        errors = record.int("SUM_ERRORS") ?? 0
        warnings = record.int("SUM_WARNINGS") ?? 0
        noIndexUsed = record.int("SUM_NO_INDEX_USED") ?? 0
        temporaryDiskTables = record.int("SUM_CREATED_TMP_DISK_TABLES") ?? 0
        sortRows = record.int("SUM_SORT_ROWS") ?? 0
        firstSeen = record.text("FIRST_SEEN")
        lastSeen = record.text("LAST_SEEN")
        sample = record.text("QUERY_SAMPLE_TEXT")
    }

    static func seconds(_ picoseconds: Double?) -> Double {
        guard let picoseconds, picoseconds.isFinite, picoseconds >= 0 else { return 0 }
        return picoseconds / 1e12
    }

    public var id: String { "\(schema ?? "")/\(digest)" }
    public var rowsExaminedPerExecution: Double { executions > 0 ? Double(rowsExamined) / Double(executions) : 0 }
}

/// One replication channel (MySQL channel or MariaDB connection), mapped from both REPLICA and SLAVE vocabularies.
public struct ReplicaChannel: Sendable, Hashable, Identifiable {
    public let name: String
    public let sourceHost: String?
    public let sourcePort: Int?
    public let sourceUser: String?
    public let ioRunning: String?
    public let sqlRunning: String?
    public let secondsBehind: Int64?
    public let lastIOError: String?
    public let lastSQLError: String?
    public let sqlState: String?
    public let retrievedGTIDSet: String?
    public let executedGTIDSet: String?
    public let sourceLogFile: String?
    public let readSourceLogPosition: Int64?
    public let executedSourceLogFile: String?
    public let executedSourceLogPosition: Int64?
    public let usesGTID: String?

    public init(record: Record) {
        name = record.text("Channel_Name", "Connection_name") ?? ""
        sourceHost = record.text("Source_Host", "Master_Host")
        sourcePort = record.int("Source_Port", "Master_Port").map { Int(clamping: $0) }
        sourceUser = record.text("Source_User", "Master_User")
        ioRunning = record.text("Replica_IO_Running", "Slave_IO_Running")
        sqlRunning = record.text("Replica_SQL_Running", "Slave_SQL_Running")
        secondsBehind = record.int("Seconds_Behind_Source", "Seconds_Behind_Master")
        lastIOError = record.text("Last_IO_Error")
        lastSQLError = record.text("Last_SQL_Error")
        sqlState = record.text("Replica_SQL_Running_State", "Slave_SQL_Running_State")
        retrievedGTIDSet = record.text("Retrieved_Gtid_Set", "Gtid_IO_Pos")
        executedGTIDSet = record.text("Executed_Gtid_Set", "Gtid_Slave_Pos")
        sourceLogFile = record.text("Source_Log_File", "Master_Log_File")
        readSourceLogPosition = record.int("Read_Source_Log_Pos", "Read_Master_Log_Pos")
        executedSourceLogFile = record.text("Relay_Source_Log_File", "Relay_Master_Log_File")
        executedSourceLogPosition = record.int("Exec_Source_Log_Pos", "Exec_Master_Log_Pos")
        usesGTID = record.text("Using_Gtid", "Auto_Position")
    }

    public var id: String { name.isEmpty ? "(default)" : name }
    public var isHealthy: Bool { ioRunning?.lowercased() == "yes" && sqlRunning?.lowercased() == "yes" }
}

public struct GroupMember: Sendable, Hashable, Identifiable {
    public let memberID: String
    public let host: String?
    public let port: Int?
    public let state: String?
    public let role: String?
    public let version: String?

    public init(record: Record) {
        memberID = record.text("MEMBER_ID") ?? UUID().uuidString
        host = record.text("MEMBER_HOST")
        port = record.int("MEMBER_PORT").map { Int(clamping: $0) }
        state = record.text("MEMBER_STATE")
        role = record.text("MEMBER_ROLE")
        version = record.text("MEMBER_VERSION")
    }

    public var id: String { memberID }
}

/// Replication and cluster topology seen from the connected server (design D13).
public struct ReplicationOverview: Sendable {
    public var channels: [ReplicaChannel] = []
    /// Binary log file and position (or GTID) of this server as a source.
    public var binlogFile: String?
    public var binlogPosition: Int64?
    public var executedGTIDSet: String?
    public var gtidMode: String?
    /// Replicas registered with this server (`SHOW REPLICAS`).
    public var connectedReplicas: [[String: String]] = []
    public var groupMembers: [GroupMember] = []
    public var groupName: String?
    /// `wsrep_%` status of a Galera node.
    public var galera: [String: String] = [:]
    /// Instances from `mysql_innodb_cluster_metadata`, when present.
    public var innoDBClusterInstances: [[String: String]] = []
    public var unavailable: [String: String] = [:]

    public init() {}

    public enum Role: String, Sendable { case standalone, source, replica, sourceAndReplica, groupMember, galeraNode }

    public var role: Role {
        if !galera.isEmpty { return .galeraNode }
        if !groupMembers.isEmpty { return .groupMember }
        let isReplica = !channels.isEmpty
        let isSource = !connectedReplicas.isEmpty
        switch (isSource, isReplica) {
        case (true, true): return .sourceAndReplica
        case (true, false): return .source
        case (false, true): return .replica
        default: return .standalone
        }
    }
}

public struct ServerVariable: Sendable, Hashable, Identifiable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var id: String { name }
}

public struct AccountInfo: Sendable, Hashable, Identifiable {
    public let user: String
    public let host: String
    public let plugin: String?
    public let isLocked: Bool?
    public let passwordExpired: Bool?
    public let passwordLastChanged: String?
    public let isRole: Bool?

    public init(user: String, host: String, plugin: String? = nil, isLocked: Bool? = nil, passwordExpired: Bool? = nil,
                passwordLastChanged: String? = nil, isRole: Bool? = nil) {
        self.user = user
        self.host = host
        self.plugin = plugin
        self.isLocked = isLocked
        self.passwordExpired = passwordExpired
        self.passwordLastChanged = passwordLastChanged
        self.isRole = isRole
    }

    public var id: String { "'\(user)'@'\(host)'" }
    public var accountName: String { "\(SQLText.literal(user))@\(SQLText.literal(host))" }
}
