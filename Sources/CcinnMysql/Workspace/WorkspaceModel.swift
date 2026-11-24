import CcinnMysqlKit
import Foundation
import Observation
import MySQLKit

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// One tab in the workspace.
struct WorkspaceTab: Identifiable, Equatable {
    enum Kind {
        case object(ObjectDetailModel)
        case sql(SQLTabModel)
        case server(ServerModel)
        case knowledge(KnowledgeTabModel)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool { lhs.id == rhs.id }

    @MainActor var title: String {
        switch kind {
        case let .object(model): model.object.name
        case let .sql(model): model.title
        case .server: "Server"
        case .knowledge: "Knowledge"
        }
    }

    @MainActor var subtitle: String? {
        switch kind {
        case let .object(model): model.object.schema
        case let .sql(model): model.database
        case .server: nil
        case let .knowledge(model): model.key.database
        }
    }

    @MainActor var icon: String {
        switch kind {
        case let .object(model): Theme.icon(for: model.object.kind)
        case .sql: "chevron.left.forwardslash.chevron.right"
        case .server: "gauge.with.dots.needle.67percent"
        case .knowledge: "brain"
        }
    }
}

/// Everything a connected window shows: schema tree, open tabs, and caches shared by tabs.
@MainActor
@Observable
final class WorkspaceModel {
    enum DatabaseState {
        case loading
        case loaded(SchemaObjects)
        case failed(String)
    }

    let profile: ConnectionProfile
    let client: MySQLClient
    let history: QueryHistoryStore

    var schemas: [SchemaInfo] = [] { didSet { completionSchemaDidChange() } }
    var databases: [String] { schemas.map(\.name) }
    var showSystemSchemas = false
    var isLoadingDatabases = false
    var databasesError: String?
    var databaseStates: [String: DatabaseState] = [:] { didSet { completionSchemaDidChange() } }
    var expandedDatabases: Set<String> = []
    var sidebarFilter = ""
    var sidebarSelection: String?

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var toast: Toast?

    /// Columns per table for completion and previews.
    private var columnCache: [TableKey: [ColumnInfo]] = [:] { didSet { completionSchemaDidChange() } }
    private var columnMisses: [TableKey: Date] = [:]
    /// When each cached column list and object list loaded, and when an object list last failed to.
    @ObservationIgnored private var columnsLoadedAt: [TableKey: Date] = [:]
    @ObservationIgnored private var objectsLoadedAt: [String: Date] = [:]
    @ObservationIgnored private var objectLoadFailures: [String: Date] = [:]
    @ObservationIgnored private var lastStaleSchemaCheck = Date.distantPast
    /// The completion schema built from the above, until any of it changes.
    @ObservationIgnored private var completionSchema: SchemaSnapshot?
    /// Changes whenever the completion schema does.
    @ObservationIgnored private(set) var completionSchemaVersion: UInt64 = 0
    private var columnLoads: [String: Task<Void, Never>] = [:]
    private var objectLoads: [String: Task<Void, Never>] = [:]
    private var objectLoadGenerations: [String: UInt64] = [:]
    private var objectLoadGeneration: UInt64 = 0
    private var sqlTabCounter = 0
    private var toastTask: Task<Void, Never>?

    init(profile: ConnectionProfile, client: MySQLClient) {
        self.profile = profile
        self.client = client
        history = QueryHistoryStore(directory: AppServices.shared.historyDirectory, profileID: profile.id)
    }

    var serverInfo: ServerInfo { client.serverInfo }

    var versionLabel: String { serverInfo.productDescription }

    // MARK: Lifecycle

    func start() {
        Task { await reloadDatabases() }
    }

    func shutdown() {
        for tab in tabs { closeResources(of: tab) }
        tabs.removeAll()
        let client = client
        Task.detached { await client.close() }
    }

    // MARK: Schema tree

    func reloadDatabases() async {
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }
        do {
            let loaded = try await client.schemas()
            schemas = loaded
            databasesError = nil
            let names = loaded.map(\.name)
            if expandedDatabases.isEmpty {
                let preferred = profile.defaultDatabase.flatMap { name in names.first { $0 == name } }
                    ?? loaded.first { !$0.isSystem }?.name
                if let preferred { setExpanded(preferred, true) }
            }
            for database in expandedDatabases where names.contains(database) {
                loadObjects(database: database, force: true)
            }
        } catch {
            databasesError = describe(error)
        }
    }

    func refreshAll() {
        columnCache.removeAll()
        columnMisses.removeAll()
        columnsLoadedAt.removeAll()
        objectLoadFailures.removeAll()
        Task { await reloadDatabases() }
    }

    func setExpanded(_ database: String, _ expanded: Bool) {
        if expanded {
            expandedDatabases.insert(database)
            if databaseStates[database] == nil { loadObjects(database: database) }
        } else {
            expandedDatabases.remove(database)
        }
    }

