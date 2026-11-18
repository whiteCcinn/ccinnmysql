import Foundation
import MySQLWire
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite("Table insights")
struct TableInsightsTests {
    private func column(_ name: String, _ type: String, key: String = "", extra: String = "", nullable: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, ordinal: 1, dataType: type.components(separatedBy: CharacterSet(charactersIn: "( ")).first ?? type,
                   columnType: type, isNullable: nullable, columnKey: key, extra: extra)
    }

    @Test func autoIncrementHeadroomBySignedness() throws {
        let signed = [column("id", "int", key: "PRI", extra: "auto_increment")]
        let critical = try #require(TableInsights.autoIncrementHeadroom(columns: signed, nextValue: 1_932_735_284))
        #expect(critical.maximum == 2_147_483_647)
        #expect(critical.severity == .critical)
        let unsigned = [column("id", "int unsigned", key: "PRI", extra: "auto_increment")]
        #expect(TableInsights.autoIncrementHeadroom(columns: unsigned, nextValue: 1_932_735_284)?.severity == .ok)
        let tiny = [column("id", "tinyint", key: "PRI", extra: "auto_increment")]
        #expect(TableInsights.autoIncrementHeadroom(columns: tiny, nextValue: 122)?.severity == .critical)
        let bigUnsigned = [column("id", "bigint unsigned", key: "PRI", extra: "auto_increment")]
        #expect(TableInsights.autoIncrementHeadroom(columns: bigUnsigned, nextValue: UInt64.max)?.current == UInt64.max - 1)
        #expect(TableInsights.autoIncrementHeadroom(columns: tiny, nextValue: 0)?.current == 0, "no underflow")
        #expect(TableInsights.autoIncrementHeadroom(columns: [column("a", "varchar(10)")], nextValue: 5) == nil)
    }

    @Test func redundantAndDuplicateIndexes() {
        func index(_ name: String, _ columns: [String], unique: Bool = false, type: String = "BTREE") -> IndexInfo {
            IndexInfo(name: name, isUnique: unique, type: type, columns: columns.map { IndexColumn(name: $0) })
        }
        let indexes = [
            index("PRIMARY", ["id"], unique: true), index("idx_customer", ["customer_id"]), index("idx_customer_created", ["customer_id", "created_at"]),
            index("uk_email", ["email"], unique: true), index("idx_email", ["email"]), index("ft_note", ["note"], type: "FULLTEXT"),
            index("idx_note", ["note"]), index("dup_a", ["status"]), index("dup_b", ["status"]),
        ]
        let findings = TableInsights.redundantIndexes(indexes)
        let titles = Set(findings.map(\.title))
        #expect(titles.contains("Redundant index idx_customer"))
        #expect(titles.contains("Duplicate index idx_email"), "a plain index equal to a unique one is a duplicate")
        #expect(!titles.contains("Redundant index uk_email"), "unique indexes enforce constraints")
        #expect(!titles.contains("Redundant index idx_note"), "different index types are not comparable")
        #expect(titles.contains("Duplicate index dup_b") && !titles.contains("Duplicate index dup_a"), "only one of an equal pair is reported")
        #expect(!titles.contains { $0.contains("PRIMARY") })
    }

    @Test func findingsForATableWithoutPrimaryKey() {
        var object = DatabaseObject(schema: "shop", name: "audit", kind: .table)
        object.engine = "InnoDB"
        let detail = TableDetail(object: object, columns: [column("happened_at", "datetime"), column("note", "varchar(100)", nullable: true)])
        let findings = TableInsights.findings(for: detail)
        #expect(findings.first?.kind == .missingPrimaryKey)
        #expect(findings.first?.severity == .critical)
    }

    @Test func byteFormatting() {
        #expect(ByteFormatter.string(512) == "512 B")
        #expect(ByteFormatter.string(1_536) == "1.5 KB")
        #expect(ByteFormatter.string(Int64.max).hasSuffix("EB"))
        #expect(ByteFormatter.string(nil) == "—")
    }
}

@Suite("EXPLAIN parsing")
struct ExplainParserTests {
    @Test(arguments: ["explain-m84-q1.json", "explain-m57-q1.json", "explain-percona80-q1.json"])
    func mysqlJSONJoinWithFilesort(name: String) throws {
        let plan = try ExplainParser.parse(try fixture(name))
        #expect(plan.format == .mysqlJSON)
        #expect((plan.totalCost ?? 0) > 0)
        let tables = plan.nodes.compactMap(\.table)
        #expect(tables.contains("o") && tables.contains("c"))
        #expect(plan.warnings.contains(.filesort))
        #expect(plan.warnings.contains(.temporaryTable))
        let customers = try #require(plan.nodes.first { $0.table == "c" })
        #expect(customers.accessType == "eq_ref")
        #expect(customers.key == "PRIMARY")
    }

