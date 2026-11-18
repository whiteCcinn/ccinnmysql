import Darwin
import Foundation

/// Scans the directories the user linked to a database for SQL joins and table references (design D8).
/// Keeps identifiers, relative paths and line numbers only, never code text (which can hold credentials).
/// Files are processed in parallel by a bounded task group; each task returns its own partial result and the
/// results are merged once, so no state is shared between tasks.
public struct CodeScanner: Sendable {
    public struct Limits: Sendable {
        public var maxFiles: Int
        public var maxFileBytes: Int
        public var maxTotalBytes: Int
        public var maxReferencesPerTable: Int
        public var concurrency: Int

        public init(maxFiles: Int = 20_000, maxFileBytes: Int = 1_048_576, maxTotalBytes: Int = 256 * 1_048_576,
                    maxReferencesPerTable: Int = 20, concurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
            self.maxFiles = max(0, maxFiles)
            self.maxFileBytes = max(0, maxFileBytes)
            self.maxTotalBytes = max(0, maxTotalBytes)
            self.maxReferencesPerTable = max(1, maxReferencesPerTable)
            self.concurrency = min(max(1, concurrency), 32)
        }
    }

    public struct Result: Sendable {
        public var joins: [KnowledgeRelationship]
        /// Exact table name → references, SQL uses first.
        public var references: [String: [CodeReference]]
        public var projects: [ProjectScan]
    }

    public struct Progress: Sendable {
        public let filesDone: Int
        public let filesTotal: Int
    }

    public static let sourceExtensions: Set<String> = [
        "go", "rs", "java", "kt", "kts", "scala", "groovy", "py", "rb", "php", "js", "jsx", "ts", "tsx", "mjs", "cjs", "cs", "swift",
        "m", "mm", "c", "cc", "cpp", "h", "hpp", "sql", "xml", "yaml", "yml", "toml", "properties", "ex", "exs", "erl", "clj", "dart",
        "lua", "pl", "pm", "sh", "vue", "svelte", "tpl", "tmpl", "jsp", "ftl", "vm", "hql", "prisma", "graphql", "ini", "conf",
    ]

    /// Dependency, build and cache folders (hidden folders are skipped too).
    public static let skippedDirectories: Set<String> = [
        "node_modules", "vendor", "build", "dist", "target", "Pods", "DerivedData", "__pycache__", "venv", "bin", "obj", "coverage",
        "out", "bower_components", "jspm_packages", "site-packages",
    ]

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    private struct FileJob: Sendable {
        let project: String
        let url: URL
        let relativePath: String
    }

    private struct FileResult: Sendable {
        let job: FileJob
        let findings: SQLJoinExtractor.Findings?
    }

    public func scan(projects: [LinkedProject], index: KnowledgeSchemaIndex, database: String,
                     progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Result {
        try Task.checkCancellation()
        var scans: [ProjectScan] = []
        var jobs: [FileJob] = []
        var totalBytes = 0
        for project in projects {
            var scan = ProjectScan(projectID: project.id, project: project.name, path: project.path, commit: nil)
            let root = URL(fileURLWithPath: project.path, isDirectory: true).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                scan.error = "The folder \(project.path) does not exist."
                scans.append(scan)
                continue
            }
            scan.commit = GitHead.commit(for: root)
            let listed = try list(root: root, project: project.name, budgetFiles: limits.maxFiles - jobs.count, budgetBytes: limits.maxTotalBytes - totalBytes)
            jobs += listed.jobs
            totalBytes += listed.bytes
            scan.bytes = Int64(listed.bytes)
            scan.truncated = listed.truncated
            scans.append(scan)
        }

        var results: [FileResult] = []
        results.reserveCapacity(jobs.count)
        let total = jobs.count
        try await withThrowingTaskGroup(of: FileResult.self) { group in
            var pending = jobs.makeIterator()
            let maxFileBytes = limits.maxFileBytes
            func enqueue() -> Bool {
                guard let job = pending.next() else { return false }
                group.addTask { try Self.process(job, index: index, database: database, maxFileBytes: maxFileBytes) }
                return true
            }
            for _ in 0..<limits.concurrency {
                if !enqueue() { break }
            }
            while let result = try await group.next() {
                results.append(result)
                if results.count % 64 == 0 || results.count == total { progress?(Progress(filesDone: results.count, filesTotal: total)) }
                _ = enqueue()
            }
        }
        try Task.checkCancellation()
        return merge(results, scans: scans)
    }

