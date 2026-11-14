import Foundation

/// Parsed server release, e.g. `8.4.13`, `10.11.6-MariaDB-1`, `5.7.44-log`.
public struct ServerVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let raw: String

    public init(major: Int, minor: Int, patch: Int = 0, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw ?? "\(major).\(minor).\(patch)"
    }

    /// Accepts `8.0.39-30`, `v9.1.0`, `5.5.5-10.11.6-MariaDB-…` (MariaDB's replication-compatibility prefix is skipped).
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("5.5.5-"), trimmed.range(of: "MariaDB", options: .caseInsensitive) != nil {
            trimmed.removeFirst(6)
        }
        let body = trimmed.drop(while: { !$0.isNumber })
        let numbers = body.prefix(while: { $0.isNumber || $0 == "." }).split(separator: ".").prefix(3).map { Int($0.prefix(9)) ?? 0 }
        guard numbers.count >= 2 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0, raw: trimmed)
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    public func atLeast(_ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool {
        self >= ServerVersion(major: major, minor: minor, patch: patch)
    }

    public var shortDescription: String { "\(major).\(minor).\(patch)" }
    public var description: String { raw }
}

public enum ServerFlavor: String, Sendable, Codable, Hashable {
    case mysql
    case mariadb
    case percona
    case unknown

    public var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .percona: "Percona Server"
        case .unknown: "MySQL-compatible"
        }
    }

    static func detect(version: String, comment: String) -> ServerFlavor {
        let lowered = (version + " " + comment).lowercased()
        if lowered.contains("mariadb") { return .mariadb }
        if lowered.contains("percona") { return .percona }
        if lowered.contains("mysql") || ServerVersion(version) != nil { return .mysql }
        return .unknown
    }
}

/// Which server a connection reached (design D6). Thread ids are only meaningful per server.
public struct ServerIdentity: Sendable, Hashable, CustomStringConvertible {
    public let serverUUID: String?
    public let hostname: String?
    public let port: Int?
    public let serverID: Int64?

    public init(serverUUID: String?, hostname: String?, port: Int?, serverID: Int64?) {
        self.serverUUID = serverUUID?.nilIfBlank
        self.hostname = hostname?.nilIfBlank
        self.port = port
        self.serverID = serverID
    }

    /// Same server: by UUID when both know it, otherwise by host name, port and server id.
    public func matches(_ other: ServerIdentity) -> Bool {
        if let lhs = serverUUID, let rhs = other.serverUUID { return lhs.caseInsensitiveCompare(rhs) == .orderedSame }
        return hostname == other.hostname && port == other.port && serverID == other.serverID
    }

    public var description: String {
        let address = [hostname, port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        return address.isEmpty ? (serverUUID ?? "unknown server") : address
    }
}

/// Facts about the connected server, loaded once per client (design D7).
public struct ServerInfo: Sendable, Equatable {
    public let versionString: String
    public let versionComment: String
    public let version: ServerVersion?
    public let flavor: ServerFlavor
    /// Version string from the handshake.
    public let protocolVersion: String
    public let currentUser: String?
    public let identity: ServerIdentity
    /// The profile points at ProxySQL (it answers `SELECT @@version_comment LIMIT 1` itself).
    public let isProxySQL: Bool
    public let readOnly: Bool
    public let superReadOnly: Bool
    public let performanceSchemaEnabled: Bool
    /// `wsrep_on` (Galera) is ON.
    public let galeraEnabled: Bool
    public let characterSet: String?
    public let timeZone: String?
    public let lowerCaseTableNames: Int?
    public let tlsVersion: String?
    public let tlsCipher: String?
    public let authPlugin: String
    public let tlsFallbackReason: String?

