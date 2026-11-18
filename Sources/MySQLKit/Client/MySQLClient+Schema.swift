import Foundation

/// Schema browsing and table structure (design D8: `information_schema` first, `SHOW` fallbacks only on server errors).
extension MySQLClient {
    /// Runs an optional metadata statement: `nil` when the server rejects it (unknown table on older
    /// versions, missing privilege); timeouts, network errors and cancellation still propagate so that a
    /// slow server never yields silently incomplete metadata.
    func tolerant(_ sql: String) async throws -> ResultSet? {
        do {
            return try await execute(sql)
        } catch let error as MySQLError where error.kind == .server || error.kind == .authentication {
            return nil
        }
    }

    /// Like `tolerant`, but reports the server's reason.
    func attempt(_ sql: String) async throws -> Result<ResultSet, MySQLError> {
        do {
            return .success(try await execute(sql))
        } catch let error as MySQLError where error.kind == .server || error.kind == .authentication {
            return .failure(error)
        }
    }

    // MARK: Schemas

    /// User schemas first (natural order), system schemas last.
    public func schemas() async throws -> [SchemaInfo] {
        let schemas: [SchemaInfo]
        if let result = try await tolerant("SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA") {
            schemas = result.records.compactMap { record in
                record.text("SCHEMA_NAME").map { SchemaInfo(name: $0, characterSet: record.text("DEFAULT_CHARACTER_SET_NAME"), collation: record.text("DEFAULT_COLLATION_NAME")) }
            }
        } else {
            schemas = try await execute("SHOW DATABASES").rows.compactMap { $0.first ?? nil }.map { SchemaInfo(name: $0) }
        }
        return schemas.sorted(by: Self.schemaOrder)
    }

