import Foundation
import MySQLKit
import MySQLWire

/// Opens (once) and caches a client per profile for the lifetime of the MCP process.
public actor MCPClientRegistry {
    public typealias Opener = @Sendable (ConnectionProfile) async throws -> MySQLClient

    private let opener: Opener
    private var clients: [UUID: MySQLClient] = [:]
    private var opening: [UUID: Task<MySQLClient, any Error>] = [:]

    public init(opener: @escaping Opener) {
        self.opener = opener
    }

    public func client(for profile: ConnectionProfile) async throws -> MySQLClient {
        if let client = clients[profile.id] { return client }
        if let pending = opening[profile.id] { return try await pending.value }
        let opener = opener
        let task = Task { try await opener(profile) }
        opening[profile.id] = task
        do {
            let client = try await task.value
            opening[profile.id] = nil
            clients[profile.id] = client
            return client
        } catch {
            opening[profile.id] = nil
            throw error
        }
    }

    public func closeAll() async {
        let open = Array(clients.values)
        clients.removeAll()
        for client in open { await client.close() }
    }
}

/// The MySQL tool set of the MCP server (ccinn MCP design, design D14).
public struct MySQLMCPTools: MCPToolProvider {
    public let resolver: MCPProfileResolver
    public let registry: MCPClientRegistry
    public let audit: MCPAuditLog?
    /// Definer-rights objects each connection's account can reach, for the notice of read-only query results.
    private let definerRights = DefinerRightsCache()

    public static let defaultRowLimit = 200
    public static let maxRowLimit = 1_000
    public static let defaultTimeout = 30.0
    public static let maxTimeout = 120.0

    public init(resolver: MCPProfileResolver, registry: MCPClientRegistry, audit: MCPAuditLog?) {
        self.resolver = resolver
        self.registry = registry
        self.audit = audit
    }

    // MARK: Definitions

