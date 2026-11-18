import Darwin
import Foundation
import Testing
@testable import MySQLKit

/// Integration tests run only with `CCINNMYSQL_IT=1` against containers started by `scripts/it-up.sh`.
/// Targets whose port is not listening are skipped, so any subset of the matrix can be tested.
enum IntegrationEnvironment {
    static let rootPassword = "ccinn-root-pw"

    struct Target: Sendable, CustomTestStringConvertible {
        let label: String
        let port: Int
        let flavor: ServerFlavor
        /// The server offers TLS out of the box (auto-generated certificates).
        let offersTLS: Bool
        let container: String

        var endpoint: Endpoint { Endpoint(host: "127.0.0.1", port: port) }
        var testDescription: String { label }
        var isMySQL8OrLater: Bool { flavor != .mariadb && !label.hasPrefix("MySQL 5") }
    }

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CCINNMYSQL_IT"] == "1" }

    static let matrix: [Target] = [
        Target(label: "MySQL 5.5", port: 13355, flavor: .mysql, offersTLS: false, container: "ccinnmysql-it-m55"),
        Target(label: "MySQL 5.6", port: 13356, flavor: .mysql, offersTLS: false, container: "ccinnmysql-it-m56"),
        Target(label: "MySQL 5.7", port: 13357, flavor: .mysql, offersTLS: true, container: "ccinnmysql-it-m57"),
        Target(label: "MySQL 8.0", port: 13380, flavor: .mysql, offersTLS: true, container: "ccinnmysql-it-m80"),
        Target(label: "MySQL 8.4", port: 13384, flavor: .mysql, offersTLS: true, container: "ccinnmysql-it-m84"),
        Target(label: "MySQL 9.6", port: 13396, flavor: .mysql, offersTLS: true, container: "ccinnmysql-it-m96"),
        Target(label: "Percona 8.0", port: 13381, flavor: .percona, offersTLS: true, container: "ccinnmysql-it-percona80"),
        Target(label: "MariaDB 10.6", port: 13316, flavor: .mariadb, offersTLS: false, container: "ccinnmysql-it-mariadb106"),
        Target(label: "MariaDB 10.11", port: 13321, flavor: .mariadb, offersTLS: false, container: "ccinnmysql-it-mariadb1011"),
        Target(label: "MariaDB 11.4", port: 13314, flavor: .mariadb, offersTLS: true, container: "ccinnmysql-it-mariadb114"),
        Target(label: "MariaDB 12.0", port: 13312, flavor: .mariadb, offersTLS: true, container: "ccinnmysql-it-mariadb120"),
        Target(label: "MariaDB 11.4 Galera", port: 13340, flavor: .mariadb, offersTLS: true, container: "ccinnmysql-it-galera"),
    ]

    /// Listening targets (optionally narrowed with `CCINNMYSQL_IT_TARGETS=m84,mariadb1011` container suffixes).
    static var targets: [Target] {
        guard isEnabled else { return [] }
        let filter = ProcessInfo.processInfo.environment["CCINNMYSQL_IT_TARGETS"]?.split(separator: ",").map(String.init)
        return matrix.filter { target in
            (filter.map { $0.contains(String(target.container.dropFirst("ccinnmysql-it-".count))) } ?? true) && isListening(port: target.port)
        }
    }

    static func rootConfiguration(_ target: Target, tls: TLSMode = .preferred, database: String? = nil) -> ConnectionConfiguration {
        ConnectionConfiguration(endpoint: target.endpoint, username: "root", password: rootPassword, database: database, connectTimeout: 20,
                                tls: TLSOptions(mode: tls, serverName: "127.0.0.1"))
    }

    /// Objects the integration tests create carry the `ccinn_` prefix (users, roles, routines, views); every test awaits its
    /// own cleanup, also after a failure. A crashed run can still leave some behind, so the first test on a server that
    /// creates such objects drops what earlier runs left (once per process; the suites run one server at a time, serialized).
    static func sweepLeftovers(_ admin: MySQLClient, target: Target) async {
        guard await LeftoverSweeps.shared.claim(target.port) else { return }
        func rows(_ sql: String) async -> [[String?]] { (try? await admin.query(sql).flatMap(\.rows)) ?? [] }
        let isMariaDB = target.flavor == .mariadb
        let accounts = await rows(isMariaDB ? "SELECT user, host, is_role FROM mysql.user WHERE user LIKE 'ccinn\\_%'"
                                            : "SELECT user, host, 'N' FROM mysql.user WHERE user LIKE 'ccinn\\_%'")
        for account in accounts where account.count == 3 {
            guard let user = account[0], let host = account[1] else { continue }
            let quoted = SQLText.literal(user)
            _ = try? await admin.execute(account[2] == "Y" ? "DROP ROLE \(quoted)" : "DROP USER IF EXISTS \(quoted)@\(SQLText.literal(host))")
        }
        for routine in await rows("SELECT ROUTINE_TYPE, ROUTINE_SCHEMA, ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_NAME LIKE 'ccinn\\_%'")
        where routine.count == 3 {
            guard let kind = routine[0], ["FUNCTION", "PROCEDURE"].contains(kind), let schema = routine[1], let name = routine[2] else { continue }
            _ = try? await admin.execute("DROP \(kind) IF EXISTS \(SQLText.qualified(schema, name))")
        }
        for view in await rows("SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_NAME LIKE 'ccinn\\_%'") where view.count == 2 {
            guard let schema = view[0], let name = view[1] else { continue }
            _ = try? await admin.execute("DROP VIEW IF EXISTS \(SQLText.qualified(schema, name))")
        }
    }

    static func isListening(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// `docker cp` of a file out of a test container (used for the auto-generated CA).
    static func copyFromContainer(_ container: String, path: String) throws -> Data {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnmysql-it-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "cp", "\(container):\(path)", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: destination) }
        return try Data(contentsOf: destination)
    }
}

/// The servers already swept by this test process.
actor LeftoverSweeps {
    static let shared = LeftoverSweeps()
    private var swept: Set<Int> = []

    /// Whether this call is the first for `port`.
    func claim(_ port: Int) -> Bool { swept.insert(port).inserted }
}