    public init(versionString: String, versionComment: String = "", protocolVersion: String, currentUser: String? = nil,
                identity: ServerIdentity = ServerIdentity(serverUUID: nil, hostname: nil, port: nil, serverID: nil),
                isProxySQL: Bool = false, readOnly: Bool = false, superReadOnly: Bool = false, performanceSchemaEnabled: Bool = false,
                galeraEnabled: Bool = false, characterSet: String? = nil, timeZone: String? = nil, lowerCaseTableNames: Int? = nil,
                tlsVersion: String? = nil, tlsCipher: String? = nil, authPlugin: String = "", tlsFallbackReason: String? = nil) {
        self.versionString = versionString
        self.versionComment = versionComment
        version = ServerVersion(versionString) ?? ServerVersion(protocolVersion)
        flavor = ServerFlavor.detect(version: versionString.isEmpty ? protocolVersion : versionString, comment: versionComment)
        self.protocolVersion = protocolVersion
        self.currentUser = currentUser
        self.identity = identity
        self.isProxySQL = isProxySQL
        self.readOnly = readOnly
        self.superReadOnly = superReadOnly
        self.performanceSchemaEnabled = performanceSchemaEnabled
        self.galeraEnabled = galeraEnabled
        self.characterSet = characterSet
        self.timeZone = timeZone
        self.lowerCaseTableNames = lowerCaseTableNames
        self.tlsVersion = tlsVersion
        self.tlsCipher = tlsCipher
        self.authPlugin = authPlugin
        self.tlsFallbackReason = tlsFallbackReason
    }

    public var isMariaDB: Bool { flavor == .mariadb }
    public var isTLS: Bool { tlsVersion != nil }

    /// e.g. "MySQL 8.4.13", "MariaDB 10.11.6".
    public var productDescription: String {
        "\(flavor.displayName) \(version?.shortDescription ?? versionString)"
    }