    @Test func fullScanIsFlagged() throws {
        let plan = try ExplainParser.parse(try fixture("explain-m84-q2.json"))
        let orders = try #require(plan.nodes.first { $0.table == "orders" })
        #expect(orders.accessType == "ALL")
        #expect(orders.warnings.contains(.fullTableScan))
        #expect((orders.estimatedRows ?? 0) >= 1_000)
    }

    @Test(arguments: ["explain-m84-q3.json", "explain-m57-q3.json", "explain-mariadb1011-q3.json"])
    func unionsAndSubqueries(name: String) throws {
        let plan = try ExplainParser.parse(try fixture(name))
        #expect(plan.nodes.contains { $0.title.hasPrefix("Union") })
        #expect(plan.nodes.filter { $0.table == "customers" }.count >= 2)
        #expect(plan.nodes.count < ExplainParser.maxNodes)
    }

    @Test func mariaDBAnalyzeHasActualRows() throws {
        let plan = try ExplainParser.parse(try fixture("analyze-mariadb1011-q1.json"))
        #expect(plan.format == .mariadbJSON)
        #expect(plan.isAnalyzed)
        let orders = try #require(plan.nodes.first { $0.table == "o" })
        #expect(orders.actualRows == 2000)
        #expect(orders.warnings.contains(.fullTableScan))
        #expect(plan.warnings.contains(.filesort))
    }

    @Test func mysqlJSONVersion2Tree() throws {
        let plan = try ExplainParser.parse(try fixture("explain-m84v2-q1.json"))
        #expect(plan.format == .mysqlJSONTree)
        let lookup = try #require(plan.nodes.first { $0.title.hasPrefix("Index lookup on o") })
        #expect(lookup.key == "idx_status")
        #expect(lookup.estimatedRows == 510)
    }

    @Test func explainAnalyzeTree() throws {
        let plan = try ExplainParser.parse(try fixture("analyze-m84-q3.txt"))
        #expect(plan.format == .tree)
        #expect(plan.isAnalyzed)
        #expect(plan.root.title.hasPrefix("Table scan on <union temporary>"))
        let scan = try #require(plan.nodes.first { $0.title == "Table scan on orders" })
        #expect(scan.warnings.contains(.fullTableScan))
        #expect(scan.actualRows == 2000)
        #expect(scan.estimatedRows == 2000)
        #expect(scan.table == "orders")
        let filter = try #require(plan.nodes.first { $0.title.hasPrefix("Filter:") })
        #expect(filter.children.first?.title == "Table scan on orders", "indentation builds the tree")
        let join = try #require(plan.nodes.first { $0.title == "Nested loop inner join" })
        #expect(join.children.count == 2)
    }

    @Test func malformedInputThrowsOrDegrades() async {
        #expect(throws: ExplainParseError.self) { try ExplainParser.parse("not a plan") }
        #expect(throws: ExplainParseError.self) { try ExplainParser.parse("{\"query_block\": ") }
        var deep = ""
        for _ in 0..<500 { deep += "{\"query_block\": " }
        deep += "{}" + String(repeating: "}", count: 500)
        #expect(throws: ExplainParseError.self) { try ExplainParser.parse(deep) }
        let deeperThrows = await onDedicatedThread { () -> Bool in
            let deeper = String(repeating: "[", count: 100_000)
            do {
                _ = try ExplainParser.parse("{\"a\": " + deeper)
                return false
            } catch {
                return error is ExplainParseError
            }
        }
        #expect(deeperThrows)
        await onDedicatedThread {
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<500 {
                let tree = (0..<Int.random(in: 1..<30, using: &generator)).map { _ in
                    String(repeating: " ", count: Int.random(in: 0..<40, using: &generator)) + "-> Op (cost=\(Int.random(in: 0..<9))..x rows=1e999) (actual time=1..2 rows=nan loops=1)"
                }.joined(separator: "\n")
                _ = ExplainParser.parseTree(tree)
            }
        }
    }
}

@Suite("Inline row edit")
struct RowEditorTests {
    private func column(_ name: String, _ type: ColumnType, table: String = "orders", schema: String = "shop", charset: UInt16 = 45) -> ColumnDefinition {
        var writer = PayloadWriter()
        for part in ["def", schema, table, table, name, name] { writer.writeLengthEncodedString(part) }
        writer.writeLengthEncoded(0x0C)
        writer.writeUInt16(charset)
        writer.writeUInt32(255)
        writer.writeUInt8(type.rawValue)
        writer.writeUInt16(0)
        writer.writeUInt8(0)
        writer.writeUInt16(0)
        // The builder above is well-formed by construction.
        return (try? ColumnDefinition(payload: writer.bytes)) ?? ColumnDefinition(name: name, type: type)
    }

