import Foundation
import MySQLKit

/// What this Mac holds of what a backup covers, as the planner compares against it.
public struct BackupLocalState: Sendable {
    public var profiles: [ConnectionProfile]
    public var knowledgeIndex: KnowledgeIndex
    public var knowledgeDatabases: [DatabaseKey: DatabaseKnowledge]
    /// Databases whose local file this version cannot rewrite (a newer schema, or unreadable).
    public var unwritableDatabases: Set<DatabaseKey>
    /// `false` when the local index was written by a newer version or cannot be read.
    public var isKnowledgeWritable = true
    public var settings: [String: BackupSettingValue]
    public var history: [UUID: [QueryHistoryEntry]]
    /// Secrets of matched profiles, read only when the backup carries secrets.
    public var secrets: [UUID: BackupProfileSecrets]
    /// Profiles whose secrets could not be read; imported ones never silently replace them.
    public var unreadableSecrets: Set<UUID> = []
    public var warnings: [BackupWarning] = []

    public init(profiles: [ConnectionProfile], knowledgeIndex: KnowledgeIndex = KnowledgeIndex(),
                knowledgeDatabases: [DatabaseKey: DatabaseKnowledge] = [:], unwritableDatabases: Set<DatabaseKey> = [],
                settings: [String: BackupSettingValue] = [:], history: [UUID: [QueryHistoryEntry]] = [:],
                secrets: [UUID: BackupProfileSecrets] = [:]) {
        self.profiles = profiles
        self.knowledgeIndex = knowledgeIndex
        self.knowledgeDatabases = knowledgeDatabases
        self.unwritableDatabases = unwritableDatabases
        self.settings = settings
        self.history = history
        self.secrets = secrets
    }

    /// Reads only what `bundle` needs: knowledge of its databases, history and secrets of the profiles it matches.
    /// Secrets are read only when the backup carries some (each read may ask for Keychain access).
    public static func load(for bundle: BackupBundle, profiles: [ConnectionProfile], knowledge: KnowledgeStore, historyDirectory: URL,
                            settings: [String: BackupSettingValue], secretStore: any SecretStore) -> BackupLocalState {
        var state = BackupLocalState(profiles: profiles, settings: settings)
        let matches = BackupImportPlanner.matches(imported: bundle.payload.profiles, local: profiles)
        if let section = bundle.payload.knowledge {
            state.loadKnowledge(section, from: knowledge)
        }
        if bundle.payload.history != nil {
            for match in matches.values {
                state.history[match.profile.id] = (try? BackupHistoryFiles.read(for: match.profile.id, in: historyDirectory)) ?? []
            }
        }
        for (importedID, match) in matches where bundle.secrets[importedID]?.isEmpty == false {
            state.loadSecrets(of: match.profile.id, from: secretStore)
        }
        if !state.unreadableSecrets.isEmpty { state.warnings.append(.secretsNotChecked) }
        return state
    }

    private mutating func loadKnowledge(_ section: BackupKnowledge, from store: KnowledgeStore) {
        do {
            knowledgeIndex = try store.index()
            isKnowledgeWritable = knowledgeIndex.schemaVersion <= KnowledgeStore.schemaVersion
        } catch {
            isKnowledgeWritable = false
        }
        for database in section.databases {
            do {
                guard let local = try store.database(database.key) else { continue }
                if local.schemaVersion > KnowledgeStore.schemaVersion {
                    unwritableDatabases.insert(database.key)
                } else {
                    knowledgeDatabases[database.key] = local
                }
            } catch {
                unwritableDatabases.insert(database.key)
            }
        }
    }

    private mutating func loadSecrets(of profileID: UUID, from store: any SecretStore) {
        do {
            secrets[profileID] = try BackupProfileSecrets.reading { (kind: SecretKey.Kind) throws -> String? in
                try store.secret(for: SecretKey(profileID: profileID, kind: kind))
            }
        } catch {
            unreadableSecrets.insert(profileID)
        }
    }
}

