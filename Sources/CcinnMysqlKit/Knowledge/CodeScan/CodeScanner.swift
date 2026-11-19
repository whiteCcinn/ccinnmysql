import Darwin
import Foundation

/// Scans the local projects linked to a database for SQL joins written in their code (CcinnMysql 1.5's code scanner,
/// kept as a knowledge source). Keeps identifiers, relative paths and line numbers only, never code text (which can
/// hold credentials). Files are read in parallel by a bounded task group; each task returns its own result and results
/// are merged once, in path order, so the outcome does not depend on timing.
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

    /// A linked project to scan.
    public struct Project: Sendable {
        public let id: String
        public let root: URL

        public init(id: String, root: URL) {
            self.id = id
            self.root = root
        }
    }

    public struct Result: Sendable {
        /// One relationship per join, with `scan` evidence for up to `maxEvidence` files.
        public var relationships: [Relationship]
        public var files: Int
        /// A file or byte budget ran out before every file was read.
        public var truncated: Bool
    }

    /// Files cited per relationship; the confidence does not grow with more.
    public static let maxEvidence = 5

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
        let findings: CodeSQLScanner.Findings?
    }

    /// Joins between `tables` (this database's, by exact name) in the projects' code. A project folder that does not
    /// exist is skipped.
    public func scan(projects: [Project], tables: [TableFacts], database: String, now: Date) async throws -> Result {
        try Task.checkCancellation()
        let index = CodeSchemaIndex(tables)
        var jobs: [FileJob] = []
        var totalBytes = 0
        var truncated = false
        for project in projects {
            let root = project.root.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let listed = try list(root: root, project: project.id, budgetFiles: limits.maxFiles - jobs.count, budgetBytes: limits.maxTotalBytes - totalBytes)
            jobs += listed.jobs
            totalBytes += listed.bytes
            truncated = truncated || listed.truncated
        }
        var results: [FileResult] = []
        results.reserveCapacity(jobs.count)
        try await withThrowingTaskGroup(of: FileResult.self) { (group: inout ThrowingTaskGroup<FileResult, any Error>) -> Void in
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
                _ = enqueue()
            }
        }
        try Task.checkCancellation()
        return Self.merge(results, now: now, truncated: truncated)
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

    private static func process(_ job: FileJob, index: CodeSchemaIndex, database: String, maxFileBytes: Int) throws -> FileResult {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: job.url) else { return FileResult(job: job, findings: nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else {
            return FileResult(job: job, findings: nil)
        }
        // Binary files (NUL in the first 8 KB) are not source code.
        if data.prefix(8_192).contains(0) { return FileResult(job: job, findings: nil) }
        return FileResult(job: job, findings: CodeSQLScanner.scan(Array(data), index: index, database: database))
    }

    /// One relationship per join: `from` holds the referencing columns (as the knowledge model wants), unknown direction
    /// stays as written and becomes many-to-many.
    private static func merge(_ results: [FileResult], now: Date, truncated: Bool) -> Result {
        var byID: [String: Relationship] = [:]
        var files = 0
        for result in results.sorted(by: { ($0.job.project, $0.job.relativePath) < ($1.job.project, $1.job.relativePath) }) {
            guard let findings = result.findings else { continue }
            files += 1
            for join in findings.joins {
                let kind: Relationship.Kind
                switch join.cardinality {
                case .manyToOne: kind = .manyToOne
                case .oneToOne: kind = .oneToOne
                case .unknown: kind = .manyToMany
                }
                let evidence = Evidence(source: .scan, project: result.job.project, path: result.job.relativePath, line: join.line, by: "scan", at: now)
                let candidate = Relationship(from: .init(table: join.from.table, columns: join.from.columns), to: .init(table: join.to.table, columns: join.to.columns),
                                             kind: kind, evidence: [evidence])
                if var existing = byID[candidate.id] {
                    if existing.evidence.count < maxEvidence { existing.evidence.append(evidence) }
                    byID[candidate.id] = existing
                } else {
                    byID[candidate.id] = candidate
                }
            }
        }
        return Result(relationships: byID.values.sorted { $0.id < $1.id }, files: files, truncated: truncated)
    }
}