    private func mysql(_ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool {
        !isMariaDB && (version?.atLeast(major, minor, patch) ?? false)
    }

    private func mariadb(_ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool {
        isMariaDB && (version?.atLeast(major, minor, patch) ?? false)
    }

    // MARK: Feature gates

    /// `performance_schema.data_locks` / `data_lock_waits` (MySQL 8.0.1+).
    public var hasDataLocks: Bool { mysql(8, 0, 1) }
    /// `information_schema.innodb_trx` exists everywhere relevant; `innodb_locks` only before MySQL 8.0 and on MariaDB.
    public var hasInnoDBLocksTables: Bool { isMariaDB || !(version?.atLeast(8, 0) ?? false) }
    public var supportsExplainJSON: Bool { mysql(5, 6, 5) || mariadb(10, 1) }
    public var supportsExplainAnalyze: Bool { mysql(8, 0, 18) }
    public var supportsExplainTree: Bool { mysql(8, 0, 16) }
    /// MariaDB `ANALYZE FORMAT=JSON <stmt>` (executes the statement).
    public var supportsAnalyzeJSON: Bool { mariadb(10, 1) }
    public var usesReplicaVocabulary: Bool { mysql(8, 0, 22) || mariadb(10, 5, 1) }
    public var supportsReadOnlyTransactions: Bool { mysql(5, 6, 5) || mariadb(10, 0) }
    /// `SET SESSION MAX_EXECUTION_TIME` (milliseconds, SELECT only).
    public var supportsMaxExecutionTime: Bool { mysql(5, 7, 8) }
    /// MariaDB `SET SESSION max_statement_time` (seconds).
    public var supportsMaxStatementTime: Bool { mariadb(10, 1, 1) }
    public var supportsResetConnection: Bool { mysql(5, 7, 3) || mariadb(10, 2, 4) }
    public var supportsInvisibleIndexes: Bool { mysql(8, 0) }
    public var supportsIgnoredIndexes: Bool { mariadb(10, 6) }
    public var supportsCTE: Bool { mysql(8, 0) || mariadb(10, 2, 1) }
    public var hasServerUUID: Bool { mysql(5, 6) }
    public var hasPerformanceSchemaDigests: Bool { mysql(5, 6) || mariadb(10, 0) }

    /// `SELECT … identity …` for the connection's own server (MariaDB has no `server_uuid`).
    public var identityQuery: String {
        let uuid = hasServerUUID ? "@@server_uuid" : "NULL"
        return "SELECT CONNECTION_ID() AS thread_id, \(uuid) AS server_uuid, @@hostname AS hostname, @@port AS port, @@server_id AS server_id"
    }

    // MARK: Loading

    static func load(from connection: MySQLConnection) async throws -> ServerInfo {
        // ProxySQL answers exactly this query itself; real servers return their comment.
        let proxyComment = try await tolerant(connection, "select @@version_comment limit 1")?.scalar ?? ""
        let isProxySQL = proxyComment.localizedCaseInsensitiveContains("ProxySQL")
        let base = try await connection.execute("""
            SELECT @@version AS version, @@version_comment AS comment, CURRENT_USER() AS user, @@hostname AS hostname, \
            @@port AS port, @@server_id AS server_id, @@read_only AS ro, @@character_set_server AS cs, \
            @@lower_case_table_names AS lctn, @@time_zone AS tz, @@system_time_zone AS stz
            """).first
        let versionString = base?.text("version") ?? connection.protocolVersion
        let comment = base?.text("comment") ?? (isProxySQL ? "" : proxyComment)
        let probe = ServerInfo(versionString: versionString, versionComment: comment, protocolVersion: connection.protocolVersion)

        var uuid: String?
        var superReadOnly = false
        var performanceSchema = false
        var galera = false
        let extras: String
        if probe.isMariaDB {
            extras = "SELECT @@performance_schema AS ps, @@wsrep_on AS wsrep"
        } else if probe.version?.atLeast(5, 7, 8) == true {
            extras = "SELECT @@server_uuid AS uuid, @@super_read_only AS sro, @@performance_schema AS ps"
        } else if probe.version?.atLeast(5, 6) == true {
            extras = "SELECT @@server_uuid AS uuid, @@performance_schema AS ps"
        } else {
            extras = "SELECT @@performance_schema AS ps"
        }
        if let row = try await tolerant(connection, extras)?.first {
            uuid = row.text("uuid")
            superReadOnly = row.bool("sro") ?? false
            performanceSchema = row.bool("ps") ?? false
            galera = row.bool("wsrep") ?? false
        }
        var tlsVersion: String?
        var tlsCipher: String?
        if connection.isTLS, let status = try await tolerant(connection, "SHOW SESSION STATUS WHERE Variable_name IN ('Ssl_version', 'Ssl_cipher')") {
            for record in status.records {
                switch record.text("Variable_name") {
                case "Ssl_version": tlsVersion = record.text("Value")
                case "Ssl_cipher": tlsCipher = record.text("Value")
                default: break
                }
            }
        }
        let timeZone = base?.text("tz").flatMap { $0 == "SYSTEM" ? base?.text("stz").map { "SYSTEM (\($0))" } : $0 }
        return ServerInfo(
            versionString: versionString, versionComment: comment, protocolVersion: connection.protocolVersion,
            currentUser: base?.text("user"),
            identity: ServerIdentity(serverUUID: uuid, hostname: base?.text("hostname"), port: base?.int("port").map { Int(clamping: $0) },
                                     serverID: base?.int("server_id")),
            isProxySQL: isProxySQL, readOnly: base?.bool("ro") ?? false, superReadOnly: superReadOnly,
            performanceSchemaEnabled: performanceSchema, galeraEnabled: galera, characterSet: base?.text("cs"), timeZone: timeZone,
            lowerCaseTableNames: base?.int("lctn").map { Int(clamping: $0) },
            tlsVersion: connection.isTLS ? (tlsVersion ?? "TLS") : nil, tlsCipher: tlsCipher,
            authPlugin: connection.authPlugin, tlsFallbackReason: connection.tlsFallbackReason)
    }

    /// `nil` when the server rejects the statement; timeouts, network errors and cancellation propagate (design D8).
    static func tolerant(_ connection: MySQLConnection, _ sql: String) async throws -> ResultSet? {
        do {
            return try await connection.execute(sql)
        } catch let error as MySQLError where error.kind == .server || error.kind == .authentication {
            return nil
        }
    }
}