    /// Source files under `root`, within the remaining file and byte budgets.
    private func list(root: URL, project: String, budgetFiles: Int, budgetBytes: Int) throws -> (jobs: [FileJob], bytes: Int, truncated: Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], 0, false)
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var jobs: [FileJob] = []
        var bytes = 0
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 512 == 0 { try Task.checkCancellation() }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, Self.sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= limits.maxFileBytes else { continue }
            guard jobs.count < budgetFiles, bytes + size <= budgetBytes else { return (jobs, bytes, true) }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            jobs.append(FileJob(project: project, url: url, relativePath: String(path.dropFirst(rootPath.count))))
            bytes += size
        }
        return (jobs, bytes, false)
    }

    private static func process(_ job: FileJob, index: KnowledgeSchemaIndex, database: String, maxFileBytes: Int) throws -> FileResult {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: job.url) else { return FileResult(job: job, findings: nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else {
            return FileResult(job: job, findings: nil)
        }
        // Binary files (NUL in the first 8 KB) are not source code.
        if data.prefix(8_192).contains(0) { return FileResult(job: job, findings: nil) }
        return FileResult(job: job, findings: SQLJoinExtractor.scan(Array(data), index: index, database: database))
    }

    private func merge(_ results: [FileResult], scans: [ProjectScan]) -> Result {
        var relationships: [String: KnowledgeRelationship] = [:]
        var order: [String] = []
        var references: [String: [CodeReference]] = [:]
        var filesByProject: [String: Int] = [:]
        // Deterministic regardless of completion order.
        for result in results.sorted(by: { ($0.job.project, $0.job.relativePath) < ($1.job.project, $1.job.relativePath) }) {
            guard let findings = result.findings else { continue }
            filesByProject[result.job.project, default: 0] += 1
            for join in findings.joins {
                let evidence = KnowledgeEvidence(kind: .code, project: result.job.project, path: result.job.relativePath, line: join.line)
                let relationship = Self.relationship(join, source: .code, evidence: evidence)
                if let existing = relationships[relationship.id] {
                    relationships[relationship.id] = existing.merged(with: relationship)
                } else {
                    relationships[relationship.id] = relationship
                    order.append(relationship.id)
                }
            }
            for (table, use) in findings.tables {
                references[table, default: []].append(CodeReference(project: result.job.project, path: result.job.relativePath,
                                                                    line: use.firstLine, count: use.count, sql: use.sql))
            }
        }
        for table in references.keys {
            references[table] = references[table]?.sorted { lhs, rhs in
                if lhs.sql != rhs.sql { return lhs.sql }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.project, lhs.path) < (rhs.project, rhs.path)
            }.prefix(limits.maxReferencesPerTable).map { $0 }
        }
        var projects = scans
        for index in projects.indices { projects[index].files = filesByProject[projects[index].project] ?? 0 }
        return Result(joins: order.compactMap { relationships[$0] }, references: references, projects: projects)
    }

    /// A join found in text as a relationship: 0.9 when one side is a key, 0.6 otherwise.
    static func relationship(_ join: SQLJoinExtractor.Join, source: RelationshipSource, evidence: KnowledgeEvidence) -> KnowledgeRelationship {
        KnowledgeRelationship(from: join.from, to: join.to, sources: [source], confidence: join.cardinality == .unknown ? 0.6 : 0.9,
                              cardinality: join.cardinality, evidence: [evidence], occurrences: join.count)
    }
}

/// The commit checked out in a directory, read from files only (no `git` process): branches, detached `HEAD`,
/// packed refs and worktrees (`.git` file with `gitdir:` and `commondir`). Looks in parent folders too.
public enum GitHead {
    public static func commit(for directory: URL) -> String? {
        var current = directory.standardizedFileURL
        for _ in 0..<64 {
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return resolveHead(gitDirectory: dotGit) }
                guard let text = read(dotGit), text.hasPrefix("gitdir:") else { return nil }
                let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path) : current.appendingPathComponent(path).standardizedFileURL
                return resolveHead(gitDirectory: gitDirectory)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    static func resolveHead(gitDirectory: URL) -> String? {
        guard let head = read(gitDirectory.appendingPathComponent("HEAD")) else { return nil }
        guard head.hasPrefix("ref:") else { return isObjectName(head) ? head.lowercased() : nil }
        let reference = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
        guard reference.hasPrefix("refs/"), !reference.split(separator: "/").contains(".."), !reference.contains("\\") else { return nil }
        var directories = [gitDirectory]
        if let common = read(gitDirectory.appendingPathComponent("commondir")) {
            directories.append(common.hasPrefix("/") ? URL(fileURLWithPath: common) : gitDirectory.appendingPathComponent(common).standardizedFileURL)
        }
        for directory in directories {
            if let value = read(directory.appendingPathComponent(reference)), isObjectName(value) { return value.lowercased() }
        }
        for directory in directories {
            guard let packed = read(directory.appendingPathComponent("packed-refs"), maxBytes: 32 * 1_048_576) else { continue }
            for line in packed.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[1] == reference, isObjectName(String(parts[0])) { return parts[0].lowercased() }
            }
        }
        return nil
    }

    static func isObjectName(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// A small regular file, never through a symbolic link (whose target could be anything, of any size).
    static func read(_ url: URL, maxBytes: Int = 65_536) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxBytes,
              let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