/// Plans an import: pure, from a decoded backup, this Mac's state, its home directory and a file-existence check.
public enum BackupImportPlanner {
    public static func plan(_ bundle: BackupBundle, local: BackupLocalState, home: String, fileExists: (String) -> Bool,
                            makeID: () -> UUID = UUID.init) -> BackupImportPlan {
        var warnings = bundle.warnings + local.warnings
        let profiles = planProfiles(bundle, local: local, home: home, fileExists: fileExists, makeID: makeID)
        let knowledge = bundle.payload.knowledge.map { (section: BackupKnowledge) -> BackupKnowledgePlan in
            planKnowledge(section, profiles: bundle.payload.profiles, local: local, home: home, fileExists: fileExists, warnings: &warnings)
        }
        let settings = planSettings(bundle.payload.settings ?? [:], local: local.settings, warnings: &warnings)
        let history = (bundle.payload.history ?? []).map { (group: BackupHistory) -> BackupHistoryItem in
            BackupHistoryItem(profileID: group.profile, entries: group.entries.map(BackupHistoryFiles.sanitized))
        }
        return BackupImportPlan(isAuthenticated: bundle.isAuthenticated, profiles: profiles, knowledge: knowledge, settings: settings,
                                history: history, warnings: warnings, localHistory: local.history)
    }

    // MARK: Profiles

    struct ProfileMatch {
        let profile: ConnectionProfile
        let kind: BackupProfileItem.Match
    }

    /// Imported id → the local profile it matches: by id first, then by endpoint. Each local profile matches once.
    static func matches(imported: [ConnectionProfile], local: [ConnectionProfile]) -> [UUID: ProfileMatch] {
        var byID: [UUID: ConnectionProfile] = [:]
        var byEndpoint: [EndpointKey: [ConnectionProfile]] = [:]
        for profile in local {
            if byID[profile.id] == nil { byID[profile.id] = profile }
            byEndpoint[EndpointKey(profile), default: []].append(profile)
        }
        var result: [UUID: ProfileMatch] = [:]
        var used = Set<UUID>()
        for profile in imported {
            guard let match = byID[profile.id] else { continue }
            result[profile.id] = ProfileMatch(profile: match, kind: .id)
            used.insert(match.id)
        }
        for profile in imported where result[profile.id] == nil {
            let candidates = byEndpoint[EndpointKey(profile)] ?? []
            guard let match = candidates.first(where: { !used.contains($0.id) }) else { continue }
            result[profile.id] = ProfileMatch(profile: match, kind: .endpoint)
            used.insert(match.id)
        }
        return result
    }

    /// The account a profile signs in as: host (normalized like `ClusterKey`), port, user name and SSH host. A MySQL
    /// account (`'user'@'client host'`) and its privileges belong to the whole server; the default database is only
    /// where a session starts, so it is not part of it.
    struct EndpointKey: Hashable {
        let host: String
        let port: Int
        let username: String
        let sshHost: String?

        init(_ profile: ConnectionProfile) {
            host = ClusterKey.normalized(profile.host)
            port = profile.port
            username = profile.username.trimmingCharacters(in: .whitespaces)
            sshHost = profile.ssh.map { (ssh: SSHTunnelConfiguration) -> String in ClusterKey.normalized(ssh.host) }
        }
    }

    /// Where a profile's credentials go and how they travel: the endpoint, the SSH port, user and authentication, and TLS
    /// (mode, legacy protocols, RSA key retrieval, the CA, client certificate and pinned server key files). A change sends
    /// the stored password (or the SSH secret, or the client certificate's passphrase) somewhere it was not given for, or
    /// with less protection on the way.
    struct RouteKey: Hashable {
        /// The server and the SSH route to it.
        struct Network: Hashable {
            let endpoint: EndpointKey
            let sshPort: Int?
            let sshUsername: String?
            let sshAuthentication: String?
        }

        struct Security: Hashable {
            let tlsMode: TLSMode
            let allowLegacyTLS: Bool
            let allowPublicKeyRetrieval: Bool
            /// Trimmed, `nil` when blank (as the connection uses them). Compare profiles whose paths are written alike
            /// (`withPortablePaths`).
            let caCertificatePath: String?
            let clientCertificatePath: String?
            let serverPublicKeyPath: String?
        }

