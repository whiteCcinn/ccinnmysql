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

    func loadPreview() {
        let object = object
        let token = generation
        run({ [weak self] state in
            self?.preview = state
            self?.previewID = UUID()
        }) {
            let result = try await self.client.preview(object, limit: 200)
            if object.kind == .table {
                let keys = (try? await self.client.identifyingKeys(schema: object.schema, table: object.name)) ?? []
                if token == self.generation {
                    self.editEligibility = RowEditor.eligibility(columns: result.columns, keys: keys, isBaseTable: true)
                }
            } else {
                self.editEligibility = .readOnly("Only base tables can be edited.")
            }
            return result
        }
    }

    // MARK: Editing

    /// Prepares an UPDATE for one changed cell and asks for confirmation.
    func proposeEdit(row: Int, column: Int, newValue: String?) {
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
                generation &+= 1
                loadPreview()
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
