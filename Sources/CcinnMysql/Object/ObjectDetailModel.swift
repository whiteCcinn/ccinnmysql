import CcinnMysqlKit
import Foundation
import Observation
import MySQLKit

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// State of one table / view / routine / trigger / event tab. Sections load lazily; every load carries a
/// generation token so a slow earlier load never overwrites a newer one.
@MainActor
@Observable
final class ObjectDetailModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case columns = "Columns"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"
        case partitions = "Partitions"
        case insights = "Insights"
        case ddl = "DDL"
        case data = "Data"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "info.circle"
            case .columns: "list.bullet.rectangle"
            case .indexes: "list.number"
            case .foreignKeys: "link"
            case .partitions: "square.split.bottomrightquarter"
            case .insights: "stethoscope"
            case .ddl: "doc.plaintext"
            case .data: "tablecells"
            }
        }
    }

    private(set) var object: DatabaseObject
    unowned let workspace: WorkspaceModel
    private(set) var section: Section = .overview

    var detail: Loadable<TableDetail> = .idle
    var ddl: Loadable<String> = .idle
    var preview: Loadable<ResultSet> = .idle
    var previewID = UUID()
    /// The Data tab's position: sort, page, and whether pages are read by key.
    private(set) var pager: TablePager?
    /// A page is being read; the page on screen stays until it arrives.
    private(set) var isLoadingPage = false
    /// The Data tab's filter on the page on screen; why the last one entered was refused (by the check or the server).
    private(set) var dataFilter: TableFilter?
    private(set) var filterProblem: String?
    /// The table's identifying keys (primary key first) and, without one, the columns that break ties; read once.
    private var identifyingKeys: [[String]]?
    private var tieBreakers: [String] = []
    private var pageLoad: UInt64 = 0
    private var pageTask: Task<Void, Never>?
    /// Whether the preview rows can be edited, and how.
    var editEligibility: RowEditEligibility?
    var pendingEdit: PendingRowEdit?
    var inspected: InspectedValue?
    private var generation: UInt64 = 0

    init(object: DatabaseObject, workspace: WorkspaceModel) {
        self.object = object
        self.workspace = workspace
        load(.overview)
    }

    var client: MySQLClient { workspace.client }

    var availableSections: [Section] {
        switch object.kind {
        case .table:
            object.isPartitioned ? [.overview, .columns, .indexes, .foreignKeys, .partitions, .insights, .ddl, .data]
                : [.overview, .columns, .indexes, .foreignKeys, .insights, .ddl, .data]
        case .view, .systemView, .sequence: [.overview, .columns, .ddl, .data]
        case .procedure, .function, .trigger, .event: [.overview, .ddl]
        }
    }

    var findings: [TableFinding] {
        detail.value.map(TableInsights.findings(for:)) ?? []
    }

    var autoIncrement: AutoIncrementHeadroom? {
        detail.value.flatMap { TableInsights.autoIncrementHeadroom(columns: $0.columns, nextValue: object.autoIncrement) }
    }

    func select(_ section: Section) {
        guard availableSections.contains(section) else { return }
        self.section = section
        load(section)
    }

    func reload() {
        generation &+= 1
        detail = .idle
        ddl = .idle
        preview = .idle
        editEligibility = nil
        pager = nil
        identifyingKeys = nil
        tieBreakers = []
        pageTask?.cancel()
        if let refreshed = workspace.object(database: object.schema, name: object.name), refreshed.kind == object.kind { object = refreshed }
        load(section)
    }

    func load(_ section: Section) {
        switch section {
        case .overview:
            if object.kind.isRelation, case .idle = detail { loadDetail() }
            if !object.kind.isRelation, case .idle = ddl { loadDDL() }
        case .columns, .indexes, .foreignKeys, .partitions, .insights:
            if case .idle = detail { loadDetail() }
        case .ddl:
            if case .idle = ddl { loadDDL() }
        case .data:
            if case .idle = preview { loadPreview() }
        }
    }

    // MARK: Loaders

    private func run<Value>(_ assign: @escaping (Loadable<Value>) -> Void, _ body: @escaping @MainActor () async throws -> Value) {
        let token = generation
        assign(.loading)
        Task {
            do {
                let value = try await body()
                guard token == self.generation else { return }
                assign(.loaded(value))
            } catch {
                guard token == self.generation else { return }
                assign(.failed(describe(error)))
            }
        }
    }

    func loadDetail() {
        let object = object
        run({ self.detail = $0 }) {
            var detail = try await self.client.tableDetail(object)
            if detail.ddl != nil { self.ddl = .loaded(detail.ddl ?? "") }
            detail.ddl = nil
            return detail
        }
    }

    func loadDDL() {
        let object = object
        run({ self.ddl = $0 }) { try await self.client.ddl(of: object) }
    }

    /// The first page, in the current sort (first load, Try Again).
    func loadPreview() {
        let sort = pager?.sort
        loadPage(replacing: true) { $0.first(sortedBy: sort) }
    }

    /// The page on screen again.
    func reloadPage() { loadPage { $0.reload() } }
    func nextPage() { loadPage { $0.next() } }
    func previousPage() { loadPage { $0.previous() } }
    func firstPage() { loadPage { $0.first(sortedBy: $0.sort) } }

    /// Sorts on the server by `column` (`nil`: the table's order) and shows the first page.
    func sortPreview(by sort: TablePager.Sort?) { loadPage { $0.first(sortedBy: sort) } }

    /// Shows the first page of the rows matching `text` (empty: every row), in the current sort. The filter takes
    /// effect when its page arrives; a refused or failing one leaves the page on screen and says why.
    func applyFilter(_ text: String) {
        switch TableFilter.parse(text) {
        case let .failure(refusal):
            filterProblem = refusal.message
        case let .success(filter):
            filterProblem = nil
            let sort = pager?.sort
            loadPage(filter: .some(filter)) { $0.first(sortedBy: sort) }
        }
    }

    /// Reads the page `choose` picks. The page on screen stays until the new one arrives (`replacing` shows progress
    /// instead); only the newest request may show its page.
    /// `filter`: start over with this filter (`.some(nil)`: none) instead of the page on screen's.
    private func loadPage(replacing: Bool = false, filter: TableFilter?? = nil, _ choose: @escaping (TablePager) -> TablePager.Request?) {
        let object = object
        let token = generation
        pageLoad &+= 1
        let load = pageLoad
        if replacing || preview.value == nil {
            preview = .loading
            previewID = UUID()
        }
        isLoadingPage = true
        // A superseded read (a second click, a new sort) is cancelled: the server stops its statement.
        pageTask?.cancel()
        pageTask = Task {
            defer { if load == self.pageLoad { self.isLoadingPage = false } }
            do {
                let keys = try await self.keys(of: object)
                let fresh = { (filter: TableFilter?) in
                    TablePager(table: object.qualifiedName, keyColumns: keys.first ?? [], tieBreakers: self.tieBreakers, filter: filter)
                }
                var pager = filter.map(fresh) ?? self.pager ?? fresh(self.dataFilter)
                guard let request = choose(pager) else { return }
                let result = try await self.client.previewPage(request.sql, maxRows: pager.pageSize + 1)
                guard token == self.generation, load == self.pageLoad else { return }
                let rows = pager.apply(request, columns: result.columns, rows: result.rows, truncated: result.isTruncated)
                self.pager = pager
                self.dataFilter = pager.filter
                if filter != nil { self.filterProblem = nil }
                // Everything before the page went away meanwhile: show the start of the table.
                if rows.isEmpty, request.readsBackward { return self.firstPage() }
                self.editEligibility = object.kind == .table
                    ? RowEditor.eligibility(columns: result.columns, keys: keys, isBaseTable: true)
                    : .readOnly("Only base tables can be edited.")
                self.preview = .loaded(ResultSet(columns: result.columns, rows: rows, isTruncated: result.isTruncated,
                                                 warnings: result.warnings, status: result.status))
                self.previewID = UUID()
            } catch is CancellationError {
                return
            } catch {
                guard token == self.generation, load == self.pageLoad else { return }
                if filter != nil {
                    self.filterProblem = describe(error)
                    if self.preview.value != nil { return }
                }
                if self.preview.value == nil {
                    self.preview = .failed(describe(error))
                } else {
                    self.workspace.showToast(describe(error), isError: true)
                }
            }
        }
    }

    /// Primary key first, then NOT NULL unique keys; none for views. Without a key, the columns that can break ties
    /// in a sort (not TEXT, BLOB, JSON or spatial) are read too.
    private func keys(of object: DatabaseObject) async throws -> [[String]] {
        if let identifyingKeys { return identifyingKeys }
        let keys = object.kind == .table ? ((try? await client.identifyingKeys(schema: object.schema, table: object.name)) ?? []) : []
        if keys.isEmpty, let columns = try? await client.columns(schema: object.schema, table: object.name) {
            tieBreakers = columns.filter { TablePager.breaksTies(dataType: $0.dataType) }.map(\.name)
        }
        identifyingKeys = keys
        return keys
    }

    /// The Data tab's page as a query in the editor.
    func openPageInEditor() {
        let sql = (pager ?? TablePager(table: object.qualifiedName, keyColumns: identifyingKeys?.first ?? [])).editorSQL
        workspace.openSQL(text: sql + ";", database: object.schema, run: true)
    }

    // MARK: Editing

    /// Prepares an UPDATE for one changed cell and asks for confirmation.
    func proposeEdit(_ request: CellEditRequest, newValue: String?) {
        // The page changed while the editor was open: the row index now names another row.
        guard request.resultID == previewID else {
            return workspace.showToast("The page changed while you edited. Double-click the cell again.", isError: true)
        }
        let row = request.row
        let column = request.column
        guard let plan = editEligibility?.plan, let result = preview.value, result.rows.indices.contains(row) else { return }
        let original = result.rows[row]
        guard column < original.count, original[column] != newValue else { return }
        do {
            let sql = try RowEditor.updateStatement(plan: plan, row: original, changes: [column: newValue])
            pendingEdit = PendingRowEdit(sql: sql, row: row, column: column, newValue: newValue)
        } catch {
            workspace.showToast(describe(error), isError: true)
        }
    }

    func confirmEdit() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        let client = client
        Task {
            do {
                try await client.applyRowEdit(edit.sql)
                workspace.showToast("Row updated")
                reloadPage()
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    // MARK: Shortcuts

    func openQuery() {
        workspace.openSQL(text: "SELECT *\nFROM \(object.qualifiedName)\nLIMIT 100;", database: object.schema, run: true)
    }

    func openExplainOfPreview() {
        workspace.openSQL(text: "EXPLAIN FORMAT=JSON\nSELECT * FROM \(object.qualifiedName) LIMIT 100;", database: object.schema)
    }
}

/// An UPDATE generated from an inline edit, waiting for the user's confirmation.
struct PendingRowEdit: Identifiable, Equatable {
    let id = UUID()
    let sql: String
    let row: Int
    let column: Int
    let newValue: String?
}