        let network: Network
        let security: Security

        init(_ profile: ConnectionProfile) {
            let sshUsername = profile.ssh.map { (ssh: SSHTunnelConfiguration) -> String in ssh.username.trimmingCharacters(in: .whitespaces) }
            network = Network(endpoint: EndpointKey(profile), sshPort: profile.ssh?.port, sshUsername: sshUsername,
                              sshAuthentication: profile.ssh?.authentication.rawValue)
            security = Security(tlsMode: profile.tlsMode, allowLegacyTLS: profile.allowLegacyTLS,
                                allowPublicKeyRetrieval: profile.allowPublicKeyRetrieval,
                                caCertificatePath: profile.caCertificatePath?.nilIfBlank,
                                clientCertificatePath: profile.clientCertificatePath?.nilIfBlank,
                                serverPublicKeyPath: profile.serverPublicKeyPath?.nilIfBlank)
        }
    }

    private static func planProfiles(_ bundle: BackupBundle, local: BackupLocalState, home: String, fileExists: (String) -> Bool,
                                     makeID: () -> UUID) -> [BackupProfileItem] {
        let matches = matches(imported: bundle.payload.profiles, local: local.profiles)
        return bundle.payload.profiles.map { (raw: ConnectionProfile) -> BackupProfileItem in
            let match = matches[raw.id]
            let localProfile = match?.profile
            let localPortable = localProfile.map { (profile: ConnectionProfile) -> ConnectionProfile in withPortablePaths(profile, home: home) }
            var candidate = withPortablePaths(raw, home: home)
            if !bundle.isAuthenticated {
                candidate.aiAllowsPrivilegedAccount = false
                if let localProfile { candidate = keepingPrivilegedOptIn(candidate, from: localProfile) }
            }
            let importedSecrets = bundle.secrets[raw.id] ?? BackupProfileSecrets()
            let localSecrets = localProfile.flatMap { (profile: ConnectionProfile) -> BackupProfileSecrets? in
                local.unreadableSecrets.contains(profile.id) ? nil : (local.secrets[profile.id] ?? BackupProfileSecrets())
            }
            let contentMatches = localPortable.map { (profile: ConnectionProfile) -> Bool in sameContent(candidate, profile) } ?? false
            let secretsDiffer = localSecrets.map { (secrets: BackupProfileSecrets) -> Bool in secretsConflict(importedSecrets, secrets) } ?? false

            var flags = Set<BackupProfileItem.Flag>()
            if raw.aiAllowsPrivilegedAccount && !candidate.aiAllowsPrivilegedAccount { flags.insert(.privilegedOptInReset) }
            if aiAccessDiffers(candidate, localProfile) { flags.insert(.aiAccessChanged) }
            if secretsDiffer { flags.insert(.secretsDiffer) }
            if isKeyMissing(candidate, home: home, fileExists: fileExists) { flags.insert(.missingSSHKey) }
            flags.formUnion(missingFileFlags(candidate, home: home, fileExists: fileExists))
            if let localPortable {
                flags.formUnion(routeFlags(RouteKey(candidate), over: RouteKey(localPortable)))
                if candidate.allowCleartextPassword && !localPortable.allowCleartextPassword { flags.insert(.cleartextPasswordEnabled) }
                if localPortable.confirmMutations && !candidate.confirmMutations { flags.insert(.mutationConfirmationDisabled) }
            }

            let status: BackupProfileItem.Status
            if localProfile == nil {
                status = .new
            } else if contentMatches && !secretsDiffer {
                status = .unchanged
            } else {
                status = .conflict
            }
            let weakens = localProfile.map { (profile: ConnectionProfile) -> Bool in weakensSecurity(candidate, over: profile, flags: flags) } ?? false
            let resolution = defaultResolution(status: status, imported: candidate, local: localProfile, weakensSecurity: weakens,
                                               isAuthenticated: bundle.isAuthenticated)
            return BackupProfileItem(imported: candidate, local: localProfile, match: match?.kind, status: status, defaultResolution: resolution,
                                     resolution: resolution, keepBothID: makeID(), flags: flags, contentMatches: contentMatches,
                                     isAuthenticated: bundle.isAuthenticated, importedSecrets: importedSecrets, localSecrets: localSecrets)
        }
    }

