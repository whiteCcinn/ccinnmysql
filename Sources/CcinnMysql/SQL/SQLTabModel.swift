import AppKit
import CcinnMysqlKit
import Foundation
import MySQLWire
import Observation
import MySQLKit

/// Result of one executed statement.
@MainActor
@Observable
final class StatementOutcome: Identifiable {
    let id = UUID()
    let index: Int
    let sql: String
    let executedSQL: String
    let kind: SQLStatementKind
    let startedAt: Date
    var durationMilliseconds: Double = 0
    var results: [ResultSet] = []
    var errorMessage: String?
    var errorCode: Int?
    /// The server's error, parsed once, off the main actor.
    var serverError: SQLServerError?
    var limitApplied: Int?
    var isRunning = true
    var viewMode: ViewMode = .grid
    var chart: ChartState?
    /// Parsed EXPLAIN FORMAT=JSON / EXPLAIN ANALYZE output.
    var plan: ExplainPlan?
    var planError: String?
    /// Whether the result grid may be edited (single base table with a key).
    var editEligibility: RowEditEligibility?
    /// Changes when rows are edited in place, so the grid reloads.
    var resultID = UUID()

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case chart = "Chart"
        case plan = "Plan"
        var id: String { rawValue }
    }

    init(index: Int, sql: String, executedSQL: String, kind: SQLStatementKind) {
        self.index = index
        self.sql = sql
        self.executedSQL = executedSQL
        self.kind = kind
        startedAt = Date()
        if kind == .explain { viewMode = .plan }
    }

    /// The row set to display (last result that has columns).
    var rowSet: ResultSet? { results.last { $0.hasRowSet } }

    var summary: String {
        if isRunning { return "Running…" }
        if errorMessage != nil { return "Failed" }
        if let rowSet {
            let rows = Format.count(rowSet.rows.count)
            return rowSet.isTruncated ? "\(rows)+ rows" : "\(rows) row\(rowSet.rows.count == 1 ? "" : "s")"
        }
        let affected = results.reduce(UInt64(0)) { $0 &+ $1.affectedRows }
        return affected > 0 ? "\(affected.formatted()) affected" : "OK"
    }

    /// Plain-text plan for EXPLAIN results (one column of lines).
    var planText: String? {
        guard let rowSet, kind == .explain else { return nil }
        return rowSet.rows.map { $0.compactMap { $0 }.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Replaces one cell after a confirmed edit.
    func replaceCell(row: Int, column: Int, value: String?) {
        guard let index = results.lastIndex(where: \.hasRowSet) else { return }
        let set = results[index]
        guard set.rows.indices.contains(row), column < set.rows[row].count else { return }
        var rows = set.rows
        rows[row][column] = value
        results[index] = ResultSet(columns: set.columns, rows: rows, isTruncated: set.isTruncated, warnings: set.warnings, status: set.status)
        resultID = UUID()
    }
}

/// Chart configuration and prepared data for one result.
@MainActor
@Observable
final class ChartState {
    var spec: ChartSpec { didSet { if spec != oldValue { rebuild() } } }
    let roles: [ColumnRole]
    private(set) var data: ChartData = .empty
    private(set) var isPreparing = false
    private let columns: [ColumnDefinition]
    private let rows: [[String?]]
    private var buildTask: Task<Void, Never>?

    init?(result: ResultSet) {
        guard result.hasRowSet, !result.rows.isEmpty else { return nil }
        columns = result.columns
        rows = result.rows
        let roles = ChartSuggester.roles(columns: result.columns, rows: result.rows)
        self.roles = roles
        let numeric = roles.indices.first { roles[$0] == .numeric }
        guard let suggested = ChartSuggester.suggest(roles: roles, rows: result.rows)
            ?? numeric.map({ ChartSpec(kind: .bar, xColumn: 0, yColumns: [$0]) }) else { return nil }
        spec = suggested
        rebuild()
    }

    var columnNames: [String] { columns.map(\.name) }
    var numericColumns: [Int] { roles.indices.filter { roles[$0] == .numeric } }

    private func rebuild() {
        buildTask?.cancel()
        isPreparing = true
        let (columns, rows, spec, roles) = (self.columns, self.rows, self.spec, self.roles)
        buildTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                ChartDataBuilder.build(columns: columns, rows: rows, spec: spec, roles: roles)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.data = data
            self.isPreparing = false
        }
    }
}

