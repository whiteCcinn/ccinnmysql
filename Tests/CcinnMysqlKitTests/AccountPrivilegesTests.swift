import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit
import MySQLWire

/// Final review D: read-only AI tools refuse accounts that can reach files, server state, credentials or other sessions'
/// statements through functions, which no check of the statement text can see.
@Suite("Account privileges")
struct AccountPrivilegesTests {
    @Test func plainAccountsAreNotPrivileged() {
        let mysql = ["GRANT USAGE ON *.* TO `ai`@`%`", "GRANT SELECT, SHOW VIEW ON `shop`.* TO `ai`@`%`", "GRANT SELECT (`id`, `name`) ON `shop`.`t` TO `ai`@`%`",
                     "GRANT EXECUTE ON PROCEDURE `shop`.`p` TO `ai`@`%`", "GRANT REPLICATION CLIENT, SHOW DATABASES ON *.* TO `ai`@`%`"]
        #expect(AccountPrivileges(grants: mysql).reasons == [])
        let mariadb = ["GRANT USAGE ON *.* TO `ai`@`%` IDENTIFIED BY PASSWORD '*B2C82F34FAD0972EBD86E4C2C5225B5D3F502C97'",
                       "GRANT SELECT ON `shop`.* TO `ai`@`%`", "SET DEFAULT ROLE `reader` FOR `ai`@`%`"]
        #expect(!AccountPrivileges(grants: mariadb).isPrivileged)
    }