    /// What changes between the local route and the imported one: another server or SSH route, weaker TLS, another CA,
    /// client certificate or pinned server key file.
    static func routeFlags(_ imported: RouteKey, over local: RouteKey) -> Set<BackupProfileItem.Flag> {
        var flags = Set<BackupProfileItem.Flag>()
        let mine = local.security
        let theirs = imported.security
        if imported.network != local.network { flags.insert(.endpointChanged) }
        if tlsWeakens(theirs, over: mine) { flags.insert(.tlsWeakened) }
        if theirs.caCertificatePath != mine.caCertificatePath { flags.insert(.caCertificateChanged) }
        if theirs.clientCertificatePath != mine.clientCertificatePath { flags.insert(.clientCertificateChanged) }
        if theirs.serverPublicKeyPath != mine.serverPublicKeyPath { flags.insert(.serverPublicKeyChanged) }
        return flags
    }

    /// A lower TLS mode, or legacy TLS 1.0/1.1 or retrieving the server's RSA key turned on.
    static func tlsWeakens(_ imported: RouteKey.Security, over local: RouteKey.Security) -> Bool {
        let lowerMode: Bool = tlsModeRank(imported.tlsMode) < tlsModeRank(local.tlsMode)
        let legacyProtocols: Bool = imported.allowLegacyTLS && !local.allowLegacyTLS
        let keyRetrieval: Bool = imported.allowPublicKeyRetrieval && !local.allowPublicKeyRetrieval
        return lowerMode || legacyProtocols || keyRetrieval
    }

    /// `disabled` < `preferred` < `required` < `verifyCA` < `verifyIdentity`: each protects the password more than the
    /// one before.
    static func tlsModeRank(_ mode: TLSMode) -> Int {
        switch mode {
        case .disabled: 0
        case .preferred: 1
        case .required: 2
        case .verifyCA: 3
        case .verifyIdentity: 4
        }
    }

    /// `profile` keeping `previous`'s privileged-account opt-in only while it signs in as the same account on the same
    /// server, as `ClusterKey` tells servers apart (through the same SSH host and port): the opt-in was given for that
    /// account. The default database does not matter; privileges belong to the account.
    static func keepingPrivilegedOptIn(_ profile: ConnectionProfile, from previous: ConnectionProfile) -> ConnectionProfile {
        var copy = profile
        let sameAccount: Bool = EndpointKey(profile) == EndpointKey(previous)
        let sameServer: Bool = ClusterKey(profile: profile) == ClusterKey(profile: previous)
        copy.aiAllowsPrivilegedAccount = sameAccount && sameServer && previous.aiAllowsPrivilegedAccount
        return copy
    }

    private static func defaultResolution(status: BackupProfileItem.Status, imported: ConnectionProfile, local: ConnectionProfile?,
                                          weakensSecurity: Bool, isAuthenticated: Bool) -> BackupProfileItem.Resolution {
        switch status {
        case .new: return .useImported
        case .unchanged: return .keepMine
        case .conflict:
            // Anyone could have written an unauthenticated backup, its `updatedAt` included: it never wins by default
            // when it would send the local password elsewhere or loosen a safeguard.
            if weakensSecurity && !isAuthenticated { return .keepMine }
            guard let importedDate = imported.updatedAt, let localDate = local?.updatedAt else { return .keepMine }
            return importedDate > localDate ? .useImported : .keepMine
        }
    }

    /// The flags that loosen a safeguard: the password would go elsewhere or travel less protected, the server would be
    /// trusted differently, other key files would be used, the password sent in clear text, or data changed without
    /// asking.
    static let weakeningFlags: Set<BackupProfileItem.Flag> = [.endpointChanged, .tlsWeakened, .caCertificateChanged, .clientCertificateChanged,
                                                              .serverPublicKeyChanged, .cleartextPasswordEnabled, .mutationConfirmationDisabled]