    static func schemaOrder(_ lhs: SchemaInfo, _ rhs: SchemaInfo) -> Bool {
        if lhs.isSystem != rhs.isSystem { return !lhs.isSystem }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Tables, views, sequences, routines, triggers and events of a schema. Groups the user may not read
    /// are reported in `unavailable` instead of failing the whole listing.
    public func objects(schema: String) async throws -> SchemaObjects {
        let literal = SQLText.literal(schema)
        async let tables = attempt("""
            SELECT TABLE_NAME, TABLE_TYPE, ENGINE, ROW_FORMAT, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, DATA_FREE, AUTO_INCREMENT, \
            CREATE_TIME, UPDATE_TIME, TABLE_COLLATION, CREATE_OPTIONS, TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(literal)
            """)
        async let routines = attempt("""
            SELECT ROUTINE_NAME, ROUTINE_TYPE, DTD_IDENTIFIER, IS_DETERMINISTIC, SECURITY_TYPE, DEFINER, CREATED, LAST_ALTERED, ROUTINE_COMMENT \
            FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(literal)
            """)
        async let triggers = attempt("""
            SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_TIMING, DEFINER, CREATED \
            FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(literal)
            """)
        async let events = attempt("""
            SELECT EVENT_NAME, STATUS, EVENT_TYPE, INTERVAL_VALUE, INTERVAL_FIELD, EXECUTE_AT, LAST_EXECUTED, DEFINER, CREATED, EVENT_COMMENT \
            FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(literal)
            """)
        var result = SchemaObjects()
        switch try await tables {
        case let .success(set): result.objects += set.records.compactMap { Self.tableObject($0, schema: schema) }
        case let .failure(error):
            // Fall back to SHOW FULL TABLES (names and types only).
            if let show = try await tolerant("SHOW FULL TABLES FROM \(SQLText.quoteIdentifier(schema))") {
                result.objects += show.records.compactMap { record in
                    guard let name = record.values.first ?? nil else { return nil }
                    let type = record.text("Table_type")?.uppercased() ?? "BASE TABLE"
                    return DatabaseObject(schema: schema, name: name, kind: Self.relationKind(type))
                }
            } else {
                result.unavailable["Tables"] = error.message
            }
        }
        switch try await routines {
        case let .success(set): result.objects += set.records.compactMap { Self.routineObject($0, schema: schema) }
        case let .failure(error): result.unavailable["Routines"] = error.message
        }
        switch try await triggers {
        case let .success(set): result.objects += set.records.compactMap { Self.triggerObject($0, schema: schema) }
        case let .failure(error): result.unavailable["Triggers"] = error.message
        }
        switch try await events {
        case let .success(set): result.objects += set.records.compactMap { Self.eventObject($0, schema: schema) }
        case let .failure(error): result.unavailable["Events"] = error.message
        }
        return result
    }

    static func relationKind(_ tableType: String) -> ObjectKind {
        switch tableType.uppercased() {
        case "VIEW": .view
        case "SYSTEM VIEW": .systemView
        case "SEQUENCE": .sequence
        default: .table
        }
    }

    static func tableObject(_ record: Record, schema: String) -> DatabaseObject? {
        guard let name = record.text("TABLE_NAME") else { return nil }
        var object = DatabaseObject(schema: schema, name: name, kind: relationKind(record.text("TABLE_TYPE") ?? "BASE TABLE"))
        object.engine = record.text("ENGINE")
        object.rowFormat = record.text("ROW_FORMAT")
        object.rowCount = record.int("TABLE_ROWS")
        object.dataLength = record.int("DATA_LENGTH")
        object.indexLength = record.int("INDEX_LENGTH")
        object.dataFree = record.int("DATA_FREE")
        object.autoIncrement = record.raw("AUTO_INCREMENT").flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        object.createTime = record.text("CREATE_TIME")
        object.updateTime = record.text("UPDATE_TIME")
        object.collation = record.text("TABLE_COLLATION")
        object.createOptions = record.text("CREATE_OPTIONS")
        let comment = record.text("TABLE_COMMENT")
        object.comment = object.kind == .view && comment?.uppercased() == "VIEW" ? nil : comment
        return object
    }

    static func routineObject(_ record: Record, schema: String) -> DatabaseObject? {
        guard let name = record.text("ROUTINE_NAME") else { return nil }
        let kind: ObjectKind = record.text("ROUTINE_TYPE")?.uppercased() == "FUNCTION" ? .function : .procedure
        var object = DatabaseObject(schema: schema, name: name, kind: kind)
        object.detail = kind == .function ? record.text("DTD_IDENTIFIER") : nil
        object.definer = record.text("DEFINER")
        var flags: [String] = []
        if record.text("IS_DETERMINISTIC")?.uppercased() == "YES" { flags.append("DETERMINISTIC") }
        if let security = record.text("SECURITY_TYPE") { flags.append("SQL SECURITY \(security)") }
        object.status = flags.joined(separator: " · ")
        object.createTime = record.text("CREATED")
        object.updateTime = record.text("LAST_ALTERED")
        object.comment = record.text("ROUTINE_COMMENT")
        return object
    }

    static func triggerObject(_ record: Record, schema: String) -> DatabaseObject? {
        guard let name = record.text("TRIGGER_NAME") else { return nil }
        var object = DatabaseObject(schema: schema, name: name, kind: .trigger)
        object.detail = record.text("EVENT_OBJECT_TABLE")
        object.status = [record.text("ACTION_TIMING"), record.text("EVENT_MANIPULATION")].compactMap { $0 }.joined(separator: " ")
        object.definer = record.text("DEFINER")
        object.createTime = record.text("CREATED")
        return object
    }

    static func eventObject(_ record: Record, schema: String) -> DatabaseObject? {
        guard let name = record.text("EVENT_NAME") else { return nil }
        var object = DatabaseObject(schema: schema, name: name, kind: .event)
        object.status = record.text("STATUS")
        if record.text("EVENT_TYPE")?.uppercased() == "RECURRING" {
            object.detail = "EVERY \(record.text("INTERVAL_VALUE") ?? "?") \(record.text("INTERVAL_FIELD") ?? "")"
        } else {
            object.detail = record.text("EXECUTE_AT").map { "AT \($0)" }
        }
        object.updateTime = record.text("LAST_EXECUTED")
        object.definer = record.text("DEFINER")
        object.createTime = record.text("CREATED")
        object.comment = record.text("EVENT_COMMENT")
        return object
    }

    // MARK: Columns

    public func columns(schema: String, table: String) async throws -> [ColumnInfo] {
        try await columnsByTable(schema: schema, tables: [table])[table] ?? []
    }

    /// Columns keyed by table name, for the given tables (at most 200) or a whole schema.
    public func columnsByTable(schema: String, tables: [String]? = nil) async throws -> [String: [ColumnInfo]] {
        var sql = """
            SELECT * FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(SQLText.literal(schema))
            """
        if let tables {
            guard !tables.isEmpty else { return [:] }
            sql += " AND TABLE_NAME IN (\(tables.prefix(200).map(SQLText.literal).joined(separator: ", ")))"
        }
        var columns: [String: [ColumnInfo]] = [:]
        for record in try await execute(sql).records {
            guard let table = record.text("TABLE_NAME"), let column = Self.column(record) else { continue }
            columns[table, default: []].append(column)
        }
        for key in columns.keys { columns[key]?.sort { $0.ordinal < $1.ordinal } }
        return columns
    }

    static func column(_ record: Record) -> ColumnInfo? {
        guard let name = record.text("COLUMN_NAME") else { return nil }
        let dataType = record.text("DATA_TYPE") ?? ""
        return ColumnInfo(name: name, ordinal: Int(clamping: record.int("ORDINAL_POSITION") ?? 0), dataType: dataType,
                          columnType: record.text("COLUMN_TYPE") ?? dataType, isNullable: record.text("IS_NULLABLE")?.uppercased() != "NO",
                          columnKey: record.text("COLUMN_KEY") ?? "", defaultValue: record.raw("COLUMN_DEFAULT"), extra: record.text("EXTRA") ?? "",
                          characterSet: record.text("CHARACTER_SET_NAME"), collation: record.text("COLLATION_NAME"),
                          comment: record.text("COLUMN_COMMENT"), generationExpression: record.text("GENERATION_EXPRESSION"))
    }

    // MARK: Indexes, keys, partitions

    public func indexes(schema: String, table: String) async throws -> [IndexInfo] {
        let result = try await execute("""
            SELECT * FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(SQLText.literal(schema)) AND TABLE_NAME = \(SQLText.literal(table)) \
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
            """)
        return Self.indexes(result.records)
    }

    static func indexes(_ records: [Record]) -> [IndexInfo] {
        var order: [String] = []
        var grouped: [String: [Record]] = [:]
        for record in records {
            guard let name = record.text("INDEX_NAME") else { continue }
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(record)
        }
        let indexes = order.compactMap { name -> IndexInfo? in
            guard let parts = grouped[name], let first = parts.first else { return nil }
            let columns = parts.sorted { ($0.int("SEQ_IN_INDEX") ?? 0) < ($1.int("SEQ_IN_INDEX") ?? 0) }.map { part in
                IndexColumn(name: part.text("COLUMN_NAME"), expression: part.text("EXPRESSION"), subPart: part.int("SUB_PART").map { Int(clamping: $0) },
                            cardinality: part.int("CARDINALITY"), isDescending: part.text("COLLATION")?.uppercased() == "D")
            }
            let visible = first.text("IS_VISIBLE").map { $0.uppercased() != "NO" } ?? first.text("IGNORED").map { $0.uppercased() != "YES" } ?? true
            return IndexInfo(name: name, isUnique: first.int("NON_UNIQUE") == 0, type: first.text("INDEX_TYPE") ?? "BTREE", columns: columns,
                             isVisible: visible, comment: first.text("INDEX_COMMENT"))
        }
        return indexes.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Outgoing foreign keys of a table (`referencing: false`) or keys of other tables pointing at it.
    public func foreignKeys(schema: String, table: String, referencing: Bool = false) async throws -> [ForeignKeyInfo] {
        let filter = referencing
            ? "k.REFERENCED_TABLE_SCHEMA = \(SQLText.literal(schema)) AND k.REFERENCED_TABLE_NAME = \(SQLText.literal(table))"
            : "k.TABLE_SCHEMA = \(SQLText.literal(schema)) AND k.TABLE_NAME = \(SQLText.literal(table)) AND k.REFERENCED_TABLE_NAME IS NOT NULL"
        let result = try await execute("""
            SELECT k.CONSTRAINT_NAME, k.TABLE_SCHEMA, k.TABLE_NAME, k.COLUMN_NAME, k.ORDINAL_POSITION, k.REFERENCED_TABLE_SCHEMA, \
            k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE \
            FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r \
            ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME \
            WHERE \(filter) ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        return Self.foreignKeys(result.records, qualifyWithTable: referencing)
    }

    static func foreignKeys(_ records: [Record], qualifyWithTable: Bool) -> [ForeignKeyInfo] {
        var order: [String] = []
        var grouped: [String: [Record]] = [:]
        for record in records {
            guard let name = record.text("CONSTRAINT_NAME") else { continue }
            let key = qualifyWithTable ? "\(record.text("TABLE_SCHEMA") ?? "").\(record.text("TABLE_NAME") ?? "").\(name)" : name
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(record)
        }
        return order.compactMap { key in
            guard let parts = grouped[key], let first = parts.first, let name = first.text("CONSTRAINT_NAME") else { return nil }
            let displayName = qualifyWithTable ? "\(first.text("TABLE_NAME") ?? "?").\(name)" : name
            return ForeignKeyInfo(name: displayName, columns: parts.compactMap { $0.text("COLUMN_NAME") },
                                  referencedSchema: first.text("REFERENCED_TABLE_SCHEMA") ?? "", referencedTable: first.text("REFERENCED_TABLE_NAME") ?? "",
                                  referencedColumns: parts.compactMap { $0.text("REFERENCED_COLUMN_NAME") },
                                  onUpdate: first.text("UPDATE_RULE") ?? "RESTRICT", onDelete: first.text("DELETE_RULE") ?? "RESTRICT")
        }
    }

    // MARK: Whole-schema metadata (one query each, for knowledge builds)

    /// Indexes of every table of a schema, keyed by table name.
    public func indexesByTable(schema: String) async throws -> [String: [IndexInfo]] {
        let result = try await execute("""
            SELECT * FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(SQLText.literal(schema)) \
            ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
            """)
        return Dictionary(grouping: result.records) { $0.text("TABLE_NAME") ?? "" }
            .filter { !$0.key.isEmpty }
            .mapValues { Self.indexes($0) }
    }

    /// Outgoing foreign keys of every table of a schema, keyed by table name.
    public func foreignKeysByTable(schema: String) async throws -> [String: [ForeignKeyInfo]] {
        let result = try await execute("""
            SELECT k.CONSTRAINT_NAME, k.TABLE_SCHEMA, k.TABLE_NAME, k.COLUMN_NAME, k.ORDINAL_POSITION, k.REFERENCED_TABLE_SCHEMA, \
            k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE \
            FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r \
            ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME \
            WHERE k.TABLE_SCHEMA = \(SQLText.literal(schema)) AND k.REFERENCED_TABLE_NAME IS NOT NULL \
            ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        return Dictionary(grouping: result.records) { $0.text("TABLE_NAME") ?? "" }
            .filter { !$0.key.isEmpty }
            .mapValues { Self.foreignKeys($0, qualifyWithTable: false) }
    }

    /// SQL stored in a schema: view, routine, trigger and event definitions the account can read. Groups the server
    /// refuses are reported in `unavailable`; definitions hidden from the account (empty or NULL) are counted there too.
    public func storedDefinitions(schema: String) async throws -> (definitions: [StoredDefinition], unavailable: [String: String]) {
        let literal = SQLText.literal(schema)
        let queries: [(StoredDefinition.Kind, String, String, String)] = [
            (.view, "TABLE_NAME", "VIEW_DEFINITION", "SELECT TABLE_NAME, VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(literal)"),
            (.routine, "ROUTINE_NAME", "ROUTINE_DEFINITION",
             "SELECT ROUTINE_NAME, ROUTINE_DEFINITION FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(literal)"),
            (.trigger, "TRIGGER_NAME", "ACTION_STATEMENT",
             "SELECT TRIGGER_NAME, ACTION_STATEMENT FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(literal)"),
            (.event, "EVENT_NAME", "EVENT_DEFINITION", "SELECT EVENT_NAME, EVENT_DEFINITION FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(literal)"),
        ]
        var definitions: [StoredDefinition] = []
        var unavailable: [String: String] = [:]
        for (kind, nameColumn, sqlColumn, sql) in queries {
            switch try await attempt(sql) {
            case let .success(result):
                var hidden = 0
                for record in result.records {
                    guard let name = record.text(nameColumn) else { continue }
                    guard let body = record.raw(sqlColumn), !body.isEmpty else {
                        hidden += 1
                        continue
                    }
                    definitions.append(StoredDefinition(kind: kind, name: name, sql: body))
                }
                if hidden > 0 { unavailable[kind.rawValue] = "\(hidden) definition(s) are not visible to this account" }
            case let .failure(error):
                unavailable[kind.rawValue] = error.message
            }
        }
        return (definitions, unavailable)
    }

    public func partitions(schema: String, table: String) async throws -> [PartitionInfo] {
        let result = try await execute("""
            SELECT PARTITION_NAME, SUBPARTITION_NAME, PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION, PARTITION_METHOD, \
            SUBPARTITION_METHOD, PARTITION_EXPRESSION, PARTITION_DESCRIPTION, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, PARTITION_COMMENT \
            FROM information_schema.PARTITIONS WHERE TABLE_SCHEMA = \(SQLText.literal(schema)) AND TABLE_NAME = \(SQLText.literal(table)) \
            AND PARTITION_NAME IS NOT NULL ORDER BY PARTITION_ORDINAL_POSITION, SUBPARTITION_ORDINAL_POSITION
            """)
        return result.records.enumerated().compactMap { offset, record in
            guard let name = record.text("PARTITION_NAME") else { return nil }
            return PartitionInfo(name: name, subpartition: record.text("SUBPARTITION_NAME"),
                                 ordinal: Int(clamping: record.int("PARTITION_ORDINAL_POSITION") ?? Int64(offset + 1)),
                                 method: record.text("PARTITION_METHOD"), expression: record.text("PARTITION_EXPRESSION"),
                                 bound: record.text("PARTITION_DESCRIPTION"), rowCount: record.int("TABLE_ROWS"), dataLength: record.int("DATA_LENGTH"),
                                 indexLength: record.int("INDEX_LENGTH"), comment: record.text("PARTITION_COMMENT"))
        }
    }

    // MARK: DDL and preview

    public func ddl(of object: DatabaseObject) async throws -> String {
        let name = object.qualifiedName
        let sql: String = switch object.kind {
        case .table, .systemView: "SHOW CREATE TABLE \(name)"
        case .sequence: "SHOW CREATE SEQUENCE \(name)"
        case .view: "SHOW CREATE VIEW \(name)"
        case .procedure: "SHOW CREATE PROCEDURE \(name)"
        case .function: "SHOW CREATE FUNCTION \(name)"
        case .trigger: "SHOW CREATE TRIGGER \(name)"
        case .event: "SHOW CREATE EVENT \(name)"
        }
        let result = try await execute(sql)
        return Self.createStatement(result) ?? "-- \(object.kind.displayName) definition is not visible to this account"
    }

    /// The `Create …` column of a `SHOW CREATE` result (`SQL Original Statement` for triggers).
    static func createStatement(_ result: ResultSet) -> String? {
        guard let record = result.first else { return nil }
        let names = result.columns.map { $0.name.lowercased() }
        if let index = names.firstIndex(where: { $0.hasPrefix("create ") || $0 == "sql original statement" }), index < record.values.count {
            return record.values[index]
        }
        return record.values.count > 1 ? record.values[1] : record.values.first ?? nil
    }

    /// First rows of a table or view (bounded).
    public func preview(_ object: DatabaseObject, limit: Int = 200) async throws -> ResultSet {
        let rows = max(1, min(limit, 10_000))
        let results = try await query("SELECT * FROM \(object.qualifiedName) LIMIT \(rows)", limits: RowLimits(maxRows: rows, maxBytes: 64 * 1024 * 1024, drainRows: 0),
                                      timeout: Self.metadataTimeout)
        guard let last = results.last else { throw MySQLError(.protocolViolation, "The server returned no result") }
        return last
    }

    /// Columns, indexes, foreign keys (both directions), partitions and DDL of a table, loaded concurrently.
    public func tableDetail(_ object: DatabaseObject) async throws -> TableDetail {
        async let columns = capture { try await self.columns(schema: object.schema, table: object.name) }
        async let indexes = capture { try await self.indexes(schema: object.schema, table: object.name) }
        async let outgoing = capture { try await self.foreignKeys(schema: object.schema, table: object.name) }
        async let incoming = capture { try await self.foreignKeys(schema: object.schema, table: object.name, referencing: true) }
        async let partitions = capture { object.isPartitioned ? try await self.partitions(schema: object.schema, table: object.name) : [] }
        async let ddl = capture { try await self.ddl(of: object) }
        var detail = TableDetail(object: object)
        detail.columns = try Self.unwrap(await columns, section: "Columns", into: &detail.unavailable) ?? []
        detail.indexes = try Self.unwrap(await indexes, section: "Indexes", into: &detail.unavailable) ?? []
        detail.foreignKeys = try Self.unwrap(await outgoing, section: "Foreign keys", into: &detail.unavailable) ?? []
        detail.referencedBy = try Self.unwrap(await incoming, section: "Referenced by", into: &detail.unavailable) ?? []
        detail.partitions = try Self.unwrap(await partitions, section: "Partitions", into: &detail.unavailable) ?? []
        detail.ddl = try Self.unwrap(await ddl, section: "DDL", into: &detail.unavailable)
        return detail
    }

    /// Runs `body`, turning server errors into `.failure` so one section cannot fail a whole page.
    func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, MySQLError> {
        do {
            return .success(try await body())
        } catch let error as MySQLError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(MySQLError.cancelled())
        } catch {
            return .failure(MySQLError(.network, error.localizedDescription))
        }
    }

    /// Server errors become an "unavailable" note; anything else (timeouts, cancellation) propagates.
    static func unwrap<T>(_ result: Result<T, MySQLError>, section: String, into unavailable: inout [String: String]) throws -> T? {
        switch result {
        case let .success(value): return value
        case let .failure(error) where error.kind == .server || error.kind == .authentication:
            unavailable[section] = error.message
            return nil
        case let .failure(error): throw error
        }
    }
}
