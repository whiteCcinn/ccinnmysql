import Foundation
import MySQLKit

/// Routes each call to the provider that defines the tool.
public struct CompositeMCPToolProvider: MCPToolProvider {
    public let providers: [any MCPToolProvider]

    public init(_ providers: [any MCPToolProvider]) {
        self.providers = providers
    }

    public func tools() async -> [MCPTool] {
        var all: [MCPTool] = []
        for provider in providers { all += await provider.tools() }
        return all
    }

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        for provider in providers {
            if await provider.tools().contains(where: { $0.name == name }) {
                return await provider.call(name: name, arguments: arguments)
            }
        }
        return .failure("Unknown tool “\(name)”.")
    }
}

/// The knowledge base tools of the MCP server (design D11). Only `knowledge_build` contacts the server; every other
/// tool reads the local knowledge base. Access follows the connection's AI setting, like the MySQL tools.
public struct KnowledgeMCPTools: MCPToolProvider {
    public let resolver: MCPProfileResolver
    public let registry: MCPClientRegistry
    public let store: KnowledgeStore
    public let audit: MCPAuditLog?
    public let scanner: CodeScanner
    /// Serialized result budget in bytes, like the MySQL tools; every result stays within it.
    public let payloadBudget: Int

    public init(resolver: MCPProfileResolver, registry: MCPClientRegistry, store: KnowledgeStore, audit: MCPAuditLog?,
                scanner: CodeScanner = CodeScanner(), payloadBudget: Int = 240 * 1024) {
        self.resolver = resolver
        self.registry = registry
        self.store = store
        self.audit = audit
        self.scanner = scanner
        self.payloadBudget = max(4_096, payloadBudget)
    }

    // MARK: Definitions

