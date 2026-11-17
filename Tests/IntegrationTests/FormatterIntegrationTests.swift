import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// Formatted SQL means exactly what the original means, on real servers.
@Suite("SQL formatter integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct FormatterIntegrationTests {
    /// Valid on MySQL 8.x and MariaDB 10.x against the demo schema.
    static let queries = [
        "select o.channel, count(*) n, sum(o.amount) as total from shop.orders o where o.created_at between '2025-01-01' and '2025-06-30' and o.status in ('paid','shipped') group by o.channel having count(*) > 0 order by total desc, o.channel limit 5",
        "select c.id, c.city, (select count(*) from shop.orders x where x.customer_id = c.id) as orders, count(o.id) n from shop.customers c left join shop.orders o on o.customer_id = c.id and o.amount > 10 where c.id < 20 group by c.id, c.city order by c.id",
        "with paid as (select * from shop.orders where status = 'paid'), channels as (select distinct channel from paid) select case when count(*) > 10 then 'many' when count(*) > 0 then 'some' else 'none' end k, count(*) from channels",
        "select channel, sum(amount) over (partition by channel order by created_at, id rows between unbounded preceding and current row) s from shop.orders order by channel, created_at, id limit 10",
        "/* note */ select -1 * amount as q, `channel`, x'41' as h, _utf8mb4'a' as u, @'v' as v, ifnull(null, 1) as i, date_format('2025-01-02','%Y') as y from shop.orders o where -amount < 0 order by o.id limit 3 -- end",
        "with recursive r (n) as (select 1 union all select n + 1 from r where n < 5) select * from r",
        "select id, status from shop.orders where id between 1 and 3 order by id for update",
        "select * from shop.v_paid_orders order by 1 limit 3",
        "show create table shop.orders",
    ]

    private func client(_ target: IntegrationEnvironment.Target) async throws -> MySQLClient {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 2)
        try await DemoSchema.load(into: client)
        return client
    }

    private func results(_ session: SQLSession, _ sql: String) async throws -> [[String]] {
        try await session.run(sql).filter(\.hasRowSet).map { set in
            set.columns.map(\.name) + set.rows.flatMap { $0.map { $0 ?? "NULL" } }
        }
    }

    /// What a statement does on the server: its result sets, or its error code.
    private enum Outcome: Equatable {
        case rows([[String]])
        case error(Int?)
    }

    private func outcome(_ session: SQLSession, _ sql: String) async -> Outcome {
        do {
            return .rows(try await results(session, sql))
        } catch let error as MySQLError {
            return .error(error.code)
        } catch {
            return .error(nil)
        }
    }

    // Review (1): every word whose case the formatter may change is reserved here: rejected as a name (error 1064) and,
    // on MySQL 8+, listed as reserved by information_schema.KEYWORDS.
    @Test(arguments: IntegrationEnvironment.targets)
    func caseChangeableWordsAreReservedOnThisServer(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        var acceptedAsNames: [String] = []
        for word in SQLKeywords.reservedEverywhere.sorted() {
            let result = await outcome(session, "SELECT 1 AS \(word)")
            if result != .error(1064) { acceptedAsNames.append("\(word): \(result)") }
        }
        #expect(acceptedAsNames.isEmpty, "\(target.label) accepts these as names: \(acceptedAsNames)")
        if target.isMySQL8OrLater {
            let listed = try await session.run("SELECT WORD FROM information_schema.KEYWORDS WHERE RESERVED = 1")
            let reserved = Set(listed.flatMap(\.rows).compactMap { $0.first ?? nil }.map { $0.uppercased() })
            #expect(SQLKeywords.reservedEverywhere.subtracting(reserved).isEmpty,
                    "\(target.label) does not list as reserved: \(SQLKeywords.reservedEverywhere.subtracting(reserved).sorted())")
        }
    }

    // Review (1): words that some server accepts as table names keep their case, so the formatted query still finds the
    // table (names are case-sensitive on these Linux servers). On a server that reserves the word both fail alike.
    @Test(arguments: IntegrationEnvironment.targets)
    func tablesNamedLikeKeywordsElsewhereAreStillFound(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        var found = 0
        for name in ["Database", "Schema", "Option", "Window", "Lateral", "Partition", "Offset", "Rows", "Over"] {
            // Created through a qualified name, where every server takes any word as a name.
            _ = try await session.run("DROP TABLE IF EXISTS shop.`\(name)`")
            _ = try await session.run("CREATE TABLE shop.`\(name)` (id INT)")
            _ = try await session.run("INSERT INTO shop.`\(name)` VALUES (7)")
            let query = "select id from \(name) where id = 7"
            let formatted = try #require(SQLFormatter.format(query))
            let expected = await outcome(session, query)
            #expect(await outcome(session, formatted) == expected, "\(target.label): \(formatted)")
            if expected == .rows([["id", "7"]]) { found += 1 }
            _ = try await session.run("DROP TABLE shop.`\(name)`")
        }
        #expect(found > 0, "\(target.label): every name was reserved")
    }

    // Owner request: `COUNT (*)` keeps its space and so its meaning (an error without IGNORE_SPACE), `COUNT(*)` its rows.
    @Test(arguments: IntegrationEnvironment.targets)
    func functionCallSpacingKeepsItsMeaning(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        for query in ["select count (*) from shop.orders where id < 10", "select count(*) from shop.orders where id < 10",
                      "select count(*) n, count (id) m from shop.orders"] {
            let formatted = try #require(SQLFormatter.format(query))
            #expect(formatted.contains("count (") == query.contains("count ("), "\(formatted)")
            #expect(await outcome(session, formatted) == (await outcome(session, query)), "\(target.label): \(formatted)")
        }
        #expect(await outcome(session, "SELECT COUNT (*) FROM shop.orders") == .error(1064), "\(target.label)")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func formattedQueriesReturnTheSame(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        for query in Self.queries {
            let formatted = try #require(SQLFormatter.format(query), "\(query)")
            #expect(formatted != query)
            let expected = try await results(session, query)
            let actual = try await results(session, formatted)
            #expect(actual == expected, "\(target.label): \(formatted)")
        }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func formattedDefinitionsCreateTheSameObjects(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        let suffix = UInt32.random(in: 0...UInt32.max)
        let original = "ccinn_fmt_a_\(suffix)"
        let reformatted = "ccinn_fmt_b_\(suffix)"
        func ddl(_ name: String) -> String {
            "create table shop.\(name) (id bigint unsigned not null auto_increment, name varchar(32) not null default '', "
                + "total decimal(12,2), created_at datetime default current_timestamp, primary key (id), key idx_name (name)) "
                + "engine=InnoDB default charset=utf8mb4 partition by range (id) "
                + "(partition p0 values less than (1000), partition p1 values less than maxvalue)"
        }
        _ = try await session.run(ddl(original))
        _ = try await session.run(try #require(SQLFormatter.format(ddl(reformatted))))
        let created = try await results(session, "SHOW CREATE TABLE shop.\(original)")
        let createdFormatted = try await results(session, "SHOW CREATE TABLE shop.\(reformatted)")
        #expect(created.description.replacingOccurrences(of: original, with: "T") == createdFormatted.description.replacingOccurrences(of: reformatted, with: "T"))

        // INSERT … ON DUPLICATE KEY UPDATE with `VALUES(col)`: same rows either way.
        let upsert = "insert into shop.%@ (id, name, total) values (1, 'a', 1), (2, 'b', 2) on duplicate key update total = total + values(total), name = values(name)"
        for name in [original, reformatted] {
            let statement = upsert.replacingOccurrences(of: "%@", with: name)
            _ = try await session.run(statement)
            _ = try await session.run(try #require(SQLFormatter.format(statement)))
        }
        let rows = try await results(session, "SELECT id, name, total FROM shop.\(original) ORDER BY id")
        #expect(rows == (try await results(session, "SELECT id, name, total FROM shop.\(reformatted) ORDER BY id")))
        #expect(rows.first?.suffix(6) == ["1", "a", "2.00", "2", "b", "4.00"])
        _ = try await session.run("DROP TABLE shop.\(original), shop.\(reformatted)")
    }

    // Final review: raw and formatted text do the same on the server (rows and column labels, or the same error), for
    // the shapes the review found: set-operator words that are aliases, numbers glued to words, non-ASCII look-alikes of
    // keywords, CRLF text and comments before a comma.
    @Test(arguments: IntegrationEnvironment.targets)
    func reviewedShapesMeanTheSameFormatted(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        let queries = [
            // An alias with a column list where EXCEPT / INTERSECT are names (8.0.19-8.0.30); an error here, the same one.
            "select * from (select 1 a) except (x)",
            "select * from (select 1 a) intersect (x)",
            "select x from (select 1 a) except (x)",
            // Real set operations.
            "select 1 a except select 2",
            "(select 1 a) intersect (select 1)",
            "select 1 a except all select 2",
            // `1e2` + END closes the CASE; the alias `end` keeps its label.
            "select case when 1 then 1e2end end",
            "select 1.5x, 1e2x, x'41'z, 1e2e3, .5e1f, 1.a",
            "select 1 ſelect, 2 ﬁrst",
            "select id,\r\nstatus from shop.orders\r\nwhere id < 3 order by id",
            "select id /* x */ -- y\n, status from shop.orders where id < 3 order by id",
        ]
        for query in queries {
            let formatted = try #require(SQLFormatter.format(query), "\(query)")
            #expect(await outcome(session, formatted) == (await outcome(session, query)), "\(target.label): \(formatted)")
        }
        // The aliases keep their case (they are names), and nothing is laid out as a set operation.
        #expect(SQLFormatter.format("select * from (select 1 a) except (x)")?.contains(") except (x)") == true)
        #expect(await outcome(session, "select case when 1 then 1e2end end") == .rows([["end", "100"]]), "\(target.label)")
    }

    // CASE … END proof: `end` as a CTE, a table alias, a column, a column alias and before `.`, next to CASE expressions.
    // END is not reserved, and table aliases and CTE names are case-sensitive on these servers: re-casing a name `end` as a
    // CASE's END changes which table a column comes from (or the label of a column). Expressions are aliased: the label of
    // an unaliased expression is its text, spaces included.
    @Test(arguments: IntegrationEnvironment.targets)
    func casesNextToNamesCalledEndMeanTheSame(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        let queries = [
            "with end as (select 5 a), `END` as (select 6 a) select case when 1=1 then 1 else 0 end x, a from end",
            "select case when 1=1 then end.a else 0 end v from (select 5 a) end, (select 6 b) `END`",
            "select end.a, case when 1 then 2 end k from (select 5 a) end",
            "select case when a = 5 then 'x' else 'y' end end from (select 5 a) end",
            "select case when a then end else 0 end v from (select 1 a, 2 end) t",
            "select end.x from (select case when 1 then 2 end x) end",
            "select case when 1 then 1e2end end",
            "select case when 1 then 2 end, case when 2 then 3 else 4 end from (select 1) end",
        ]
        for query in queries {
            let formatted = try #require(SQLFormatter.format(query), "\(query)")
            #expect(await outcome(session, formatted) == (await outcome(session, query)), "\(target.label): \(formatted)")
        }
        #expect(await outcome(session, queries[1]) == .rows([["v", "5"]]), "\(target.label)")
    }

    // Review #3: a CASE statement in a procedure holds `;`; `end` is a table there. The procedures created from the raw and
    // the formatted script return the same (formatting `FROM end` as `FROM END` made the call fail with 1146).
    @Test(arguments: IntegrationEnvironment.targets)
    func caseStatementsInProceduresKeepTheirNames(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        _ = try await session.run("DROP TABLE IF EXISTS shop.`end`")
        _ = try await session.run("CREATE TABLE shop.`end` (a INT)")
        _ = try await session.run("INSERT INTO shop.`end` VALUES (7)")
        let suffix = UInt32.random(in: 0...UInt32.max)
        let bodies = [
            "sel": "CASE v WHEN 1 THEN SELECT a FROM end ORDER BY a LIMIT 1; ELSE SELECT 2 AS two; END CASE;",
            "ins": "CASE v WHEN 1 THEN INSERT INTO end VALUES (v + 10); ELSE SELECT 2 AS two; END CASE; SELECT max(a) AS m FROM end;",
        ]
        for (kind, body) in bodies {
            var outcomes: [Outcome] = []
            for variant in ["raw", "fmt"] {
                let name = "ccinn_case_\(kind)_\(variant)_\(suffix)"
                let script = "DELIMITER //\nCREATE PROCEDURE shop.\(name)(v INT) BEGIN \(body) END//\nDELIMITER ;"
                let text = variant == "raw" ? script : try #require(SQLFormatter.format(script), "\(script)")
                for statement in SQLStatementSplitter.split(text) { _ = try await session.run(statement.text) }
                outcomes.append(await outcome(session, "CALL shop.\(name)(1)"))
                _ = try await session.run("DROP PROCEDURE shop.\(name)")
            }
            #expect(outcomes[0] == outcomes[1], "\(target.label) \(kind): \(outcomes)")
            #expect(outcomes[0] == .rows([[kind == "sel" ? "a" : "m", kind == "sel" ? "7" : "11"]]), "\(target.label) \(kind)")
        }
        _ = try await session.run("DROP TABLE shop.`end`")
    }

    // Review #4/#5: formatting follows the session's sql_mode. Under NO_BACKSLASH_ESCAPES `'C:\'` is a whole string (also
    // in a DELIMITER script); under ANSI_QUOTES `"C:\"` is a name and the string after it keeps its spaces.
    @Test(arguments: IntegrationEnvironment.targets)
    func formattingFollowsTheSessionsSQLMode(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        let cases: [(mode: String, expected: SQLLexingMode, scripts: [String], value: String)] = [
            ("NO_BACKSLASH_ESCAPES", SQLLexingMode(backslashEscapes: false),
             ["SELECT 'C:\\' AS d,   'x  y' AS e", "SELECT 'C:\\' AS d; SELECT 'a  b' AS e",
              "DELIMITER ;;\nSELECT 'C:\\' AS d;;\nSELECT 2 AS two;;\nDELIMITER ;"], "C:\\"),
            ("ANSI_QUOTES", SQLLexingMode(ansiQuotes: true),
             ["SELECT \"C:\\\" AS c, 'a\" ,   two  spaces' AS s FROM (SELECT 1 AS \"C:\\\") t", "SELECT \"a  b\" FROM (SELECT 1 AS \"a  b\") t"],
             "a\" ,   two  spaces"),
        ]
        for (sqlMode, expected, scripts, value) in cases {
            _ = try await session.run("SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@@SESSION.sql_mode, ''), '\(sqlMode)')")
            let mode = SQLLexingMode(sqlMode: try await session.run("SELECT @@SESSION.sql_mode AS m").last?.scalar ?? "")
            #expect(mode == expected, "\(target.label)")
            let options = SQLFormatOptions(backslashEscapes: mode.backslashEscapes, ansiQuotes: mode.ansiQuotes)
            var seen = ""
            for script in scripts {
                let formatted = try #require(SQLFormatter.format(script, options: options), "\(script)")
                var raw: [Outcome] = []
                var reformatted: [Outcome] = []
                for statement in SQLStatementSplitter.split(script, mode: mode) { raw.append(await outcome(session, statement.text)) }
                for statement in SQLStatementSplitter.split(formatted, mode: mode) { reformatted.append(await outcome(session, statement.text)) }
                #expect(raw == reformatted, "\(target.label) \(sqlMode): \(formatted)")
                #expect(!raw.contains { if case .error = $0 { true } else { false } }, "\(target.label) \(sqlMode): \(raw)")
                for case let .rows(sets) in raw { seen += sets.flatMap { $0 }.joined(separator: "|") + "|" }
            }
            #expect(seen.contains(value), "\(target.label) \(sqlMode): \(seen)")
            _ = try await session.run("SET SESSION sql_mode = DEFAULT")
        }
    }

    // `'user'@'host'` stays glued (GRANT, CREATE USER, DEFINER=), and the formatted statements manage the same account.
    @Test(arguments: IntegrationEnvironment.targets)
    func accountNamesStayGlued(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        let user = "ccinn_fmt_u\(UInt32.random(in: 0...UInt32.max))"
        let statements = [
            "create user '\(user)'@'localhost' identified by 'Secret-1x'",
            "grant select on shop.* to '\(user)'@'localhost'",
            "create definer='\(user)'@'localhost' sql security invoker view shop.\(user)_v as select 1 a",
        ]
        for statement in statements {
            let formatted = try #require(SQLFormatter.format(statement))
            #expect(formatted.contains("'\(user)'@'localhost'"), "\(formatted)")
            _ = try await session.run(formatted)
        }
        let grants = try await results(session, try #require(SQLFormatter.format("show grants for '\(user)'@'localhost'")))
        #expect(grants.description.contains("SELECT ON `shop`.*"), "\(target.label): \(grants)")
        _ = try await session.run(try #require(SQLFormatter.format("drop view shop.\(user)_v")))
        _ = try await session.run(try #require(SQLFormatter.format("drop user '\(user)'@'localhost'")))
    }

    // DELIMITER scripts: the statements the app runs (as split) still create a working procedure.
    @Test(arguments: IntegrationEnvironment.targets)
    func formattedDelimiterScriptsStillRun(target: IntegrationEnvironment.Target) async throws {
        let client = try await client(target)
        defer { Task { await client.close() } }
        let session = client.openSession(database: "shop")
        defer { Task { await session.close() } }
        let procedure = "ccinn_fmt_p_\(UInt32.random(in: 0...UInt32.max))"
        let script = "DELIMITER $$\ncreate procedure shop.\(procedure)(in x int) begin select x + 1 as y; select x * 2 as z; end$$\nDELIMITER ;\ncall shop.\(procedure)(3)"
        let formatted = try #require(SQLFormatter.format(script))
        let statements = SQLStatementSplitter.split(formatted)
        #expect(statements.count == 2)
        for statement in statements.dropLast() { _ = try await session.run(statement.text) }
        let called = try await results(session, try #require(statements.last).text)
        _ = try await session.run("DROP PROCEDURE shop.\(procedure)")
        #expect(called == [["y", "4"], ["z", "6"]])
    }
}