/// One SQL editor tab: text, session, execution of current/selected/all statements, results and history.
@MainActor
@Observable
final class SQLTabModel {
    let title: String
    /// Edits made in the editor arrive through `editorDidEdit` first; any other assignment (History →
    /// Open) replaces the text, which makes every server diagnostic stale.
    var text: String {
        didSet {
            if editorEditPending {
                editorEditPending = false
                if lineIndexIsStale { rebuildLineIndex() }
            } else {
                textWasReplaced()
            }
            scheduleLint()
        }
    }
    var selection = NSRange(location: 0, length: 0)
    private(set) var database: String?
    private(set) var isInTransaction = false
    var outcomes: [StatementOutcome] = []
    var selectedOutcomeID: UUID?
    var isRunning = false
    var runStartedAt: Date?
    /// Errors of the last run, anchored to the statements that failed.
    private(set) var serverDiagnostics: [SQLDiagnostic] = []
    /// Local checks of the current text (refreshed shortly after typing stops).
    private(set) var localDiagnostics: [SQLDiagnostic] = []
    var inspected: InspectedValue?
    var pendingConfirmation: PendingConfirmation?
    var showHistory = false
    var editing: (outcome: StatementOutcome, request: CellEditRequest)?
    var pendingEdit: (outcome: StatementOutcome, edit: PendingRowEdit)?

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let statements: [String]
        let continuation: CheckedContinuation<Bool, Never>
    }

    unowned let workspace: WorkspaceModel
    private let session: SQLSession
    private var runTask: Task<Void, Never>?
    private var stopRequested = false
    private var lintTask: Task<Void, Never>?
    private var editorEditPending = false
    /// The session lexes strings with backslash escapes (sql_mode without NO_BACKSLASH_ESCAPES); read after
    /// every statement, so local checks agree with the server.
    @ObservationIgnored private var lintsWithBackslashEscapes = true
    /// Line starts of `text`, maintained edit by edit (positions without scanning the text).
    @ObservationIgnored private var lineIndex: SQLLineIndex
    @ObservationIgnored private var lineIndexIsStale = false
    /// Editor ranges of the statements in the running batch, by index; `nil` once a statement was edited.
    private var runAnchors: [Range<Int>?] = []

    /// A statement to execute: `sql` is sent as is; `editorOffset` is where its source starts in the
    /// editor (nil when unknown) and `prefixLength` the units the app prepended (`EXPLAIN FORMAT=JSON `).
    private struct PlannedStatement {
        let sql: String
        let editorOffset: Int?
        var prefixLength = 0
    }

    /// Rows kept per result (hard cap) and the default auto-limit for plain SELECTs.
    static let hardRowCap = 100_000
    var autoLimit: Int {
        get { UserDefaults.standard.object(forKey: "autoLimit") as? Int ?? 1000 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLimit") }
    }

    init(title: String, text: String, database: String?, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        lineIndex = SQLLineIndex(text)
        self.database = database
        self.workspace = workspace
        session = workspace.client.openSession(database: database)
        self.selection = NSRange(location: (text as NSString).length, length: 0)
        scheduleLint(after: .zero)
    }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

    // MARK: Diagnostics

    /// Server and local diagnostics, in text order.
    var diagnostics: [SQLDiagnostic] {
        guard !localDiagnostics.isEmpty else { return serverDiagnostics }
        guard !serverDiagnostics.isEmpty else { return localDiagnostics }
        // Server first on ties, so the order is deterministic and the editor does not re-highlight needlessly.
        return (serverDiagnostics + localDiagnostics).sorted {
            ($0.range.lowerBound, $0.source == .server ? 0 : 1, $0.range.upperBound) < ($1.range.lowerBound, $1.source == .server ? 0 : 1, $1.range.upperBound)
        }
    }

    /// The marker of a result's error, while it is still valid.
    func serverDiagnostic(for outcome: StatementOutcome) -> SQLDiagnostic? {
        serverDiagnostics.first { $0.origin == outcome.id }
    }

    /// Called by the editor before it writes the edited text: keeps markers, run anchors and the line
    /// index on their text.
    func editorDidEdit(_ edits: [SQLTextEdit]) {
        editorEditPending = true
        guard !edits.isEmpty else { return }
        for edit in edits where !lineIndexIsStale {
            if !lineIndex.apply(edit) { lineIndexIsStale = true }
        }
        let server = SQLDiagnosticTracker.apply(edits, to: serverDiagnostics)
        if server != serverDiagnostics { serverDiagnostics = server }
        let local = SQLDiagnosticTracker.apply(edits, to: localDiagnostics)
        if local != localDiagnostics { localDiagnostics = local }
        if !runAnchors.isEmpty { runAnchors = SQLDiagnosticTracker.apply(edits, to: runAnchors) }
    }

    /// Selects a diagnostic's text in the editor (which scrolls to it).
    func reveal(_ diagnostic: SQLDiagnostic) {
        let length = (text as NSString).length
        let lower = min(max(0, diagnostic.range.lowerBound), length)
        let upper = min(max(lower, diagnostic.range.upperBound), length)
        selection = NSRange(location: lower, length: upper - lower)
    }

    /// 1-based line and column of an offset in `text` (O(log lines + line length)).
    func position(of offset: Int) -> SQLTextPosition {
        lineIndex.position(of: offset, in: text as NSString)
    }

    private func rebuildLineIndex() {
        lineIndex = SQLLineIndex(text)
        lineIndexIsStale = false
    }

    private func textWasReplaced() {
        rebuildLineIndex()
        if !serverDiagnostics.isEmpty { serverDiagnostics = [] }
        if !localDiagnostics.isEmpty { localDiagnostics = [] }
        runAnchors = runAnchors.map { _ in nil }
    }

    /// Re-checks the text off the main actor once typing pauses; a newer edit cancels the check.
    private func scheduleLint(after delay: Duration = .milliseconds(300)) {
        lintTask?.cancel()
        let snapshot = text
        let backslashEscapes = lintsWithBackslashEscapes
        lintTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .utility) { SQLLinter.diagnose(snapshot, backslashEscapes: backslashEscapes) }.value
            // Any edit since the snapshot cancelled this task (both run on the main actor).
            guard let self, !Task.isCancelled else { return }
            if found != self.localDiagnostics { self.localDiagnostics = found }
        }
    }

    /// Follows the session's NO_BACKSLASH_ESCAPES (it can change with `SET sql_mode`).
    private func refreshLintMode() async {
        let backslashEscapes = !(await session.noBackslashEscapes)
        guard backslashEscapes != lintsWithBackslashEscapes else { return }
        lintsWithBackslashEscapes = backslashEscapes
        scheduleLint(after: .zero)
    }

    // MARK: Running

    /// Selection if any, otherwise the statement under the cursor.
    func runCurrent() {
        if let selected = selectedText {
            run(SQLStatementSplitter.split(selected).map { PlannedStatement(sql: $0.text, editorOffset: selection.location + $0.range.lowerBound) })
            return
        }
        guard let statement = SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        run([PlannedStatement(sql: statement.text, editorOffset: statement.range.lowerBound)])
    }

    func runAll() {
        run(SQLStatementSplitter.split(text).map { PlannedStatement(sql: $0.text, editorOffset: $0.range.lowerBound) })
    }

    /// EXPLAIN of the current statement: FORMAT=JSON (visual plan), or `analyze` to execute it and measure
    /// (EXPLAIN ANALYZE on MySQL 8.0.18+, ANALYZE FORMAT=JSON on MariaDB) — only for queries, never for writes.
    func explain(analyze: Bool) {
        let selected = selectedText
        guard let statement = selected.map({ SQLStatementSplitter.split($0).first })
            ?? SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        let base = selected == nil ? 0 : selection.location
        let body = statement.text
        let editorOffset = base + statement.range.lowerBound
        let kind = SQLStatementKind.of(body)
        guard kind != .explain else {
            return run([PlannedStatement(sql: body, editorOffset: editorOffset)])
        }
        let info = workspace.serverInfo
        let prefix: String
        if analyze {
            guard kind == .query else {
                workspace.showToast("EXPLAIN ANALYZE runs the statement; it is only offered for queries.", isError: true)
                return
            }
            if info.supportsExplainAnalyze {
                prefix = "EXPLAIN ANALYZE "
            } else if info.supportsAnalyzeJSON {
                prefix = "ANALYZE FORMAT=JSON "
            } else {
                workspace.showToast("This server does not support EXPLAIN ANALYZE (MySQL 8.0.18+ or MariaDB 10.1+).", isError: true)
                return
            }
        } else {
            prefix = info.supportsExplainJSON ? "EXPLAIN FORMAT=JSON " : "EXPLAIN "
        }
        run([PlannedStatement(sql: prefix + body, editorOffset: editorOffset, prefixLength: prefix.utf16.count)])
    }

    /// The selected text, when the selection is non-empty and inside the text.
    private var selectedText: String? {
        let nsText = text as NSString
        guard selection.length > 0, selection.location >= 0, NSMaxRange(selection) <= nsText.length else { return nil }
        return nsText.substring(with: selection)
    }

    /// Clears session variables and temporary tables (COM_RESET_CONNECTION or a reconnect).
    func resetSession() {
        guard !isRunning else { return }
        Task {
            do {
                try await session.resetSession()
                isInTransaction = false
                workspace.showToast("Session reset")
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        // Do not start the remaining statements of "Run All"; the running one is stopped with KILL QUERY.
        stopRequested = true
        Task { await session.cancel() }
    }

    /// Runs statements sequentially; stops at the first error.
    private func run(_ statements: [PlannedStatement]) {
        guard !isRunning, !statements.isEmpty else { return }
        serverDiagnostics = []
        runAnchors = statements.map { statement in
            statement.editorOffset.map { $0..<($0 + max(0, statement.sql.utf16.count - statement.prefixLength)) }
        }
        stopRequested = false
        isRunning = true
        runStartedAt = Date()
        outcomes = []
        runTask = Task {
            defer {
                isRunning = false
                runStartedAt = nil
                runAnchors = []
            }
            let mutations = statements.map(\.sql).filter { SQLStatementKind.of($0).isMutation }
            if workspace.profile.confirmMutations, !mutations.isEmpty {
                let confirmed = await withCheckedContinuation { continuation in
                    pendingConfirmation = PendingConfirmation(statements: mutations, continuation: continuation)
                }
                guard confirmed else { return }
            }
            for (index, statement) in statements.enumerated() {
                let succeeded = await execute(statement, index: index)
                if !succeeded || Task.isCancelled || stopRequested { break }
            }
        }
    }

    func resolveConfirmation(_ confirmed: Bool) {
        pendingConfirmation?.continuation.resume(returning: confirmed)
        pendingConfirmation = nil
    }

    private func execute(_ statement: PlannedStatement, index: Int) async -> Bool {
        let sql = statement.sql
        let kind = SQLStatementKind.of(sql)
        var executed = sql
        var limitApplied: Int?
        var mapping = SQLExecutedTextMapping(prefixLength: statement.prefixLength)
        if kind == .query, autoLimit > 0 {
            let outcome = AutoLimit.apply(to: sql, limit: autoLimit)
            if outcome.applied {
                executed = outcome.sql
                limitApplied = autoLimit
                mapping.insertion = outcome.insertion
            }
        }
        let outcome = StatementOutcome(index: index, sql: sql, executedSQL: executed, kind: kind)
        outcome.limitApplied = limitApplied
        outcomes.append(outcome)
        selectedOutcomeID = outcome.id

        let clock = ContinuousClock()
        let started = clock.now
        var historyEntry = QueryHistoryEntry(sql: sql, database: database, durationMilliseconds: 0)
        var failure: (message: String, code: Int?)?
        do {
            let results = try await session.run(executed, limits: RowLimits(maxRows: Self.hardRowCap))
            outcome.results = results
            if let rowSet = outcome.rowSet { historyEntry.rowCount = rowSet.rows.count }
            historyEntry.affectedRows = results.reduce(0) { $0 &+ $1.affectedRows }
            database = await session.database
            if kind == .definition || kind == .use { refreshSidebar(after: sql) }
            if kind == .explain, let rowSet = outcome.rowSet { await preparePlan(outcome, rowSet) }
            if kind == .query, let rowSet = outcome.rowSet, !rowSet.rows.isEmpty {
                // Key lookup runs on the pool, after the statement, without delaying the next statement.
                Task { await prepareEditing(outcome, rowSet) }
            }
        } catch {
            outcome.errorMessage = describe(error)
            outcome.errorCode = (error as? MySQLError)?.code
            historyEntry.errorMessage = outcome.errorMessage
            failure = ((error as? MySQLError)?.message ?? describe(error), outcome.errorCode)
        }
        // Measured before locating the error, which is not part of the statement's run time.
        let elapsed = clock.now - started
        outcome.durationMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        historyEntry.durationMilliseconds = outcome.durationMilliseconds
        isInTransaction = await session.isInTransaction
        if let failure {
            let (parsed, diagnostic) = await diagnose(failure.message, code: failure.code, statement: statement, executed: executed,
                                                      mapping: mapping, index: index, origin: outcome.id)
            outcome.serverError = parsed
            if let diagnostic { serverDiagnostics.append(diagnostic) }
        }
        outcome.isRunning = false
        await workspace.history.append(historyEntry)
        await refreshLintMode()
        return outcome.errorMessage == nil
    }

    /// Parses a failure and, unless the statement was edited while it ran, its editor marker. Both run
    /// off the main actor: locating lexes the statement, which can be large.
    private func diagnose(_ message: String, code: Int?, statement: PlannedStatement, executed: String, mapping: SQLExecutedTextMapping,
                          index: Int, origin: UUID) async -> (SQLServerError, SQLDiagnostic?) {
        let wantsMarker = runAnchors.indices.contains(index) && runAnchors[index] != nil
        let sql = statement.sql
        let prefixLength = statement.prefixLength
        let (parsed, located) = await Task.detached(priority: .userInitiated) { () -> (SQLServerError, (range: Range<Int>, message: String)?) in
            let parsed = SQLServerError.parse(message, code: code)
            guard wantsMarker else { return (parsed, nil) }
            let units = Array(sql.utf16)
            let sourceUnits = units[min(max(0, prefixLength), units.count)...]
            let source = String(decoding: sourceUnits, as: UTF16.self)
            guard let range = SQLErrorLocator.range(in: source, executed: executed, mapping: mapping, error: parsed) else { return (parsed, nil) }
            let marked = String(decoding: Array(source.utf16)[range], as: UTF16.self)
            return (parsed, (range, parsed.markerMessage(for: marked)))
        }.value
        // Re-read the anchor: the user may have typed while the statement was being located.
        guard let located, runAnchors.indices.contains(index), let anchor = runAnchors[index],
              located.range.upperBound <= anchor.count else { return (parsed, nil) }
        let marked = (anchor.lowerBound + located.range.lowerBound)..<(anchor.lowerBound + located.range.upperBound)
        return (parsed, SQLDiagnostic(range: marked, scope: anchor, severity: .error, source: .server, message: located.message, origin: origin))
    }

    private func refreshSidebar(after sql: String) {
        guard let database else { return }
        if SessionContextChange.parse(sql) == nil { workspace.loadObjects(database: database, force: true) }
    }

    /// Parses a JSON or tree plan off the main actor.
    private func preparePlan(_ outcome: StatementOutcome, _ rowSet: ResultSet) async {
        let text = rowSet.rows.compactMap { $0.first ?? nil }.joined(separator: "\n")
        guard rowSet.columns.count == 1, text.hasPrefix("{") || text.hasPrefix("->") else { return }
        let parsed = await Task.detached(priority: .userInitiated) { () -> Result<ExplainPlan, ExplainParseError> in
            do { return .success(try ExplainParser.parse(text)) } catch let error as ExplainParseError { return .failure(error) } catch {
                return .failure(ExplainParseError(description: error.localizedDescription))
            }
        }.value
        switch parsed {
        case let .success(plan): outcome.plan = plan
        case let .failure(error): outcome.planError = error.description
        }
    }

    /// Decides whether the result can be edited (design D11).
    private func prepareEditing(_ outcome: StatementOutcome, _ rowSet: ResultSet) async {
        let tables = Set(rowSet.columns.filter { !$0.originalTable.isEmpty }.map { "\($0.schema)\u{1F}\($0.originalTable)" })
        guard tables.count == 1, let column = rowSet.columns.first(where: { !$0.originalTable.isEmpty }), !column.schema.isEmpty else {
            outcome.editEligibility = .readOnly(tables.count > 1 ? "Cells are read-only: the result combines several tables." : "Cells are read-only: the result has no table columns.")
            return
        }
        let client = workspace.client
        let (schema, table) = (column.schema, column.originalTable)
        do {
            let isBase = try await client.isBaseTable(schema: schema, table: table)
            let keys = isBase ? try await client.identifyingKeys(schema: schema, table: table) : []
            outcome.editEligibility = RowEditor.eligibility(columns: rowSet.columns, keys: keys, isBaseTable: isBase)
        } catch {
            outcome.editEligibility = .readOnly("Cells are read-only: \(describe(error))")
        }
    }

    // MARK: Editing

    func beginEdit(_ outcome: StatementOutcome, _ request: CellEditRequest) {
        editing = (outcome, request)
    }

    func proposeEdit(_ outcome: StatementOutcome, row: Int, column: Int, newValue: String?) {
        guard let plan = outcome.editEligibility?.plan, let rowSet = outcome.rowSet, rowSet.rows.indices.contains(row) else { return }
        let original = rowSet.rows[row]
        guard column < original.count, original[column] != newValue else { return }
        Task {
            // Literals follow the session's sql_mode: the edit runs on the same connection as the result.
            let noBackslashEscapes = await session.noBackslashEscapes
            do {
                let sql = try RowEditor.updateStatement(plan: plan, row: original, changes: [column: newValue], noBackslashEscapes: noBackslashEscapes)
                pendingEdit = (outcome, PendingRowEdit(sql: sql, row: row, column: column, newValue: newValue))
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    func confirmEdit() {
        guard let (outcome, edit) = pendingEdit else { return }
        pendingEdit = nil
        let session = session
        Task {
            do {
                // Same connection as the result: session time zone, character set and sql_mode apply to the key values.
                try await session.applyRowEdit(edit.sql)
                isInTransaction = await session.isInTransaction
                outcome.replaceCell(row: edit.row, column: edit.column, value: edit.newValue)
                await workspace.history.append(QueryHistoryEntry(sql: edit.sql, database: database, durationMilliseconds: 0, affectedRows: 1))
                workspace.showToast("Row updated")
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    /// Changes the session database (`USE`).
    func use(database name: String) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                _ = try await session.run("USE \(SQLText.quoteIdentifier(name))")
                database = await session.database
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    // MARK: Completion

    func completions(text: String, cursor: Int) async -> CompletionResult {
        let database = self.database
        var result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(currentDatabase: database))
        if result.needsMoreSchema {
            await workspace.ensureSchema(columns: result.missingColumns, databases: result.missingDatabases)
            result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(currentDatabase: database))
        }
        return result
    }

    /// Runs the (pure) completion engine off the main actor.
    private nonisolated static func complete(text: String, cursor: Int, schema: SchemaSnapshot) async -> CompletionResult {
        await Task.detached(priority: .userInitiated) {
            CompletionEngine.complete(text: text, cursor: cursor, schema: schema)
        }.value
    }

    // MARK: Export

    func exportCSV(_ result: ResultSet) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: " ", with: "_")).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let (columns, rows) = (result.columns, result.rows)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ResultExport.writeCSV(to: url, columns: columns, rows: rows)
                }.value
                workspace.showToast("Exported \(Format.count(rows.count)) rows")
            } catch {
                workspace.showToast("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func copyTSV(_ result: ResultSet) {
        let (columns, rows) = (result.columns, result.rows)
        Task {
            let text = await Task.detached(priority: .userInitiated) { ResultExport.tsv(columns: columns, rows: rows) }.value
            Pasteboard.copy(text)
            workspace.showToast("Copied \(Format.count(rows.count)) rows")
        }
    }

    func close() {
        runTask?.cancel()
        lintTask?.cancel()
        if let pendingConfirmation { pendingConfirmation.continuation.resume(returning: false) }
        pendingConfirmation = nil
        let session = session
        Task { await session.cancel(graceSeconds: 1); await session.close() }
    }
}