    func loadObjects(database: String, force: Bool = false) {
        if !force, let state = databaseStates[database], case .loaded = state { return }
        if objectLoads[database] != nil, !force { return }
        if databaseStates[database] == nil { databaseStates[database] = .loading }
        objectLoadGeneration &+= 1
        let generation = objectLoadGeneration
        objectLoads[database]?.cancel()
        objectLoads[database] = Task {
            // Only the newest load for this database may publish its result or clear the slot.
            defer { if objectLoadGenerations[database] == generation { objectLoads[database] = nil } }
            do {
                let objects = try await client.objects(schema: database)
                guard objectLoadGenerations[database] == generation else { return }
                databaseStates[database] = .loaded(objects)
                objectsLoadedAt[database] = Date()
                objectLoadFailures[database] = nil
            } catch {
                guard objectLoadGenerations[database] == generation, !Task.isCancelled else { return }
                objectLoadFailures[database] = Date()
                // A reload that fails keeps the list already shown.
                if case .loaded? = databaseStates[database] { return }
                databaseStates[database] = .failed(describe(error))
            }
        }
        objectLoadGenerations[database] = generation
    }

    func awaitObjects(database: String) async -> [DatabaseObject]? {
        if case let .loaded(objects)? = databaseStates[database] { return objects.objects }
        loadObjects(database: database)
        while let task = objectLoads[database] {
            await task.value
            if objectLoads[database] == task { break }
        }
        if case let .loaded(objects)? = databaseStates[database] { return objects.objects }
        return nil
    }

    func objects(in database: String) -> [DatabaseObject]? {
        if case let .loaded(objects)? = databaseStates[database] { return objects.objects }
        return nil
    }

    func object(database: String, name: String) -> DatabaseObject? {
        objects(in: database)?.first { $0.name == name }
    }

    // MARK: Completion schema

    /// Schema for completion from the sidebar's metadata and the column cache; built once per schema change.
    func completionSnapshot(currentDatabase: String?) -> SchemaSnapshot {
        let base: SchemaSnapshot
        if let cached = completionSchema {
            base = cached
        } else {
            var objectsByDatabase: [String: [SchemaSnapshot.ObjectEntry]] = [:]
            for (database, state) in databaseStates {
                if case let .loaded(objects) = state {
                    objectsByDatabase[database] = objects.objects.map { SchemaSnapshot.ObjectEntry(name: $0.name, kind: $0.kind) }
                }
            }
            base = SchemaSnapshot(databases: databases, objectsByDatabase: objectsByDatabase, columnsByTable: columnCache)
            completionSchema = base
        }
        var snapshot = base
        snapshot.currentDatabase = currentDatabase
        return snapshot
    }

    private func completionSchemaDidChange() {
        completionSchema = nil
        completionSchemaVersion &+= 1
    }

