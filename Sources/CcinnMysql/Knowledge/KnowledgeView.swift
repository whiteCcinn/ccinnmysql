import AppKit
import CcinnMysqlKit
import SwiftUI

/// The Knowledge tab of a database: linked code projects, build, relationships, tables, notes and a diagram.
struct KnowledgeView: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        VStack(spacing: 0) {
            KnowledgeHeader(model: model)
            Divider()
            if let error = model.loadError {
                KnowledgeErrorBanner(message: error, canReset: model.loadErrorIsDamage) { model.reset() }
                Divider()
            }
            if !model.isSavedConnection {
                Label("This connection is not saved. Its knowledge base cannot be found again after you disconnect, and AI assistants only see saved connections: save the connection to keep it.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            HStack(spacing: 0) {
                KnowledgeSidePanel(model: model)
                    .frame(width: 280)
                Divider()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Picker("Section", selection: $model.section) {
                            ForEach(KnowledgeModel.Section.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        TextField("Filter", text: $model.searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                    }
                    .padding(10)
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { model.reload() }
    }

    @ViewBuilder private var content: some View {
        if model.knowledge?.snapshot == nil {
            KnowledgeEmptyState(model: model)
        } else {
            switch model.section {
            case .relationships: RelationshipsSection(model: model)
            case .tables: TablesSection(model: model)
            case .notes: NotesSection(model: model)
            case .diagram: DiagramSection(model: model)
            }
        }
    }
}

// MARK: - Header

private struct KnowledgeHeader: View {
    let model: KnowledgeModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Knowledge · \(model.database)").font(.headline)
                summary.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBuilding {
                if let fraction = model.buildFraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(model.buildStatus ?? "Building…").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { model.cancelBuild() }
            } else {
                Menu {
                    Button("Rebuild Schema Only") { model.build(scanCode: false) }
                        .disabled(model.knowledge?.snapshot == nil)
                } label: {
                    Label(model.knowledge?.snapshot == nil ? "Build" : "Rebuild", systemImage: "hammer")
                } primaryAction: {
                    model.build()
                }
                .fixedSize()
                .help("Read the schema (metadata only, no rows), find relationships in definitions and linked code, and keep all notes")
            }
            Menu {
                Button("Copy Mermaid ER Diagram") { model.copyMermaid() }
                Button("Export Markdown…") { model.exportMarkdown() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(model.graph?.tableNames.isEmpty != false)
        }
        .padding(12)
    }

    private var summary: Text {
        guard let knowledge = model.knowledge, let build = knowledge.build, let graph = model.graph else {
            return Text("Not built yet. Building reads metadata only; AI assistants use the result through the MCP server.")
        }
        let tables = graph.tables.values.filter { $0.kind == .table }.count
        let declared = graph.edges.filter(\.relationship.isDeclared).count
        return Text("Built ") + Text(build.builtAt, style: .relative) + Text(" ago · \(tables) tables · \(graph.tables.count - tables) views · \(graph.edges.count) relationships (\(declared) declared) · \(knowledge.notes.count) notes")
    }
}

private struct KnowledgeErrorBanner: View {
    let message: String
    let canReset: Bool
    let reset: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Spacer()
            if canReset {
                Button("Reset…") { confirming = true }
                    .help("Move the damaged file aside (it is kept) and start a new knowledge base")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.06))
        .confirmationDialog("Start a new knowledge base?", isPresented: $confirming) {
            Button("Move the Damaged File Aside and Start Over", role: .destructive, action: reset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The damaged file is kept next to it (….corrupt-<date>). Notes and verdicts in it are not carried over.")
        }
    }
}

private struct KnowledgeEmptyState: View {
    let model: KnowledgeModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("No knowledge of \(model.database) yet").font(.title3.weight(.semibold))
            Text("A build reads the schema (metadata only), declared foreign keys, view and routine definitions and the code folders you link, and maps how the tables relate. AI assistants connected through the MCP server then answer questions from it, and add notes about what they verify.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack {
                Button { model.linkProjects() } label: { Label("Link Code Folder…", systemImage: "folder.badge.plus") }
                Button { model.build() } label: { Label("Build", systemImage: "hammer") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBuilding)
            }
        }
        .padding(30)
    }
}

// MARK: - Side panel

