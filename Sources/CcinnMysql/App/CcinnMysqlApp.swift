import AppKit
import CcinnMysqlKit
import MySQLKit
import SwiftUI

struct CcinnMysqlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        // Every window has its own connection. A request opens a window that connects right away.
        WindowGroup("CcinnMysql", id: RootView.windowGroupID, for: WindowRequest.self) { $request in
            RootView(request: request)
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
            UpdateCommands()
        }

        Settings {
            SettingsTabs()
            .frame(width: 620)
            .tint(Theme.accent)
        }

        SoftwareUpdateScene()
    }
}

private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MCPSettingsView(store: AppServices.shared.profiles)
                .tabItem { Label("MCP", systemImage: "sparkles") }
                .tag("mcp")
            MigrationSettingsView(store: AppServices.shared.profiles, knowledge: AppServices.shared.knowledgeStore)
                .tabItem { Label("Backup", systemImage: "externaldrive") }
                .tag("backup")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restored windows would only reopen the connection screen; start with one clean window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotTool.isRequested {
            // Automated captures render off-screen without a Dock icon and never take focus.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Behave like a regular app when launched from `swift run` (no bundle).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        if let appearance = LaunchArguments.value("--appearance") {
            NSApp.appearance = NSAppearance(named: appearance.lowercased() == "dark" ? .darkAqua : .aqua)
        }
        SnapshotTool.scheduleIfRequested()
        UpdateController.shared.scheduleAutomaticCheck()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close SSH port forwards synchronously; detached cleanup tasks do not run during exit.
        SSHTunnel.terminateAll()
    }
}

/// Per-window root: connection manager, progress, or workspace.
struct RootView: View {
    static let windowGroupID = "main"

    /// Set when the window was opened for a connection (Open in New Window, New Window with This Connection).
    let request: WindowRequest?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var session = WindowSession()
    private let store = AppServices.shared.profiles

    var body: some View {
        Group {
            switch session.phase {
            case .connections:
                ConnectionsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name, status):
                ConnectingView(name: name, status: status) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .presentsSoftwareUpdates()
        .onDisappear { session.disconnect() }
        .task {
            // Windows opened by this process connect and skip the launch arguments. Every other window (no request,
            // or a request macOS restored) falls through to the File ▸ New Window path below.
            if session.connect(request, store: store) { return }
            LaunchArguments.consume(into: session, store: store) { openWindow(id: Self.windowGroupID, value: $0) }
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--settings"), arguments.indices.contains(index + 1) {
                UserDefaults.standard.set(arguments[index + 1], forKey: "settingsTab")
                openSettings()
            }
        }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .connections: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .connections: "CcinnMysql — Connections"
        case let .connecting(name, _): "Connecting to \(name)"
        case let .connected(workspace): workspace.profile.displayName
        }
    }
}

/// Full-window progress while a connection is being established.
struct ConnectingView: View {
    let name: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64).symbolEffect(.pulse)
            Text("Connecting to \(name)").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Developer conveniences, deep links and automated visual checks:
/// `CcinnMysql --connect host:port [--user u] [--database db] [--tls disabled|preferred|required|verifyCA|verifyIdentity]
///  [--object schema.name] [--section overview|columns|indexes|foreign|partitions|insights|ddl|data] [--sql "…"] [--auto-run]
///  [--view grid|chart|plan] [--server overview|processlist|innodb|statements|replication|variables|status|users] [--profile name]
///  [--duplicate-window] [--format] [--appearance light|dark]`. The password comes from `CCINNMYSQL_PASSWORD` (never the command line).
/// Applied once per process, in the first window opened without a connection request.
@MainActor
enum LaunchArguments {
    private static var consumed = false

