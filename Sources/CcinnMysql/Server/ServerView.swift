import CcinnMysqlKit
import MySQLKit
import SwiftUI

struct ServerView: View {
    @Bindable var model: ServerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.section {
                case .overview: ServerOverview(model: model)
                case .processlist: ProcesslistView(model: model)
                case .innodb: InnoDBView(model: model)
                case .statements: StatementsView(model: model)
                case .replication: ReplicationView(model: model)
                case .variables: VariablesView(model: model, state: model.variables, rates: [:])
                case .status: VariablesView(model: model, state: model.status, rates: model.statusRates)
                case .users: UsersView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(model.pendingAction?.title ?? "", isPresented: Binding(get: { model.pendingAction != nil }, set: { if !$0 { model.pendingAction = nil } }),
                            titleVisibility: .visible) {
            Button(model.pendingAction?.confirmLabel ?? "OK", role: .destructive) { model.runPendingAction() }
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
        } message: {
            Text(model.pendingAction?.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.title2).foregroundStyle(Theme.accent)
                Text("Server").font(.title2.weight(.semibold))
                Badge(text: model.workspace.versionLabel, color: Theme.accent)
                if model.info.isTLS { Badge(text: model.info.tlsVersion ?? "TLS", color: .green, systemImage: "lock.fill") }
                if model.info.isProxySQL { Badge(text: "ProxySQL", color: .purple) }
                if model.info.readOnly { Badge(text: model.info.superReadOnly ? "SUPER READ-ONLY" : "READ-ONLY", color: .orange) }
                Spacer()
                if model.section == .variables || model.section == .status {
                    Picker("Scope", selection: $model.globalScope) {
                        Text("Global").tag(true)
                        Text("Session").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(model.section == .status)
                }
                if model.section.autoRefreshes {
                    Toggle("Auto-refresh", isOn: $model.autoRefresh)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Refresh every 5 seconds")
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                if let refreshed = model.lastRefreshed {
                    Text(refreshed, style: .time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(ServerModel.Section.allCases) { section in
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
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

/// Filter field shared by list sections.
private struct FilterField: View {
    @Binding var text: String
    var prompt = "Filter"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: 280)
    }
}

// MARK: - Overview

private struct ServerOverview: View {
    let model: ServerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let status = model.status.value ?? []
                HStack(spacing: 12) {
                    StatTile(title: "Uptime", value: Format.duration(seconds: StatusMetrics.value("Uptime", in: status).flatMap(Double.init)), systemImage: "clock")
                    StatTile(title: "Connections", value: StatusMetrics.value("Threads_connected", in: status) ?? "—", systemImage: "person.2")
                    StatTile(title: "Running", value: StatusMetrics.value("Threads_running", in: status) ?? "—", systemImage: "bolt")
                    StatTile(title: "Queries / s", value: model.statusRates["Questions"].map { String(format: "%.1f", $0) } ?? "…", systemImage: "speedometer")
                    StatTile(title: "Buffer pool hits", value: StatusMetrics.bufferPoolHitRatio(status).map { String(format: "%.2f%%", $0 * 100) } ?? "—",
                             systemImage: "memorychip")
                }
                HStack(alignment: .top, spacing: 14) {
                    Card(title: "Server", systemImage: "server.rack") { KeyValueList(items: serverFacts) }
                    Card(title: "Topology", systemImage: "arrow.triangle.branch") {
                        if let replication = model.replication.value {
                            KeyValueList(items: topologyFacts(replication))
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                }
                if !model.info.isTLS, !model.workspace.client.isTunnelled {
                    NoticeBanner(message: model.workspace.profile.tlsMode == .disabled
                                    ? "TLS is disabled for this connection: queries and results travel unencrypted."
                                    : "The server does not offer TLS, so this connection is not encrypted. Configure TLS on the server or use an SSH tunnel.",
                                 systemImage: "lock.open", color: .orange)
                }
                if case let .failed(message) = model.status { ErrorBanner(message: message) }
            }
            .padding(18)
        }
    }

    private var serverFacts: [(String, String)] {
        let info = model.info
        var items: [(String, String)] = [("Product", info.productDescription), ("Version", info.versionString)]
        if !info.versionComment.isEmpty { items.append(("Build", info.versionComment)) }
        items.append(("Server", info.identity.description))
        if let uuid = info.identity.serverUUID { items.append(("Server UUID", uuid)) }
        if let user = info.currentUser { items.append(("Account", user)) }
        items.append(("Encryption", info.tlsVersion.map { "\($0)\(info.tlsCipher.map { " · \($0)" } ?? "")" } ?? "None"))
        items.append(("Authentication", info.authPlugin))
        if let charset = info.characterSet { items.append(("Character set", charset)) }
        if let zone = info.timeZone { items.append(("Time zone", zone)) }
        items.append(("Performance Schema", info.performanceSchemaEnabled ? "ON" : "OFF"))
        return items
    }

    private func topologyFacts(_ replication: ReplicationOverview) -> [(String, String)] {
        var items: [(String, String)] = [("Role", Self.roleName(replication.role))]
        if let file = replication.binlogFile { items.append(("Binary log", "\(file):\(replication.binlogPosition.map(String.init) ?? "?")")) }
        if let mode = replication.gtidMode { items.append(("GTID mode", mode)) }
        for channel in replication.channels.prefix(3) {
            let lag = channel.secondsBehind.map { "\($0) s behind" } ?? "lag unknown"
            items.append(("Replica \(channel.name.isEmpty ? "" : channel.name)", "\(channel.sourceHost ?? "?") · IO \(channel.ioRunning ?? "?") · SQL \(channel.sqlRunning ?? "?") · \(lag)"))
        }
        if !replication.connectedReplicas.isEmpty { items.append(("Replicas", "\(replication.connectedReplicas.count) connected")) }
        if !replication.groupMembers.isEmpty {
            items.append(("Group", "\(replication.groupMembers.count) members · " + replication.groupMembers.map { "\($0.host ?? "?") \($0.role ?? "") \($0.state ?? "")" }.joined(separator: ", ")))
        }
        if let size = replication.galera["wsrep_cluster_size"] {
            items.append(("Galera", "\(size) nodes · \(replication.galera["wsrep_cluster_status"] ?? "?") · \(replication.galera["wsrep_local_state_comment"] ?? "?")"))
        }
        return items
    }

    static func roleName(_ role: ReplicationOverview.Role) -> String {
        switch role {
        case .standalone: "Standalone"
        case .source: "Replication source"
        case .replica: "Replica"
        case .sourceAndReplica: "Source and replica (relay)"
        case .groupMember: "Group Replication member"
        case .galeraNode: "Galera node"
        }
    }
}

// MARK: - Processlist

private struct ProcesslistView: View {
    @Bindable var model: ServerModel

    var body: some View {
        LoadableView(state: model.processes, retry: { model.refresh() }) { snapshot in
            let shown = rows(snapshot)
            VStack(spacing: 0) {
                HStack {
                    FilterField(text: $model.filter, prompt: "Filter by user, host, schema or statement")
                    Toggle("Include idle", isOn: $model.includeIdle).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(shown.count) of \(snapshot.processes.count) sessions" + (snapshot.identity.map { " on \($0.description)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Table(shown) {
                    TableColumn("ID") { Text(String($0.id)).monospacedDigit() }.width(70)
                    TableColumn("User") { Text($0.user ?? "") }.width(min: 70, ideal: 100)
                    TableColumn("Host") { Text($0.host ?? "").foregroundStyle(.secondary) }.width(min: 90, ideal: 140)
                    TableColumn("Schema") { Text($0.database ?? "") }.width(min: 60, ideal: 100)
                    TableColumn("Command") { process in StateBadge(state: process.command ?? "") }.width(90)
                    TableColumn("Time") { process in
                        Text(Format.duration(seconds: process.timeSeconds.map(Double.init)))
                            .monospacedDigit()
                            .foregroundStyle((process.timeSeconds ?? 0) > 60 && process.isRunningStatement ? .orange : .primary)
                    }
                    .width(70)
                    TableColumn("State") { Text($0.state ?? "").font(.caption).foregroundStyle(.secondary) }.width(min: 80, ideal: 140)
                    TableColumn("Statement") { process in
                        Text(process.statement.map { SQLRedactor.redact(String($0.prefix(400))) } ?? "")
                            .font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled)
                    }
                }
                .contextMenu(forSelectionType: SessionProcess.ID.self) { ids in
                    if let id = ids.first, let process = snapshot.processes.first(where: { $0.id == id }), !snapshot.ownConnectionIDs.contains(id) {
                        Button("Kill Query…") { model.confirmKill(process, in: snapshot, connection: false) }
                        Button("Kill Connection…") { model.confirmKill(process, in: snapshot, connection: true) }
                        if let statement = process.statement {
                            Divider()
                            Button("Open Statement in Editor") { model.workspace.openSQL(text: statement, database: process.database) }
                            Button("Copy Statement") { Pasteboard.copy(statement) }
                        }
                    }
                }
            }
        }
    }

    private func rows(_ snapshot: ProcessListSnapshot) -> [SessionProcess] {
        let filter = model.filter.trimmingCharacters(in: .whitespaces)
        return snapshot.processes.filter { process in
            guard !snapshot.ownConnectionIDs.contains(process.id) else { return false }
            guard model.includeIdle || process.command?.lowercased() != "sleep" else { return false }
            guard !filter.isEmpty else { return true }
            return [process.user, process.host, process.database, process.statement, process.state].contains { $0?.localizedCaseInsensitiveContains(filter) == true }
        }
        .sorted { ($0.timeSeconds ?? 0) > ($1.timeSeconds ?? 0) }
    }
}

// MARK: - InnoDB

private struct InnoDBView: View {
    let model: ServerModel

    var body: some View {
        LoadableView(state: model.innodb, retry: { model.refresh() }) { activity in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !activity.unavailable.isEmpty {
                        NoticeBanner(message: activity.unavailable.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"), systemImage: "lock")
                    }
                    Card(title: "Lock waits · \(activity.lockWaits.count)", systemImage: "lock.trianglebadge.exclamationmark") {
                        if activity.lockWaits.isEmpty {
                            Text("No session is waiting for a lock.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(activity.lockWaits) { wait in LockWaitRow(wait: wait, model: model) }
                            }
                        }
                    }
                    Card(title: "Transactions · \(activity.transactions.count)", systemImage: "arrow.left.arrow.right") {
                        if activity.transactions.isEmpty {
                            Text("No open InnoDB transactions.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(activity.transactions.prefix(200)) { trx in
                                    HStack(alignment: .top, spacing: 8) {
                                        StateBadge(state: trx.state)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Session \(trx.threadID.map(String.init) ?? "?") · \(Format.duration(seconds: trx.ageSeconds.map(Double.init))) · \(trx.rowsLocked ?? 0) rows locked · \(trx.rowsModified ?? 0) modified")
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(trx.query.map { SQLRedactor.redact(String($0.prefix(300))) } ?? "(idle in transaction)")
                                                .font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let deadlock = activity.latestDeadlock {
                        Card(title: "Latest detected deadlock", systemImage: "exclamationmark.octagon") {
                            Text(SQLRedactor.redact(deadlock)).font(Theme.monospacedSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

private struct LockWaitRow: View {
    let wait: LockWait
    let model: ServerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass").foregroundStyle(.orange)
                Text("Session \(wait.waitingThread.map(String.init) ?? "?") waits \(Format.duration(seconds: wait.waitSeconds.map(Double.init)))")
                    .font(.callout.weight(.semibold))
                Text("for \(wait.lockMode ?? "?") \(wait.lockType ?? "") lock on \(wait.lockedTable ?? "?")\(wait.lockedIndex.map { " (\($0))" } ?? "")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(wait.waitingQuery.map { SQLRedactor.redact(String($0.prefix(300))) } ?? "").font(Theme.monospacedSmall).lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.red).imageScale(.small)
                Text("Blocked by session \(wait.blockingThread.map(String.init) ?? "?"):").font(.caption)
                Text(wait.blockingQuery.map { SQLRedactor.redact(String($0.prefix(200))) } ?? "(idle in transaction)").font(Theme.monospacedSmall).lineLimit(1)
                Spacer()
                if let blocker = wait.blockingThread {
                    Button("Kill Blocker…") {
                        model.pendingAction = ServerModel.PendingAction(title: "Kill connection \(blocker)?", message: "Its transaction is rolled back and the waiting session continues.",
                                                                        confirmLabel: "Kill Connection") { [client = model.client] in
                            try await client.killConnection(KillTarget(threadID: blocker, proxySessionID: nil, identity: model.info.isProxySQL ? nil : model.innodb.value?.identity))
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.info.isProxySQL)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Statements

private struct StatementsView: View {
    @Bindable var model: ServerModel

    var body: some View {
        LoadableView(state: model.statements, retry: { model.refresh() }) { digests in
            let filter = model.filter.trimmingCharacters(in: .whitespaces)
            let shown = filter.isEmpty ? digests : digests.filter { $0.text.localizedCaseInsensitiveContains(filter) || ($0.schema ?? "").localizedCaseInsensitiveContains(filter) }
            VStack(spacing: 0) {
                HStack {
                    FilterField(text: $model.filter, prompt: "Filter statements")
                    Picker("Order by", selection: $model.statementOrder) {
                        ForEach(StatementOrder.allCases) { Text($0.displayName).tag($0) }
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    Text("performance_schema digests since the last reset").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Table(shown) {
                    TableColumn("Statement") { digest in
                        Text(SQLRedactor.redact(String(digest.text.prefix(600)))).font(Theme.monospacedSmall).lineLimit(3).textSelection(.enabled)
                    }
                    .width(min: 260, ideal: 460)
                    TableColumn("Schema") { Text($0.schema ?? "").foregroundStyle(.secondary) }.width(min: 60, ideal: 90)
                    TableColumn("Calls") { Text(Format.count($0.executions)).monospacedDigit() }.width(70)
                    TableColumn("Total") { Text(Format.duration(seconds: $0.totalSeconds)).monospacedDigit() }.width(70)
                    TableColumn("Avg") { Text(Format.duration(milliseconds: $0.averageSeconds * 1000)).monospacedDigit() }.width(70)
                    TableColumn("Rows examined / call") { Text(String(format: "%.0f", $0.rowsExaminedPerExecution)).monospacedDigit() }.width(90)
                    TableColumn("Full scans") { digest in
                        Text(Format.count(digest.noIndexUsed)).monospacedDigit().foregroundStyle(digest.noIndexUsed > 0 ? .orange : .secondary)
                    }
                    .width(70)
                    TableColumn("Errors") { digest in Text(Format.count(digest.errors)).monospacedDigit().foregroundStyle(digest.errors > 0 ? .red : .secondary) }
                        .width(56)
                }
                .contextMenu(forSelectionType: StatementDigest.ID.self) { ids in
                    if let id = ids.first, let digest = digests.first(where: { $0.id == id }) {
                        Button("Open in Editor") { model.workspace.openSQL(text: digest.sample ?? digest.text, database: digest.schema) }
                        Button("Copy Statement") { Pasteboard.copy(digest.sample ?? digest.text) }
                    }
                }
            }
        }
    }
}

// MARK: - Replication

private struct ReplicationView: View {
    let model: ServerModel

    var body: some View {
        LoadableView(state: model.replication, retry: { model.refresh() }) { replication in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        StatTile(title: "Role", value: ServerOverview.roleName(replication.role), systemImage: "arrow.triangle.branch")
                        StatTile(title: "Read-only", value: model.info.readOnly ? (model.info.superReadOnly ? "super_read_only" : "ON") : "OFF", systemImage: "lock")
                        StatTile(title: "GTID", value: replication.gtidMode ?? (replication.executedGTIDSet == nil ? "—" : "ON"), systemImage: "number")
                    }
                    if replication.channels.isEmpty, replication.groupMembers.isEmpty, replication.galera.isEmpty, replication.connectedReplicas.isEmpty {
                        NoticeBanner(message: "This server is not replicating and has no registered replicas.")
                    }
                    ForEach(replication.channels) { channel in ChannelCard(channel: channel) }
                    if let file = replication.binlogFile {
                        Card(title: "Binary log (as a source)", systemImage: "doc.text") {
                            KeyValueList(items: [("File", file), ("Position", replication.binlogPosition.map(String.init) ?? "?")]
                                         + (replication.executedGTIDSet.map { [("Executed GTID set", $0)] } ?? []), monospacedValues: true)
                        }
                    }
                    if !replication.connectedReplicas.isEmpty {
                        Card(title: "Connected replicas · \(replication.connectedReplicas.count)", systemImage: "point.3.connected.trianglepath.dotted") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(replication.connectedReplicas.enumerated()), id: \.offset) { _, replica in
                                    Text(replica.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")).font(Theme.monospacedSmall)
                                }
                            }
                        }
                    }
                    if !replication.groupMembers.isEmpty {
                        Card(title: "Group Replication\(replication.groupName.map { " · \($0)" } ?? "")", systemImage: "circle.hexagongrid") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(replication.groupMembers) { member in
                                    HStack {
                                        StateBadge(state: member.state ?? "?")
                                        Text("\(member.host ?? "?"):\(member.port.map(String.init) ?? "?")").font(.callout.weight(.medium))
                                        if let role = member.role { Badge(text: role, color: Theme.color(forState: role)) }
                                        Spacer()
                                        Text(member.version ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !replication.galera.isEmpty {
                        Card(title: "Galera cluster", systemImage: "circle.grid.cross") {
                            KeyValueList(items: replication.galera.filter { Self.galeraKeys.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                         monospacedValues: true)
                        }
                    }
                    if !replication.innoDBClusterInstances.isEmpty {
                        Card(title: "InnoDB Cluster metadata", systemImage: "square.stack.3d.up") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(replication.innoDBClusterInstances.enumerated()), id: \.offset) { _, instance in
                                    Text([instance["instance_name"], instance["address"], instance["mysql_server_uuid"]].compactMap { $0 }.joined(separator: " · "))
                                        .font(Theme.monospacedSmall)
                                }
                            }
                        }
                    }
                    if !replication.unavailable.isEmpty {
                        NoticeBanner(message: replication.unavailable.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"), systemImage: "lock")
                    }
                }
                .padding(18)
            }
        }
    }

    static let galeraKeys: Set<String> = ["wsrep_cluster_size", "wsrep_cluster_status", "wsrep_local_state_comment", "wsrep_ready", "wsrep_connected",
                                          "wsrep_flow_control_paused", "wsrep_incoming_addresses", "wsrep_provider_version", "wsrep_cluster_state_uuid",
                                          "wsrep_local_recv_queue_avg", "wsrep_local_send_queue_avg", "wsrep_cert_deps_distance"]
}

private struct ChannelCard: View {
    let channel: ReplicaChannel

    private var items: [(String, String)] {
        var items: [(String, String)] = [("Source", "\(channel.sourceUser ?? "?")@\(channel.sourceHost ?? "?"):\(channel.sourcePort.map(String.init) ?? "3306")")]
        if let file = channel.sourceLogFile { items.append(("Read position", "\(file):\(channel.readSourceLogPosition.map(String.init) ?? "?")")) }
        if let file = channel.executedSourceLogFile { items.append(("Executed position", "\(file):\(channel.executedSourceLogPosition.map(String.init) ?? "?")")) }
        if let gtid = channel.retrievedGTIDSet { items.append(("Retrieved GTIDs", gtid)) }
        if let gtid = channel.executedGTIDSet { items.append(("Executed GTIDs", gtid)) }
        if let state = channel.sqlState { items.append(("SQL thread", state)) }
        return items
    }

    var body: some View {
        Card(title: channel.name.isEmpty ? "Replica of \(channel.sourceHost ?? "?")" : "Channel \(channel.name)", systemImage: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Badge(text: "IO \(channel.ioRunning ?? "?")", color: Theme.color(forState: channel.ioRunning ?? ""))
                    Badge(text: "SQL \(channel.sqlRunning ?? "?")", color: Theme.color(forState: channel.sqlRunning ?? ""))
                    Text(channel.secondsBehind.map { "\($0) s behind" } ?? "lag unknown")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle((channel.secondsBehind ?? 0) > 30 ? .orange : .primary)
                    Spacer()
                }
                KeyValueList(items: items, monospacedValues: true)
                if let error = channel.lastIOError { ErrorBanner(message: "IO: \(error)") }
                if let error = channel.lastSQLError { ErrorBanner(message: "SQL: \(error)") }
            }
        }
    }
}

// MARK: - Variables / status

private struct VariablesView: View {
    @Bindable var model: ServerModel
    let state: Loadable<[ServerVariable]>
    let rates: [String: Double]

    var body: some View {
        LoadableView(state: state, retry: { model.refresh() }) { variables in
            let filter = model.filter.trimmingCharacters(in: .whitespaces)
            let shown = filter.isEmpty ? variables : variables.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
            VStack(spacing: 0) {
                HStack {
                    FilterField(text: $model.filter, prompt: "Filter by name or value")
                    Spacer()
                    Text("\(shown.count) of \(variables.count)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Table(shown) {
                    TableColumn("Name") { Text($0.name).font(Theme.monospacedSmall).textSelection(.enabled) }.width(min: 200, ideal: 320)
                    TableColumn("Value") { Text($0.value).font(Theme.monospacedSmall).textSelection(.enabled).lineLimit(3) }
                    TableColumn(rates.isEmpty ? "" : "Per second") { variable in
                        Text(rates[variable.name].map { $0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.2f", $0) } ?? "")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(rates.isEmpty ? 1 : 100)
                }
            }
        }
    }
}

// MARK: - Users

private struct UsersView: View {
    @Bindable var model: ServerModel

    var body: some View {
        LoadableView(state: model.accounts, retry: { model.refresh() }) { accounts in
            HSplitView {
                Table(accounts, selection: Binding(get: { model.selectedAccount?.id }, set: { id in model.selectedAccount = accounts.first { $0.id == id } })) {
                    TableColumn("User") { account in
                        HStack(spacing: 4) {
                            if account.isRole == true { Image(systemName: "person.3").foregroundStyle(.secondary).help("Role") }
                            Text(account.user.isEmpty ? "(anonymous)" : account.user)
                        }
                    }
                    .width(min: 80, ideal: 140)
                    TableColumn("Host") { Text($0.host).foregroundStyle(.secondary) }.width(min: 60, ideal: 110)
                    TableColumn("Plugin") { Text($0.plugin ?? "").font(.caption) }.width(min: 80, ideal: 150)
                    TableColumn("Locked") { Text($0.isLocked == true ? "YES" : "").foregroundStyle(.orange) }.width(50)
                    TableColumn("Expired") { Text($0.passwordExpired == true ? "YES" : "").foregroundStyle(.orange) }.width(56)
                }
                .frame(minWidth: 380)
                VStack(alignment: .leading, spacing: 8) {
                    if let account = model.selectedAccount {
                        Text("Grants for \(account.id)").font(.headline)
                        LoadableView(state: model.grants) { lines in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(Theme.monospacedSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        Text("Read-only view; change privileges with GRANT / REVOKE in a SQL tab.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("Select an account", systemImage: "person.badge.key", description: Text("Its grants appear here."))
                    }
                }
                .padding(14)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}
