import Foundation
import Testing
@testable import CcinnMysqlKit

@Suite("Knowledge code scanner")
struct CodeScannerTests {
    static let index = KnowledgeSchemaIndex([
        table("customers", [col("id"), col("name", "varchar(64)")]),
        table("orders", [col("id"), col("customer_id")]),
    ])

    static let joinSQL = "SELECT o.id FROM orders o JOIN customers c ON c.id = o.customer_id"

    private func project(_ directory: TemporaryDirectory, name: String = "api") -> LinkedProject {
        LinkedProject(name: name, path: directory.url.path)
    }

    @Test func findsJoinsAndReferencesWithRelativeLocations() async throws {
        let directory = TemporaryDirectory()
        try directory.write("internal/repo/order.go", "package repo\n\nconst q = `\n\(Self.joinSQL)`\n")
        try directory.write("mapper/OrderMapper.xml", "<select id=\"x\">\nSELECT * FROM orders WHERE id = #{id}\n</select>\n")
        try directory.write("model/customer.py", "class Customer:\n    __tablename__ = \"customers\"\n")
        let result = try await CodeScanner().scan(projects: [project(directory)], index: Self.index, database: "shop")
        let join = try #require(result.joins.first)
        #expect(result.joins.count == 1)
        #expect(join.id == "orders(customer_id)->customers(id)")
        #expect(join.sources == [.code] && join.confidence == 0.9)
        #expect(join.evidence.first == KnowledgeEvidence(kind: .code, project: "api", path: "internal/repo/order.go", line: 4))
        let orders = try #require(result.references["orders"])
        #expect(Set(orders.map(\.path)) == ["internal/repo/order.go", "mapper/OrderMapper.xml"])
        #expect(orders.allSatisfy { $0.sql && $0.project == "api" })
        #expect(result.references["customers"]?.contains { $0.path == "model/customer.py" && !$0.sql && $0.line == 2 } == true)
        #expect(result.projects.first?.files == 3 && result.projects.first?.truncated == false && result.projects.first?.error == nil)
    }

    @Test func skipsDependenciesHiddenLinksBinariesAndLargeFiles() async throws {
        let directory = TemporaryDirectory()
        let outside = TemporaryDirectory()
        try outside.write("secret.go", Self.joinSQL)
        for path in ["node_modules/x/q.js", "vendor/lib/q.go", ".git/hooks/q.sh", ".hidden/q.go", "build/q.java", "notes.txt", "img.png"] {
            try directory.write(path, Self.joinSQL)
        }
        try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("linked"), withDestinationURL: outside.url)
        try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("link.go"),
                                                   withDestinationURL: outside.url.appendingPathComponent("secret.go"))
        var binary = Data(Self.joinSQL.utf8)
        binary.insert(0, at: 3)
        try binary.write(to: directory.url.appendingPathComponent("blob.go"))
        try directory.write("big.sql", Self.joinSQL + String(repeating: " ", count: 2_000))
        let scanner = CodeScanner(limits: CodeScanner.Limits(maxFileBytes: 1_000))
        let result = try await scanner.scan(projects: [project(directory)], index: Self.index, database: "shop")
        #expect(result.joins.isEmpty)
        #expect(result.references.isEmpty)
        #expect(result.projects.first?.files == 0, "only the binary file was read, and it was skipped")
    }

    @Test func limitsStopTheScanAndSaySo() async throws {
        let directory = TemporaryDirectory()
        for index in 0..<5 { try directory.write("q\(index).go", Self.joinSQL) }
        let result = try await CodeScanner(limits: CodeScanner.Limits(maxFiles: 2)).scan(projects: [project(directory)], index: Self.index, database: "shop")
        #expect(result.projects.first?.files == 2)
        #expect(result.projects.first?.truncated == true)
        #expect(result.joins.first?.occurrences == 2)
        let bytes = try await CodeScanner(limits: CodeScanner.Limits(maxTotalBytes: Self.joinSQL.utf8.count * 3 + 1))
            .scan(projects: [project(directory)], index: Self.index, database: "shop")
        #expect(bytes.projects.first?.files == 3 && bytes.projects.first?.truncated == true)
    }

    @Test func missingProjectsAreReportedAndOthersStillScanned() async throws {
        let directory = TemporaryDirectory()
        try directory.write("q.go", Self.joinSQL)
        let missing = LinkedProject(name: "gone", path: directory.url.appendingPathComponent("nope").path)
        let result = try await CodeScanner().scan(projects: [missing, project(directory)], index: Self.index, database: "shop")
        #expect(result.projects.first { $0.project == "gone" }?.error != nil)
        #expect(result.joins.count == 1)
    }

    @Test func referencesAreCappedSqlFirst() async throws {
        let directory = TemporaryDirectory()
        for index in 0..<6 { try directory.write("s\(index).py", "name = \"orders\"") }
        try directory.write("z.go", "SELECT * FROM orders")
        let result = try await CodeScanner(limits: CodeScanner.Limits(maxReferencesPerTable: 3))
            .scan(projects: [project(directory)], index: Self.index, database: "shop")
        let references = try #require(result.references["orders"])
        #expect(references.count == 3)
        #expect(references.first?.path == "z.go" && references.first?.sql == true)
    }

    @Test func cancellationStopsTheScan() async throws {
        let directory = TemporaryDirectory()
        for index in 0..<200 { try directory.write("q\(index).go", Self.joinSQL) }
        let task = Task {
            try await CodeScanner(limits: CodeScanner.Limits(concurrency: 1)).scan(projects: [project(directory)], index: Self.index, database: "shop")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("Knowledge git HEAD")
struct GitHeadTests {
    static let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test func branchDetachedAndPackedRefs() throws {
        let directory = TemporaryDirectory()
        try directory.write(".git/HEAD", "ref: refs/heads/main\n")
        try directory.write(".git/refs/heads/main", Self.sha + "\n")
        try directory.write("src/app/x.go", "")
        #expect(GitHead.commit(for: directory.url) == Self.sha)
        #expect(GitHead.commit(for: directory.url.appendingPathComponent("src/app")) == Self.sha, "a project inside a repository")
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent(".git/refs/heads/main"))
        try directory.write(".git/packed-refs", "# pack-refs with: peeled\n\(Self.sha) refs/heads/main\n")
        #expect(GitHead.commit(for: directory.url) == Self.sha)
        try directory.write(".git/HEAD", Self.sha + "\n")
        #expect(GitHead.commit(for: directory.url) == Self.sha, "detached HEAD")
        try directory.write(".git/HEAD", "ref: ../../etc/passwd\n")
        #expect(GitHead.commit(for: directory.url) == nil)
    }

    @Test func worktreesUseTheirGitDirAndCommonDir() throws {
        let main = TemporaryDirectory()
        let worktree = TemporaryDirectory()
        try main.write(".git/refs/heads/feature", Self.sha)
        try main.write(".git/worktrees/wt/HEAD", "ref: refs/heads/feature")
        try main.write(".git/worktrees/wt/commondir", "../..")
        try worktree.write(".git", "gitdir: \(main.url.path)/.git/worktrees/wt\n")
        #expect(GitHead.commit(for: worktree.url) == Self.sha)
    }

    @Test func noRepository() {
        #expect(GitHead.commit(for: TemporaryDirectory().url) == nil)
    }
}