    static let databaseProperty: JSONValue = ["type": "string", "description": "Database (schema) name."]
    static let tablesProperty: JSONValue = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 30]
    static let columnsProperty: JSONValue = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 16]
    static let evidenceProperty: JSONValue = [
        "type": "array", "maxItems": 5,
        "description": "Why it is true: a file in a linked project (`path`, relative or absolute, with `line`), or the query you ran to verify it (`kind: query`, `detail`; its values are replaced by `?`, never store result rows).",
        "items": ["type": "object", "additionalProperties": false, "properties": [
            "kind": ["type": "string", "enum": ["code", "query", "note"]],
            "project": ["type": "string", "description": "Linked project name (optional when the path identifies it)."],
            "path": ["type": "string"], "line": ["type": "integer", "minimum": 1], "detail": ["type": "string"],
        ]],
    ]

    public func tools() async -> [MCPTool] {
        [
            MCPTool(name: "knowledge_status", title: "Knowledge base status",
                    description: "Lists the local knowledge bases of a connection, or details one database: when it was built, tables, relationships by source (declared, view, routine, code, naming, ai, user), notes, and the code projects the user linked, with whether they changed since the scan. Call it first when working with a database: if a knowledge base exists, use knowledge_search, knowledge_context and knowledge_join_path instead of describing tables one by one. Offline.",
                    inputSchema: MySQLMCPTools.schema(["database": Self.databaseProperty]), readOnly: true),
            MCPTool(name: "knowledge_build", title: "Build knowledge base",
                    description: "Builds or refreshes the local knowledge base of a database from metadata only (no rows): tables, columns, keys, declared foreign keys, relationships suggested by naming conventions, joins found in view, routine, trigger and event definitions, and joins and table uses found in the code projects the user linked in CcinnMysql (with file:line). Keeps notes and verdicts and reports schema changes since the last build. `scan_code: false` refreshes the schema only.",
                    inputSchema: MySQLMCPTools.schema(["database": Self.databaseProperty,
                                                       "scan_code": ["type": "boolean", "description": "Also scan the linked code projects (default true)."]],
                                                      required: ["database"]),
                    readOnly: false, idempotent: true),
            MCPTool(name: "knowledge_search", title: "Search knowledge base",
                    description: "Finds the tables relevant to a question by table and column names, comments, notes, value meanings and glossary terms (English or CJK words). Returns ranked tables with what matched, and matching glossary terms with their read-only SQL recipes. Offline.",
                    inputSchema: MySQLMCPTools.schema(["database": Self.databaseProperty,
                                                       "query": ["type": "string", "description": "Words describing what you look for, e.g. `advertiser revenue by day` or `广告主 收入`."],
                                                       "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Tables to return (default 10)."]],
                                                      required: ["database", "query"]), readOnly: true),
            MCPTool(name: "knowledge_context", title: "Knowledge of tables",
                    description: "What is known about up to 30 tables: columns with types, comments, notes and value meanings; keys; relationships in both directions with join conditions, sources, confidence and evidence; where the linked code uses them; and their neighbours. Offline. Use it before writing SQL against unfamiliar tables.",
                    inputSchema: MySQLMCPTools.schema(["database": Self.databaseProperty, "tables": Self.tablesProperty,
                                                       "depth": ["type": "integer", "minimum": 0, "maximum": 2, "description": "Neighbour levels to list (default 1)."],
                                                       "include_columns": ["type": "boolean", "description": "Columns of the tables (default true)."],
                                                       "include_code": ["type": "boolean", "description": "Code references (default true)."]],
                                                      required: ["database", "tables"]), readOnly: true),
            MCPTool(name: "knowledge_join_path", title: "Join path",
                    description: "How to join two tables: the most reliable relationship paths with ready-to-use `FROM … JOIN … ON` SQL and the confidence and sources of each step. Rejected relationships are never used; prefer paths of declared or confirmed relationships. Offline.",
                    inputSchema: MySQLMCPTools.schema(["database": Self.databaseProperty,
                                                       "from": ["type": "string", "description": "Table to start from."],
                                                       "to": ["type": "string", "description": "Table to reach."],
                                                       "max_paths": ["type": "integer", "minimum": 1, "maximum": 5, "description": "Paths to return (default 3)."],
                                                       "max_hops": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Longest path (default 6)."]],
                                                      required: ["database", "from", "to"]), readOnly: true),
            MCPTool(name: "knowledge_erd", title: "Entity relationship diagram",
                    description: "Mermaid `erDiagram` of the given tables and their neighbourhood (or of the most connected tables): keys, foreign keys and relationships, solid when declared or confirmed and dotted when inferred. At most 60 tables. Show it to the user or put it in documents. Offline.",
                    inputSchema: MySQLMCPTools.schema(["database": Self.databaseProperty,
                                                       "tables": ["type": "array", "items": ["type": "string"], "maxItems": 30,
                                                                  "description": "Focus tables (default: the most connected tables)."],
                                                       "depth": ["type": "integer", "minimum": 0, "maximum": 3, "description": "Neighbour levels around the focus (default 1)."],
                                                       "columns": ["type": "string", "enum": ["keys", "all"], "description": "Key columns only (default) or all."]],
                                                      required: ["database"]), readOnly: true),
            MCPTool(name: "knowledge_annotate", title: "Record knowledge",
                    description: "Records what you verified so later sessions reuse it: table notes (purpose), column notes with value meanings (e.g. status 3 = paused), glossary terms with an optional read-only SQL recipe, relationships the knowledge base lacks (evidence required: a file in a linked project with its line, or the query that verified it), and verdicts confirming or rejecting inferred relationships (a reason is required to reject). Saved locally, never on the server. Notes written by the user cannot be changed by an AI. An empty `summary` or `definition` deletes your own note or term.",
                    inputSchema: MySQLMCPTools.schema([
                        "database": Self.databaseProperty,
                        "table_notes": ["type": "array", "maxItems": 100, "items": ["type": "object", "additionalProperties": false,
                                                                                     "required": ["table", "summary"],
                                                                                     "properties": ["table": ["type": "string"], "summary": ["type": "string"],
                                                                                                    "evidence": Self.evidenceProperty]]],
                        "column_notes": ["type": "array", "maxItems": 100, "items": ["type": "object", "additionalProperties": false,
                                                                                      "required": ["table", "column"],
                                                                                      "properties": ["table": ["type": "string"], "column": ["type": "string"],
                                                                                                     "note": ["type": "string"],
                                                                                                     "values": ["type": "object", "additionalProperties": ["type": "string"],
                                                                                                                "description": "Stored value → meaning."],
                                                                                                     "evidence": Self.evidenceProperty]]],
                        "relationships": ["type": "array", "maxItems": 100, "items": ["type": "object", "additionalProperties": false,
                                                                                       "required": ["from_table", "from_columns", "to_table", "to_columns"],
                                                                                       "properties": ["from_table": ["type": "string"], "from_columns": Self.columnsProperty,
                                                                                                      "to_table": ["type": "string"], "to_columns": Self.columnsProperty,
                                                                                                      "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                                                                                                      "note": ["type": "string"], "evidence": Self.evidenceProperty,
                                                                                                      "remove": ["type": "boolean", "description": "Delete a relationship you added."]]]],
                        "verdicts": ["type": "array", "maxItems": 100, "items": ["type": "object", "additionalProperties": false,
                                                                                  "required": ["from_table", "from_columns", "to_table", "to_columns", "verdict"],
                                                                                  "properties": ["from_table": ["type": "string"], "from_columns": Self.columnsProperty,
                                                                                                 "to_table": ["type": "string"], "to_columns": Self.columnsProperty,
                                                                                                 "verdict": ["type": "string", "enum": ["confirmed", "rejected", "cleared"]],
                                                                                                 "reason": ["type": "string"]]]],
                        "glossary": ["type": "array", "maxItems": 100, "items": ["type": "object", "additionalProperties": false,
                                                                                  "required": ["term", "definition"],
                                                                                  "properties": ["term": ["type": "string"], "definition": ["type": "string"],
                                                                                                 "tables": ["type": "array", "items": ["type": "string"]],
                                                                                                 "sql": ["type": "string", "description": "One read-only statement computing the term."]]]],
                    ], required: ["database"]),
                    readOnly: false, idempotent: true),
        ]
    }

    // MARK: Calls

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let context = MySQLMCPTools.CallContext()
        let result: MCPToolResult
        do {
            try await validate(name: name, arguments: arguments)
            let payload = try await dispatch(name, Arguments(arguments), context)
            // Backstop: the tools bound their own output, but no result ever exceeds the budget.
            guard payload.serialized().utf8.count <= payloadBudget else {
                throw MCPToolError("The result is larger than \(payloadBudget / 1024) KB; ask for less (fewer tables, a smaller depth, or key columns only).")
            }
            result = .success(payload)
        } catch let error as KnowledgeError {
            result = .failure(error.message)
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
        await audit?.record(tool: name, connection: context.connection, statement: nil, durationMilliseconds: milliseconds, rows: context.rows,
                            error: result.isError ? result.payload.stringValue : nil)
        return result
    }

    private func validate(name: String, arguments: [String: JSONValue]) async throws {
        guard let tool = await tools().first(where: { $0.name == name }) else { throw MCPToolError("Unknown tool “\(name)”.") }
        let allowed = Set(tool.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let unknown = arguments.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw MCPToolError("Unknown argument\(unknown.count > 1 ? "s" : "") \(unknown.map { "`\($0)`" }.joined(separator: ", ")) for \(name); allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
    }

    private func dispatch(_ name: String, _ args: Arguments, _ context: MySQLMCPTools.CallContext) async throws -> JSONValue {
        if let key = args.controlCharacterArgument() {
            throw MCPToolError("`\(key)` contains a control character.")
        }
        let resolved = try resolver.resolve(args.string("connection"))
        context.connection = resolved.profile.displayName
        switch name {
        case "knowledge_status":
            return try status(resolved.profile, database: args.string("database"))
        case "knowledge_build":
            return try await build(resolved, args, context)
        case "knowledge_annotate":
            let key = try knowledgeKey(resolved.profile, database: try args.required("database"))
            let annotation = try Self.annotation(args)
            let applied = try await store.update(key, create: false) { knowledge in
                try KnowledgeAnnotator.apply(annotation, author: .ai, to: &knowledge)
            }
            context.rows = applied.count
            return ["database": .string(key.database), "applied": .array(applied.map(JSONValue.string))]
        default:
            let key = try knowledgeKey(resolved.profile, database: try args.required("database"))
            guard let (knowledge, graph) = try store.loadWithGraph(key), knowledge.snapshot != nil else { throw notBuilt(key, resolved.profile) }
            switch name {
            case "knowledge_search": return try search(graph, args)
            case "knowledge_context": return try tableContext(knowledge, graph, args)
            case "knowledge_join_path": return try joinPath(graph, args)
            case "knowledge_erd": return erd(graph, args)
            default: throw MCPToolError("Unknown tool “\(name)”.")
            }
        }
    }

    // MARK: Knowledge bases

    /// The knowledge base of `database` (exact name, else the only case-insensitive match).
    func knowledgeKey(_ profile: ConnectionProfile, database: String) throws -> KnowledgeKey {
        let exact = KnowledgeKey(connectionID: profile.id, database: database)
        if FileManager.default.fileExists(atPath: store.fileURL(for: exact).path) { return exact }
        let names = store.list(connectionID: profile.id).compactMap(\.database)
        let matches = names.filter { $0.caseInsensitiveCompare(database) == .orderedSame }
        if matches.count == 1 { return KnowledgeKey(connectionID: profile.id, database: matches[0]) }
        throw notBuilt(exact, profile, existing: names)
    }

    private func notBuilt(_ key: KnowledgeKey, _ profile: ConnectionProfile, existing: [String]? = nil) -> KnowledgeError {
        let names = existing ?? store.list(connectionID: profile.id).compactMap(\.database)
        let others = names.isEmpty ? "" : " Knowledge bases of this connection: \(names.joined(separator: ", "))."
        return KnowledgeError("No knowledge base for database “\(key.database)” on connection “\(profile.displayName)” yet; call knowledge_build with database “\(key.database)” to create it.\(others)")
    }

    private func status(_ profile: ConnectionProfile, database: String?) throws -> JSONValue {
        guard let database else {
            let listed = store.list(connectionID: profile.id)
            let entries: [JSONValue] = listed.map { listing in
                guard let knowledge = listing.knowledge else {
                    return ["database": JSONValue(listing.database), "error": JSONValue(listing.error)]
                }
                return [
                    "database": .string(knowledge.database), "built_at": JSONValue(knowledge.build.map { Self.timestamp($0.builtAt) }),
                    "tables": .int(Int64(knowledge.snapshot?.tables.count ?? 0)), "relationships": .int(Int64(knowledge.computed.count)),
                    "notes": .int(Int64(knowledge.notes.count)), "projects": .array(knowledge.projects.map { .string($0.name) }),
                ]
            }
            var result: [String: JSONValue] = ["connection": .string(profile.displayName), "knowledge_bases": .array(entries)]
            result["hint"] = .string(entries.isEmpty
                ? "No knowledge base yet: call knowledge_build with a database. In CcinnMysql the user can link code folders to a database (Knowledge tab) so builds also learn joins from code."
                : "Pass `database` for details. Use knowledge_search, knowledge_context and knowledge_join_path before exploring tables one by one.")
            return .object(result)
        }
        let key = try knowledgeKey(profile, database: database)
        guard let (knowledge, graph) = try store.loadWithGraph(key) else { throw notBuilt(key, profile) }
        var bySource: [String: JSONValue] = [:]
        for edge in graph.edges {
            for source in edge.relationship.sources { bySource[source.rawValue] = .int((bySource[source.rawValue]?.intValue ?? 0) + 1) }
        }
        let scans = Dictionary(knowledge.build?.projects.map { ($0.projectID, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        var stale = false
        let projects: [JSONValue] = knowledge.projects.map { project in
            let scan = scans[project.id]
            let current = GitHead.commit(for: URL(fileURLWithPath: project.path))
            let changed = scan.map { $0.commit != current } ?? true
            stale = stale || changed
            return ["name": .string(project.name), "path": .string(project.path), "scanned_commit": JSONValue(scan?.commit),
                    "current_commit": JSONValue(current), "changed_since_scan": .bool(changed), "files": JSONValue(scan?.files),
                    "truncated": JSONValue(scan?.truncated), "error": JSONValue(scan?.error)]
        }
        var result: [String: JSONValue] = [
            "connection": .string(profile.displayName), "database": .string(knowledge.database),
            "built": .bool(knowledge.snapshot != nil), "projects": .array(projects),
        ]
        if let snapshot = knowledge.snapshot, let build = knowledge.build {
            let age = Date().timeIntervalSince(build.builtAt) / 3600
            stale = stale || age > 24 * 7
            result["built_at"] = .string(Self.timestamp(build.builtAt))
            result["age_hours"] = .double((age * 10).rounded() / 10)
            result["server_version"] = JSONValue(snapshot.serverVersion)
            result["tables"] = .int(Int64(snapshot.tables.filter { $0.kind == .table }.count))
            result["views"] = .int(Int64(snapshot.tables.filter { $0.kind == .view }.count))
            result["relationships"] = .int(Int64(graph.edges.count))
            result["relationships_by_source"] = .object(bySource)
            result["rejected_relationships"] = .int(Int64(graph.rejected.count))
            result["code_scanned"] = .bool(build.codeScanned)
            if let changes = build.changes, !changes.isEmpty {
                result["last_changes"] = ["added": .array(changes.added.prefix(50).map(JSONValue.string)),
                                          "removed": .array(changes.removed.prefix(50).map(JSONValue.string)),
                                          "changed": .array(changes.changed.prefix(50).map(JSONValue.string))]
            }
            if !build.warnings.isEmpty { result["warnings"] = .array(build.warnings.prefix(20).map(JSONValue.string)) }
        }
        let notes = knowledge.notes
        result["notes"] = ["tables": .int(Int64(notes.tables.count)), "columns": .int(Int64(notes.columns.values.reduce(0) { $0 + $1.count })),
                           "glossary": .int(Int64(notes.glossary.count)), "relationships": .int(Int64(notes.relationships.count)),
                           "verdicts": .int(Int64(notes.verdicts.count))]
        let orphans = knowledge.orphanedNotes
        if !orphans.isEmpty { result["orphaned_notes"] = .array(orphans.prefix(50).map(JSONValue.string)) }
        result["hint"] = .string(knowledge.snapshot == nil
            ? "Not built yet: call knowledge_build."
            : stale ? "The schema snapshot or a linked project may be outdated; call knowledge_build to refresh it."
            : "Up to date. Use knowledge_search to find tables, knowledge_context for details, knowledge_join_path for joins.")
        return .object(result)
    }

    private func build(_ resolved: MCPProfileResolver.Resolved, _ args: Arguments, _ context: MySQLMCPTools.CallContext) async throws -> JSONValue {
        let database = try args.required("database")
        let client = try await registry.client(for: resolved.profile)
        // The same account check as the other metadata tools (read-only access with a privileged account is refused).
        if resolved.access == .readOnly, !resolved.profile.aiAllowsPrivilegedAccount {
            try await MySQLMCPTools.requireUnprivileged(flavor: client.serverInfo.flavor) { try await client.query($0) }
        }
        let key = KnowledgeKey(connectionID: resolved.profile.id, database: database)
        let summary = try await KnowledgeBuilder(store: store, scanner: scanner)
            .build(key, source: MySQLKnowledgeSource(client: client), scanCode: args.bool("scan_code") ?? true)
        context.rows = summary.tables + summary.views
        var result: [String: JSONValue] = [
            "database": .string(database), "tables": .int(Int64(summary.tables)), "views": .int(Int64(summary.views)),
            "relationships": .int(Int64(summary.totalRelationships)),
            "relationships_by_source": .object(Dictionary(uniqueKeysWithValues: summary.relationships.map { ($0.key.rawValue, JSONValue.int(Int64($0.value))) })),
            "projects": .array(summary.projects.map { scan in
                ["name": .string(scan.project), "files": .int(Int64(scan.files)), "commit": JSONValue(scan.commit), "truncated": .bool(scan.truncated),
                 "error": JSONValue(scan.error)]
            }),
            "seconds": .double((summary.durationSeconds * 100).rounded() / 100),
        ]
        if let changes = summary.changes {
            result["changes"] = ["added": .array(changes.added.prefix(100).map(JSONValue.string)),
                                 "removed": .array(changes.removed.prefix(100).map(JSONValue.string)),
                                 "changed": .array(changes.changed.prefix(100).map(JSONValue.string))]
        }
        if !summary.orphanedNotes.isEmpty { result["orphaned_notes"] = .array(summary.orphanedNotes.prefix(50).map(JSONValue.string)) }
        if !summary.warnings.isEmpty { result["warnings"] = .array(summary.warnings.prefix(20).map(JSONValue.string)) }
        if summary.projects.isEmpty {
            result["hint"] = "No code project is linked to this database. The user can link folders in CcinnMysql (Knowledge tab) so builds also learn joins and table uses from code."
        }
        return .object(result)
    }

    // MARK: Queries

    private func search(_ graph: KnowledgeGraph, _ args: Arguments) throws -> JSONValue {
        let query = try args.required("query")
        let result = graph.search(query, limit: args.int("limit", default: 10, range: 1...50))
        var payload: [String: JSONValue] = [
            "database": .string(graph.database), "query": .string(query),
            "tables": .array(result.tables.map { hit in
                let table = graph.tables[hit.table]
                return ["table": .string(hit.table), "kind": JSONValue(table?.kind.rawValue), "score": .int(Int64(hit.score)),
                        "matched": .array(hit.reasons.map(JSONValue.string)), "rows_estimate": JSONValue(table?.rowsEstimate),
                        "purpose": JSONValue(Self.purpose(hit.table, graph)), "relationships": .int(Int64(graph.edges(of: hit.table).count))]
            }),
            "glossary": .array(result.glossary.map(Self.encode(term:))),
        ]
        if result.tables.isEmpty && result.glossary.isEmpty {
            payload["hint"] = "Nothing matched. Try other words (names, comments or business terms), or knowledge_status / list_tables."
        }
        return .object(payload)
    }

    func tableContext(_ knowledge: KnowledgeBase, _ graph: KnowledgeGraph, _ args: Arguments) throws -> JSONValue {
        let requested = try args.strings("tables")
        guard !requested.isEmpty else { throw MCPToolError("Pass at least one table in `tables`.") }
        guard requested.count <= 30 else { throw MCPToolError("At most 30 tables per call.") }
        let depth = args.int("depth", default: 1, range: 0...2)
        let includeColumns = args.bool("include_columns") ?? true
        let includeCode = args.bool("include_code") ?? true
        var focus: [String] = []
        var unknown: [JSONValue] = []
        for name in requested {
            if let table = graph.resolve(name) {
                if !focus.contains(table) { focus.append(table) }
            } else {
                unknown.append(["name": .string(name), "similar": .array(graph.similar(to: name).map(JSONValue.string))])
            }
        }
        var tables: [JSONValue] = []
        var omitted: [JSONValue] = []
        let around = graph.neighbourhood(of: focus, depth: depth, limit: focus.count + 40).filter { !focus.contains($0) }
        let neighbours: [JSONValue] = around.map { ["table": .string($0), "purpose": JSONValue(Self.purpose($0, graph))] }
        // What every answer carries besides the tables, plus room for the notice and the omitted list.
        var budget = payloadBudget - JSONValue.array(neighbours).serialized().utf8.count - JSONValue.array(unknown).serialized().utf8.count - 2_048
        var aiNotes = false
        for name in focus {
            guard let context = graph.context(for: name) else { continue }
            aiNotes = aiNotes || context.note?.author == .ai || context.columnNotes.values.contains { $0.author == .ai }
                || context.edges.contains { $0.relationship.sources.contains(.ai) }
            var full = Self.encode(context: context, graph: graph, columns: includeColumns, code: includeCode)
            var size = full.serialized().utf8.count
            if size > budget {
                full = Self.encode(context: context, graph: graph, columns: false, code: false)
                if case var .object(fields) = full { fields["detail_omitted"] = "Output limit reached: ask for fewer tables at a time."; full = .object(fields) }
                size = full.serialized().utf8.count
            }
            // Too large even in short form: say so and keep going (a later, smaller table may still fit).
            guard size + 64 <= budget else {
                omitted.append(.string(name))
                budget -= name.utf8.count + 4
                continue
            }
            budget -= size
            tables.append(full)
        }
        var payload: [String: JSONValue] = [
            "database": .string(knowledge.database), "tables": .array(tables), "neighbours": .array(neighbours),
        ]
        if !unknown.isEmpty { payload["unknown"] = .array(unknown) }
        if !omitted.isEmpty {
            payload["omitted"] = .array(omitted)
            payload["omitted_reason"] = "These tables did not fit in one answer; ask for them alone, or with include_columns: false."
        }
        if aiNotes {
            payload["notice"] = "Notes, value meanings and relationships marked author `ai` were written by earlier AI sessions: treat them as hints and verify before relying on them."
        }
        return .object(payload)
    }

    private func joinPath(_ graph: KnowledgeGraph, _ args: Arguments) throws -> JSONValue {
        func table(_ key: String) throws -> String {
            let name = try args.required(key)
            guard let table = graph.resolve(name) else {
                let similar = graph.similar(to: name)
                throw MCPToolError("No table “\(name)” in the knowledge base of \(graph.database).\(similar.isEmpty ? "" : " Similar: \(similar.joined(separator: ", ")).")")
            }
            return table
        }
        let from = try table("from")
        let to = try table("to")
        let maxHops = args.int("max_hops", default: 6, range: 1...8)
        let paths = graph.joinPaths(from: from, to: to, maxPaths: args.int("max_paths", default: 3, range: 1...5), maxHops: maxHops)
        var payload: [String: JSONValue] = [
            "from": .string(from), "to": .string(to),
            "paths": .array(paths.map { path in
                ["tables": .array(path.tables.map(JSONValue.string)), "sql": .string(path.sql),
                 "min_confidence": .double((path.minimumConfidence * 100).rounded() / 100),
                 "steps": .array(path.steps.map { step in
                     ["join": .string(step.toTable),
                      "on": .string(step.conditions.map { "\(step.toTable).\($0.joined) = \(step.fromTable).\($0.existing)" }.joined(separator: " AND ")),
                      "cardinality": .string(step.edge.cardinality.rawValue), "sources": .array(step.edge.relationship.sources.map { .string($0.rawValue) }),
                      "confidence": .double((step.edge.confidence * 100).rounded() / 100)]
                 })]
            }),
        ]
        if from == to {
            payload["hint"] = "Both names are the same table."
        } else if paths.isEmpty {
            payload["hint"] = .string("No known relationship path within \(maxHops) hops. If you find how they join, record it with knowledge_annotate (with evidence).")
            payload["reachable_from"] = .array(graph.neighbourhood(of: [from], depth: 2, limit: 21).dropFirst().map(JSONValue.string))
        }
        return .object(payload)
    }

    func erd(_ graph: KnowledgeGraph, _ args: Arguments) -> JSONValue {
        let focus = (try? args.strings("tables")) ?? []
        var columns = args.string("columns").flatMap(KnowledgeERD.Columns.init(rawValue:)) ?? .keys
        let depth = args.int("depth", default: 1, range: 0...3)
        // The diagram (and its table list) must fit: all columns become key columns, then fewer tables.
        let room = payloadBudget - 2_048
        var entities = KnowledgeERD.maxEntities
        var diagram = KnowledgeERD.mermaid(graph, focus: focus, depth: depth, columns: columns, maxEntities: entities)
        var shrunk = false
        while diagram.text.utf8.count + diagram.tables.reduce(0, { $0 + $1.utf8.count + 3 }) > room, entities > 1 {
            shrunk = true
            if columns == .all {
                columns = .keys
            } else {
                entities = max(1, entities / 2)
            }
            diagram = KnowledgeERD.mermaid(graph, focus: focus, depth: depth, columns: columns, maxEntities: entities)
        }
        var payload: [String: JSONValue] = [
            "database": .string(graph.database), "mermaid": .string(diagram.text), "tables": .array(diagram.tables.map(JSONValue.string)),
            "truncated": .bool(diagram.truncated || shrunk),
            "legend": "Solid lines: declared foreign keys or confirmed relationships. Dotted lines: inferred (naming, code, definitions, AI). ||--o{ many-to-one, ||--o| one-to-one, }o--o{ unknown.",
        ]
        let unknown = focus.filter { graph.resolve($0) == nil }
        if !unknown.isEmpty { payload["unknown"] = .array(unknown.map(JSONValue.string)) }
        return .object(payload)
    }

    // MARK: Encoding

    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func purpose(_ table: String, _ graph: KnowledgeGraph) -> String? {
        (graph.notes.tables[table]?.summary ?? graph.tables[table]?.comment).map { clip($0, bytes: 300) }
    }

    /// At most `bytes` of UTF-8, cut at a character boundary.
    static func clip(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= bytes - 3 else { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }

    static func encode(term: GlossaryTerm) -> JSONValue {
        ["term": .string(term.term), "definition": .string(term.definition), "tables": .array(term.tables.map(JSONValue.string)),
         "sql": JSONValue(term.sql), "author": .string(term.author.rawValue)]
    }

    static func encode(note: TableNote) -> JSONValue {
        ["summary": .string(clip(note.summary, bytes: 2_000)), "author": .string(note.author.rawValue), "updated_at": .string(timestamp(note.updatedAt))]
    }

    static func encode(context: KnowledgeGraph.TableContext, graph: KnowledgeGraph, columns includeColumns: Bool, code includeCode: Bool) -> JSONValue {
        let table = context.table
        var result: [String: JSONValue] = [
            "name": .string(table.name), "kind": .string(table.kind.rawValue), "engine": JSONValue(table.engine),
            "rows_estimate": JSONValue(table.rowsEstimate), "comment": JSONValue(table.comment),
            "primary_key": .array(table.primaryKey.map(JSONValue.string)),
        ]
        if let note = context.note { result["note"] = encode(note: note) }
        if !table.uniqueKeys.isEmpty { result["unique_keys"] = .array(table.uniqueKeys.map { .array($0.map(JSONValue.string)) }) }
        if includeColumns {
            let foreign = Set(context.edges.filter { $0.relationship.from.table == table.name && $0.cardinality != .unknown }.flatMap(\.relationship.from.columns))
            result["columns"] = .array(table.columns.prefix(200).map { column in
                var entry: [String: JSONValue] = ["name": .string(column.name), "type": .string(column.type), "nullable": .bool(column.nullable)]
                var keys: [String] = []
                if table.primaryKey.contains(column.name) { keys.append("PK") }
                if table.uniqueKeys.contains([column.name]) { keys.append("UK") }
                if foreign.contains(column.name) { keys.append("FK") }
                if !keys.isEmpty { entry["key"] = .string(keys.joined(separator: ",")) }
                if let comment = column.comment { entry["comment"] = .string(clip(comment, bytes: 500)) }
                if let note = context.columnNotes[column.name] {
                    if let text = note.note { entry["note"] = .string(clip(text, bytes: 1_000)) }
                    if !note.values.isEmpty { entry["values"] = .object(note.values.mapValues(JSONValue.string)) }
                    entry["note_author"] = .string(note.author.rawValue)
                }
                return .object(entry)
            })
            if table.columns.count > 200 { result["columns_truncated"] = .bool(true) }
        }
        result["relationships"] = .array(context.edges.prefix(100).map { edge in
            let relationship = edge.relationship
            let outgoing = relationship.from.table == table.name
            let other = outgoing ? relationship.to : relationship.from
            let own = outgoing ? relationship.from : relationship.to
            let direction = edge.cardinality == .unknown ? "related" : outgoing ? "references" : "referenced_by"
            var entry: [String: JSONValue] = [
                "direction": .string(direction), "table": .string(other.table),
                "join": .string(zip(own.columns, other.columns).map { "\(table.name).\($0) = \(other.table).\($1)" }.joined(separator: " AND ")),
                "cardinality": .string(edge.cardinality.rawValue), "sources": .array(relationship.sources.map { .string($0.rawValue) }),
                "confidence": .double((edge.confidence * 100).rounded() / 100),
                "evidence": .array(relationship.evidence.map { .string(clip($0.label, bytes: 400)) }),
            ]
            if relationship.from.table == relationship.to.table { entry["self_reference"] = .bool(true) }
            if let verdict = edge.verdict { entry["verdict"] = .string("\(verdict.status.rawValue) by \(verdict.author.rawValue)") }
            if let note = edge.note { entry["note"] = .string(clip(note, bytes: 1_000)) }
            return .object(entry)
        })
        if includeCode, !context.references.isEmpty {
            result["code_references"] = .array(context.references.prefix(10).map { reference in
                ["project": .string(reference.project), "path": .string(reference.path), "line": .int(Int64(reference.line)),
                 "count": .int(Int64(reference.count)), "sql": .bool(reference.sql)]
            })
        }
        return .object(result)
    }

    // MARK: Annotation input

    /// One object of an annotation array, with strict field checks.
    struct Item {
        let values: [String: JSONValue]
        let path: String

        init(_ value: JSONValue, path: String, allowed: Set<String>) throws {
            guard case let .object(values) = value else { throw MCPToolError("`\(path)` must be an object.") }
            let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw MCPToolError("Unknown field\(unknown.count > 1 ? "s" : "") \(unknown.map { "`\($0)`" }.joined(separator: ", ")) in `\(path)`; allowed: \(allowed.sorted().joined(separator: ", ")).")
            }
            self.values = values
            self.path = path
        }

        func string(_ key: String) throws -> String? {
            switch values[key] {
            case nil, .null?: return nil
            case let .string(text)?: return text
            default: throw MCPToolError("`\(path).\(key)` must be a string.")
            }
        }

        func required(_ key: String) throws -> String {
            guard let text = try string(key) else { throw MCPToolError("`\(path).\(key)` is required.") }
            return text
        }

        func strings(_ key: String, required: Bool = false) throws -> [String] {
            switch values[key] {
            case nil, .null?:
                if required { throw MCPToolError("`\(path).\(key)` is required.") }
                return []
            case let .array(items)?:
                return try items.map { item in
                    guard case let .string(text) = item else { throw MCPToolError("`\(path).\(key)` must be an array of strings.") }
                    return text
                }
            default:
                throw MCPToolError("`\(path).\(key)` must be an array of strings.")
            }
        }

        func evidence() throws -> [KnowledgeAnnotation.EvidenceInput] {
            guard let value = values["evidence"], value != .null else { return [] }
            guard case let .array(items) = value else { throw MCPToolError("`\(path).evidence` must be an array.") }
            return try items.enumerated().map { index, item in
                let entry = try Item(item, path: "\(path).evidence[\(index)]", allowed: ["kind", "project", "path", "line", "detail"])
                let kind = try entry.string("kind").map { name in
                    guard let kind = KnowledgeAnnotation.EvidenceInput.Kind(rawValue: name) else {
                        throw MCPToolError("`\(entry.path).kind` must be code, query or note.")
                    }
                    return kind
                }
                var line: Int?
                if let value = entry.values["line"], value != .null {
                    guard let number = value.intValue else { throw MCPToolError("`\(entry.path).line` must be an integer.") }
                    line = Int(clamping: number)
                }
                return KnowledgeAnnotation.EvidenceInput(kind: kind, project: try entry.string("project"), path: try entry.string("path"), line: line,
                                                         detail: try entry.string("detail"))
            }
        }
    }

    static func items(_ args: Arguments, _ key: String, allowed: Set<String>) throws -> [Item] {
        guard let value = args.values[key], value != .null else { return [] }
        guard case let .array(items) = value else { throw MCPToolError("`\(key)` must be an array.") }
        guard items.count <= KnowledgeAnnotator.maxItems else { throw MCPToolError("At most \(KnowledgeAnnotator.maxItems) entries in `\(key)`.") }
        return try items.enumerated().map { try Item($1, path: "\(key)[\($0)]", allowed: allowed) }
    }

    static func annotation(_ args: Arguments) throws -> KnowledgeAnnotation {
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = try items(args, "table_notes", allowed: ["table", "summary", "evidence"]).map { item in
            .init(table: try item.required("table"), summary: try item.required("summary"), evidence: try item.evidence())
        }
        annotation.columnNotes = try items(args, "column_notes", allowed: ["table", "column", "note", "values", "evidence"]).map { item in
            var values: [String: String] = [:]
            if let raw = item.values["values"], raw != .null {
                guard case let .object(members) = raw else { throw MCPToolError("`\(item.path).values` must be an object of strings.") }
                for (value, meaning) in members {
                    switch meaning {
                    case let .string(text): values[value] = text
                    case let .int(number): values[value] = String(number)
                    default: throw MCPToolError("`\(item.path).values.\(value)` must be a string.")
                    }
                }
            }
            return .init(table: try item.required("table"), column: try item.required("column"), note: try item.string("note"), values: values,
                         evidence: try item.evidence())
        }
        annotation.relationships = try items(args, "relationships",
                                             allowed: ["from_table", "from_columns", "to_table", "to_columns", "confidence", "note", "evidence", "remove"]).map { item in
            var confidence: Double?
            if let value = item.values["confidence"], value != .null {
                guard let number = value.doubleValue ?? value.intValue.map(Double.init) else { throw MCPToolError("`\(item.path).confidence` must be a number.") }
                confidence = number
            }
            var remove = false
            if let value = item.values["remove"], value != .null {
                guard let flag = value.boolValue else { throw MCPToolError("`\(item.path).remove` must be a boolean.") }
                remove = flag
            }
            return .init(fromTable: try item.required("from_table"), fromColumns: try item.strings("from_columns", required: true),
                         toTable: try item.required("to_table"), toColumns: try item.strings("to_columns", required: true),
                         confidence: confidence, note: try item.string("note"), evidence: try item.evidence(), remove: remove)
        }
        annotation.verdicts = try items(args, "verdicts", allowed: ["from_table", "from_columns", "to_table", "to_columns", "verdict", "reason"]).map { item in
            guard let status = KnowledgeAnnotation.VerdictInput.Status(rawValue: try item.required("verdict")) else {
                throw MCPToolError("`\(item.path).verdict` must be confirmed, rejected or cleared.")
            }
            return .init(fromTable: try item.required("from_table"), fromColumns: try item.strings("from_columns", required: true),
                         toTable: try item.required("to_table"), toColumns: try item.strings("to_columns", required: true), status: status,
                         reason: try item.string("reason"))
        }
        annotation.glossary = try items(args, "glossary", allowed: ["term", "definition", "tables", "sql"]).map { item in
            .init(term: try item.required("term"), definition: try item.required("definition"), tables: try item.strings("tables"),
                  sql: try item.string("sql"))
        }
        guard !annotation.isEmpty else {
            throw MCPToolError("Pass at least one of table_notes, column_notes, relationships, verdicts or glossary.")
        }
        return annotation
    }
}

extension Arguments {
    /// An array of strings (absent: empty).
    func strings(_ key: String) throws -> [String] {
        switch values[key] {
        case nil, .null?:
            return []
        case let .array(items)?:
            return try items.map { item in
                guard case let .string(text) = item else { throw MCPToolError("`\(key)` must be an array of strings.") }
                return text
            }
        case let .string(text)?:
            return [text]
        default:
            throw MCPToolError("`\(key)` must be an array of strings.")
        }
    }
}
