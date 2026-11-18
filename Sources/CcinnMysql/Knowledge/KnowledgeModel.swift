import AppKit
import CcinnMysqlKit
import Foundation
import MySQLKit
import Observation
import UniformTypeIdentifiers

/// The Knowledge tab of one database (design D12): linked projects, builds, relationships and notes. File I/O and
/// decoding run off the main actor; every change goes through `KnowledgeStore.update`, so the tab and MCP processes
/// can write the same knowledge base safely.
@MainActor
@Observable
final class KnowledgeModel {
    enum Section: String, CaseIterable, Identifiable {
        case relationships = "Relationships"
        case tables = "Tables"
        case notes = "Notes"
        case diagram = "Diagram"

        var id: String { rawValue }
    }

    enum RelationshipFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case declared = "Declared"
        case inferred = "Inferred"
        case rejected = "Rejected"

        var id: String { rawValue }
    }

    unowned let workspace: WorkspaceModel
    let database: String
    let store: KnowledgeStore

    private(set) var knowledge: KnowledgeBase?
    private(set) var graph: KnowledgeGraph?
    private(set) var loadError: String?
    /// Only a damaged file may be reset (never a newer version's, or one that is briefly unavailable).
    private(set) var loadErrorIsDamage = false
    private(set) var isLoading = false
    /// Linked projects never scanned or changed (another commit) since the last build.
    private(set) var staleProjects: Set<UUID> = []
    /// Linked projects whose folder does not exist (moved, or another Mac).
    private(set) var missingProjects: Set<UUID> = []
    var section: Section = .relationships
    var filter: RelationshipFilter = .all
    var searchText = ""
    var selectedTable: String?

    private(set) var isBuilding = false
    private(set) var buildStatus: String?
    private(set) var buildFraction: Double?
    private var buildTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(workspace: WorkspaceModel, database: String, store: KnowledgeStore) {
        self.workspace = workspace
        self.database = database
        self.store = store
    }

    var key: KnowledgeKey { KnowledgeKey(connectionID: workspace.profile.id, database: database) }

    /// Knowledge is kept per saved connection; an unsaved one has a temporary id that is not found again later
    /// (and AI assistants only see saved connections).
    var isSavedConnection: Bool { AppServices.shared.profiles.profile(id: workspace.profile.id) != nil }

    // MARK: Loading

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let store = store
        let key = key
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (loaded: (knowledge: KnowledgeBase, graph: KnowledgeGraph)?, stale: Set<UUID>, missing: Set<UUID>) in
                    let loaded = try store.loadWithGraph(key)
                    let missing = Set(loaded?.knowledge.projects.filter { project in
                        var isDirectory: ObjCBool = false
                        return !FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory) || !isDirectory.boolValue
                    }.map(\.id) ?? [])
                    return (loaded, loaded.map { Self.staleProjects(in: $0.knowledge) } ?? [], missing)
                }
            }.value
            guard generation == loadGeneration else { return }
            isLoading = false
            switch result {
            case let .success((loaded, stale, missing)):
                knowledge = loaded?.knowledge
                graph = loaded?.graph
                staleProjects = stale
                missingProjects = missing
                loadError = nil
                loadErrorIsDamage = false
                if let selected = selectedTable, graph?.tables[selected] == nil { selectedTable = nil }
            case let .failure(error):
                knowledge = nil
                graph = nil
                loadError = Self.describe(error)
                loadErrorIsDamage = (error as? KnowledgeError)?.kind == .damaged
            }
        }
    }

    // MARK: Building

    func build(scanCode: Bool = true) {
        guard !isBuilding else { return }
        isBuilding = true
        buildStatus = "Reading the schema…"
        buildFraction = nil
        let builder = KnowledgeBuilder(store: store)
        let source = MySQLKnowledgeSource(client: workspace.client)
        let key = key
        let progress: @Sendable (KnowledgeBuilder.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.show(phase) }
        }
        buildTask = Task {
            do {
                let summary = try await builder.build(key, source: source, scanCode: scanCode, progress: progress)
                finishBuild()
                var parts = ["\(summary.tables) tables", "\(summary.totalRelationships) relationships"]
                if let changes = summary.changes, !changes.isEmpty {
                    parts.append("\(changes.added.count) added, \(changes.removed.count) removed, \(changes.changed.count) changed")
                }
                workspace.showToast("Knowledge of \(database) built: " + parts.joined(separator: ", "))
            } catch is CancellationError {
                finishBuild()
                workspace.showToast("Build cancelled; the knowledge base is unchanged")
            } catch {
                finishBuild()
                workspace.showToast("Build failed: \(Self.describe(error))", isError: true)
            }
            reload()
        }
    }

    func cancelBuild() {
        buildTask?.cancel()
    }

    private func show(_ phase: KnowledgeBuilder.Phase) {
        guard isBuilding else { return }
        switch phase {
        case .schema:
            buildStatus = "Reading the schema…"
            buildFraction = nil
        case .relationships:
            buildStatus = "Finding relationships…"
            buildFraction = nil
        case let .code(done, total):
            buildStatus = "Scanning code: \(Format.count(done)) of \(Format.count(total)) files"
            buildFraction = total > 0 ? Double(done) / Double(total) : nil
        case .saving:
            buildStatus = "Saving…"
            buildFraction = nil
        }
    }

    private func finishBuild() {
        isBuilding = false
        buildStatus = nil
        buildFraction = nil
        buildTask = nil
    }

    func close() {
        buildTask?.cancel()
    }

    // MARK: Projects

    func linkProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Choose the code folders that use \(database). Builds read their source files to find joins and table uses; only names, paths and line numbers are kept, and nothing leaves this Mac."
        guard panel.runModal() == .OK else { return }
        let folders = panel.urls.map { $0.standardizedFileURL }
        mutate(success: folders.count == 1 ? "Linked \(folders[0].lastPathComponent); rebuild to scan it" : "Linked \(folders.count) folders; rebuild to scan them") { knowledge in
            for folder in folders where !knowledge.projects.contains(where: { $0.path == folder.path }) {
                let base = folder.lastPathComponent.isEmpty ? "project" : folder.lastPathComponent
                var name = base
                var suffix = 2
                while knowledge.projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(base)-\(suffix)"
                    suffix += 1
                }
                knowledge.projects.append(LinkedProject(name: name, path: folder.path))
            }
        }
    }

    /// Points a linked project at its new folder, keeping its name (and so the evidence that cites it).
    func relocate(_ project: LinkedProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.message = "Where is “\(project.name)” now? It was \(project.path)."
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL else { return }
        let id = project.id
        mutate(success: "\(project.name) now points to \(folder.path); rebuild to scan it") { knowledge in
            guard let index = knowledge.projects.firstIndex(where: { $0.id == id }) else {
                throw KnowledgeError("That project is no longer linked.")
            }
            if knowledge.projects.contains(where: { $0.id != id && $0.path == folder.path }) {
                throw KnowledgeError("\(folder.path) is already linked.")
            }
            knowledge.projects[index].path = folder.path
            knowledge.build?.projects.removeAll { $0.projectID == id }
        }
    }

    /// Unlinks a project and forgets what was found in it.
    func unlink(_ project: LinkedProject) {
        mutate(success: "Unlinked \(project.name)") { knowledge in
            knowledge.projects.removeAll { $0.id == project.id }
            let kept = Set(knowledge.projects.map(\.name))
            knowledge.references = knowledge.references.compactMapValues { references in
                let filtered = references.filter { kept.contains($0.project) }
                return filtered.isEmpty ? nil : filtered
            }
            knowledge.computed = knowledge.computed.compactMap { relationship in
                guard relationship.evidence.contains(where: { $0.kind == .code && !kept.contains($0.project ?? "") }) else { return relationship }
                let evidence = relationship.evidence.filter { $0.kind != .code || kept.contains($0.project ?? "") }
                var sources = relationship.sources
                if !evidence.contains(where: { $0.kind == .code }) { sources.removeAll { $0 == .code } }
                guard !sources.isEmpty else { return nil }
                return KnowledgeRelationship(from: relationship.from, to: relationship.to, sources: sources, confidence: relationship.confidence,
                                             cardinality: relationship.cardinality, evidence: evidence, occurrences: relationship.occurrences,
                                             constraintName: relationship.constraintName)
            }
            knowledge.build?.projects.removeAll { $0.projectID == project.id }
        }
    }

    // MARK: Annotations (written as the user)

    func setVerdict(_ edge: KnowledgeGraph.Edge, _ status: KnowledgeAnnotation.VerdictInput.Status, reason: String? = nil) {
        var annotation = KnowledgeAnnotation()
        let relationship = edge.relationship
        annotation.verdicts = [.init(fromTable: relationship.from.table, fromColumns: relationship.from.columns, toTable: relationship.to.table,
                                     toColumns: relationship.to.columns, status: status, reason: reason)]
        annotate(annotation, success: status == .cleared ? "Verdict cleared" : "Relationship \(status.rawValue)")
    }

    func removeAdded(_ edge: KnowledgeGraph.Edge) {
        let id = edge.id
        mutate(success: "Relationship removed") { $0.notes.relationships[id] = nil }
    }

    func saveTableNote(_ table: String, summary: String) {
        var annotation = KnowledgeAnnotation()
        annotation.tableNotes = [.init(table: table, summary: summary)]
        annotate(annotation, success: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Note deleted" : "Note saved")
    }

    func deleteTableNote(_ table: String) {
        mutate(success: "Note deleted") { $0.notes.tables[table] = nil }
    }

    func deleteColumnNote(_ table: String, _ column: String) {
        mutate(success: "Note deleted") { knowledge in
            knowledge.notes.columns[table]?[column] = nil
            if knowledge.notes.columns[table]?.isEmpty == true { knowledge.notes.columns[table] = nil }
        }
    }

    func deleteTerm(_ term: GlossaryTerm) {
        let key = term.term.lowercased()
        mutate(success: "Term deleted") { $0.notes.glossary[key] = nil }
    }

    /// Deletes annotations whose table or column no longer exists.
    func deleteOrphans() {
        mutate(success: "Outdated notes deleted") { knowledge in
            guard let snapshot = knowledge.snapshot else { return }
            let tables = Dictionary(snapshot.tables.map { ($0.name, Set($0.columns.map(\.name))) }, uniquingKeysWith: { first, _ in first })
            knowledge.notes.tables = knowledge.notes.tables.filter { tables[$0.key] != nil }
            var columns: [String: [String: ColumnNote]] = [:]
            for (table, notes) in knowledge.notes.columns {
                guard let known = tables[table] else { continue }
                let kept = notes.filter { known.contains($0.key) }
                if !kept.isEmpty { columns[table] = kept }
            }
            knowledge.notes.columns = columns
            knowledge.notes.relationships = knowledge.notes.relationships.filter { _, added in
                [added.relationship.from, added.relationship.to].allSatisfy { end in
                    tables[end.table].map { known in end.columns.allSatisfy(known.contains) } ?? false
                }
            }
        }
    }

    private func annotate(_ annotation: KnowledgeAnnotation, success: String) {
        mutate(success: success) { knowledge in
            _ = try KnowledgeAnnotator.apply(annotation, author: .user, to: &knowledge)
        }
    }

    private func mutate(success: String?, _ change: @escaping @Sendable (inout KnowledgeBase) throws -> Void) {
        let store = store
        let key = key
        Task {
            do {
                try await store.update(key) { try change(&$0) }
                if let success { workspace.showToast(success) }
            } catch {
                workspace.showToast(Self.describe(error), isError: true)
            }
            reload()
        }
    }

    /// Moves an unreadable knowledge base aside and starts over.
    func reset() {
        let store = store
        let key = key
        Task {
            do {
                let moved = try await store.reset(key)
                workspace.showToast(moved.map { "The old file was kept as \($0.lastPathComponent)" } ?? "Knowledge base reset")
            } catch {
                workspace.showToast(Self.describe(error), isError: true)
            }
            reload()
        }
    }

    // MARK: Export

    func copyMermaid(focus: [String] = []) {
        guard let graph else { return }
        let diagram = KnowledgeERD.mermaid(graph, focus: focus, columns: .keys)
        Pasteboard.copy(diagram.text)
        workspace.showToast(diagram.truncated ? "Copied the ER diagram of \(diagram.entities) tables (limit reached)" : "Copied the ER diagram (Mermaid)")
    }

    func exportMarkdown() {
        guard let knowledge, let graph else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(database)-knowledge.md"
        panel.message = "Markdown with tables, relationships, notes, glossary and an ER diagram. Commit it to a repository so AI tools without MCP can read it too. It contains no host, user or local paths."
        if let project = knowledge.projects.first { panel.directoryURL = URL(fileURLWithPath: project.path, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Data(KnowledgeMarkdown.render(knowledge, graph: graph).utf8).write(to: url, options: .atomic)
                }.value
                workspace.showToast("Exported \(url.lastPathComponent)")
            } catch {
                workspace.showToast("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: Derived

    var visibleEdges: [KnowledgeGraph.Edge] {
        guard let graph else { return [] }
        let edges: [KnowledgeGraph.Edge] = switch filter {
        case .all: graph.edges
        case .declared: graph.edges.filter(\.relationship.isDeclared)
        case .inferred: graph.edges.filter { !$0.relationship.isDeclared }
        case .rejected: graph.rejected
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return edges }
        return edges.filter { $0.id.lowercased().contains(query) }
    }

    var visibleTables: [KnowledgeTable] {
        guard let graph else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return graph.tableNames.compactMap { graph.tables[$0] } }
        let hits = graph.search(query, limit: 200).tables.map(\.table)
        return hits.compactMap { graph.tables[$0] }
    }

    /// Projects never scanned, or whose checked-out commit differs from the scanned one (reads git files: off the main actor).
    nonisolated static func staleProjects(in knowledge: KnowledgeBase) -> Set<UUID> {
        let scans = Dictionary(knowledge.build?.projects.map { ($0.projectID, $0.commit) } ?? [], uniquingKeysWith: { first, _ in first })
        return Set(knowledge.projects.filter { project in
            guard let scanned = scans[project.id] else { return true }
            return scanned != GitHead.commit(for: URL(fileURLWithPath: project.path))
        }.map(\.id))
    }

    static func describe(_ error: any Error) -> String {
        (error as? KnowledgeError)?.message ?? (error as? MySQLError)?.message ?? error.localizedDescription
    }
}
