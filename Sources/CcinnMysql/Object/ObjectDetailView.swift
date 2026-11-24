import CcinnMysqlKit
import MySQLKit
import SwiftUI

struct ObjectDetailView: View {
    @Bindable var model: ObjectDetailModel
    @State private var editing: CellEditRequest?

    var body: some View {
        VStack(spacing: 0) {
            ObjectHeader(model: model)
            SectionBar(model: model)
            Divider()
            Group {
                switch model.section {
                case .overview: OverviewSection(model: model)
                case .columns: ColumnsSection(model: model)
                case .indexes: IndexesSection(model: model)
                case .foreignKeys: ForeignKeysSection(model: model)
                case .partitions: PartitionsSection(model: model)
                case .insights: InsightsSection(model: model)
                case .ddl: DDLSection(model: model)
                case .data: DataSection(model: model, editing: $editing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $model.inspected) { ValueInspectorView(value: $0) }
        .sheet(item: $editing) { request in
            CellEditorSheet(request: request) { newValue in model.proposeEdit(request, newValue: newValue) }
        }
        .sheet(item: $model.pendingEdit) { edit in
            ConfirmStatementSheet(title: "Save this change?", message: "CcinnMysql runs the statement in a transaction and commits only if exactly one row matches.",
                                  sql: edit.sql, confirmTitle: "Save Change") { model.confirmEdit() }
        }
    }
}

// MARK: - Header

private struct ObjectHeader: View {
    let model: ObjectDetailModel

    var body: some View {
        let object = model.object
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: Theme.icon(for: object.kind))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.color(for: object.kind))
                .frame(width: 44, height: 44)
                .background(Theme.color(for: object.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(object.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let engine = object.engine, object.kind == .table { EngineBadge(engine: engine) }
                    if object.isPartitioned { Badge(text: "PARTITIONED", color: .teal) }
                }
                HStack(spacing: 6) {
                    Text(object.kind.displayName)
                    Text("·")
                    Text(object.schema)
                    if let detail = object.detail { Text("· \(detail)") }
                    if let comment = object.comment, !comment.isEmpty { Text("· \(comment)").lineLimit(1) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if object.kind.isRelation {
                Button {
                    model.openQuery()
                } label: {
                    Label("Query", systemImage: "play.rectangle")
                }
                .help("Open a SQL editor with SELECT * FROM \(object.name)")
            }
            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload this object's details")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SectionBar: View {
    let model: ObjectDetailModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.availableSections) { section in
                let selected = model.section == section
                Button {
                    model.select(section)
                } label: {
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                        .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Shows loading / error / content for a `Loadable`.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    var retry: (() -> Void)?
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                ErrorBanner(message: message)
                if let retry { Button("Try Again", action: retry) }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(value):
            content(value)
        }
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        let object = model.object
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if object.kind == .table { statTiles }
                if object.kind.isRelation {
                    LoadableView(state: model.detail, retry: model.loadDetail) { detail in
                        VStack(alignment: .leading, spacing: 14) {
                            if let headroom = model.autoIncrement { AutoIncrementCard(headroom: headroom) }
                            let findings = model.findings
                            if !findings.isEmpty { FindingsCard(findings: Array(findings.prefix(4)), more: findings.count - 4) { model.select(.insights) } }
                            HStack(alignment: .top, spacing: 14) {
                                Card(title: "Table", systemImage: "info.circle") { KeyValueList(items: facts(detail)) }
                                Card(title: "Keys", systemImage: "key") { KeyValueList(items: keys(detail), monospacedValues: true) }
                            }
                            if !detail.unavailable.isEmpty {
                                NoticeBanner(message: detail.unavailable.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"), systemImage: "lock")
                            }
                        }
                    }
                } else {
                    Card(title: object.kind.displayName, systemImage: Theme.icon(for: object.kind)) {
                        KeyValueList(items: routineFacts)
                    }
                    LoadableView(state: model.ddl, retry: model.loadDDL) { ddl in
                        Text(ddl).font(Theme.monospacedSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(18)
        }
    }

    private var statTiles: some View {
        let object = model.object
        return HStack(spacing: 12) {
            StatTile(title: "Rows (estimate)", value: Format.count(object.rowCount), systemImage: "number")
            StatTile(title: "Data", value: Format.bytes(object.dataLength), systemImage: "internaldrive")
            StatTile(title: "Indexes", value: Format.bytes(object.indexLength), systemImage: "list.number")
            StatTile(title: "Free", value: Format.bytes(object.dataFree), systemImage: "square.dashed")
        }
    }

    private func facts(_ detail: TableDetail) -> [(String, String)] {
        let object = model.object
        var items: [(String, String)] = [("Kind", object.kind.displayName)]
        if let engine = object.engine { items.append(("Engine", engine)) }
        if let format = object.rowFormat { items.append(("Row format", format)) }
        if let collation = object.collation { items.append(("Collation", collation)) }
        items.append(("Columns", "\(detail.columns.count)"))
        if let next = object.autoIncrement { items.append(("AUTO_INCREMENT", String(next))) }
        if let created = object.createTime { items.append(("Created", created)) }
        if let updated = object.updateTime { items.append(("Updated", updated)) }
        if let options = object.createOptions, !options.isEmpty { items.append(("Options", options)) }
        return items
    }

    private func keys(_ detail: TableDetail) -> [(String, String)] {
        var items: [(String, String)] = []
        if let primary = detail.indexes.first(where: \.isPrimary) {
            items.append(("Primary key", primary.columns.map(\.displayName).joined(separator: ", ")))
        } else {
            items.append(("Primary key", "none"))
        }
        let unique = detail.indexes.filter { $0.isUnique && !$0.isPrimary }
        if !unique.isEmpty { items.append(("Unique", unique.map(\.name).joined(separator: ", "))) }
        items.append(("Indexes", "\(detail.indexes.count)"))
        if !detail.foreignKeys.isEmpty { items.append(("References", Set(detail.foreignKeys.map(\.referencedTable)).sorted().joined(separator: ", "))) }
        if !detail.referencedBy.isEmpty { items.append(("Referenced by", "\(detail.referencedBy.count) foreign key(s)")) }
        if !detail.partitions.isEmpty { items.append(("Partitions", "\(detail.partitions.count) · \(detail.partitions.first?.method ?? "")")) }
        return items
    }

    private var routineFacts: [(String, String)] {
        let object = model.object
        var items: [(String, String)] = []
        if let detail = object.detail { items.append((object.kind == .trigger ? "Table" : object.kind == .event ? "Schedule" : "Returns", detail)) }
        if let status = object.status, !status.isEmpty { items.append(("Characteristics", status)) }
        if let definer = object.definer { items.append(("Definer", definer)) }
        if let created = object.createTime { items.append(("Created", created)) }
        if let updated = object.updateTime { items.append((object.kind == .event ? "Last executed" : "Altered", updated)) }
        return items
    }
}

/// AUTO_INCREMENT headroom gauge.
private struct AutoIncrementCard: View {
    let headroom: AutoIncrementHeadroom

    var body: some View {
        let color: Color = headroom.severity == .critical ? .red : headroom.severity == .warning ? .orange : .green
        Card(title: "AUTO_INCREMENT headroom", systemImage: "gauge.with.dots.needle.33percent") {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: headroom.usedFraction).tint(color)
                HStack {
                    Text("\(headroom.column) · \(headroom.columnType)").font(.callout.weight(.medium))
                    Spacer()
                    Text(String(format: "%.1f%% used", headroom.usedFraction * 100)).foregroundStyle(color).monospacedDigit()
                }
                Text("\(headroom.current.formatted()) of \(headroom.maximum.formatted()) · \(headroom.remaining.formatted()) left")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct FindingsCard: View {
    let findings: [TableFinding]
    let more: Int
    let showAll: () -> Void

    var body: some View {
        Card(title: "Findings", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(findings) { FindingRow(finding: $0) }
                if more > 0 { Button("Show all \(findings.count + more)…", action: showAll).buttonStyle(.link) }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: TableFinding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.color(for: finding.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.callout.weight(.semibold))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Columns, indexes, keys, partitions

private struct ColumnsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.detail, retry: model.loadDetail) { detail in
            Table(detail.columns) {
                TableColumn("#") { Text("\($0.ordinal)").foregroundStyle(.tertiary).monospacedDigit() }
                    .width(32)
                TableColumn("Name") { column in
                    HStack(spacing: 5) {
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill").foregroundStyle(.orange).imageScale(.small).help("Primary key")
                        } else if column.isKey {
                            Image(systemName: "key").foregroundStyle(.secondary).imageScale(.small).help(column.columnKey == "UNI" ? "Unique" : "Indexed")
                        }
                        Text(column.name).font(.body.weight(column.isPrimaryKey ? .semibold : .regular)).textSelection(.enabled)
                    }
                }
                .width(min: 120, ideal: 190)
                TableColumn("Type") { Text($0.columnType).font(Theme.monospacedSmall).foregroundStyle(Color(nsColor: .syntaxKeyword)) }
                    .width(min: 90, ideal: 150)
                TableColumn("Null") { Text($0.isNullable ? "YES" : "NO").foregroundStyle($0.isNullable ? .secondary : .primary) }
                    .width(44)
                TableColumn("Default") { Text($0.defaultValue ?? ($0.isNullable ? "NULL" : "")).font(Theme.monospacedSmall).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 110)
                TableColumn("Extra") { Text($0.generationExpression.map { "AS (\($0))" } ?? $0.extra).font(.caption).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 130)
                TableColumn("Collation") { Text($0.collation ?? "").font(.caption).foregroundStyle(.tertiary) }
                    .width(min: 60, ideal: 120)
                TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }
}

private struct IndexesSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.detail, retry: model.loadDetail) { detail in
            let findings = Dictionary(TableInsights.redundantIndexes(detail.indexes).map { ($0.title.components(separatedBy: " ").last ?? "", $0) },
                                      uniquingKeysWith: { first, _ in first })
            Table(detail.indexes) {
                TableColumn("Name") { index in
                    HStack(spacing: 5) {
                        Image(systemName: index.isPrimary ? "key.fill" : index.isUnique ? "checkmark.seal" : "list.number")
                            .foregroundStyle(index.isPrimary ? .orange : .secondary).imageScale(.small)
                        Text(index.name).font(.body.weight(index.isPrimary ? .semibold : .regular)).textSelection(.enabled)
                        if !index.isVisible { Badge(text: "INVISIBLE", color: .orange) }
                        if let finding = findings[index.name] { Badge(text: finding.kind == .duplicateIndex ? "DUPLICATE" : "REDUNDANT", color: .orange).help(finding.detail) }
                    }
                }
                .width(min: 140, ideal: 220)
                TableColumn("Columns") { index in
                    Text(index.columns.map(\.displayName).joined(separator: ", ")).font(Theme.monospacedSmall).textSelection(.enabled)
                }
                .width(min: 140, ideal: 260)
                TableColumn("Unique") { Text($0.isUnique ? "YES" : "").foregroundStyle(.secondary) }.width(52)
                TableColumn("Type") { Text($0.type).font(.caption).foregroundStyle(.secondary) }.width(70)
                TableColumn("Cardinality") { index in
                    Text(index.columns.map { $0.cardinality.map { Format.count($0) } ?? "—" }.joined(separator: " → "))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Cardinality of each key prefix")
                }
                .width(min: 90, ideal: 160)
                TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary) }
            }
        }
    }
}

private struct ForeignKeysSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.detail, retry: model.loadDetail) { detail in
            VStack(alignment: .leading, spacing: 0) {
                if detail.foreignKeys.isEmpty, detail.referencedBy.isEmpty {
                    ContentUnavailableView("No foreign keys", systemImage: "link", description: Text("This table neither references nor is referenced by other tables."))
                } else {
                    ForeignKeyTable(title: "References", keys: detail.foreignKeys)
                    Divider()
                    ForeignKeyTable(title: "Referenced by", keys: detail.referencedBy)
                }
            }
        }
    }
}

private struct ForeignKeyTable: View {
    let title: String
    let keys: [ForeignKeyInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(keys.count)").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.top, 8)
            Table(keys) {
                TableColumn("Constraint") { Text($0.name).textSelection(.enabled) }.width(min: 120, ideal: 200)
                TableColumn("Columns") { Text($0.columns.joined(separator: ", ")).font(Theme.monospacedSmall) }.width(min: 90, ideal: 150)
                TableColumn("References") { key in
                    Text("\(key.referencedSchema).\(key.referencedTable) (\(key.referencedColumns.joined(separator: ", ")))").font(Theme.monospacedSmall)
                }
                .width(min: 160, ideal: 260)
                TableColumn("On update") { Text($0.onUpdate).font(.caption) }.width(80)
                TableColumn("On delete") { Text($0.onDelete).font(.caption).foregroundStyle($0.onDelete == "CASCADE" ? .orange : .primary) }.width(80)
            }
        }
    }
}

private struct PartitionsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.detail, retry: model.loadDetail) { detail in
            let largest = detail.partitions.compactMap(\.dataLength).max() ?? 0
            Table(detail.partitions) {
                TableColumn("#") { Text("\($0.ordinal)").foregroundStyle(.tertiary).monospacedDigit() }.width(32)
                TableColumn("Partition") { partition in
                    Text(partition.subpartition.map { "\(partition.name) / \($0)" } ?? partition.name).textSelection(.enabled)
                }
                .width(min: 100, ideal: 160)
                TableColumn("Method") { Text($0.method ?? "").font(.caption) }.width(80)
                TableColumn("Bound") { Text($0.bound ?? "").font(Theme.monospacedSmall).foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                TableColumn("Rows") { Text(Format.count($0.rowCount)).monospacedDigit() }.width(90)
                TableColumn("Data") { partition in
                    HStack(spacing: 6) {
                        ProgressView(value: largest > 0 ? Double(partition.dataLength ?? 0) / Double(largest) : 0).frame(width: 60)
                        Text(Format.bytes(partition.dataLength)).monospacedDigit()
                    }
                }
                .width(min: 120, ideal: 150)
                TableColumn("Index") { Text(Format.bytes($0.indexLength)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
            }
        }
    }
}

private struct InsightsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.detail, retry: model.loadDetail) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let headroom = model.autoIncrement { AutoIncrementCard(headroom: headroom) }
                    let findings = model.findings
                    if findings.isEmpty {
                        NoticeBanner(message: "No problems found: the table has a primary key, no redundant indexes and enough AUTO_INCREMENT headroom.",
                                     systemImage: "checkmark.seal", color: .green)
                    } else {
                        Card(title: "Findings · \(findings.count)", systemImage: "stethoscope") {
                            VStack(alignment: .leading, spacing: 10) { ForEach(findings) { FindingRow(finding: $0) } }
                        }
                    }
                    Card(title: "Plan check", systemImage: "list.bullet.indent") {
                        HStack {
                            Text("See how MySQL reads this table").foregroundStyle(.secondary)
                            Spacer()
                            Button("Explain SELECT *") { model.openExplainOfPreview() }
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - DDL and data

private struct DDLSection: View {
    let model: ObjectDetailModel
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        LoadableView(state: model.ddl, retry: model.loadDDL) { ddl in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        Pasteboard.copy(ddl)
                        model.workspace.showToast("DDL copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.workspace.openSQL(text: ddl, database: model.object.schema)
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                SQLEditor(text: .constant(ddl), selection: $selection, isEditable: false, highlightsCurrentStatement: false)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct DataSection: View {
    let model: ObjectDetailModel
    @Binding var editing: CellEditRequest?

    var body: some View {
        LoadableView(state: model.preview, retry: model.loadPreview) { result in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(position(result)).font(.callout.weight(.semibold)).monospacedDigit()
                    switch model.editEligibility {
                    case .editable?:
                        Label("Double-click a cell to edit", systemImage: "pencil").font(.caption).foregroundStyle(.secondary)
                    case let .readOnly(reason)?:
                        Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary).help(reason)
                    case nil:
                        EmptyView()
                    }
                    Spacer()
                    if model.isLoadingPage { ProgressView().controlSize(.small) }
                    pageButtons
                    Divider().frame(height: 16)
                    Button {
                        model.reloadPage()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.openPageInEditor()
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                    .help("Open this page's query in a SQL tab")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                let plan = model.editEligibility?.plan
                ResultGrid(resultID: model.previewID, columns: result.columns, rows: result.rows,
                           insertTableName: model.object.qualifiedName, onInspect: { model.inspected = $0 },
                           editableColumns: plan?.editableColumns ?? [], onEdit: plan == nil ? nil : { editing = $0 },
                           serverSort: serverSort(result), rowNumberOffset: (model.pager?.firstRow ?? 1) - 1)
            }
        }
    }

    private var pageButtons: some View {
        HStack(spacing: 4) {
            Button {
                model.firstPage()
            } label: {
                Image(systemName: "chevron.left.to.line")
            }
            .help("First page")
            .disabled(!(model.pager?.hasPrevious ?? false))
            Button {
                model.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous \(model.pager?.pageSize ?? 200) rows")
            .disabled(!(model.pager?.hasPrevious ?? false))
            Button {
                model.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next \(model.pager?.pageSize ?? 200) rows")
            .disabled(!(model.pager?.hasNext ?? false))
        }
        .disabled(model.isLoadingPage)
    }

    private func position(_ result: ResultSet) -> String {
        guard let pager = model.pager else { return "\(Format.count(result.rows.count)) rows" }
        return pager.position(rowsOnPage: result.rows.count, estimatedTotal: model.object.kind == .table ? model.object.rowCount : nil)
    }

    /// Header clicks sort on the server; the arrow shows the server's sort.
    private func serverSort(_ result: ResultSet) -> ResultGrid.ServerSort {
        let sort = model.pager?.sort
        let column = sort.flatMap { sort in result.columns.firstIndex { $0.name.caseInsensitiveCompare(sort.column) == .orderedSame } }
        return ResultGrid.ServerSort(column: column, ascending: sort?.ascending ?? true) { request in
            model.sortPreview(by: request.flatMap { request in
                result.columns.indices.contains(request.column)
                    ? TablePager.Sort(column: result.columns[request.column].name, ascending: request.ascending) : nil
            })
        }
    }
}

// MARK: - Editing sheets

/// Edits one cell value (or sets it to NULL).
struct CellEditorSheet: View {
    let request: CellEditRequest
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isNull: Bool

    init(request: CellEditRequest, save: @escaping (String?) -> Void) {
        self.request = request
        self.save = save
        _text = State(initialValue: request.value ?? "")
        _isNull = State(initialValue: request.value == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(request.columnName)").font(.headline)
            TextEditor(text: $text)
                .font(Theme.monospaced)
                .frame(minHeight: 120)
                .disabled(isNull)
                .opacity(isNull ? 0.4 : 1)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Toggle("NULL", isOn: $isNull).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review Change…") {
                    dismiss()
                    save(isNull ? nil : text)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

/// Shows a generated statement and asks before running it.
struct ConfirmStatementSheet: View {
    let title: String
    let message: String
    let sql: String
    let confirmTitle: String
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(sql).font(Theme.monospacedSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(minHeight: 70, maxHeight: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button { Pasteboard.copy(sql) } label: { Label("Copy SQL", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    dismiss()
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}