private struct KnowledgeSidePanel: View {
    let model: KnowledgeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Linked code").font(.headline)
                Text("Folders whose code uses this database. Builds find joins and table uses there; only names, relative paths and line numbers are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.knowledge?.projects ?? []) { project in
                    ProjectRow(project: project, scan: model.knowledge?.build?.projects.first { $0.projectID == project.id },
                               stale: model.staleProjects.contains(project.id), missing: model.missingProjects.contains(project.id),
                               locate: { model.relocate(project) }, unlink: { model.unlink(project) })
                }
                Button { model.linkProjects() } label: { Label("Link Folder…", systemImage: "folder.badge.plus") }
                if let knowledge = model.knowledge, let graph = model.graph, knowledge.snapshot != nil {
                    Divider()
                    KnowledgeStats(knowledge: knowledge, graph: graph) { model.deleteOrphans() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProjectRow: View {
    let project: LinkedProject
    let scan: ProjectScan?
    let stale: Bool
    let missing: Bool
    let locate: () -> Void
    let unlink: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.callout.weight(.medium))
                Text(project.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.path)
                HStack(spacing: 4) {
                    if let scan {
                        Text("\(Format.count(scan.files)) files" + (scan.commit.map { " · \($0.prefix(7))" } ?? ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if scan.truncated { Badge(text: "limit reached", color: .orange) }
                        if let error = scan.error { Badge(text: "error", color: .red).help(error) }
                    }
                    if missing {
                        Badge(text: "missing", color: .red).help("This folder does not exist on this Mac")
                    } else if stale {
                        Badge(text: scan == nil ? "not scanned" : "changed", color: .orange).help("Rebuild to scan the current code")
                    }
                }
                if missing {
                    Button("Locate…", action: locate)
                        .controlSize(.small)
                        .help("Choose where this folder is now; its name and the evidence that cites it are kept")
                }
            }
            Spacer(minLength: 0)
            Button(action: unlink) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Unlink this folder and forget what was found in it")
        }
    }
}

private struct KnowledgeStats: View {
    let knowledge: KnowledgeBase
    let graph: KnowledgeGraph
    let deleteOrphans: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relationships").font(.headline)
            let counts = Dictionary(grouping: graph.edges.flatMap(\.relationship.sources), by: { $0 }).mapValues(\.count)
            ForEach(RelationshipSource.allCases, id: \.self) { source in
                if let count = counts[source] {
                    HStack {
                        SourceBadge(source: source)
                        Spacer()
                        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            if !graph.rejected.isEmpty {
                Text("\(graph.rejected.count) rejected").font(.caption).foregroundStyle(.secondary)
            }
            if let changes = knowledge.build?.changes, !changes.isEmpty {
                Divider()
                Text("Since the previous build").font(.headline)
                Text([changes.added.isEmpty ? nil : "Added: \(changes.added.prefix(8).joined(separator: ", "))",
                      changes.removed.isEmpty ? nil : "Removed: \(changes.removed.prefix(8).joined(separator: ", "))",
                      changes.changed.isEmpty ? nil : "Changed: \(changes.changed.prefix(8).joined(separator: ", "))"]
                    .compactMap { $0 }.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let warnings = knowledge.build?.warnings, !warnings.isEmpty {
                Divider()
                Label(warnings.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let orphans = knowledge.orphanedNotes
            if !orphans.isEmpty {
                Divider()
                Text("\(orphans.count) note(s) refer to tables or columns that no longer exist.").font(.caption).foregroundStyle(.secondary)
                    .help(orphans.joined(separator: "\n"))
                Button("Delete Outdated Notes", action: deleteOrphans).controlSize(.small)
            }
        }
    }
}

struct SourceBadge: View {
    let source: RelationshipSource

    var body: some View {
        Badge(text: source.rawValue, color: color)
    }

    private var color: Color {
        switch source {
        case .declared: .green
        case .user: .blue
        case .view, .routine: .teal
        case .code: .purple
        case .ai: .pink
        case .naming: .orange
        }
    }
}

// MARK: - Relationships

private struct RelationshipsSection: View {
    @Bindable var model: KnowledgeModel
    @State private var selection: Set<String> = []
    @State private var rejecting: KnowledgeGraph.Edge?
    @State private var reason = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $model.filter) {
                    ForEach(KnowledgeModel.RelationshipFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("\(model.visibleEdges.count) shown").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Table(model.visibleEdges, selection: $selection) {
                TableColumn("From") { edge in
                    Text(edge.relationship.from.label).font(Theme.monospacedSmall).help(edge.relationship.from.label)
                }
                TableColumn("To") { edge in
                    Text(edge.relationship.to.label).font(Theme.monospacedSmall).help(edge.relationship.to.label)
                }
                TableColumn("Kind") { edge in Text(Self.cardinality(edge.cardinality)).font(.caption) }
                    .width(min: 70, ideal: 90, max: 110)
                TableColumn("Sources") { edge in
                    HStack(spacing: 3) { ForEach(edge.relationship.sources, id: \.self) { SourceBadge(source: $0) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                        .help(edge.relationship.sources.map(\.rawValue).joined(separator: ", "))
                }
                .width(min: 120, ideal: 250)
                TableColumn("Confidence") { edge in Text("\(Int((edge.confidence * 100).rounded()))%").monospacedDigit() }
                    .width(min: 70, ideal: 80, max: 90)
                TableColumn("Verdict") { edge in
                    if let verdict = edge.verdict {
                        Text("\(verdict.status.rawValue) (\(verdict.author == .ai ? "AI" : "you"))")
                            .font(.caption)
                            .foregroundStyle(verdict.status == .rejected ? Color.red : Color.green)
                            .help(verdict.reason ?? "")
                    }
                }
                .width(min: 90, ideal: 120, max: 160)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let edge = edge(id) {
                    if !edge.relationship.isDeclared {
                        Button("Confirm") { model.setVerdict(edge, .confirmed) }
                        Button("Reject…") {
                            reason = ""
                            rejecting = edge
                        }
                        if edge.verdict != nil { Button("Clear Verdict") { model.setVerdict(edge, .cleared) } }
                    }
                    if model.knowledge?.notes.relationships[edge.id] != nil {
                        Divider()
                        Button("Remove Added Relationship") { model.removeAdded(edge) }
                    }
                    Divider()
                    Button("Copy Join Condition") { Pasteboard.copy(Self.join(edge)) }
                }
            }
            if let id = selection.first, let edge = edge(id) {
                Divider()
                EvidencePanel(edge: edge, projects: model.knowledge?.projects ?? [])
            }
        }
        .alert("Reject this relationship?", isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } })) {
            TextField("Why is it wrong?", text: $reason)
            Button("Reject", role: .destructive) {
                if let edge = rejecting { model.setVerdict(edge, .rejected, reason: reason.isEmpty ? "Rejected in CcinnMysql" : reason) }
                rejecting = nil
            }
            Button("Cancel", role: .cancel) { rejecting = nil }
        } message: {
            Text("\(rejecting.map { "\($0.relationship.from.label) → \($0.relationship.to.label)" } ?? "")\nJoin paths will no longer use it, also after rebuilds.")
        }
    }

    private func edge(_ id: String) -> KnowledgeGraph.Edge? {
        model.graph.flatMap { graph in graph.edges.first { $0.id == id } ?? graph.rejected.first { $0.id == id } }
    }

    static func cardinality(_ value: RelationshipCardinality) -> String {
        switch value {
        case .manyToOne: "many → one"
        case .oneToOne: "one → one"
        case .unknown: "related"
        }
    }

    static func join(_ edge: KnowledgeGraph.Edge) -> String {
        let relationship = edge.relationship
        return zip(relationship.from.columns, relationship.to.columns)
            .map { "\(relationship.from.table).\($0) = \(relationship.to.table).\($1)" }
            .joined(separator: " AND ")
    }
}

private struct EvidencePanel: View {
    let edge: KnowledgeGraph.Edge
    let projects: [LinkedProject]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Evidence").font(.caption.weight(.semibold))
            ForEach(Array(edge.relationship.evidence.enumerated()), id: \.offset) { _, evidence in
                HStack(spacing: 6) {
                    Text(evidence.label).font(Theme.monospacedSmall).textSelection(.enabled)
                    if let url = fileURL(evidence) {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            if let note = edge.note { Text("Note: \(note)").font(.caption) }
            if let reason = edge.verdict?.reason { Text("Verdict: \(reason)").font(.caption).foregroundStyle(.secondary) }
            if edge.relationship.occurrences > 1 {
                Text("Seen \(edge.relationship.occurrences) times in definitions and code").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private func fileURL(_ evidence: KnowledgeEvidence) -> URL? {
        guard evidence.kind == .code, let path = evidence.path, let project = projects.first(where: { $0.name == evidence.project }) else { return nil }
        return URL(fileURLWithPath: project.path, isDirectory: true).appendingPathComponent(path)
    }
}

// MARK: - Tables

private struct TablesSection: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        HSplitView {
            List(model.visibleTables, id: \.name, selection: $model.selectedTable) { table in
                HStack(spacing: 6) {
                    Image(systemName: table.kind == .view ? "eye" : "tablecells").foregroundStyle(.secondary)
                    Text(table.name).lineLimit(1)
                    Spacer()
                    if model.graph?.notes.tables[table.name] != nil { Image(systemName: "note.text").foregroundStyle(.secondary) }
                }
                .tag(table.name)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
            Group {
                if let name = model.selectedTable, let graph = model.graph, let context = graph.context(for: name) {
                    TableDetailPane(model: model, context: context)
                        .id(name)
                } else {
                    Text("Select a table").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TableDetailPane: View {
    let model: KnowledgeModel
    let context: KnowledgeGraph.TableContext
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(context.table.name).font(.title3.weight(.semibold))
                    Badge(text: context.table.kind.rawValue)
                    if let engine = context.table.engine { EngineBadge(engine: engine) }
                    Spacer()
                    if let rows = context.table.rowsEstimate { Text("≈ \(Format.count(Int(clamping: rows))) rows").foregroundStyle(.secondary) }
                }
                if let comment = context.table.comment { Text(comment).foregroundStyle(.secondary).textSelection(.enabled) }
                noteEditor
                columns
                relationships
                references
            }
            .padding(14)
        }
        .onAppear { draft = context.note?.summary ?? "" }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Purpose").font(.headline)
                if let note = context.note {
                    Text("by \(note.author == .ai ? "AI" : "you"), ") .font(.caption).foregroundStyle(.secondary)
                        + Text(note.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            HStack {
                Button("Save Note") { model.saveTableNote(context.table.name, summary: draft) }
                    .disabled(draft == (context.note?.summary ?? ""))
                if context.note != nil { Button("Delete", role: .destructive) { model.deleteTableNote(context.table.name) } }
            }
            .controlSize(.small)
        }
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Columns").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(context.table.columns, id: \.name) { column in
                    GridRow {
                        Text(column.name).font(Theme.monospacedSmall.weight(context.table.primaryKey.contains(column.name) ? .bold : .regular))
                        Text(column.type).font(Theme.monospacedSmall).foregroundStyle(.secondary)
                        Text(meaning(column)).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func meaning(_ column: KnowledgeColumn) -> String {
        var parts: [String] = []
        if let comment = column.comment { parts.append(comment) }
        if let note = context.columnNotes[column.name] {
            if let text = note.note { parts.append(text + (note.author == .ai ? " (AI)" : "")) }
            if !note.values.isEmpty {
                parts.append(note.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { "\($0.key) = \($0.value)" }.joined(separator: ", "))
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var relationships: some View {
        if !context.edges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Relationships").font(.headline)
                ForEach(context.edges) { edge in
                    HStack(spacing: 6) {
                        Text("\(edge.relationship.from.label) → \(edge.relationship.to.label)").font(Theme.monospacedSmall).textSelection(.enabled)
                        ForEach(edge.relationship.sources, id: \.self) { SourceBadge(source: $0) }
                        Text("\(Int((edge.confidence * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var references: some View {
        if !context.references.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Used in code").font(.headline)
                ForEach(Array(context.references.enumerated()), id: \.offset) { _, reference in
                    HStack(spacing: 6) {
                        Text("\(reference.project): \(reference.path):\(reference.line)").font(Theme.monospacedSmall).textSelection(.enabled)
                        Text(reference.sql ? "SQL × \(reference.count)" : "name × \(reference.count)").font(.caption).foregroundStyle(.secondary)
                        if let project = model.knowledge?.projects.first(where: { $0.name == reference.project }) {
                            Button("Reveal") {
                                let url = URL(fileURLWithPath: project.path, isDirectory: true).appendingPathComponent(reference.path)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Notes

private struct NotesSection: View {
    let model: KnowledgeModel

    var body: some View {
        let notes = model.knowledge?.notes ?? KnowledgeNotes()
        List {
            Section("Table notes") {
                if notes.tables.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(notes.tables.keys.sorted(), id: \.self) { table in
                    if let note = notes.tables[table] {
                        NoteRow(title: table, text: note.summary, author: note.author, date: note.updatedAt) { model.deleteTableNote(table) }
                    }
                }
            }
            Section("Column notes") {
                if notes.columns.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(notes.columns.keys.sorted(), id: \.self) { table in
                    ForEach((notes.columns[table] ?? [:]).keys.sorted(), id: \.self) { column in
                        if let note = notes.columns[table]?[column] {
                            let values = note.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { "\($0.key) = \($0.value)" }
                            NoteRow(title: "\(table).\(column)", text: ([note.note].compactMap { $0 } + values).joined(separator: " · "),
                                    author: note.author, date: note.updatedAt) { model.deleteColumnNote(table, column) }
                        }
                    }
                }
            }
            Section("Glossary") {
                if notes.glossary.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(notes.glossary.values.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }, id: \.term) { term in
                    NoteRow(title: term.term, text: term.definition + (term.sql.map { "\n\($0)" } ?? ""), author: term.author, date: term.updatedAt) {
                        model.deleteTerm(term)
                    }
                }
            }
        }
    }
}

private struct NoteRow: View {
    let title: String
    let text: String
    let author: KnowledgeAuthor
    let date: Date
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.monospacedSmall.weight(.semibold))
                    Badge(text: author == .ai ? "AI" : "you", color: author == .ai ? .pink : .blue)
                    Text(date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(text).font(.callout).textSelection(.enabled)
            }
            Spacer()
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Diagram

private struct DiagramSection: View {
    @Bindable var model: KnowledgeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let graph = model.graph {
                    Picker("Table", selection: Binding(get: { center(graph) ?? "" }, set: { model.selectedTable = $0 })) {
                        ForEach(graph.tablesByDegree, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 320)
                }
                Spacer()
                Button("Copy Mermaid for This Neighbourhood") {
                    if let graph = model.graph, let center = center(graph) { model.copyMermaid(focus: [center]) }
                }
            }
            .padding(10)
            Divider()
            if let graph = model.graph, let center = center(graph) {
                NeighbourhoodDiagram(graph: graph, center: center) { model.selectedTable = $0 }
                    .padding(20)
            } else {
                Text("No tables").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Solid: declared or confirmed · dashed: inferred. Click a table to centre it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func center(_ graph: KnowledgeGraph) -> String? {
        if let selected = model.selectedTable, graph.tables[selected] != nil { return selected }
        return graph.tablesByDegree.first
    }
}

/// A table in the centre and its neighbours on a ring (at most 24), with relationship lines.
private struct NeighbourhoodDiagram: View {
    let graph: KnowledgeGraph
    let center: String
    let select: (String) -> Void

    private struct Neighbour: Identifiable {
        let table: String
        let label: String
        let solid: Bool
        var id: String { table }
    }

    private var neighbours: [Neighbour] {
        var seen = Set<String>()
        var result: [Neighbour] = []
        for edge in graph.edges(of: center) {
            let other = edge.relationship.from.table == center ? edge.relationship.to.table : edge.relationship.from.table
            guard other != center, seen.insert(other).inserted else { continue }
            let label = edge.relationship.from.columns.joined(separator: ", ") + " → " + edge.relationship.to.columns.joined(separator: ", ")
            result.append(Neighbour(table: other, label: label, solid: edge.isSolid))
            if result.count == 24 { break }
        }
        return result
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(80, min(size.width, size.height) / 2 - 50)
            let items = neighbours
            let points = items.indices.map { index -> CGPoint in
                let angle = Double(index) / Double(max(items.count, 1)) * 2 * .pi - .pi / 2
                return CGPoint(x: middle.x + radius * cos(angle), y: middle.y + radius * sin(angle))
            }
            ZStack {
                Canvas { context, _ in
                    for (index, item) in items.enumerated() {
                        var path = Path()
                        path.move(to: middle)
                        path.addLine(to: points[index])
                        context.stroke(path, with: .color(.secondary.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 1.2, dash: item.solid ? [] : [5, 4]))
                    }
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .background(.background.opacity(0.8))
                        .position(x: (middle.x + points[index].x) / 2, y: (middle.y + points[index].y) / 2)
                    Button { select(item.table) } label: { node(item.table, emphasized: false) }
                        .buttonStyle(.plain)
                        .position(points[index])
                }
                node(center, emphasized: true).position(middle)
                if items.isEmpty {
                    Text("No known relationships").font(.caption).foregroundStyle(.secondary).position(x: middle.x, y: middle.y + 40)
                }
            }
        }
    }

    private func node(_ table: String, emphasized: Bool) -> some View {
        Text(table)
            .font(emphasized ? .callout.weight(.semibold) : .caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background((emphasized ? Theme.accent.opacity(0.18) : Color.secondary.opacity(0.1)), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(emphasized ? Theme.accent : Color.secondary.opacity(0.4)))
            .fixedSize()
    }
}
