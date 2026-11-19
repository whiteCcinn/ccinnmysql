import Foundation

/// The knowledge section of a CcinnMysql 1.5 backup (`BackupLegacyFormat`), converted base by base with
/// `LegacyKnowledgeConverter` and gathered into one `BackupKnowledge`: one project per folder however many databases it
/// was linked to, one database however many connections (users of the same server) had knowledge of it.
enum BackupLegacyKnowledge {
    static func convert(_ bases: [LegacyKnowledgeBase], profiles: [ConnectionProfile], sourceHome: String,
                        warnings: inout [BackupWarning]) -> BackupKnowledge? {
        guard !bases.isEmpty else { return nil }
        var profilesByID: [UUID: ConnectionProfile] = [:]
        for profile in profiles where profilesByID[profile.id] == nil { profilesByID[profile.id] = profile }
        var gathered = Gathered()
        var reported = Set(warnings)
        func warn(_ warning: BackupWarning) {
            if reported.insert(warning).inserted { warnings.append(warning) }
        }
        for base in bases {
            guard let profile = profilesByID[base.connectionID] else {
                let name = LegacyKnowledgeConverter.label(base.database)
                warn(.legacyKnowledgeNotConverted("the knowledge of “\(name)” belongs to a connection not in the backup."))
                continue
            }
            let converted = LegacyKnowledgeConverter.convert(base, profile: profile, home: sourceHome)
            converted.warnings.forEach(warn)
            gathered.add(converted.knowledge, projects: converted.projects, links: converted.links)
        }
        guard !gathered.index.databases.isEmpty else { return nil }
        return BackupKnowledge(index: gathered.index, databases: gathered.order.compactMap { gathered.databases[$0] })
    }

    /// The index and the databases, without duplicates.
    private struct Gathered {
        var index = KnowledgeIndex()
        var databases: [DatabaseKey: DatabaseKnowledge] = [:]
        var order: [DatabaseKey] = []
        private var projectIDs = Set<String>()
        private var links = Set<String>()
        private var clusters = Set<ClusterKey>()
        private var databaseIDs = Set<String>()

        mutating func add(_ knowledge: DatabaseKnowledge, projects: [KnowledgeIndex.Project], links newLinks: [KnowledgeIndex.Link]) {
            for project in projects where projectIDs.insert(project.id).inserted { index.projects.append(project) }
            for link in newLinks where links.insert(link.project + "\u{1F}" + link.database).inserted { index.links.append(link) }
            let key = knowledge.key
            let isEmpty = LegacyKnowledgeConverter.isEmpty(knowledge)
            // Without notes, terms or relationships there is no file to write: the index entry carries the links.
            if !isEmpty || !newLinks.isEmpty {
                if databaseIDs.insert(key.fileID).inserted { index.databases.append(KnowledgeIndex.DatabaseEntry(key: key)) }
                if clusters.insert(key.cluster).inserted { index.clusters.append(KnowledgeIndex.ClusterEntry(key: key.cluster)) }
            }
            guard !isEmpty else { return }
            if let existing = databases[key] {
                // Two connections (other users of the same server) both had knowledge of this database.
                databases[key] = BackupKnowledgeMerge.merge(local: existing, imported: knowledge).merged
            } else {
                databases[key] = knowledge
                order.append(key)
            }
        }
    }
}