    /// The database's name as the server lists it.
    private func knownDatabase(_ name: String) -> String? {
        databases.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Loads what completion reported as missing: object lists, and columns of the referenced tables.
    /// Tables that do not exist, and databases whose list failed to load, are left alone for a minute so typing does
    /// not re-query them.
    func ensureSchema(columns keys: [TableKey], databases missingDatabases: [String]) async {
        let now = Date()
        for database in Set(missingDatabases.compactMap(knownDatabase))
        where SchemaCachePolicy.mayRetry(failedAt: objectLoadFailures[database], now: now) {
            _ = await awaitObjects(database: database)
        }
        let wanted = Set(keys).filter { key in
            columnCache[key] == nil && SchemaCachePolicy.mayRetry(failedAt: columnMisses[key], now: now)
        }
        await loadColumns(wanted, recordingMisses: true)
    }

    /// Reloads, in the background, the object lists of `databases` and the cached columns that are older than
    /// `SchemaCachePolicy.maxAge`, so tables created elsewhere appear. Checks at most every 30 seconds.
    func refreshStaleSchema(databases inUse: [String]) {
        let now = Date()
        guard now.timeIntervalSince(lastStaleSchemaCheck) > 30 else { return }
        lastStaleSchemaCheck = now
        for database in Set(inUse.compactMap(knownDatabase)) {
            guard case .loaded? = databaseStates[database], objectLoads[database] == nil,
                  let loadedAt = objectsLoadedAt[database], SchemaCachePolicy.isStale(loadedAt: loadedAt, now: now) else { continue }
            loadObjects(database: database, force: true)
        }
        let staleColumns = Set(columnsLoadedAt.filter { SchemaCachePolicy.isStale(loadedAt: $0.value, now: now) }.keys)
        if !staleColumns.isEmpty { Task { await loadColumns(staleColumns, recordingMisses: false) } }
    }

    /// After DDL: reloads the object lists of the databases `sql` names and drops the cached columns of its tables.
    func schemaDidChange(after sql: String, currentDatabase: String?) {
        let change = SchemaChange(sql: sql, currentDatabase: currentDatabase)
        if change.changesDatabaseList { Task { await reloadDatabases() } }
        for database in Set(change.databases.compactMap(knownDatabase)) where databaseStates[database] != nil {
            loadObjects(database: database, force: true)
        }
        for key in change.tables {
            columnCache[key] = nil
            columnsLoadedAt[key] = nil
            columnMisses[key] = nil
        }
    }

    /// Loads the columns of `keys`, one query per database. A table missing from the answer is remembered as missing
    /// (`recordingMisses`) or dropped from the cache (a reload: it was dropped on the server).
    private func loadColumns(_ keys: Set<TableKey>, recordingMisses: Bool) async {
        for (database, group) in Dictionary(grouping: keys, by: \.database) {
            let tables = group.map(\.table)
            let loadKey = database + "\u{1F}" + tables.sorted().joined(separator: ",")
            if let running = columnLoads[loadKey] {
                await running.value
                continue
            }
            let client = client
            let task = Task {
                guard let columns = try? await client.columnsByTable(schema: database, tables: tables) else { return }
                var found = Set<TableKey>()
                let loadedAt = Date()
                for (table, list) in columns {
                    let key = TableKey(database: database, table: table)
                    columnCache[key] = list
                    columnsLoadedAt[key] = loadedAt
                    found.insert(key)
                }
                for key in group where !found.contains(key) {
                    if recordingMisses {
                        columnMisses[key] = loadedAt
                    } else {
                        columnCache[key] = nil
                        columnsLoadedAt[key] = nil
                    }
                }
            }
            columnLoads[loadKey] = task
            await task.value
            columnLoads[loadKey] = nil
        }
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var selectedSQL: SQLTabModel? {
        if case let .sql(model)? = selectedTab?.kind { return model }
        return nil
    }

    func openObject(_ object: DatabaseObject, section: ObjectDetailModel.Section? = nil) {
        if let existing = tabs.first(where: { if case let .object(model) = $0.kind { model.object.id == object.id } else { false } }) {
            selectedTabID = existing.id
            if let section, case let .object(model) = existing.kind { model.select(section) }
            return
        }
        let model = ObjectDetailModel(object: object, workspace: self)
        if let section { model.select(section) }
        let tab = WorkspaceTab(kind: .object(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    @discardableResult
    func openSQL(text: String = "", database: String? = nil, run: Bool = false) -> SQLTabModel {
        sqlTabCounter += 1
        let model = SQLTabModel(title: "Query \(sqlTabCounter)", text: text, database: database ?? sidebarContextHint(), workspace: self)
        let tab = WorkspaceTab(kind: .sql(model))
        tabs.append(tab)
        selectedTabID = tab.id
        if run { model.runAll() }
        return model
    }

    func openServer(section: ServerModel.Section = .processlist) {
        if let existing = tabs.first(where: { if case .server = $0.kind { true } else { false } }) {
            selectedTabID = existing.id
            if case let .server(model) = existing.kind { model.select(section) }
            return
        }
        let model = ServerModel(workspace: self, section: section)
        let tab = WorkspaceTab(kind: .server(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// The knowledge base of `database` (default: the database in context), one tab per database.
    func openKnowledge(database: String? = nil) {
        guard let database = database ?? currentDatabase else {
            showToast("Choose a database in the sidebar first", isError: true)
            return
        }
        if let existing = tabs.first(where: { if case let .knowledge(model) = $0.kind { model.key.database == database } else { false } }) {
            selectedTabID = existing.id
            return
        }
        guard !KnowledgeExtractor.isSystemDatabase(database) else {
            showToast("“\(database)” is the server's own database; knowledge covers your databases.", isError: true)
            return
        }
        let model = KnowledgeTabModel(workspace: self, database: database)
        let tab = WorkspaceTab(kind: .knowledge(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// The database of the selected tab, else the sidebar's.
    var currentDatabase: String? {
        if case let .knowledge(model)? = selectedTab?.kind { return model.key.database }
        return sidebarContextHint()
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        closeResources(of: tab)
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    private func closeResources(of tab: WorkspaceTab) {
        switch tab.kind {
        case let .sql(model): model.close()
        case let .server(model): model.close()
        case let .knowledge(model): model.stopWatching()
        case .object: break
        }
    }

    /// Schema for new SQL tabs: the open object's, the current tab's, or the sidebar's.
    private func sidebarContextHint() -> String? {
        if case let .object(model)? = selectedTab?.kind { return model.object.schema }
        if case let .sql(model)? = selectedTab?.kind { return model.database }
        let configured = profile.defaultDatabase?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Before the database list has loaded, the tab's session uses the profile's default database: completion must too.
        if schemas.isEmpty, let configured, !configured.isEmpty { return configured }
        let preferred = configured.flatMap { name in databases.contains(name) ? name : nil }
        return preferred ?? expandedDatabases.sorted().first
    }

    // MARK: Feedback

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
