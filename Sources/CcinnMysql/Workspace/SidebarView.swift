import CcinnMysqlKit
import MySQLKit
import SwiftUI

/// Schema → objects, grouped as tables by storage engine, views, procedures, functions, triggers and events,
/// with engine badges, row estimates, filtering and context actions.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            List(selection: $workspace.sidebarSelection) {
                if let error = workspace.databasesError {
                    ErrorBanner(message: error).listRowSeparator(.hidden)
                }
                ForEach(visibleDatabases, id: \.self) { database in
                    DatabaseRow(workspace: workspace, database: database, filter: filter)
                }
                if workspace.isLoadingDatabases, workspace.databases.isEmpty {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: workspace.sidebarSelection) { _, id in
                guard let id, let object = findObject(id) else { return }
                workspace.openObject(object)
            }
        }
        .placedBelowWindowToolbar()
    }

    private var filter: String { workspace.sidebarFilter.trimmingCharacters(in: .whitespaces) }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter schemas and objects", text: $workspace.sidebarFilter)
                    .textFieldStyle(.plain)
                if !workspace.sidebarFilter.isEmpty {
                    Button { workspace.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            Toggle("Show system schemas", isOn: $workspace.showSystemSchemas)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var visibleDatabases: [String] {
        let all = workspace.schemas.filter { workspace.showSystemSchemas || !$0.isSystem || workspace.expandedDatabases.contains($0.name) }.map(\.name)
        guard !filter.isEmpty else { return all }
        return all.filter { database in
            database.localizedCaseInsensitiveContains(filter)
                || (workspace.objects(in: database)?.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false)
        }
    }

    private func findObject(_ id: String) -> DatabaseObject? {
        for database in workspace.expandedDatabases {
            if let object = workspace.objects(in: database)?.first(where: { $0.id == id }) { return object }
        }
        return nil
    }
}

private struct DatabaseRow: View {
    let workspace: WorkspaceModel
    let database: String
    let filter: String

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { workspace.expandedDatabases.contains(database) || (!filter.isEmpty && hasMatches) },
                                            set: { workspace.setExpanded(database, $0) })) {
            content
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSystem ? "cylinder.split.1x2" : "cylinder")
                    .foregroundStyle(isSystem ? Color.secondary : Color.teal)
                Text(database).lineLimit(1)
                Spacer()
                if let count = workspace.objects(in: database)?.count {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
                Button("New Query") { workspace.openSQL(database: database) }
                Button("Refresh") { workspace.loadObjects(database: database, force: true) }
                Divider()
                Button("Top Statements") { workspace.openServer(section: .statements) }
                Button("Knowledge Base") { workspace.openKnowledge(database: database) }
                Divider()
                Button("Copy Name") { Pasteboard.copy(database) }
            }
        }
    }

    private var isSystem: Bool { SchemaInfo.systemSchemas.contains(database.lowercased()) }

    private var hasMatches: Bool {
        workspace.objects(in: database)?.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.databaseStates[database] {
        case nil, .loading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { workspace.loadObjects(database: database, force: true) }.buttonStyle(.link).font(.caption)
            }
        case let .loaded(listing)?:
            let objects = listing.objects
            let shown = filter.isEmpty ? objects : objects.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            if shown.isEmpty {
                Text(filter.isEmpty ? "No objects" : "No matches").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(listing.unavailable.keys.sorted(), id: \.self) { group in
                Label("\(group) unavailable", systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(listing.unavailable[group] ?? "")
                    .selectionDisabled()
            }
            ForEach(groups(shown), id: \.title) { group in
                Text("\(group.title.uppercased())  \(group.objects.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .selectionDisabled()
                ForEach(group.objects) { object in
                    ObjectRow(object: object, workspace: workspace)
                        .tag(object.id)
                }
            }
        }
    }

    /// Tables per engine (InnoDB first), then views, sequences, procedures, functions, triggers, events.
    private func groups(_ objects: [DatabaseObject]) -> [(title: String, objects: [DatabaseObject])] {
        let listing = SchemaObjects(objects: objects)
        var groups = listing.tablesByEngine.map { (title: "\($0.engine) tables", objects: $0.tables) }
        let kinds: [(ObjectKind, String)] = [(.view, "Views"), (.systemView, "System views"), (.sequence, "Sequences"), (.procedure, "Procedures"),
                                             (.function, "Functions"), (.trigger, "Triggers"), (.event, "Events")]
        for (kind, title) in kinds {
            let members = listing.objects(of: kind)
            if !members.isEmpty { groups.append((title, members)) }
        }
        return groups
    }
}

private struct ObjectRow: View {
    let object: DatabaseObject
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            ObjectIcon(kind: object.kind)
            Text(object.name).lineLimit(1).truncationMode(.middle)
            if object.isPartitioned { Badge(text: "PART", color: .teal) }
            if object.kind == .trigger, let table = object.detail {
                Text("on \(table)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            if object.kind == .event, object.status?.uppercased() != "ENABLED" {
                Text("disabled").font(.caption2).foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            if let rows = object.rowCount, rows > 0, object.kind == .table {
                Text(rows.formatted(.number.notation(.compactName))).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .help(help)
        .contextMenu {
            Button("Open") { workspace.openObject(object) }
            if object.kind.isRelation {
                Button("Query in New Tab") {
                    workspace.openSQL(text: "SELECT *\nFROM \(object.qualifiedName)\nLIMIT 100;", database: object.schema, run: true)
                }
            }
            if object.kind == .table {
                Button("Indexes") { workspace.openObject(object, section: .indexes) }
                Button("Insights") { workspace.openObject(object, section: .insights) }
            }
            if object.kind == .procedure {
                Button("Call in New Tab") { workspace.openSQL(text: "CALL \(object.qualifiedName)();", database: object.schema) }
            }
            Button("DDL") { workspace.openObject(object, section: .ddl) }
            Divider()
            Button("Copy Name") { Pasteboard.copy(object.name) }
            Button("Copy Qualified Name") { Pasteboard.copy(object.qualifiedName) }
        }
    }

    private var help: String {
        var parts = [object.kind.displayName]
        if let engine = object.engine { parts.append(engine) }
        if let detail = object.detail { parts.append(detail) }
        if let status = object.status, !status.isEmpty { parts.append(status) }
        if let comment = object.comment, !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " · ")
    }
}