    /// A weakening flag, more AI access (a higher access level, or AI knowledge writes turned on) or the
    /// privileged-account opt-in.
    private static func weakensSecurity(_ imported: ConnectionProfile, over local: ConnectionProfile, flags: Set<BackupProfileItem.Flag>) -> Bool {
        let flagged: Bool = !flags.isDisjoint(with: weakeningFlags)
        let moreAccess: Bool = accessRank(imported.mcpAccess) > accessRank(local.mcpAccess)
        let knowledgeWrites: Bool = imported.mcpKnowledgeWrites && !local.mcpKnowledgeWrites
        let optIn: Bool = imported.aiAllowsPrivilegedAccount && !local.aiAllowsPrivilegedAccount
        return flagged || moreAccess || knowledgeWrites || optIn
    }

    private static func accessRank(_ access: MCPAccess) -> Int {
        switch access {
        case .disabled: 0
        case .readOnly: 1
        case .readWrite: 2
        }
    }

    /// The SSH key, CA certificate, client certificate and pinned server key paths written `~/…` under `home`; a blank
    /// certificate or key path (none: the system trust store, no client certificate, no pinned key) is `nil`, and the
    /// others are trimmed, as the connection uses them.
    static func withPortablePaths(_ profile: ConnectionProfile, home: String) -> ConnectionProfile {
        var copy = profile
        if let path = profile.ssh?.privateKeyPath, !path.isEmpty {
            copy.ssh?.privateKeyPath = BackupPaths.collapsingHome(path, home: home)
        }
        copy.caCertificatePath = portable(profile.caCertificatePath, home: home)
        copy.clientCertificatePath = portable(profile.clientCertificatePath, home: home)
        copy.serverPublicKeyPath = portable(profile.serverPublicKeyPath, home: home)
        return copy
    }

    private static func portable(_ path: String?, home: String) -> String? {
        path?.nilIfBlank.map { (trimmed: String) -> String in BackupPaths.collapsingHome(trimmed, home: home) }
    }

    /// Equal apart from id and timestamps (created, last connected, saved), which differ between Macs and with use.
    static func sameContent(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        var other = rhs
        other.id = lhs.id
        other.createdAt = lhs.createdAt
        other.lastConnectedAt = lhs.lastConnectedAt
        other.updatedAt = lhs.updatedAt
        return lhs == other
    }

    /// Both sides have a secret of the same kind and they differ. A secret missing here is filled in, not a conflict.
    private static func secretsConflict(_ imported: BackupProfileSecrets, _ local: BackupProfileSecrets) -> Bool {
        for kind in SecretKey.Kind.allCases {
            guard let importedValue = imported.value(for: kind), let localValue = local.value(for: kind) else { continue }
            if importedValue != localValue { return true }
        }
        return false
    }

    private static func aiAccessDiffers(_ imported: ConnectionProfile, _ local: ConnectionProfile?) -> Bool {
        guard let local else { return imported.mcpAccess != .disabled || imported.aiAllowsPrivilegedAccount }
        let access: Bool = imported.mcpAccess != local.mcpAccess
        let optIn: Bool = imported.aiAllowsPrivilegedAccount != local.aiAllowsPrivilegedAccount
        let knowledgeWrites: Bool = imported.mcpKnowledgeWrites != local.mcpKnowledgeWrites
        return access || optIn || knowledgeWrites
    }

    private static func isKeyMissing(_ profile: ConnectionProfile, home: String, fileExists: (String) -> Bool) -> Bool {
        guard let ssh = profile.ssh, ssh.authentication == .privateKey, let path = ssh.privateKeyPath, !path.isEmpty else { return false }
        return !fileExists(BackupPaths.expandingHome(path, home: home))
    }

