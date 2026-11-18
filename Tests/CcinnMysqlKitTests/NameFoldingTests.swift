import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit
import MySQLWire

/// Final review, items 6 and 7: MySQL and MariaDB resolve `information_schema.processlıst` (ı), `PROCESSLİST` (İ),
/// `proceſſlist` (ſ) and, on MariaDB, `ınformation_schema`, `performance_ſchema` and Kelvin-sign names to the system
/// names, and drop NUL from a handshake database name. The read-only guard compared Swift-lower-cased names and missed
/// all of them; read-only access now refuses such names and compares the rest by an ASCII skeleton.
@Suite("Names the servers fold to ASCII")
struct NameFoldingTests {
    /// The 19 letters, derived from Unicode case mappings over every scalar.
    static let expected: Set<UInt32> = [0x00DF, 0x0130, 0x0131, 0x0149, 0x017F, 0x01F0, 0x1E96, 0x1E97, 0x1E98, 0x1E99, 0x1E9A, 0x212A,
                                        0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB05, 0xFB06]

    @Test func theLettersThatCaseMapToASCIIAreExactlyNineteen() async {
        let found = await onDedicatedThread { () -> Set<UInt32> in
            var found: Set<UInt32> = []
            for value in UInt32(0)...0x10FFFF {
                guard let scalar = Unicode.Scalar(value), SQLNameFolding.caseMapsToASCII(scalar) else { continue }
                found.insert(value)
            }
            return found
        }
        #expect(found == Self.expected, "\(found.sorted().map { String($0, radix: 16) })")
        #expect(!SQLNameFolding.caseMapsToASCII("a") && !SQLNameFolding.caseMapsToASCII("é") && !SQLNameFolding.caseMapsToASCII("Å"))
    }

    @Test(arguments: [("processlıst", "processlist"), ("PROCESSLİST", "processlist"), ("proceſſlist", "processlist"),
                      ("INNODB_LOC\u{212A}S", "innodb_locks"), ("LOAD_ﬁLE", "load_file"), ("sql_modé", "sql_mode"), ("café", "cafe"),
                      ("ｍｙｓｑｌ", "mysql"), ("Straße", "strasse"), ("performance_ſchema", "performance_schema"), ("日本", "日本"),
                      ("Shop_1", "shop_1"), ("", "")])
    func theSkeletonFoldsCaseCompatibilityAndAccents(name: String, skeleton: String) {
        #expect(SQLNameFolding.skeleton(name) == skeleton)
    }

    // MARK: Read-only guard

    @Test(arguments: [
        // The reviewer's strings (MySQL 8.0, 8.4, 9.6, MariaDB 10.11, 12.0).
        "SELECT ID, INFO FROM information_schema.processlıst", "SELECT ID, INFO FROM information_schema.PROCESSLİST",
        "SELECT ID, INFO FROM information_schema.proceſſlist", "SELECT ID, INFO FROM ınformation_schema.PROCESSLIST",
        "SELECT ID, INFO FROM information_ſchema.PROCESSLIST", "SELECT ID, INFO FROM `ınformation_schema`.PROCESSLIST",
        "SELECT * FROM performance_ſchema.threads", "SHOW TABLES FROM performance_ſchema",
        "SELECT lock_data FROM information_schema.INNODB_LOC\u{212A}S",
        // Functions.
        "SELECT LOAD_FıLE('/etc/passwd')", "SELECT LOAD_FİLE('/etc/passwd')", "SELECT ſleep(1)", "SELECT versıon()",
        "SELECT LOAD_ﬁLE('/etc/hosts')", "SELECT GET_LOC\u{212A}('x', 1)", "SELECT `ſleep`(1)",
        // Keywords and variables.
        "SELECT 1 ınto @v", "SELECT 1 FROM t FOR UPDATE ſkip locked", "SELECT @@ſecure_file_priv", "SELECT Straße FROM t",
    ])
    func namesWithLettersTheServersFoldAreRefused(sql: String) {
        let message = ReadOnlySQLGuard.check(sql)
        #expect(message?.contains("U+") == true && message?.contains("plain letters") == true, "\(sql): \(message ?? "allowed")")
    }

    @Test func theMessageNamesTheLetterAndItsCodePoint() {
        let message = ReadOnlySQLGuard.check("SELECT * FROM information_schema.processlıst") ?? ""
        #expect(message.contains("ı") && message.contains("U+0131"), "\(message)")
    }

    @Test(arguments: ["ınformation_schema", "information_ſchema", "`ınformation_schema`", "performance_ſchema", "\u{212A}eys", "ﬁles"])
    func databaseArgumentsWithSuchLettersAreRefused(database: String) {
        let message = ReadOnlySQLGuard.check("SELECT ID, INFO FROM processlist", defaultDatabase: database)
        #expect(message?.contains("U+") == true, "\(database): \(message ?? "allowed")")
    }

