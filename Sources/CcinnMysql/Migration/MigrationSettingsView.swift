import AppKit
import CcinnMysqlKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Backup: export connections, passwords (encrypted) and knowledge bases to one file, and import it on
/// another Mac. Key derivation, encoding and file I/O run off the main actor.
struct MigrationSettingsView: View {
    let store: ProfileStore
    let knowledge: KnowledgeStore

    @State private var includeKnowledge = true
    @State private var includePasswords = false
    @State private var passphrase = ""
    @State private var repeated = ""
    @State private var isExporting = false
    @State private var exportResult: (message: String, isError: Bool)?

    @State private var backupURL: URL?
    @State private var backup: MigrationBundle?
    @State private var importPassphrase = ""
    @State private var replaceExisting = false
    @State private var isImporting = false
    @State private var importReport: MigrationImporter.Report?
    @State private var importError: String?

    private var backupType: UTType { UTType(filenameExtension: MigrationBundle.fileExtension) ?? .json }

    private var passphraseProblem: String? {
        guard includePasswords else { return nil }
        if passphrase.count < SecretSealing.minimumPassphraseLength { return "Use at least \(SecretSealing.minimumPassphraseLength) characters." }
        if passphrase != repeated { return "The passphrases differ." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Text("Move your saved connections, their knowledge bases and linked code folders to another Mac: export here, then import the file on the new Mac. Folder paths under your home folder are adjusted to the new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            exportSection
            importSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }

    // MARK: Export

    private var exportSection: some View {
        Section("Export") {
            Text(Format.counted(store.profiles.count, "saved connection")).foregroundStyle(.secondary)
            Toggle("Include knowledge bases (relationships, notes, linked folders)", isOn: $includeKnowledge)
            Toggle("Include passwords, encrypted with a passphrase", isOn: $includePasswords)
            if includePasswords {
                SecureField("Passphrase", text: $passphrase)
                SecureField("Repeat passphrase", text: $repeated)
                Text(passphraseProblem ?? "You need this passphrase to import the passwords. It is not stored anywhere and cannot be recovered.")
                    .font(.caption)
                    .foregroundStyle(passphraseProblem == nil ? Color.secondary : Color.orange)
            }
            HStack {
                Button(isExporting ? "Exporting…" : "Export…", action: export)
                    .disabled(isExporting || store.profiles.isEmpty || passphraseProblem != nil)
                if let exportResult {
                    Text(exportResult.message)
                        .font(.caption)
                        .foregroundStyle(exportResult.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            Text("The file is readable only by you. Without passwords it contains no secrets; query history and row data are never included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [backupType]
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        panel.nameFieldStringValue = "CcinnMysql-\(date).\(MigrationBundle.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profiles = store.profiles
        let repository = store.repository
        let knowledge = includeKnowledge ? knowledge : nil
        let secret = includePasswords ? passphrase : nil
        isExporting = true
        exportResult = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(Int, Int, [String]), any Error> in
                Result {
                    let made = try MigrationExporter.bundle(profiles: profiles, repository: repository, store: knowledge, passphrase: secret,
                                                            appVersion: AppInfo.version)
                    try PrivateFile.write(try made.bundle.encoded(), to: url)
                    return (made.bundle.connections.count, made.bundle.knowledge.count, made.warnings)
                }
            }.value
            isExporting = false
            switch result {
            case let .success((connections, bases, warnings)):
                passphrase = ""
                repeated = ""
                exportResult = ("Exported \(Format.counted(connections, "connection")) and \(Format.counted(bases, "knowledge base")) to \(url.lastPathComponent)."
                    + (warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n")), false)
            case let .failure(error):
                exportResult = ("Export failed: \(error.localizedDescription)", true)
            }
        }
    }

    // MARK: Import

    private var importSection: some View {
        Section("Import") {
            HStack {
                Button("Choose Backup…", action: chooseBackup)
                if let backupURL { Text(backupURL.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            if let backup {
                Text("Made \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) by CcinnMysql \(backup.appVersion): \(Format.counted(backup.connections.count, "connection")), \(Format.counted(backup.knowledge.count, "knowledge base"))\(backup.secrets == nil ? ", no passwords" : ", encrypted passwords").")
                    .font(.callout)
                if backup.secrets != nil {
                    SecureField("Passphrase (leave empty to import without passwords)", text: $importPassphrase)
                }
                Toggle("Replace connections that already exist here (same connection)", isOn: $replaceExisting)
                Text("Knowledge bases are merged: newer notes win, your own notes are never replaced by an AI's, and linked folders are added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isImporting ? "Importing…" : "Import", action: runImport)
                    .disabled(isImporting)
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            if let importReport {
                ImportReportView(report: importReport)
            }
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [backupType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupURL = url
        backup = nil
        importReport = nil
        importError = nil
        importPassphrase = ""
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try MigrationBundle.read(from: url) } }.value
            switch result {
            case let .success(bundle): backup = bundle
            case let .failure(error): importError = error.localizedDescription
            }
        }
    }

    private func runImport() {
        guard let backup else { return }
        let importer = MigrationImporter(repository: store.repository, store: knowledge)
        let options = MigrationImporter.Options(replaceExisting: replaceExisting, passphrase: importPassphrase.isEmpty ? nil : importPassphrase)
        isImporting = true
        importError = nil
        importReport = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<MigrationImporter.Report, any Error> in
                do {
                    return .success(try await importer.run(backup, options: options))
                } catch {
                    return .failure(error)
                }
            }.value
            isImporting = false
            switch result {
            case let .success(report):
                importReport = report
                importPassphrase = ""
                store.reload()
            case let .failure(error):
                importError = error.localizedDescription
            }
        }
    }
}

private struct ImportReportView: View {
    let report: MigrationImporter.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Import finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            line("Added", report.added)
            line("Replaced", report.updated)
            line("Kept (already here)", report.skipped)
            if report.secretsRestored > 0 { Text("Passwords restored for \(Format.counted(report.secretsRestored, "connection")).").font(.caption) }
            if report.secretsSkipped { Text("Passwords were not imported (no passphrase).").font(.caption).foregroundStyle(.orange) }
            line("Knowledge bases created", report.knowledgeCreated)
            line("Knowledge bases merged", report.knowledgeMerged)
            line("Paths adjusted", report.remapped)
            if !report.missing.isEmpty {
                line("Not found on this Mac", report.missing)
                Text("Use Locate… in a database's Knowledge tab for a moved code folder, and edit the connection for certificate or key files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text("\(title): \(items.joined(separator: ", "))").font(.caption)
        }
    }
}