    @Test func directGlobalAndSchemaGrants() {
        #expect(AccountPrivileges(grants: ["GRANT FILE ON *.* TO `u`@`%`"]).reasons == ["FILE"])
        #expect(AccountPrivileges(grants: ["GRANT SELECT, INSERT, SUPER, PROCESS ON *.* TO `root`@`localhost` WITH GRANT OPTION"]).reasons
            == ["SELECT ON *.*", "SUPER", "PROCESS"])
        #expect(AccountPrivileges(grants: ["GRANT APPLICATION_PASSWORD_ADMIN,AUDIT_ADMIN,BACKUP_ADMIN ON *.* TO `root`@`localhost`"]).reasons
            == ["APPLICATION_PASSWORD_ADMIN", "AUDIT_ADMIN", "BACKUP_ADMIN"])
        #expect(AccountPrivileges(grants: ["GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` IDENTIFIED BY PASSWORD '*5600' WITH GRANT OPTION"]).reasons
            == ["ALL PRIVILEGES ON *.*"])
        #expect(AccountPrivileges(grants: ["GRANT BINLOG ADMIN, READ_ONLY ADMIN ON *.* TO `ops`@`%`"]).reasons == ["BINLOG ADMIN", "READ_ONLY ADMIN"])
        #expect(AccountPrivileges(grants: ["GRANT SELECT ON `mysql`.* TO `u`@`%`"]).reasons == ["SELECT ON mysql.*"])
        #expect(AccountPrivileges(grants: ["GRANT SELECT ON `mysql`.`user` TO `u`@`%`"]).reasons == ["SELECT ON mysql.user"])
        #expect(AccountPrivileges(grants: ["GRANT SELECT ON `performance_schema`.* TO `u`@`%`"]).reasons == ["SELECT ON performance_schema.*"])
        #expect(AccountPrivileges(grants: ["GRANT ALL PRIVILEGES ON `shop`.* TO `u`@`%`"]).reasons == [], "ALL on one schema has no FILE or SUPER")
        #expect(AccountPrivileges(grants: ["GRANT ALL ON `mysql`.* TO `u`@`%`"]).reasons == ["ALL PRIVILEGES ON mysql.*"])
        let privileged = AccountPrivileges(grants: ["GRANT FILE ON *.* TO `u`@`%`"])
        #expect(privileged.refusal.contains("FILE") && privileged.refusal.contains("AI settings"))
    }

    // PROCESS shows every session's statement text: refused through `information_schema.PROCESSLIST` itself, but an
    // existing view or routine over it (or `INNODB_TRX`) is something the read-only check can't see into.
    @Test func processIsPrivileged() {
        #expect(AccountPrivileges(grants: ["GRANT PROCESS ON *.* TO `monitor`@`%`"]).reasons == ["PROCESS"])
        #expect(AccountPrivileges(grants: ["GRANT process, SELECT ON *.* TO `m`@`%`"]).reasons == ["PROCESS", "SELECT ON *.*"])
        #expect(AccountPrivileges(grants: ["GRANT PROCESS, REPLICATION CLIENT ON *.* TO `m`@`%`", "GRANT SELECT ON `shop`.* TO `m`@`%`"]).isPrivileged)
        let monitor = AccountPrivileges(grants: ["GRANT PROCESS ON *.* TO `monitor`@`%`"])
        #expect(monitor.refusal.contains("PROCESS") && monitor.refusal.contains("other sessions' data"))
    }

    // Database-level grants take LIKE patterns: `%`, `my%`, `m_sql` cover mysql on both servers, and SHOW GRANTS prints
    // an escaped name as written (`performance\_schema`). A pattern counts when it matches mysql, performance_schema or
    // sys; `\_` and `\%` are literal.
    @Test(arguments: ["GRANT SELECT ON `%`.* TO `u`@`%`", "GRANT SELECT ON `my%`.* TO `u`@`%`", "GRANT SELECT ON `m_sql`.* TO `u`@`%`",
                      "GRANT SELECT ON `performance\\_schema`.* TO `u`@`%`", "GRANT SELECT ON `perf%`.* TO `u`@`%`", "GRANT SELECT ON `s_s`.* TO `u`@`%`",
                      "GRANT SELECT ON `%sql`.* TO `u`@`%`", "GRANT SELECT ON `MySQL`.* TO `u`@`%`", "GRANT SELECT ON sys.* TO `u`@`%`",
                      "GRANT SELECT ON `%`.`user` TO `u`@`%`", "GRANT ALL PRIVILEGES ON `%`.* TO `u`@`%`", "GRANT SELECT ON `_____`.* TO `u`@`%`",
                      "GRANT SELECT ON `performance%`.* TO `u`@`%`", "GRANT SELECT ON `perform_nce\\_schema`.* TO `u`@`%`",
                      "GRANT SELECT ON `performance_ſchema`.* TO `u`@`%`", "GRANT SELECT ON `PERFORMANCE_SCHEMA`.* TO `u`@`%`"])
    func wildcardAndEscapedDatabaseGrantsCoverSecretSchemas(grant: String) {
        #expect(AccountPrivileges(grants: [grant]).isPrivileged, "\(grant)")
    }

    @Test(arguments: ["GRANT SELECT ON `shop`.* TO `u`@`%`", "GRANT SELECT ON `app_db`.* TO `u`@`%`", "GRANT SELECT ON `sho_`.* TO `u`@`%`",
                      "GRANT SELECT ON `app%`.* TO `u`@`%`", "GRANT SELECT ON `m\\_sql`.* TO `u`@`%`", "GRANT SELECT ON `my\\%`.* TO `u`@`%`",
                      "GRANT SELECT ON `____`.* TO `u`@`%`", "GRANT SELECT ON `mysql_archive`.* TO `u`@`%`", "GRANT SELECT ON `a.mysql`.* TO `u`@`%`"])
    func patternsThatMatchNoSecretSchemaArePlain(grant: String) {
        #expect(!AccountPrivileges(grants: [grant]).isPrivileged, "\(grant)")
    }

    @Test func likeMatchingFollowsTheServer() {
        #expect(AccountPrivileges.likeMatches(pattern: "%", name: "mysql"))
        #expect(AccountPrivileges.likeMatches(pattern: "m%l", name: "mysql"))
        #expect(AccountPrivileges.likeMatches(pattern: "performance\\_schema", name: "performance_schema"))
        #expect(!AccountPrivileges.likeMatches(pattern: "performance\\%", name: "performance_schema"))
        #expect(AccountPrivileges.likeMatches(pattern: "%%%_", name: "sys"))
        #expect(!AccountPrivileges.likeMatches(pattern: "_", name: "sys"))
        #expect(!AccountPrivileges.likeMatches(pattern: "", name: "sys"))
        #expect(AccountPrivileges.likeMatches(pattern: "sys\\", name: "sys\\"), "a trailing backslash is literal")
    }

    // MariaDB shows an account the grants of the roles granted to it, not of the roles those roles hold: such accounts are
    // refused (fail closed), and the message says why and what to do.
    @Test func nestedRolesFailClosedWithAClearMessage() async throws {
        // As MariaDB 10.11 answers (live): with the role enabled, SHOW GRANTS also prints the role-to-role grant, and only
        // SHOW GRANTS FOR the nested role is denied.
        let server = FakeServer([
            "SHOW GRANTS": ["GRANT `outer` TO `ai`@`%`", "GRANT USAGE ON *.* TO `ai`@`%` IDENTIFIED BY PASSWORD '*792C'", "GRANT `inner` TO `outer`",
                            "GRANT USAGE ON *.* TO `outer`", "GRANT SELECT ON `shop`.* TO `inner`", "SET DEFAULT ROLE `outer` FOR `ai`@`%`"],
            "SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES": ["outer", "inner"],
            "SHOW GRANTS FOR `outer`": ["GRANT `inner` TO `outer`", "GRANT USAGE ON *.* TO `outer`", "GRANT SELECT ON `shop`.* TO `inner`"],
        ])
        do {
            _ = try await AccountPrivileges.load(flavor: .mariadb) { try await server.run($0) }
            Issue.record("a nested role that can't be inspected must refuse")
        } catch let error as AccountPrivileges.NestedRoleError {
            #expect(error.role == "`inner`")
            #expect(error.message.contains("nested roles can't be inspected") && error.message.contains("AI settings if that's intended"))
            #expect(error.localizedDescription == error.message)
        }
        let refusal = await #expect(throws: MCPToolError.self) {
            try await MySQLMCPTools.requireUnprivileged(flavor: .mariadb) { try await server.run($0) }
        }
        #expect(refusal?.message.contains("nested roles can't be inspected") == true, "\(refusal?.message ?? "")")
        // A role granted directly that can't be read is another failure, still refused, with the server's message.
        let direct = FakeServer(["SHOW GRANTS": ["GRANT `outer` TO `ai`@`%`"], "SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES": []])
        await #expect(throws: MySQLError.self) { _ = try await AccountPrivileges.load(flavor: .mariadb) { try await direct.run($0) } }
    }

    @Test func processThroughARoleIsPrivileged() async throws {
        let server = FakeServer([
            "SHOW GRANTS": ["GRANT `monitoring` TO `ai`@`%`", "GRANT SELECT ON `shop`.* TO `ai`@`%`"],
            "SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES": [],
            "SHOW GRANTS FOR `monitoring`": ["GRANT PROCESS ON *.* TO `monitoring`"],
        ])
        #expect(try await AccountPrivileges.load(flavor: .mariadb) { try await server.run($0) }.reasons == ["PROCESS"])
    }

    @Test func directRolesAreThoseGrantedToTheAccount() {
        #expect(AccountPrivileges.directRoles(in: ["GRANT `outer` TO `ai`@`%`", "GRANT `inner` TO `outer`", "GRANT `x` TO `outer` WITH ADMIN OPTION",
                                                   "GRANT SELECT ON `shop`.* TO `ai`@`%`"]) == ["`outer`"])
    }

    // Final review, item 9: a privilege is plain only when it is a reviewed static privilege or on the reviewed harmless list.
    // INNODB_REDO_LOG_ARCHIVE (no _ADMIN suffix) let a "read-only" SELECT start a server-side file write.
    @Test(arguments: ["INNODB_REDO_LOG_ARCHIVE", "INNODB_REDO_LOG_ENABLE", "SHOW_ROUTINE", "SENSITIVE_VARIABLES_OBSERVER", "SET_ANY_DEFINER",
                      "SYSTEM_USER", "REPLICATION_APPLIER", "TRANSACTION_GTID_TAG", "XA_RECOVER_ADMIN", "OPTIMIZE_LOCAL_TABLE", "SET USER",
                      "FEDERATED ADMIN", "BINLOG REPLAY", "FIREWALL_EXEMPT", "SOME_FUTURE_PRIVILEGE"])
    func everyUnreviewedPrivilegeIsPrivileged(privilege: String) {
        #expect(AccountPrivileges(grants: ["GRANT \(privilege) ON *.* TO `u`@`%`"]).reasons == [privilege])
    }

    @Test(arguments: ["FLUSH_OPTIMIZER_COSTS", "FLUSH_STATUS", "FLUSH_TABLES", "FLUSH_USER_RESOURCES", "FLUSH_PRIVILEGES", "RESOURCE_GROUP_USER",
                      "BINLOG MONITOR", "SLAVE MONITOR", "REPLICA MONITOR", "REPLICATION CLIENT", "REPLICATION SLAVE", "SHOW DATABASES",
                      "DELETE HISTORY", "SHOW VIEW", "CREATE TEMPORARY TABLES", "LOCK TABLES", "EXECUTE", "USAGE", "CREATE ROLE"])
    func reviewedStaticAndHarmlessPrivilegesArePlain(privilege: String) {
        #expect(AccountPrivileges(grants: ["GRANT \(privilege) ON *.* TO `u`@`%`"]).reasons == [])
    }

    @Test func theRedoLogArchiveGrantIsRefused() {
        let archive = AccountPrivileges(grants: ["GRANT USAGE ON *.* TO `ai`@`%`", "GRANT INNODB_REDO_LOG_ARCHIVE ON *.* TO `ai`@`%`",
                                                 "GRANT SELECT ON `shop`.* TO `ai`@`%`"])
        #expect(archive.isPrivileged && archive.refusal.contains("INNODB_REDO_LOG_ARCHIVE"))
        #expect(AccountPrivileges.reviewedPrivileges.isSuperset(of: ["SELECT", "FILE", "INNODB_REDO_LOG_ARCHIVE", "BINLOG MONITOR", "SET USER"]))
    }

    @Test func rolesAreFound() {
        #expect(AccountPrivileges.roles(in: ["GRANT `reader`@`%`,`ops`@`%` TO `ai`@`%`", "GRANT SELECT ON `shop`.* TO `ai`@`%`"])
            == ["`reader`@`%`", "`ops`@`%`"])
        #expect(AccountPrivileges.roles(in: ["GRANT `reader` TO `ai`@`%`", "GRANT `inner` TO `reader`"]) == ["`reader`", "`inner`"])
        #expect(AccountPrivileges.roles(in: ["GRANT PROXY ON ``@`` TO `root`@`localhost` WITH GRANT OPTION"]) == [])
    }

    /// Records the statements `load` runs and answers them like a server would.
    private actor FakeServer {
        let answers: [String: [String]]
        private(set) var asked: [String] = []
        init(_ answers: [String: [String]]) { self.answers = answers }
        func run(_ sql: String) throws -> [ResultSet] {
            asked.append(sql)
            guard let rows = answers[sql] else { throw MySQLError(.server, "unexpected: \(sql)") }
            return [ResultSet(columns: [ColumnDefinition(name: "Grants", type: .varString)], rows: rows.map { [$0] })]
        }
    }

    @Test func mysqlRolesAreExpandedWithUsing() async throws {
        let server = FakeServer([
            "SHOW GRANTS FOR CURRENT_USER()": ["GRANT USAGE ON *.* TO `ai`@`%`", "GRANT `reader`@`%` TO `ai`@`%`"],
            "SELECT @@GLOBAL.mandatory_roles": [""],
            "SHOW GRANTS FOR CURRENT_USER() USING `reader`@`%`": ["GRANT USAGE ON *.* TO `ai`@`%`", "GRANT FILE ON *.* TO `ai`@`%`"],
        ])
        let privileges = try await AccountPrivileges.load(flavor: .mysql) { try await server.run($0) }
        #expect(privileges.reasons == ["FILE"], "the role's FILE counts")
    }

    @Test func mariadbRolesAreFollowedThroughRoles() async throws {
        let server = FakeServer([
            "SHOW GRANTS": ["GRANT `reader` TO `ai`@`%`", "GRANT SELECT ON `shop`.* TO `ai`@`%`"],
            "SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES": ["reader"],
            "SHOW GRANTS FOR `reader`": ["GRANT `inner` TO `reader`", "GRANT SELECT ON `shop`.* TO `reader`"],
            "SHOW GRANTS FOR `inner`": ["GRANT ALL PRIVILEGES ON *.* TO `inner`"],
        ])
        let privileges = try await AccountPrivileges.load(flavor: .mariadb) { try await server.run($0) }
        #expect(privileges.reasons == ["ALL PRIVILEGES ON *.*"])
        let plain = FakeServer(["SHOW GRANTS": ["GRANT SELECT ON `shop`.* TO `ai`@`%`"], "SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES": []])
        #expect(try await AccountPrivileges.load(flavor: .mariadb) { try await plain.run($0) }.reasons == [])
    }

    @Test func errorsAreThrownSoCallersFailClosed() async {
        let broken = FakeServer([:])
        await #expect(throws: MySQLError.self) { try await AccountPrivileges.load(flavor: .mysql) { try await broken.run($0) } }
    }
}