    @Test func singleTableWithPrimaryKeyIsEditable() throws {
        let columns = [column("id", .longLong), column("status", .string), column("amount", .newDecimal)]
        let eligibility = RowEditor.eligibility(columns: columns, keys: [["id"]], isBaseTable: true)
        let plan = try #require(eligibility.plan)
        #expect(plan.keyColumns == [0])
        let sql = try RowEditor.updateStatement(plan: plan, row: ["42", "new", "9.50"], changes: [1: "paid", 2: nil])
        #expect(sql == "UPDATE `shop`.`orders` SET `status` = 'paid', `amount` = NULL WHERE `id` = '42' LIMIT 1")
        let escaped = try RowEditor.updateStatement(plan: plan, row: ["42", "x", "1"], changes: [1: "it's \\ ok"], noBackslashEscapes: true)
        #expect(escaped.contains("`status` = 'it''s \\ ok'"))
    }

    @Test func joinsViewsMissingKeysAndBinaryKeysAreReadOnly() {
        let join = [column("id", .longLong), column("name", .varString, table: "customers")]
        #expect(RowEditor.eligibility(columns: join, keys: [["id"]], isBaseTable: true).plan == nil)
        let noKey = [column("status", .string)]
        #expect(RowEditor.eligibility(columns: noKey, keys: [["id"]], isBaseTable: true).plan == nil)
        #expect(RowEditor.eligibility(columns: [column("id", .longLong)], keys: [], isBaseTable: true).plan == nil)
        #expect(RowEditor.eligibility(columns: [column("id", .longLong)], keys: [["id"]], isBaseTable: false).plan == nil)
        let binaryKey = [column("hash", .string, charset: 63), column("v", .varString)]
        #expect(RowEditor.eligibility(columns: binaryKey, keys: [["hash"]], isBaseTable: true).plan == nil)
        let floatKey = [column("f", .double)]
        #expect(RowEditor.eligibility(columns: floatKey, keys: [["f"]], isBaseTable: true).plan == nil)
    }

    @Test func computedColumnsStayReadOnly() throws {
        var columns = [column("id", .longLong), column("status", .string)]
        columns.append(ColumnDefinition(name: "upper(status)", type: .varString))
        let plan = try #require(RowEditor.eligibility(columns: columns, keys: [["id"]], isBaseTable: true).plan)
        #expect(!plan.editableColumns.contains(2))
        #expect(throws: MySQLError.self) { try RowEditor.updateStatement(plan: plan, row: ["1", "a", "A"], changes: [2: "B"]) }
        #expect(throws: MySQLError.self) { try RowEditor.updateStatement(plan: plan, row: [nil, "a", "A"], changes: [1: "B"]) }
    }

    @Test func matchedRowsFromInfo() {
        #expect(RowEditor.matchedRows(info: "Rows matched: 1  Changed: 0  Warnings: 0", affectedRows: 0) == 1)
        #expect(RowEditor.matchedRows(info: "", affectedRows: 1) == 1)
        #expect(RowEditor.matchedRows(info: "Rows matched: 99999999999999999999999  Changed: 0", affectedRows: 0) != 1, "huge numbers never look like one row")
    }
}

@Suite("Status metrics")
struct StatusMetricsTests {
    @Test func ratesPerSecondSkipGaugesAndResets() {
        let before = [ServerVariable(name: "Questions", value: "1000"), ServerVariable(name: "Threads_connected", value: "5"),
                      ServerVariable(name: "Com_select", value: "500"), ServerVariable(name: "Bytes_sent", value: "900"),
                      ServerVariable(name: "Ssl_version", value: "TLSv1.3")]
        let after = [ServerVariable(name: "Questions", value: "1600"), ServerVariable(name: "Threads_connected", value: "9"),
                     ServerVariable(name: "Com_select", value: "560"), ServerVariable(name: "Bytes_sent", value: "100"),
                     ServerVariable(name: "Ssl_version", value: "TLSv1.3")]
        let rates = StatusMetrics.rates(previous: before, current: after, seconds: 2)
        #expect(rates["Questions"] == 300)
        #expect(rates["Com_select"] == 30)
        #expect(rates["Threads_connected"] == nil, "gauges are not rates")
        #expect(rates["Bytes_sent"] == nil, "counters that went backwards are skipped")
        #expect(rates["Ssl_version"] == nil)
        #expect(StatusMetrics.rates(previous: before, current: after, seconds: 0).isEmpty)
        #expect(StatusMetrics.rates(previous: before, current: after, seconds: .nan).isEmpty)
    }

    @Test func bufferPoolHitRatio() {
        let status = [ServerVariable(name: "Innodb_buffer_pool_read_requests", value: "10000"), ServerVariable(name: "Innodb_buffer_pool_reads", value: "100")]
        #expect(StatusMetrics.bufferPoolHitRatio(status) == 0.99)
        #expect(StatusMetrics.bufferPoolHitRatio([]) == nil)
    }
}
