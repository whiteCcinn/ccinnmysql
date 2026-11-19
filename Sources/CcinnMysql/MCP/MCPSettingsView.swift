import CcinnMysqlKit
import MySQLKit
import SwiftUI

/// Settings → MCP: which connections AI clients may use, and how to register the server.
struct MCPSettingsView: View {
    let store: ProfileStore
    @State private var copied: String?
    /// Results of "Check account" per connection.
    @State private var reports: [UUID: String] = [:]
    @State private var checking: Set<UUID> = []

    private var command: String { MCPCommand.executablePath }

    private var snippets: [(title: String, text: String)] {
        let quoted = command.replacingOccurrences(of: "\"", with: "\\\"")
        return [
            ("Claude Code", "claude mcp add ccinnmysql -- \"\(quoted)\" mcp"),
            ("Codex (~/.codex/config.toml)", "[mcp_servers.ccinnmysql]\ncommand = \"\(quoted)\"\nargs = [\"mcp\"]"),
            ("Claude Desktop / JSON", "{\n  \"mcpServers\": {\n    \"ccinnmysql\": {\n      \"command\": \"\(quoted)\",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"),
        ]
    }

    /// Connects with the profile and fills `reports` with what read-only AI access means for its account.
    private func check(_ profile: ConnectionProfile) {
        checking.insert(profile.id)
        let password = store.password(for: profile) ?? ""
        let sshSecret = store.sshSecret(for: profile)
        let passphrase = store.repository.clientCertificatePassphrase(for: profile)
        Task {
            let text: String
            do {
                let client = try await ClientOpener.open(profile: profile, password: password, sshSecret: sshSecret,
                                                         clientCertificatePassphrase: passphrase, poolSize: 1)
                defer { Task { await client.close() } }
                text = try await AIAccessReport.load(client: client).summary(allowsPrivilegedAccount: profile.aiAllowsPrivilegedAccount)
            } catch {
                text = "Could not check this account: \((error as? MySQLError)?.message ?? error.localizedDescription)"
            }
            reports[profile.id] = text
            checking.remove(profile.id)
        }
    }

    var body: some View {
        Form {
            Section {
                Text("CcinnMysql includes a Model Context Protocol server, so AI assistants such as Claude Code, Codex and Claude Desktop can explore your MySQL and MariaDB servers, diagnose locks and slow statements, and run queries through your saved connections. Passwords stay in your Keychain and are never shown to the AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Each database can have a knowledge base (Knowledge in a connected window's toolbar). It records how tables relate, from foreign keys, view and routine definitions, your query history and naming, plus what AI sessions learn from your code, so AI assistants answer from it instead of exploring table by table.",
                      systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Connections available to AI") {
                if store.profiles.isEmpty {
                    Text("No saved connections yet.").foregroundStyle(.secondary)
                }
                ForEach(store.profiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { profile in
                    Picker(selection: Binding(get: { profile.mcpAccess }, set: { store.setMCPAccess($0, for: profile) })) {
                        ForEach(MCPAccess.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.color(for: profile.color).gradient).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName)
                                Text(profile.hostSummary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if profile.mcpAccess == .readOnly {
                        Toggle(isOn: Binding(get: { profile.aiAllowsPrivilegedAccount },
                                             set: { store.setAIAllowsPrivilegedAccount($0, for: profile) })) {
                            Text("Allow read-only AI access with a privileged account, and stored functions")
                        }
                        .padding(.leading, 17)
                        .help("Off: read-only AI tools refuse an account with FILE, SUPER, PROCESS, any dynamic privilege not reviewed as harmless (every *_ADMIN, INNODB_REDO_LOG_ARCHIVE, …), global ALL PRIVILEGES, or SELECT on *.*, mysql.*, performance_schema.* or sys.* (also through a matching database pattern such as % and through roles), and call only reviewed built-in functions. On: the AI may also call stored, loadable and component functions, whose insides can't be checked, and with PROCESS it can see other sessions' statements through existing views or routines over the process list.")
                        HStack(alignment: .firstTextBaseline) {
                            Button(checking.contains(profile.id) ? "Checking…" : "Check account") { check(profile) }
                                .disabled(checking.contains(profile.id))
                                .help("Connects with this account and reports whether read-only AI tools accept it, and which definer-rights routines and views run with a privileged account's rights.")
                            if let report = reports[profile.id] {
                                Text(report).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 17)
                    }
                    if profile.mcpAccess != .disabled {
                        Toggle(isOn: Binding(get: { profile.mcpKnowledgeWrites }, set: { store.setMCPKnowledgeWrites($0, for: profile) })) {
                            Text("AI may write knowledge")
                            Text("Lets AI sessions add notes, relationships, glossary terms and project links to this Mac's knowledge base. It never changes the server, so it works with read-only access too.")
                        }
                        .padding(.leading, 17)
                    }
                }
                Text("Read-only allows metadata and diagnostics tools and SELECT / SHOW / DESCRIBE / EXPLAIN inside read-only transactions, at most 1,000 rows per call. Read & write adds a tool that runs any statement. Every call is logged to mcp-audit.jsonl in the app's data folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("Read-only means no data or schema changes, but what an existing stored function or view does can't be inspected. With an account that has FILE, SUPER, PROCESS, an unreviewed dynamic privilege (*_ADMIN, INNODB_REDO_LOG_ARCHIVE, …), global ALL PRIVILEGES, or SELECT on *.*, mysql.*, performance_schema.* or sys.* (as local root has), such a function or view could write or read server files or read password hashes and other sessions' statements, so read-only AI tools refuse these accounts unless you allow it above. Use a dedicated MySQL user with SELECT (and SHOW VIEW) on the schemas the AI may read; the process list and InnoDB status tools need PROCESS, which needs the allowance above.", systemImage: "person.badge.shield.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Add the server to your AI client") {
                ForEach(snippets, id: \.title) { snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(snippet.title).font(.callout.weight(.semibold))
                            Spacer()
                            Button(copied == snippet.title ? "Copied" : "Copy") {
                                Pasteboard.copy(snippet.text)
                                copied = snippet.title
                            }
                            .controlSize(.small)
                        }
                        Text(snippet.text)
                            .font(Theme.monospacedSmall)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("Add `--read-only` after `mcp` to cap every connection at read-only, or `--profile <name>` to pick the default connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }
}