    // MySQL compares some names by collation weights (accents folded): the deny lists compare ASCII skeletons.
    @Test(arguments: ["SELECT * FROM information_schema.processlíst", "SELECT * FROM performance_schéma.threads", "SELECT SLÉEP(1)",
                      "SELECT * FROM `mÿsql`.user", "SELECT * FROM ｍｙｓｑｌ.user", "SHOW TABLES FROM `sÿs`", "SELECT `LOAD_FÍLE`('/etc/hosts')"])
    func accentedSpellingsOfDeniedNamesAreRefused(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        #expect(ReadOnlySQLGuard.check("SELECT * FROM processlíst", defaultDatabase: "information_schéma") != nil)
    }

    @Test(arguments: ["SELECT * FROM café", "SELECT naïve FROM t", "SELECT * FROM `résumé`.`données`", "SELECT 'ı' AS s",
                      "SELECT * FROM t WHERE name = 'ſ'", "SELECT 1 -- ı in a comment", "SELECT * FROM 日本"])
    func ordinaryAccentedNamesStayUsable(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql): \(ReadOnlySQLGuard.check(sql) ?? "allowed")")
        #expect(ReadOnlySQLGuard.check("SELECT 1", defaultDatabase: "café") == nil)
    }

    // MARK: Control characters (item 7)

    @Test(arguments: ["information_\u{0}schema", "information_schema\u{0}", "\u{0}information_schema", "my\u{0}sql", "performance_\u{0}schema",
                      "shop\u{1}", "shop\u{7F}", "shop\u{85}", "\u{85}shop"])
    func databaseArgumentsWithControlCharactersAreRefusedFirst(database: String) {
        let message = ReadOnlySQLGuard.check("SELECT ID, INFO FROM processlist", defaultDatabase: database)
        #expect(message?.contains("control character") == true, "\(database.debugDescription): \(message ?? "allowed")")
        #expect(ReadOnlySQLGuard.check("SELECT 1", defaultDatabase: "shop") == nil)
    }

    @Test func argumentsWithControlCharactersAreFound() {
        #expect(Arguments(["database": "my\u{0}sql", "sql": "SELECT '\u{1}'"]).controlCharacterArgument() == "database")
        #expect(Arguments(["table": "t\u{85}", "connection": "Prod"]).controlCharacterArgument() == "table")
        #expect(Arguments(["sql": .string("SELECT '\u{0}'"), "database": .string("shop"), "limit": .int(5)]).controlCharacterArgument() == nil)
    }

    // MARK: Replication status (other sessions' SQL)

    @Test(arguments: ["SHOW REPLICA STATUS", "SHOW SLAVE STATUS", "show all slaves status", "SHOW ALL REPLICAS STATUS", "SHOW SLAVE 'c1' STATUS",
                      "SHOW REPLICA STATUS FOR CHANNEL 'x'", "SHOW SLAVE STATUS NONBLOCKING"])
    func replicaStatusGoesThroughItsTool(sql: String) {
        let message = ReadOnlySQLGuard.check(sql)
        #expect(message?.contains("get_replication_status") == true, "\(sql): \(message ?? "allowed")")
        #expect(ReadOnlySQLGuard.check("SHOW REPLICAS") == nil && ReadOnlySQLGuard.check("SHOW SLAVE HOSTS") == nil)
    }

    // Item 8: the binary and relay logs print replicated statements with their values.
    @Test(arguments: ["SHOW BINLOG EVENTS", "SHOW BINLOG EVENTS IN 'mysql-bin.000001' FROM 4 LIMIT 10", "show relaylog events",
                      "SHOW RELAYLOG EVENTS FOR CHANNEL 'c'", "SHOW RELAYLOG 'conn' EVENTS", "SHOW /* x */ BINLOG EVENTS"])
    func binaryAndRelayLogEventsAreRefused(sql: String) {
        let message = ReadOnlySQLGuard.check(sql)
        #expect(message?.contains("replicated statements") == true, "\(sql): \(message ?? "allowed")")
        #expect(ReadOnlySQLGuard.check("SHOW BINARY LOGS") == nil && ReadOnlySQLGuard.check("SHOW MASTER STATUS") == nil)
    }

    @Test func replicationErrorsLoseTheirQuotedStatementAndValues() throws {
        let error = "Error 'Duplicate entry 'card-4111-secret' for key 'PRIMARY'' on query. Default database: 'shop'. "
            + "Query: 'INSERT INTO t VALUES (1, 'card-4111-secret')', Gtid 0-1-5, Internal MariaDB error code: 1062"
        let names = ["Channel_Name", "Last_IO_Error", "Last_SQL_Error"]
        let set = ResultSet(columns: names.map { ColumnDefinition(name: $0, type: .varString) }, rows: [["", "", error]])
        let channel = ReplicaChannel(record: try #require(set.records.first))
        let encoded = MySQLMCPTools.encode(channel: channel)
        let text = try #require(encoded["last_sql_error"]?.stringValue)
        for secret in ["card", "4111", "secret", "INSERT", "shop"] { #expect(!text.contains(secret), "\(text)") }
        #expect(text.hasPrefix("Error ?") && text.hasSuffix("error code: 1062"), "\(text)")
        #expect(SQLRedactor.redactQuoted("Coordinator stopped at end_log_pos 123") == "Coordinator stopped at end_log_pos 123")
        #expect(SQLRedactor.redactQuoted("a 'b' c \"d\" e `f` g") == "a ? g")
    }
}
