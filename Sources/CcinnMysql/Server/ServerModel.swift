import CcinnMysqlKit
import Foundation
import Observation
import MySQLKit

/// Server views: overview, processlist, InnoDB locking, top statements, replication/topology, variables,
/// status and accounts. The visible section refreshes periodically; timer ticks are skipped while a refresh
/// is still running (never self-cancelling), and every result carries a generation token.
@MainActor
@Observable
final class ServerModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case processlist = "Processlist"
        case innodb = "InnoDB Locks"
        case statements = "Top Statements"
        case replication = "Replication"
        case variables = "Variables"
        case status = "Status"
        case users = "Users"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "gauge.with.dots.needle.67percent"
            case .processlist: "person.2"
            case .innodb: "lock"
            case .statements: "chart.bar.doc.horizontal"
            case .replication: "arrow.triangle.branch"
            case .variables: "slider.horizontal.3"
            case .status: "speedometer"
            case .users: "person.badge.key"
            }
        }

        var autoRefreshes: Bool { [.overview, .processlist, .innodb, .replication, .status].contains(self) }
    }

    unowned let workspace: WorkspaceModel
    private(set) var section: Section
    var autoRefresh = true { didSet { autoRefresh ? startAutoRefresh() : stopAutoRefresh() } }
    var lastRefreshed: Date?
    var filter = ""
    var includeIdle = false
    var statementOrder: StatementOrder = .totalLatency { didSet { if statementOrder != oldValue { refresh() } } }
    var globalScope = true { didSet { if globalScope != oldValue { refresh() } } }

    var processes: Loadable<ProcessListSnapshot> = .idle
    var innodb: Loadable<InnoDBActivity> = .idle
    var statements: Loadable<[StatementDigest]> = .idle
    var replication: Loadable<ReplicationOverview> = .idle
    var variables: Loadable<[ServerVariable]> = .idle
    var status: Loadable<[ServerVariable]> = .idle
    var statusRates: [String: Double] = [:]
    var accounts: Loadable<[AccountInfo]> = .idle
    var selectedAccount: AccountInfo? { didSet { if selectedAccount != oldValue { loadGrants() } } }
    var grants: Loadable<[String]> = .idle
    var pendingAction: PendingAction?

    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let run: @MainActor () async throws -> Void
    }

    private var previousStatus: (values: [ServerVariable], at: Date)?
    private var refreshTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var isRefreshing = false
    private var generation: UInt64 = 0

    init(workspace: WorkspaceModel, section: Section) {
        self.workspace = workspace
        self.section = section
        refresh()
        startAutoRefresh()
    }

    var client: MySQLClient { workspace.client }
    var info: ServerInfo { client.serverInfo }

    func select(_ section: Section) {
        guard section != self.section else { return }
        self.section = section
        refresh()
    }

    // MARK: Refresh

    /// `fromTimer` refreshes are skipped while one is still running, so slow servers are never interrupted half-way.
    func refresh(fromTimer: Bool = false) {
        if fromTimer, isRefreshing { return }
        refreshTask?.cancel()
        generation &+= 1
        let token = generation
        let section = section
        isRefreshing = true
        refreshTask = Task {
            defer { if token == generation { isRefreshing = false } }
            switch section {
            case .overview:
                await load(token, { self.status = $0 }, keep: status.value) { try await self.client.status() }
                await load(token, { self.replication = $0 }, keep: replication.value) { try await self.client.replicationOverview() }
                updateRates()
            case .processlist:
                await load(token, { self.processes = $0 }, keep: processes.value) { try await self.client.processList() }
            case .innodb:
                await load(token, { self.innodb = $0 }, keep: innodb.value) { try await self.client.innoDBActivity() }
            case .statements:
                let order = statementOrder
                await load(token, { self.statements = $0 }, keep: statements.value) { try await self.client.topStatements(order: order, limit: 200) }
            case .replication:
                await load(token, { self.replication = $0 }, keep: replication.value) { try await self.client.replicationOverview() }
            case .variables:
                let global = globalScope
                await load(token, { self.variables = $0 }, keep: variables.value) { try await self.client.variables(global: global) }
            case .status:
                await load(token, { self.status = $0 }, keep: status.value) { try await self.client.status() }
                updateRates()
            case .users:
                await load(token, { self.accounts = $0 }, keep: accounts.value) { try await self.client.accounts() }
            }
            if token == generation, !Task.isCancelled { lastRefreshed = Date() }
        }
    }

    private func updateRates() {
        guard let current = status.value else { return }
        let now = Date()
        if let previous = previousStatus {
            let rates = StatusMetrics.rates(previous: previous.values, current: current, seconds: now.timeIntervalSince(previous.at))
            if !rates.isEmpty { statusRates = rates }
        }
        previousStatus = (current, now)
    }

    /// Shows a spinner only on the first load; later refreshes swap data in place. Stale results are dropped.
    private func load<Value>(_ token: UInt64, _ assign: (Loadable<Value>) -> Void, keep current: Value?, _ body: () async throws -> Value) async {
        if current == nil { assign(.loading) }
        do {
            let value = try await body()
            guard token == generation, !Task.isCancelled else { return }
            assign(.loaded(value))
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            assign(.failed(describe(error)))
        }
    }

    private func loadGrants() {
        guard let account = selectedAccount else {
            grants = .idle
            return
        }
        grants = .loading
        let client = client
        Task {
            do {
                let lines = try await client.grants(for: account).map(SQLRedactor.redact)
                if selectedAccount == account { grants = .loaded(lines) }
            } catch {
                if selectedAccount == account { grants = .failed(describe(error)) }
            }
        }
    }

    func startAutoRefresh() {
        guard autoRefresh, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.autoRefresh else { return }
                if self.section.autoRefreshes { self.refresh(fromTimer: true) }
            }
        }
    }

    func stopAutoRefresh() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Stops everything when the tab closes.
    func close() {
        stopAutoRefresh()
        refreshTask?.cancel()
    }

    // MARK: Actions

    func confirmKill(_ process: SessionProcess, in snapshot: ProcessListSnapshot, connection: Bool) {
        let server = snapshot.identity.map { " on \($0.description)" } ?? ""
        pendingAction = PendingAction(
            title: (connection ? "Kill connection \(process.id)" : "Stop the query of session \(process.id)") + server + "?",
            message: process.statement.map { SQLRedactor.redact(String($0.prefix(300))) } ?? "\(process.user ?? "") @ \(process.host ?? "")",
            confirmLabel: connection ? "Kill Connection" : "Kill Query") { [client] in
                try await client.kill(process, in: snapshot, connection: connection)
            }
    }

    func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            do {
                try await action.run()
                workspace.showToast("Done")
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }
}