    /// Certificate and key files that do not exist on this Mac. Every one that is set is read before connecting, whatever
    /// the TLS mode, so a missing one fails every connection until it is chosen again.
    private static func missingFileFlags(_ profile: ConnectionProfile, home: String, fileExists: (String) -> Bool) -> Set<BackupProfileItem.Flag> {
        let files: [(path: String?, flag: BackupProfileItem.Flag)] = [
            (profile.caCertificatePath, .missingCACertificate),
            (profile.clientCertificatePath, .missingClientCertificate),
            (profile.serverPublicKeyPath, .missingServerPublicKey),
        ]
        var flags = Set<BackupProfileItem.Flag>()
        for file in files {
            guard let path = file.path?.nilIfBlank else { continue }
            if !fileExists(BackupPaths.expandingHome(path, home: home)) { flags.insert(file.flag) }
        }
        return flags
    }

    // MARK: Knowledge

    private static func planKnowledge(_ section: BackupKnowledge, profiles: [ConnectionProfile], local: BackupLocalState, home: String,
                                      fileExists: (String) -> Bool, warnings: inout [BackupWarning]) -> BackupKnowledgePlan {
        if !local.isKnowledgeWritable { warnings.append(.localKnowledgeNotWritable) }
        let reachable = reachableClusters(local.profiles + profiles, index: section.index, localIndex: local.knowledgeIndex)
        var databases: [BackupDatabaseItem] = []
        var importable: [DatabaseKey: DatabaseKnowledge] = [:]
        for imported in section.databases {
            let key = imported.key
            let isReachable = reachable.contains(key.cluster)
            guard local.isKnowledgeWritable, !local.unwritableDatabases.contains(key) else {
                if local.isKnowledgeWritable { warnings.append(.localDatabaseNotWritable(key)) }
                databases.append(BackupDatabaseItem(key: key, status: .skipped, changes: BackupKnowledgeChanges(), hasMatchingConnection: isReachable))
                continue
            }
            let existing = local.knowledgeDatabases[key]
            let (merged, changes) = BackupKnowledgeMerge.merge(local: existing, imported: imported)
            let status: BackupDatabaseItem.Status
            if existing == nil {
                status = .new
            } else if merged == existing {
                status = .unchanged
            } else {
                status = .merged
            }
            importable[key] = imported
            databases.append(BackupDatabaseItem(key: key, status: status, changes: changes, hasMatchingConnection: isReachable))
        }
        let deletedLocally = Set(local.knowledgeIndex.tombstones.map(\.id))
        let projects = section.index.projects.filter { !deletedLocally.contains($0.id) }.map { (project: KnowledgeIndex.Project) -> BackupProjectItem in
            BackupProjectItem(source: project, localProjects: local.knowledgeIndex.projects, home: home, fileExists: fileExists)
        }
        var plan = BackupKnowledgePlan(databases: databases, projects: projects, indexChanges: false, importedIndex: section.index,
                                       importedDatabases: importable, localIndex: local.knowledgeIndex)
        if local.isKnowledgeWritable {
            plan.indexChanges = plan.mergedIndex(into: local.knowledgeIndex) != local.knowledgeIndex
        }
        return plan
    }

    /// Clusters some profile reaches, with the aliases either index declares for them.
    private static func reachableClusters(_ profiles: [ConnectionProfile], index: KnowledgeIndex, localIndex: KnowledgeIndex) -> Set<ClusterKey> {
        var reachable = Set(profiles.map { ClusterKey(profile: $0) })
        for cluster in index.clusters + localIndex.clusters {
            let group = [cluster.key] + cluster.aliases
            if group.contains(where: { reachable.contains($0) }) { reachable.formUnion(group) }
        }
        return reachable
    }

    // MARK: Settings

    private static func planSettings(_ imported: [String: BackupSettingValue], local: [String: BackupSettingValue],
                                     warnings: inout [BackupWarning]) -> [BackupSettingItem] {
        var items: [BackupSettingItem] = []
        for key in BackupSettings.keys {
            guard let value = imported[key] else { continue }
            guard BackupSettings.accepts(value, forKey: key) else {
                warnings.append(.invalidSetting(key))
                continue
            }
            items.append(BackupSettingItem(key: key, current: local[key], imported: value))
        }
        for key in imported.keys.sorted() where !BackupSettings.isWhitelisted(key) {
            warnings.append(.unsupportedSetting(key))
        }
        return items
    }
}