    public func tools() async -> [MCPTool] {
        var tools: [MCPTool] = [
            MCPTool(name: "list_connections", title: "List connections",
                    description: "Lists the saved MySQL/MariaDB connections the user enabled for AI access (no secrets).",
                    inputSchema: ["type": "object", "properties": .object([:]), "additionalProperties": false], readOnly: true),
            MCPTool(name: "server_info", title: "Server info",
                    description: "Flavor (MySQL, MariaDB, Percona), version, TLS, read-only state, replication role, uptime and key settings of a connection's server.",
                    inputSchema: Self.schema([:]), readOnly: true, idempotent: false),
            MCPTool(name: "list_databases", title: "List databases",
                    description: "Lists schemas (databases) with their default character set; system schemas last.",
                    inputSchema: Self.schema([:]), readOnly: true),
            MCPTool(name: "list_tables", title: "List tables and objects",
                    description: "Lists tables (with engine, estimated rows and size), views, procedures, functions, triggers and events of a database.",
                    inputSchema: Self.schema(["database": Self.databaseProperty,
                                              "name_filter": ["type": "string", "description": "Case-insensitive substring to filter object names."]],
                                             required: ["database"]), readOnly: true),
            MCPTool(name: "describe_table", title: "Describe table",
                    description: "Columns, indexes (with cardinality), foreign keys in both directions, partitions, size estimates, health findings (missing primary key, redundant indexes, AUTO_INCREMENT headroom) and optionally the CREATE statement.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "table": Self.tableProperty,
                                              "include_ddl": ["type": "boolean", "description": "Include the CREATE statement (default true)."]],
                                             required: ["database", "table"]), readOnly: true),
            MCPTool(name: "get_indexes", title: "Get indexes",
                    description: "Indexes of a table with column order, uniqueness, type, cardinality, visibility, and redundant/duplicate index findings.",
                    inputSchema: Self.schema(["database": Self.databaseProperty, "table": Self.tableProperty], required: ["database", "table"]),
                    readOnly: true),
            MCPTool(name: "get_processlist", title: "Get processlist",
                    description: "Current sessions (SHOW FULL PROCESSLIST): id, user, host, database, command, seconds, state and statement.",
                    inputSchema: Self.schema(["include_idle": ["type": "boolean", "description": "Include sleeping sessions (default false)."]]),
                    readOnly: true, idempotent: false),
            MCPTool(name: "get_innodb_status", title: "Get InnoDB transactions and locks",
                    description: "Running InnoDB transactions, lock waits (waiting and blocking sessions with their statements and locked objects) and the latest detected deadlock.",
                    inputSchema: Self.schema([:]), readOnly: true, idempotent: false),
            MCPTool(name: "get_top_statements", title: "Get top statements",
                    description: "Most expensive statement digests from performance_schema.events_statements_summary_by_digest.",
                    inputSchema: Self.schema(["order_by": ["type": "string", "enum": .array(StatementOrder.allCases.map { .string($0.rawValue) }),
                                                           "description": "Ranking (default totalLatency)."],
                                              "database": ["type": "string", "description": "Only statements run in this schema."],
                                              "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Digests to return (default 25)."]]),
                    readOnly: true, idempotent: false),
            MCPTool(name: "get_replication_status", title: "Get replication status",
                    description: "Replica channels (source, IO/SQL threads, lag, GTID sets, last errors), binary log position, connected replicas, Group Replication members and Galera status.",
                    inputSchema: Self.schema([:]), readOnly: true, idempotent: false),
            MCPTool(name: "run_query", title: "Run read-only SQL",
                    description: "Runs one read-only statement (SELECT, WITH, TABLE, VALUES, SHOW, DESCRIBE, EXPLAIN) inside a READ ONLY transaction with a server-side time limit. A LIMIT is added to queries without one; results are capped at `limit` rows and about 256 KB.",
                    inputSchema: Self.schema(["sql": ["type": "string", "description": "A single read-only SQL statement."],
                                              "database": ["type": "string", "description": "Database to run in (USE). Optional when the SQL qualifies names."],
                                              "limit": ["type": "integer", "minimum": 1, "maximum": .int(Int64(Self.maxRowLimit)), "description": "Maximum rows (default 200)."],
                                              "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout)), "description": "Time limit (default 30)."]],
                                             required: ["sql"]), readOnly: true, idempotent: false),
            MCPTool(name: "explain_query", title: "Explain query",
                    description: "Execution plan of a SELECT as a tree with access types, keys, row estimates, costs and warnings (full scans, filesorts, temporary tables). `analyze: true` runs the query (EXPLAIN ANALYZE on MySQL 8.0.18+, ANALYZE FORMAT=JSON on MariaDB) to report actual rows and time.",
                    inputSchema: Self.schema(["sql": ["type": "string", "description": "A SELECT or WITH query."],
                                              "database": ["type": "string", "description": "Database to run in."],
                                              "analyze": ["type": "boolean", "description": "Execute the query to measure actual rows and time (default false)."],
                                              "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout))]],
                                             required: ["sql"]), readOnly: true, idempotent: false),
        ]
        if resolver.anyWritable {
            tools.append(MCPTool(name: "execute_statement", title: "Execute SQL (writes allowed)",
                                 description: "Runs one SQL statement that may change data or schema (INSERT, UPDATE, DELETE, CREATE, ALTER, …). Only available on connections with read-write AI access. Prefer run_query for reads.",
                                 inputSchema: Self.schema(["sql": ["type": "string", "description": "A single SQL statement."],
                                                           "database": ["type": "string", "description": "Database to run in."],
                                                           "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout))]],
                                                          required: ["sql"]), readOnly: false, destructive: true, idempotent: false))
        }
        return tools
    }

    static let connectionProperty: JSONValue = ["type": "string", "description": "Saved connection name or id (see list_connections). Optional when only one connection is enabled or a default was configured."]
    static let databaseProperty: JSONValue = ["type": "string", "description": "Database (schema) name."]
    static let tableProperty: JSONValue = ["type": "string", "description": "Table or view name."]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var all = properties
        all["connection"] = connectionProperty
        return ["type": "object", "properties": .object(all), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }

    // MARK: Calls

    /// Collects audit details while a tool runs.
    final class CallContext: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: (connection: String?, statement: String?, rows: Int?) = (nil, nil, nil)

        var connection: String? {
            get { lock.withLock { storage.connection } }
            set { lock.withLock { storage.connection = newValue } }
        }
        var statement: String? {
            get { lock.withLock { storage.statement } }
            set { lock.withLock { storage.statement = newValue } }
        }
        var rows: Int? {
            get { lock.withLock { storage.rows } }
            set { lock.withLock { storage.rows = newValue } }
        }
    }

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let context = CallContext()
        let result: MCPToolResult
        do {
            try await validate(name: name, arguments: arguments)
            result = .success(try await dispatch(name, Arguments(arguments), context))
        } catch let error as MCPToolError {
            result = .failure(error.message)
        } catch let error as MySQLError {
            result = .failure(error.code.map { "\(error.message) (error \($0))" } ?? error.message)
        } catch is CancellationError {
            result = .failure("The call was cancelled.")
        } catch {
            result = .failure(error.localizedDescription)
        }
        let elapsed = clock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        await audit?.record(tool: name, connection: context.connection, statement: context.statement, durationMilliseconds: milliseconds,
                            rows: context.rows, error: result.isError ? result.payload.stringValue : nil)
        return result
    }

    /// Rejects unknown tools and arguments not declared in the tool's schema (`additionalProperties: false`).
    func validate(name: String, arguments: [String: JSONValue]) async throws {
        guard let tool = await tools().first(where: { $0.name == name }) else {
            throw MCPToolError("Unknown tool “\(name)”.")
        }
        let allowed = Set(tool.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let unknown = arguments.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw MCPToolError("Unknown argument\(unknown.count > 1 ? "s" : "") \(unknown.map { "`\($0)`" }.joined(separator: ", ")) for \(name); allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
    }

    private func dispatch(_ name: String, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        if let key = args.controlCharacterArgument() {
            throw MCPToolError("`\(key)` contains a control character. Names are sent to the server as given, so they must be plain text.")
        }
        if name == "list_connections" { return listConnections() }
        let resolved = try resolver.resolve(args.string("connection"))
        context.connection = resolved.profile.displayName
        // Statements are checked before any connection is opened: rejected SQL never reaches the server.
        try precheck(name, args, access: resolved.access, functions: ReadOnlySQLGuard.FunctionPolicy(allowsNonNative: resolved.profile.aiAllowsPrivilegedAccount),
                     context: context)
        let client = try await registry.client(for: resolved.profile)
        // Read-only access with an account that can reach files, server state or secrets through functions is refused
        // unless the connection allows it; run_query and explain_query check inside their own session, before the statement.
        let checksPrivileges = resolved.access == .readOnly && !resolved.profile.aiAllowsPrivilegedAccount
        if checksPrivileges, !["run_query", "explain_query"].contains(name) {
            try await Self.requireUnprivileged(flavor: client.serverInfo.flavor) { try await client.query($0) }
        }
        switch name {
        case "server_info":
            var info = try await serverInfo(client)
            if case var .object(fields) = info, let objects = try? await DefinerRights.load(run: { try await client.query($0) }) {
                fields["definer_rights"] = .array(objects.map { .string($0.label) })
                info = .object(fields)
            }
            return info
        case "list_databases":
            let schemas = try await client.schemas()
            return ["databases": .array(schemas.map { ["name": .string($0.name), "character_set": JSONValue($0.characterSet), "system": .bool($0.isSystem)] })]
        case "list_tables":
            return try await listTables(client, args)
        case "describe_table":
            return try await describeTable(client, args)
        case "get_indexes":
            let database = try args.required("database")
            let table = try args.required("table")
            let indexes = try await client.indexes(schema: database, table: table)
            if indexes.isEmpty, try await client.columns(schema: database, table: table).isEmpty {
                throw MCPToolError("No table named “\(table)” in \(database).")
            }
            return ["database": .string(database), "table": .string(table), "indexes": .array(indexes.map(Self.encode(index:))),
                    "findings": .array(TableInsights.redundantIndexes(indexes).map(Self.encode(finding:)))]
        case "get_processlist":
            return try await processList(client, args)
        case "get_innodb_status":
            return Self.encode(activity: try await client.innoDBActivity())
        case "get_top_statements":
            let order = args.string("order_by").flatMap(StatementOrder.init(rawValue:)) ?? .totalLatency
            let limit = args.int("limit", default: 25, range: 1...200)
            let digests = try await client.topStatements(order: order, limit: limit, schema: args.string("database"))
            return ["order_by": .string(order.rawValue), "statements": .array(digests.map(Self.encode(digest:)))]
        case "get_replication_status":
            return Self.encode(replication: try await client.replicationOverview(), info: client.serverInfo)
        case "run_query":
            let functions = ReadOnlySQLGuard.FunctionPolicy(flavor: client.serverInfo.flavor, allowsNonNative: resolved.profile.aiAllowsPrivilegedAccount)
            let result = try await runQuery(client, args, context, access: resolved.access, checksPrivileges: checksPrivileges, functions: functions)
            return await withDefinerNotice(result, profile: resolved.profile, access: resolved.access, client: client)
        case "explain_query":
            let functions = ReadOnlySQLGuard.FunctionPolicy(flavor: client.serverInfo.flavor, allowsNonNative: resolved.profile.aiAllowsPrivilegedAccount)
            let result = try await explain(client, args, context, checksPrivileges: checksPrivileges, functions: functions)
            return await withDefinerNotice(result, profile: resolved.profile, access: resolved.access, client: client)
        case "execute_statement":
            guard resolved.access == .readWrite else {
                throw MCPToolError("Connection “\(resolved.profile.displayName)” only allows read-only AI access; use run_query, or change its AI access to Read & write in CcinnMysql.")
            }
            return try await execute(client, args, context)
        default:
            throw MCPToolError("Unknown tool “\(name)”.")
        }
    }

    private func precheck(_ name: String, _ args: Arguments, access: MCPAccess, functions: ReadOnlySQLGuard.FunctionPolicy,
                          context: CallContext) throws {
        switch name {
        case "run_query":
            let sql = try args.required("sql")
            context.statement = sql
            if let reason = ReadOnlySQLGuard.check(sql, defaultDatabase: args.string("database"), functions: functions) {
                throw MCPToolError(reason + (access == .readWrite ? " Use execute_statement for statements that change data." : ""))
            }
        case "explain_query":
            let sql = try args.required("sql")
            context.statement = sql
            if let reason = ReadOnlySQLGuard.check(sql, defaultDatabase: args.string("database"), functions: functions) { throw MCPToolError(reason) }
        case "execute_statement":
            guard access == .readWrite else {
                throw MCPToolError("This connection only allows read-only AI access; use run_query, or change its AI access to Read & write in CcinnMysql.")
            }
            context.statement = try args.required("sql") // split in its session, with the session's sql_mode
        default:
            break
        }
    }

    private func listConnections() -> JSONValue {
        ["connections": .array(resolver.enabledProfiles.map { profile in
            [
                "name": .string(profile.displayName),
                "id": .string(profile.id.uuidString),
                "endpoint": .string(profile.endpoint.description),
                "user": .string(profile.username),
                "default_database": JSONValue(profile.defaultDatabase),
                "tls_mode": .string(profile.tlsMode.rawValue),
                "ssh_tunnel": .bool(profile.ssh != nil),
                "access": .string(resolver.access(of: profile) == .readWrite ? "read_write" : "read_only"),
            ]
        })]
    }

    // MARK: Metadata tools

    private func serverInfo(_ client: MySQLClient) async throws -> JSONValue {
        let info = client.serverInfo
        var result: [String: JSONValue] = [
            "flavor": .string(info.flavor.rawValue), "product": .string(info.productDescription), "version": .string(info.versionString),
            "version_comment": .string(info.versionComment), "user": JSONValue(info.currentUser), "server": .string(info.identity.description),
            "server_uuid": JSONValue(info.identity.serverUUID), "server_id": JSONValue(info.identity.serverID),
            "tls": JSONValue(info.tlsVersion), "tls_cipher": JSONValue(info.tlsCipher), "auth_plugin": .string(info.authPlugin),
            "read_only": .bool(info.readOnly), "super_read_only": .bool(info.superReadOnly), "performance_schema": .bool(info.performanceSchemaEnabled),
            "galera": .bool(info.galeraEnabled), "proxysql": .bool(info.isProxySQL), "character_set": JSONValue(info.characterSet),
            "time_zone": JSONValue(info.timeZone),
        ]
        let wanted: Set<String> = ["Uptime", "Threads_connected", "Threads_running", "Questions", "Slow_queries", "Innodb_buffer_pool_pages_free",
                                   "Innodb_row_lock_waits", "Aborted_connects"]
        if let status = try? await client.status() {
            result["status"] = .object(Dictionary(status.filter { wanted.contains($0.name) }.map { ($0.name, JSONValue.string($0.value)) },
                                                  uniquingKeysWith: { first, _ in first }))
        }
        let settings: Set<String> = ["max_connections", "innodb_buffer_pool_size", "transaction_isolation", "tx_isolation", "sql_mode",
                                     "long_query_time", "binlog_format", "gtid_mode", "innodb_flush_log_at_trx_commit", "sync_binlog"]
        if let variables = try? await client.variables() {
            result["settings"] = .object(Dictionary(variables.filter { settings.contains($0.name) }.map { ($0.name, JSONValue.string($0.value)) },
                                                    uniquingKeysWith: { first, _ in first }))
        }
        return .object(result)
    }

    private func listTables(_ client: MySQLClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        var listing = try await client.objects(schema: database)
        if let filter = args.string("name_filter"), !filter.isEmpty {
            listing.objects = listing.objects.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        let cap = 1_000
        let sorted = listing.objects.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        return [
            "database": .string(database),
            "objects": .array(sorted.prefix(cap).map(Self.encode(object:))),
            "count": .int(Int64(sorted.count)), "truncated": .bool(sorted.count > cap),
            "unavailable": .object(listing.unavailable.mapValues(JSONValue.string)),
        ]
    }

    private func findObject(_ client: MySQLClient, database: String, name: String) async throws -> DatabaseObject {
        let objects = try await client.objects(schema: database).objects.filter(\.kind.isRelation)
        if let exact = objects.first(where: { $0.name == name }) ?? objects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let similar = objects.filter { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }.prefix(10).map(\.name)
        throw MCPToolError("No table or view named “\(name)” in \(database).\(similar.isEmpty ? "" : " Similar: \(similar.joined(separator: ", ")).")")
    }

    private func describeTable(_ client: MySQLClient, _ args: Arguments) async throws -> JSONValue {
        let database = try args.required("database")
        let object = try await findObject(client, database: database, name: try args.required("table"))
        var detail = try await client.tableDetail(object)
        var result = Self.encode(object: object).objectValue ?? [:]
        result["columns"] = .array(detail.columns.map { column in
            [
                "name": .string(column.name), "type": .string(column.columnType), "nullable": .bool(column.isNullable),
                "key": .string(column.columnKey), "default": JSONValue(column.defaultValue), "extra": .string(column.extra),
                "collation": JSONValue(column.collation), "comment": JSONValue(column.comment),
            ]
        })
        result["indexes"] = .array(detail.indexes.map(Self.encode(index:)))
        result["foreign_keys"] = .array(detail.foreignKeys.map(Self.encode(foreignKey:)))
        result["referenced_by"] = .array(detail.referencedBy.map(Self.encode(foreignKey:)))
        if !detail.partitions.isEmpty {
            result["partitions"] = .array(detail.partitions.prefix(1_000).map { partition in
                ["name": .string(partition.name), "subpartition": JSONValue(partition.subpartition), "method": JSONValue(partition.method),
                 "expression": JSONValue(partition.expression), "bound": JSONValue(partition.bound), "rows": JSONValue(partition.rowCount),
                 "data_bytes": JSONValue(partition.dataLength)]
            })
        }
        result["findings"] = .array(TableInsights.findings(for: detail).map(Self.encode(finding:)))
        if let headroom = TableInsights.autoIncrementHeadroom(columns: detail.columns, nextValue: object.autoIncrement) {
            result["auto_increment"] = ["column": .string(headroom.column), "current": .string(String(headroom.current)),
                                        "maximum": .string(String(headroom.maximum)), "used_percent": .double((headroom.usedFraction * 1000).rounded() / 10)]
        }
        if args.bool("include_ddl") ?? true, let ddl = detail.ddl {
            result["ddl"] = .string(ddl.count > 20_000 ? String(ddl.prefix(20_000)) + "\n-- (truncated)" : ddl)
        }
        if !detail.unavailable.isEmpty { result["unavailable"] = .object(detail.unavailable.mapValues(JSONValue.string)) }
        detail.ddl = nil
        return .object(result)
    }

    private func processList(_ client: MySQLClient, _ args: Arguments) async throws -> JSONValue {
        let snapshot = try await client.processList()
        let includeIdle = args.bool("include_idle") ?? false
        let sessions = snapshot.processes.filter { process in
            !snapshot.ownConnectionIDs.contains(process.id) && (includeIdle || process.command?.lowercased() != "sleep")
        }
        return [
            "server": JSONValue(snapshot.identity?.description),
            "sessions": .array(sessions.prefix(500).map { process in
                ["id": .string(String(process.id)), "user": JSONValue(process.user), "host": JSONValue(process.host), "database": JSONValue(process.database),
                 "command": JSONValue(process.command), "seconds": JSONValue(process.timeSeconds), "state": JSONValue(process.state),
                 "statement": JSONValue(process.statement.map { SQLRedactor.redactLiterals(String($0.prefix(2_000))) })]
            }),
            "count": .int(Int64(sessions.count)),
        ]
    }

    // MARK: SQL tools

    private func runQuery(_ client: MySQLClient, _ args: Arguments, _ context: CallContext, access: MCPAccess,
                          checksPrivileges: Bool, functions: ReadOnlySQLGuard.FunctionPolicy) async throws -> JSONValue {
        let sql = try args.required("sql")
        let database = args.string("database")
        if let reason = ReadOnlySQLGuard.check(sql, defaultDatabase: database, functions: functions) {
            let hint = access == .readWrite ? " Use execute_statement for statements that change data." : ""
            throw MCPToolError(reason + hint)
        }
        guard let statement = SQLStatementSplitter.split(sql).first?.text else { throw MCPToolError("The statement is empty.") }
        let limit = args.int("limit", default: Self.defaultRowLimit, range: 1...Self.maxRowLimit)
        var executed = statement
        var limitApplied = false
        if SQLStatementKind.of(statement) == .query {
            let outcome = AutoLimit.apply(to: statement, limit: limit + 1)
            executed = outcome.sql
            limitApplied = outcome.applied
        }
        // The guard judges the exact text that is sent (after the automatic LIMIT), not only the request.
        if let reason = ReadOnlySQLGuard.check(executed, defaultDatabase: database, functions: functions) { throw MCPToolError(reason) }
        context.statement = executed
        let started = ContinuousClock.now
        let sent = executed
        let results = try await runInSession(client, args: args, readOnly: true, checksPrivileges: checksPrivileges,
                                             limits: RowLimits(maxRows: limit, drainRows: 10_000)) { _ in sent }.results
        let elapsed = ContinuousClock.now - started
        var payload = Self.encode(results: results, limitRows: limit)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        payload["statement"] = .string(executed)
        payload["limit_applied"] = .bool(limitApplied)
        payload["database"] = JSONValue(args.string("database"))
        payload["elapsed_ms"] = .int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return .object(payload)
    }

    private func explain(_ client: MySQLClient, _ args: Arguments, _ context: CallContext, checksPrivileges: Bool,
                         functions: ReadOnlySQLGuard.FunctionPolicy) async throws -> JSONValue {
        let sql = try args.required("sql")
        let statements = SQLStatementSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text else { throw MCPToolError("Pass exactly one SELECT query.") }
        guard ["SELECT", "WITH", "("].contains(SQLLexer.tokenize(statement).first.map { SQLLexer(statement).text(of: $0).uppercased() } ?? "") else {
            throw MCPToolError("explain_query accepts a SELECT or WITH query.")
        }
        let database = args.string("database")
        if let reason = ReadOnlySQLGuard.check(statement, defaultDatabase: database, functions: functions) { throw MCPToolError(reason) }
        let info = client.serverInfo
        let analyze = args.bool("analyze") ?? false
        let body: String
        if analyze {
            if info.supportsExplainAnalyze {
                body = "EXPLAIN ANALYZE " + statement
            } else if info.supportsAnalyzeJSON {
                body = "ANALYZE FORMAT=JSON " + statement
            } else {
                throw MCPToolError("This server does not support EXPLAIN ANALYZE (MySQL 8.0.18+ or MariaDB 10.1+); call again without `analyze`.")
            }
        } else if info.supportsExplainJSON {
            body = "EXPLAIN FORMAT=JSON " + statement
        } else {
            body = "EXPLAIN " + statement
        }
        if let reason = ReadOnlySQLGuard.check(body, defaultDatabase: database, functions: functions) { throw MCPToolError(reason) }
        context.statement = body
        let results = try await runInSession(client, args: args, readOnly: true, checksPrivileges: checksPrivileges,
                                             limits: RowLimits(maxRows: 10_000, maxBytes: 16 * 1024 * 1024)) { _ in body }.results
        guard let rows = results.last(where: \.hasRowSet) else { throw MCPToolError("The server returned no plan.") }
        let text = rows.rows.compactMap { $0.first ?? nil }.joined(separator: "\n")
        var payload: [String: JSONValue] = ["statement": .string(body)]
        if let plan = try? ExplainParser.parse(text) {
            payload["plan"] = Self.encode(plan: plan)
            payload["warnings"] = .array(plan.warnings.sorted { $0.rawValue < $1.rawValue }.map { .string($0.title) })
            payload["total_cost"] = JSONValue(plan.totalCost)
            context.rows = plan.nodes.count
        } else {
            // Traditional EXPLAIN (MySQL 5.5): return the tabular result.
            payload.merge(Self.encode(results: [rows], limitRows: 1_000)) { $1 }
        }
        if text.utf8.count <= 64 * 1024 { payload["raw"] = .string(text) }
        return .object(payload)
    }

    private func execute(_ client: MySQLClient, _ args: Arguments, _ context: CallContext) async throws -> JSONValue {
        let sql = try args.required("sql")
        // Split as the session splits: its sql_mode decides where strings end, and so where `;` is.
        let (results, statement) = try await runInSession(client, args: args, readOnly: false, checksPrivileges: false,
                                                          limits: RowLimits(maxRows: Self.maxRowLimit, drainRows: 10_000)) { mode in
            let statements = SQLStatementSplitter.split(sql, mode: mode)
            guard statements.count == 1, let statement = statements.first?.text else { throw MCPToolError("Pass exactly one statement per call.") }
            return statement
        }
        context.statement = statement
        var payload = Self.encode(results: results, limitRows: Self.maxRowLimit)
        payload["statement"] = .string(statement)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        return .object(payload)
    }

    /// Runs on a short-lived session in the requested database, bounded by a deadline (plus a server-side time limit).
    /// Read-only calls run inside `START TRANSACTION READ ONLY` and are rolled back (design D10). Cancelling the calling
    /// task (client cancellation or timeout) kills the statement on the server.
    /// `statement` gives the text to run once the session's lexing mode is known (read-only calls: the default mode, which
    /// they enforce; read-write calls: the session's own). Read-only calls also verify, in the same session and right
    /// before the statement, that it reads SQL as the guard did (no lexer-affecting sql_mode, utf8mb4) and, with
    /// `checksPrivileges`, that the account is not privileged (`AccountPrivileges`); any failure refuses the call.
    private func runInSession(_ client: MySQLClient, args: Arguments, readOnly: Bool, checksPrivileges: Bool, limits: RowLimits,
                              statement: @escaping @Sendable (SQLLexingMode) throws -> String) async throws -> (results: [ResultSet], sql: String) {
        let timeout = min(max(args.double("timeout_seconds") ?? Self.defaultTimeout, 1), Self.maxTimeout)
        let session = client.openSession(database: args.string("database"))
        let info = client.serverInfo
        do {
            let results = try await Deadline.run(seconds: timeout, timeoutError: {
                MySQLError(.timeout, "The statement did not finish within \(Int(timeout)) s and was cancelled; narrow the query or raise timeout_seconds (max \(Int(Self.maxTimeout))).")
            }) {
                if info.supportsMaxExecutionTime {
                    _ = try await session.run("SET SESSION MAX_EXECUTION_TIME = \(Int(timeout * 1000))")
                } else if info.supportsMaxStatementTime {
                    _ = try await session.run("SET SESSION max_statement_time = \(Int(timeout))")
                }
                let sessionMode = try await session.run("SELECT @@SESSION.sql_mode AS m").last?.scalar ?? ""
                let mode: SQLLexingMode
                if readOnly {
                    // The guard tokenized the statement in the default mode (backslash escapes, '"' strings) and only the
                    // grammar it knows (no ORACLE, PIPES_AS_CONCAT, …); make the server agree, or refuse.
                    if SQLModes.affectsLexing(sessionMode) {
                        _ = try await session.run("SET SESSION sql_mode = \(SQLText.literal(SQLModes.withoutLexerAffectingModes(sessionMode)))")
                        let after = try await session.run("SELECT @@SESSION.sql_mode AS m").last?.scalar ?? ""
                        guard !SQLModes.affectsLexing(after) else {
                            throw MCPToolError("The session sql_mode (\(after)) changes how SQL is tokenized; read-only calls are refused.")
                        }
                    }
                    try await Self.requireUTF8MB4(session)
                    if checksPrivileges { try await Self.requireUnprivileged(flavor: info.flavor) { try await session.run($0) } }
                    mode = .standard
                } else {
                    mode = SQLLexingMode(sqlMode: sessionMode)
                    guard mode.unmodelledModes.isEmpty else {
                        throw MCPToolError("The session sql_mode has \(mode.unmodelledModes.joined(separator: ", ")), which changes how SQL is split into statements; execute_statement is refused.")
                    }
                }
                let sql = try statement(mode)
                let transactional = readOnly && info.supportsReadOnlyTransactions
                if transactional { _ = try await session.run("START TRANSACTION READ ONLY") }
                let results = try await session.run(sql, limits: limits)
                if transactional { _ = try? await session.run("ROLLBACK") }
                return (results, sql)
            }
            await session.close()
            return results
        } catch {
            await session.cancel(graceSeconds: 1)
            await session.close()
            throw error
        }
    }

    /// The session reads the UTF-8 the app sends as UTF-8. Every connection is switched to utf8mb4 after the handshake;
    /// this re-checks it right before a guarded statement (a server can switch connections to GBK or Shift-JIS, where
    /// 0x5C can be part of a character and a string ends somewhere else than the guard saw).
    static func requireUTF8MB4(_ session: SQLSession) async throws {
        let row = try await session.run("SELECT @@character_set_client, @@character_set_connection, @@character_set_results").last?.rows.first ?? []
        let charsets = row.map { $0?.lowercased() ?? "NULL" }
        guard charsets.count == 3, charsets.allSatisfy({ $0 == "utf8mb4" }) else {
            throw MCPToolError("The session's character set is \(charsets.joined(separator: " / ")), not utf8mb4; the server could read the statement differently from the read-only check, so read-only calls are refused.")
        }
    }

    /// Read-only results carry a notice when the account can reach definer-rights routines or views of a privileged (or
    /// unverifiable) definer: the read-only check cannot see inside them, an accepted and reported risk.
    private func withDefinerNotice(_ result: JSONValue, profile: ConnectionProfile, access: MCPAccess, client: MySQLClient) async -> JSONValue {
        guard access == .readOnly, case var .object(fields) = result,
              let objects = await definerRights.objects(for: profile.id, load: { try await DefinerRights.load(run: { try await client.query($0) }) }),
              let notice = DefinerRights.notice(for: objects) else { return result }
        fields["notice"] = .string(notice)
        return .object(fields)
    }

    /// Refuses a privileged account (`AccountPrivileges`); fails closed when its privileges cannot be read.
    static func requireUnprivileged(flavor: ServerFlavor, run: @Sendable (String) async throws -> [ResultSet]) async throws {
        let privileges: AccountPrivileges
        do {
            privileges = try await AccountPrivileges.load(flavor: flavor, run: run)
        } catch let nested as AccountPrivileges.NestedRoleError {
            throw MCPToolError(nested.message)
        } catch {
            throw MCPToolError("Could not check this account's privileges (\((error as? MySQLError)?.message ?? error.localizedDescription)), so read-only AI calls are refused. Allow privileged accounts for this connection in CcinnMysql's AI settings to skip the check.")
        }
        if privileges.isPrivileged { throw MCPToolError(privileges.refusal) }
    }

    // MARK: Encoding

    static func encode(results: [ResultSet], limitRows: Int) -> [String: JSONValue] {
        guard let rowSet = results.last(where: \.hasRowSet) else {
            let affected = results.reduce(UInt64(0)) { $0 &+ $1.affectedRows }
            return ["affected_rows": .int(Int64(clamping: affected)), "row_count": 0,
                    "info": .string(results.map(\.info).filter { !$0.isEmpty }.joined(separator: "\n"))]
        }
        let columns = rowSet.columns.map { ColumnInfoLite(name: $0.name, kind: $0.type.kind) }
        let encoded = MCPResultEncoder.rows(columns: columns, rows: Array(rowSet.rows.prefix(limitRows)),
                                            truncatedByServer: rowSet.isTruncated || rowSet.rows.count > limitRows)
        return encoded.objectValue ?? [:]
    }

    static func encode(object: DatabaseObject) -> JSONValue {
        let result: [String: JSONValue] = [
            "name": .string(object.name), "kind": .string(object.kind.rawValue), "engine": JSONValue(object.engine),
            "rows_estimate": JSONValue(object.rowCount), "data_bytes": JSONValue(object.dataLength), "index_bytes": JSONValue(object.indexLength),
            "free_bytes": JSONValue(object.dataFree), "auto_increment": JSONValue(object.autoIncrement.map { String($0) }),
            "collation": JSONValue(object.collation), "comment": JSONValue(object.comment), "detail": JSONValue(object.detail),
            "status": JSONValue(object.status), "partitioned": object.isPartitioned ? .bool(true) : .null,
        ]
        return .object(result.filter { $0.value != .null })
    }

    static func encode(index: IndexInfo) -> JSONValue {
        [
            "name": .string(index.name), "unique": .bool(index.isUnique), "type": .string(index.type), "visible": .bool(index.isVisible),
            "columns": .array(index.columns.map { column in
                ["name": JSONValue(column.name), "expression": JSONValue(column.expression), "prefix_length": JSONValue(column.subPart),
                 "cardinality": JSONValue(column.cardinality), "descending": .bool(column.isDescending)]
            }),
        ]
    }

    static func encode(foreignKey: ForeignKeyInfo) -> JSONValue {
        ["name": .string(foreignKey.name), "columns": .array(foreignKey.columns.map(JSONValue.string)),
         "references": .string("\(foreignKey.referencedSchema).\(foreignKey.referencedTable)"),
         "referenced_columns": .array(foreignKey.referencedColumns.map(JSONValue.string)),
         "on_update": .string(foreignKey.onUpdate), "on_delete": .string(foreignKey.onDelete)]
    }

    static func encode(finding: TableFinding) -> JSONValue {
        ["kind": .string(finding.kind.rawValue), "severity": .string(String(describing: finding.severity)), "title": .string(finding.title),
         "detail": .string(finding.detail)]
    }

    static func encode(activity: InnoDBActivity) -> JSONValue {
        [
            "transactions": .array(activity.transactions.prefix(200).map { trx in
                ["id": .string(trx.id), "state": .string(trx.state), "age_seconds": JSONValue(trx.ageSeconds), "thread_id": JSONValue(trx.threadID.map { String($0) }),
                 "rows_locked": JSONValue(trx.rowsLocked), "rows_modified": JSONValue(trx.rowsModified), "isolation": JSONValue(trx.isolationLevel),
                 "query": JSONValue(trx.query.map { SQLRedactor.redactLiterals(String($0.prefix(2_000))) })]
            }),
            "lock_waits": .array(activity.lockWaits.prefix(200).map { wait in
                ["waiting_thread": JSONValue(wait.waitingThread.map { String($0) }),
                 "waiting_query": JSONValue(wait.waitingQuery.map { SQLRedactor.redactLiterals(String($0.prefix(2_000))) }),
                 "wait_seconds": JSONValue(wait.waitSeconds), "blocking_thread": JSONValue(wait.blockingThread.map { String($0) }),
                 "blocking_query": JSONValue(wait.blockingQuery.map { SQLRedactor.redactLiterals(String($0.prefix(2_000))) }),
                 "lock_mode": JSONValue(wait.lockMode), "lock_type": JSONValue(wait.lockType), "table": JSONValue(wait.lockedTable),
                 // The locked row's key values.
                 "index": JSONValue(wait.lockedIndex), "lock_data": JSONValue(wait.lockData.map { SQLRedactor.redactLiterals(String($0.prefix(2_000))) })]
            }),
            "latest_deadlock": JSONValue(activity.latestDeadlock.map { SQLRedactor.redactInnoDBStatus(String($0.prefix(16_000))) }),
            "unavailable": .object(activity.unavailable.mapValues(JSONValue.string)),
        ]
    }

    static func encode(digest: StatementDigest) -> JSONValue {
        ["schema": JSONValue(digest.schema), "digest_text": .string(SQLRedactor.redactLiterals(String(digest.text.prefix(4_000)))),
         "executions": .int(digest.executions), "total_seconds": .double((digest.totalSeconds * 1000).rounded() / 1000),
         "avg_ms": .double((digest.averageSeconds * 1_000_000).rounded() / 1000), "max_ms": .double((digest.maxSeconds * 1_000_000).rounded() / 1000),
         "rows_examined": .int(digest.rowsExamined), "rows_sent": .int(digest.rowsSent), "rows_affected": .int(digest.rowsAffected),
         "errors": .int(digest.errors), "no_index_used": .int(digest.noIndexUsed), "tmp_disk_tables": .int(digest.temporaryDiskTables),
         "last_seen": JSONValue(digest.lastSeen)]
    }

    /// One replication channel. The last SQL error quotes the replicated statement and duplicate values without escaping
    /// them (`Error 'Duplicate entry 'x' …' … Query: 'INSERT … ('x')'`): everything between its first and last quote is `?`.
    static func encode(channel: ReplicaChannel) -> JSONValue {
        ["name": .string(channel.name), "source": JSONValue(channel.sourceHost.map { "\($0):\(channel.sourcePort ?? 3306)" }),
         "io_running": JSONValue(channel.ioRunning), "sql_running": JSONValue(channel.sqlRunning),
         "seconds_behind_source": JSONValue(channel.secondsBehind), "last_io_error": JSONValue(channel.lastIOError),
         "last_sql_error": JSONValue(channel.lastSQLError.map { SQLRedactor.redactQuoted(String($0.prefix(4_000))) }),
         "retrieved_gtid_set": JSONValue(channel.retrievedGTIDSet), "executed_gtid_set": JSONValue(channel.executedGTIDSet),
         "state": JSONValue(channel.sqlState)]
    }

    static func encode(replication: ReplicationOverview, info: ServerInfo) -> JSONValue {
        [
            "role": .string(replication.role.rawValue),
            "channels": .array(replication.channels.map(encode(channel:))),
            "binlog_file": JSONValue(replication.binlogFile), "binlog_position": JSONValue(replication.binlogPosition),
            "gtid_mode": JSONValue(replication.gtidMode), "executed_gtid_set": JSONValue(replication.executedGTIDSet),
            "connected_replicas": .array(replication.connectedReplicas.prefix(100).map { .object($0.mapValues(JSONValue.string)) }),
            "group_members": .array(replication.groupMembers.map { member in
                ["id": .string(member.memberID), "host": JSONValue(member.host), "port": JSONValue(member.port), "state": JSONValue(member.state),
                 "role": JSONValue(member.role), "version": JSONValue(member.version)]
            }),
            "galera": .object(replication.galera.filter { ["wsrep_cluster_size", "wsrep_cluster_status", "wsrep_local_state_comment", "wsrep_ready",
                                                          "wsrep_connected", "wsrep_flow_control_paused", "wsrep_incoming_addresses",
                                                          "wsrep_provider_version"].contains($0.key) }.mapValues(JSONValue.string)),
            "read_only": .bool(info.readOnly), "unavailable": .object(replication.unavailable.mapValues(JSONValue.string)),
        ]
    }

    static func encode(plan: ExplainPlan) -> JSONValue {
        var budget = 500
        return encode(node: plan.root, depth: 0, budget: &budget)
    }

    /// One plan node and (within `budget` nodes and 32 levels) its inputs.
    static func encode(node: PlanNode, depth: Int, budget: inout Int) -> JSONValue {
        budget -= 1
        var object: [String: JSONValue] = ["operation": .string(node.title)]
        if let table = node.table { object["table"] = .string(table) }
        if let access = node.accessType { object["access_type"] = .string(access) }
        if let key = node.key { object["key"] = .string(key) }
        if !node.possibleKeys.isEmpty { object["possible_keys"] = .array(node.possibleKeys.map(JSONValue.string)) }
        if let rows = node.estimatedRows { object["estimated_rows"] = .double(rows) }
        if let rows = node.actualRows { object["actual_rows"] = .double(rows) }
        if let loops = node.loops { object["loops"] = .double(loops) }
        if let cost = node.cost { object["cost"] = .double((cost * 100).rounded() / 100) }
        if let time = node.actualTimeMilliseconds { object["actual_time_ms"] = .double((time * 1000).rounded() / 1000) }
        if let filtered = node.filtered { object["filtered_percent"] = .double(filtered) }
        if let condition = node.condition { object["condition"] = .string(String(condition.prefix(1_000))) }
        if !node.warnings.isEmpty { object["warnings"] = .array(node.warnings.sorted { $0.rawValue < $1.rawValue }.map { .string($0.title) }) }
        if depth < 32, !node.children.isEmpty {
            var inputs: [JSONValue] = []
            for child in node.children where budget > 0 {
                inputs.append(encode(node: child, depth: depth + 1, budget: &budget))
            }
            object["inputs"] = .array(inputs)
            if inputs.count < node.children.count { object["truncated"] = .bool(true) }
        }
        return .object(object)
    }
}

/// Typed access to tool arguments with clear error messages.
struct Arguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        let text: String? = switch value {
        case let .string(string): string
        case let .int(number): String(number)
        default: nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The first argument other than `sql` whose text holds a control character (Unicode Cc: NUL, C0, DEL, C1). Names reach
    /// the server as given, while the handshake and identifier quoting cannot carry NUL, so such a name could arrive as a
    /// different one than was checked.
    func controlCharacterArgument() -> String? {
        values.keys.sorted().first { key in
            guard key != "sql", case let .string(text) = values[key] else { return false }
            return text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw MCPToolError("Missing required argument `\(key)`.") }
        return value
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let value = values[key]?.intValue else { return fallback }
        return Int(clamping: min(max(value, Int64(range.lowerBound)), Int64(range.upperBound)))
    }

    func double(_ key: String) -> Double? {
        values[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }
}