    static func value(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `openWindow` opens the window for `--duplicate-window`.
    static func consume(into session: WindowSession, store: ProfileStore, openWindow: @escaping @MainActor (WindowRequest) -> Void) {
        guard !consumed else { return }
        consumed = true
        let arguments = ProcessInfo.processInfo.arguments
        let profile: ConnectionProfile
        var password: String?
        if let name = value("--profile"), let saved = store.profiles.first(where: { $0.displayName == name }) {
            profile = saved
        } else if let raw = value("--connect") {
            let parts = raw.split(separator: ":")
            let host = parts.first.map(String.init) ?? "127.0.0.1"
            let port = parts.count > 1 ? Int(parts[1]) ?? 3306 : 3306
            profile = ConnectionProfile(name: value("--name") ?? "\(host):\(port)", host: host, port: port, username: value("--user") ?? "root",
                                        defaultDatabase: value("--database"), color: .teal,
                                        tlsMode: value("--tls").flatMap(TLSMode.init(rawValue:)) ?? .preferred,
                                        allowPublicKeyRetrieval: arguments.contains("--allow-public-key-retrieval"),
                                        connectTimeout: value("--connect-timeout").flatMap(Double.init) ?? 30)
            // Passwords never go on the command line (visible to other processes); use the environment.
            password = ProcessInfo.processInfo.environment["CCINNMYSQL_PASSWORD"] ?? ""
        } else {
            return
        }
        session.connect(profile: profile, store: store, password: password) { workspace in
            // Automated checks of multiple windows: a second window with this connection, once.
            if arguments.contains("--duplicate-window"), let request = session.duplicateRequest() { openWindow(request) }
            Task { @MainActor in
                if let target = value("--object"), let dot = target.firstIndex(of: ".") {
                    let database = String(target[..<dot])
                    let name = String(target[target.index(after: dot)...])
                    workspace.setExpanded(database, true)
                    if let object = await workspace.awaitObjects(database: database)?.first(where: { $0.name == name }) {
                        let section = value("--section").flatMap { raw in
                            ObjectDetailModel.Section.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
                        }
                        workspace.openObject(object, section: section)
                    }
                }
                if let sql = value("--sql") {
                    let model = workspace.openSQL(text: sql.replacingOccurrences(of: "\\n", with: "\n"), database: value("--database"))
                    if arguments.contains("--format") {
                        try? await Task.sleep(for: .milliseconds(300)) // let the editor attach so the edit is undoable
                        model.formatSQL()
                        for _ in 0..<100 where model.isFormatting { try? await Task.sleep(for: .milliseconds(20)) }
                    }
                    if arguments.contains("--auto-run") {
                        model.runAll()
                        if let view = value("--view"), let mode = StatementOutcome.ViewMode.allCases.first(where: { $0.rawValue.lowercased() == view.lowercased() }) {
                            for _ in 0..<100 where model.isRunning || model.outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                            model.selectedOutcome?.viewMode = mode
                        }
                        if let format = value("--export"), let path = value("--export-to") {
                            await model.runAutomatedExport(format: format, to: path)
                        }
                    }
                }
                if let database = value("--knowledge") {
                    workspace.openKnowledge(database: database)
                    if case let .knowledge(model)? = workspace.selectedTab?.kind {
                        if let raw = value("--knowledge-section"),
                           let section = KnowledgeModel.Section.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }) {
                            model.section = section
                        }
                        model.selectedTable = value("--knowledge-table")
                        if arguments.contains("--knowledge-build") { model.build() }
                    }
                }
                if let raw = value("--server"),
                   let section = ServerModel.Section.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(raw.lowercased()) }) {
                    workspace.openServer(section: section)
                }
            }
        }
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot] [--snapshot-window title]`: renders the
/// key (else frontmost) window into a PNG (automated visual checks; no screen-recording permission). Windows are kept
/// off-screen and never activated.
@MainActor
enum SnapshotTool {
    static var isRequested: Bool { LaunchArguments.value("--snapshot") != nil }

    static func scheduleIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let path = LaunchArguments.value("--snapshot") else { return }
        let delay = LaunchArguments.value("--snapshot-delay").flatMap(Double.init) ?? 6.0
        let quit = arguments.contains("--quit-after-snapshot")
        // Keep every window off-screen while the app renders.
        let parker = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { parkWindowsOffscreen() }
        }
        RunLoop.main.add(parker, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            parker.invalidate()
            // The key window, else front to back: with several windows, the one opened last.
            var candidates = [NSApp.keyWindow].compactMap { $0 } + NSApp.orderedWindows + NSApp.windows
            if let title = LaunchArguments.value("--snapshot-window") {
                candidates = NSApp.windows.filter { $0.title.localizedCaseInsensitiveContains(title) } + candidates
            }
            if let window = candidates.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
               let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }

    private static func parkWindowsOffscreen() {
        for window in NSApp.windows where window.frame.origin.x > -10_000 {
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -20_000 - window.frame.width, y: -20_000))
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("autoLimit") private var autoLimit = 1000
    @AppStorage("sqlFormatKeywordCase") private var formatKeywordCase = SQLFormatOptions.KeywordCase.upper.rawValue
    @AppStorage("sqlFormatIndent") private var formatIndent = 2

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Automatic LIMIT for SELECT", selection: $autoLimit) {
                Text("None").tag(0)
                ForEach([100, 500, 1000, 5000, 10_000, 50_000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Format SQL: keyword case", selection: $formatKeywordCase) {
                Text("UPPER").tag(SQLFormatOptions.KeywordCase.upper.rawValue)
                Text("lower").tag(SQLFormatOptions.KeywordCase.lower.rawValue)
                Text("Unchanged").tag(SQLFormatOptions.KeywordCase.preserve.rawValue)
            }
            .help("Applies to reserved keywords only; names and functions always keep their case.")
            Picker("Format SQL: indent", selection: $formatIndent) {
                Text("2 spaces").tag(2)
                Text("4 spaces").tag(4)
            }
            LabeledContent("Saved connections") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProfileRepository.defaultDirectory])
                }
            }
            UpdateSettingsSections()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Export Connections & Knowledge…") { openBackupSettings() }
            Button("Import Connections & Knowledge…") { openBackupSettings() }
        }
        CommandGroup(after: .newItem) {
            // File ▸ New Window (⌘N) comes from the window group and opens the connection screen.
            Button("New Window with This Connection") {
                if let request = session?.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(session?.workspace == nil)
            Divider()
            Button("New Query") { session?.workspace?.openSQL() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.workspace == nil)
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Format SQL") { session?.workspace?.selectedSQL?.formatSQL() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedSQL == nil)
        }
        CommandMenu("Server") {
            Button("Refresh Schemas") { session?.workspace?.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Overview") { session?.workspace?.openServer(section: .overview) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("Processlist") { session?.workspace?.openServer(section: .processlist) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("InnoDB Locks") { session?.workspace?.openServer(section: .innodb) }
                .disabled(session?.workspace == nil)
            Button("Top Statements") { session?.workspace?.openServer(section: .statements) }
                .disabled(session?.workspace == nil)
            Button("Replication") { session?.workspace?.openServer(section: .replication) }
                .disabled(session?.workspace == nil)
            Button("Variables") { session?.workspace?.openServer(section: .variables) }
                .disabled(session?.workspace == nil)
            Button("Users") { session?.workspace?.openServer(section: .users) }
                .disabled(session?.workspace == nil)
            Divider()
            Button("Close Tab") { session?.workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedTab == nil)
            Button("Next Tab") { session?.workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Previous Tab") { session?.workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
    }

    /// Settings → Backup (export and import live there).
    private func openBackupSettings() {
        UserDefaults.standard.set("backup", forKey: "settingsTab")
        openSettings()
    }
}
