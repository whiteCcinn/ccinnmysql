import Foundation
import MySQLWire
import Testing
@testable import MySQLKit

/// Recorded column vocabularies of replication / topology statements across versions.
@Suite("Topology parsing")
struct TopologyParsingTests {
    private func record(_ pairs: [(String, String?)]) -> Record {
        Record(values: pairs.map(\.1), lookup: ColumnLookup(names: pairs.map(\.0)))
    }

    @Test func replicaStatusInBothVocabularies() {
        let modern = ReplicaChannel(record: record([("Source_Host", "db-1"), ("Source_Port", "3306"), ("Source_User", "repl"),
                                                    ("Replica_IO_Running", "Yes"), ("Replica_SQL_Running", "Yes"), ("Seconds_Behind_Source", "3"),
                                                    ("Retrieved_Gtid_Set", "uuid:1-10"), ("Channel_Name", "")]))
        let legacy = ReplicaChannel(record: record([("Master_Host", "db-1"), ("Master_Port", "3306"), ("Master_User", "repl"),
                                                    ("Slave_IO_Running", "Yes"), ("Slave_SQL_Running", "No"), ("Seconds_Behind_Master", nil),
                                                    ("Last_SQL_Error", "Duplicate entry '1' for key 'PRIMARY'")]))
        let mariadb = ReplicaChannel(record: record([("Connection_name", "east"), ("Master_Host", "db-2"), ("Slave_IO_Running", "Connecting"),
                                                     ("Slave_SQL_Running", "Yes"), ("Using_Gtid", "Slave_Pos"), ("Gtid_IO_Pos", "0-1-100")]))
        #expect(modern.isHealthy && modern.secondsBehind == 3 && modern.sourcePort == 3306 && modern.id == "(default)")
        #expect(!legacy.isHealthy && legacy.secondsBehind == nil && legacy.lastSQLError?.contains("Duplicate") == true)
        #expect(mariadb.name == "east" && mariadb.usesGTID == "Slave_Pos" && mariadb.retrievedGTIDSet == "0-1-100" && !mariadb.isHealthy)
    }

    @Test func groupMembersAndRoles() {
        let member = GroupMember(record: record([("CHANNEL_NAME", "group_replication_applier"), ("MEMBER_ID", "uuid-1"), ("MEMBER_HOST", "gr-1"),
                                                 ("MEMBER_PORT", "3306"), ("MEMBER_STATE", "ONLINE"), ("MEMBER_ROLE", "PRIMARY"), ("MEMBER_VERSION", "8.4.3")]))
        #expect(member.state == "ONLINE" && member.role == "PRIMARY" && member.port == 3306)
        var overview = ReplicationOverview()
        #expect(overview.role == .standalone)
        overview.connectedReplicas = [["Server_Id": "2"]]
        #expect(overview.role == .source)
        overview.channels = [ReplicaChannel(record: record([("Source_Host", "up")]))]
        #expect(overview.role == .sourceAndReplica)
        overview.groupMembers = [member]
        #expect(overview.role == .groupMember)
        overview.galera = ["wsrep_cluster_size": "3"]
        #expect(overview.role == .galeraNode)
    }

    @Test func processlistRowsFromServersAndProxySQL() {
        let mysql = SessionProcess(record: record([("Id", "42"), ("User", "app"), ("Host", "10.0.0.1:5000"), ("db", "shop"), ("Command", "Query"),
                                                   ("Time", "12"), ("State", "executing"), ("Info", "SELECT 1")]))
        #expect(mysql?.id == 42 && mysql?.isRunningStatement == true && mysql?.timeSeconds == 12)
        let maria = SessionProcess(record: record([("Id", "7"), ("User", "system user"), ("Command", "Daemon"), ("Progress", "12.5")]))
        #expect(maria?.isSystemThread == true && maria?.progress == 12.5)
        let proxy = SessionProcess(record: record([("SessionID", "9"), ("user", "proxy_user"), ("db", "shop"), ("command", "Sleep")]))
        #expect(proxy?.id == 9 && proxy?.isRunningStatement == false)
        #expect(SessionProcess(record: record([("Id", "-1")])) == nil, "negative ids are rejected, not trapped")
        #expect(SessionProcess(record: record([("Id", "99999999999999999999999")])) == nil)
    }

    @Test func latestDeadlockSection() {
        let status = """
        =====================================
        ------------------------
        LATEST DETECTED DEADLOCK
        ------------------------
        2026-11-14 20:00:00 0x7f
        *** (1) TRANSACTION:
        UPDATE t SET a = 1 WHERE id = 1
        ------------
        TRANSACTIONS
        ------------
        Trx id counter 1234
        """
        let section = MySQLClient.latestDeadlock(inInnoDBStatus: status)
        #expect(section?.contains("*** (1) TRANSACTION:") == true)
        #expect(section?.contains("Trx id counter") == false)
        #expect(MySQLClient.latestDeadlock(inInnoDBStatus: "no deadlocks here") == nil)
    }

    @Test func statementDigestsUsePicoseconds() {
        let digest = StatementDigest(record: record([("DIGEST", "abc"), ("DIGEST_TEXT", "SELECT ?"), ("COUNT_STAR", "10"),
                                                     ("SUM_TIMER_WAIT", "2000000000000"), ("AVG_TIMER_WAIT", "200000000000"),
                                                     ("MAX_TIMER_WAIT", "18446744073709551615"), ("SUM_ROWS_EXAMINED", "500")]))
        #expect(digest.totalSeconds == 2)
        #expect(digest.averageSeconds == 0.2)
        #expect(digest.maxSeconds.isFinite && digest.maxSeconds > 1e7, "BIGINT UNSIGNED timers do not overflow")
        #expect(digest.rowsExaminedPerExecution == 50)
    }
}
