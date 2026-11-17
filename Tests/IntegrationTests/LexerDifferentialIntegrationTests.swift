import Foundation
import Testing
@testable import CcinnMysqlKit
@testable import MySQLKit

/// The lexer ends numbers where the server ends them. The formatter re-lexes its output with the same lexer, so a
/// disagreement here could never be caught there: it is checked against the servers themselves.
///
/// For each generated `<number><word>` text E, `SELECT E` shows how the server split it: one column labelled E (one
/// item, no alias), one column labelled with a suffix of E (that suffix is an alias, so a token boundary sits right
/// before it), `Unknown column 'N'` (N is the first name in E), `Unknown table 'N'` (N is a qualifier: `N.`) or a syntax
/// error. The lexer's tokens must predict exactly that.
@Suite("Lexer differential integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct LexerDifferentialIntegrationTests {
    /// Numbers, near-numbers and literals the server rejects.
    static let prefixes = ["1", "12", "1.", "1.5", ".5", "1e2", "1e+2", "1E-2", "1.5e3", "1.e5", "0x41", "0X41", "0x", "0x4g", "0b1", "0b2",
                           "0B1", "x'41'", "X'4'", "x'4g'", "b'01'", "b'2'", "x''", "1e", "1.e", ".5e", "1.5E", "1e+"]
    /// What can follow a number directly: names (some of them `e`-words), digits, another number, an operator.
    static let suffixes = ["", "x", "e", "e3", "E", "end", "abc", "$", "é", "_a", "g", "1", ".5", "+x", "+2"]

    private enum ServerReading: Equatable, CustomStringConvertible {
        /// One column: its label.
        case column(String)
        case unknownColumn(String)
        case unknownTable(String)
        case syntaxError
        case other(String)

        var description: String {
            switch self {
            case let .column(label): "column \(label)"
            case let .unknownColumn(name): "unknown column \(name)"
            case let .unknownTable(name): "unknown table \(name)"
            case .syntaxError: "syntax error"
            case let .other(detail): detail
            }
        }
    }

    private func read(_ session: SQLSession, _ sql: String) async -> ServerReading {
        do {
            let sets = try await session.run(sql).filter(\.hasRowSet)
            guard sets.count == 1, let set = sets.first, set.columns.count == 1, let column = set.columns.first else {
                return .other("\(sets.map { $0.columns.map(\.name) })")
            }
            return .column(column.name)
        } catch let error as MySQLError {
            switch error.code {
            case 1064: return .syntaxError
            case 1054: return Self.quoted(in: error.message).map(ServerReading.unknownColumn) ?? .other(error.message)
            case 1109: return Self.quoted(in: error.message).map(ServerReading.unknownTable) ?? .other(error.message)
            default: return .other("\(error.code ?? 0): \(error.message)")
            }
        } catch {
            return .other("\(error)")
        }
    }

    /// The first `'…'` of a server message (`Unknown column '1e' in 'field list'`).
    private static func quoted(in message: String) -> String? {
        guard let open = message.firstIndex(of: "'") else { return nil }
        let rest = message[message.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }

    /// What the lexer predicts the server reports for `SELECT text`, or `nil` when the reading agrees.
    private static func disagreement(_ text: String, _ reading: ServerReading) -> String? {
        let lexer = SQLLexer(text)
        let tokens = lexer.tokens()
        let words = tokens.map { lexer.text(of: $0) }
        let malformed = lexer.containsMalformedLiteral(tokens)
        let context = "\(text): server \(reading), lexer \(zip(tokens, words).map { "\($0.kind) \($1)" })"
        switch reading {
        case let .column(label):
            // An alias is a word glued to a value right before it; no alias means the label is the whole text.
            let hasAlias = tokens.count >= 2 && [.identifier, .keyword].contains(tokens[tokens.count - 1].kind)
                && [.number, .string].contains(tokens[tokens.count - 2].kind)
                && tokens[tokens.count - 2].range.upperBound == tokens[tokens.count - 1].range.lowerBound
            let expected = hasAlias ? words[words.count - 1] : text
            return !malformed && label == expected ? nil : context
        case let .unknownColumn(name):
            let firstName = zip(tokens, words).first { $0.0.kind == .identifier || $0.0.kind == .keyword }?.1
            return !malformed && firstName == name ? nil : context
        case let .unknownTable(name):
            let qualifier = tokens.count >= 2 && tokens[0].kind == .identifier && words[0] == name && words[1] == "."
                && tokens[1].kind == .punctuation && tokens[0].range.upperBound == tokens[1].range.lowerBound
            return !malformed && qualifier ? nil : context
        case .syntaxError:
            // A literal the server rejects (flagged), two values in a row, or an operator without its right operand.
            let valueKinds: Set<SQLToken.Kind> = [.number, .string]
            let twoValues = zip(tokens, tokens.dropFirst()).contains { valueKinds.contains($0.kind) && valueKinds.contains($1.kind) }
            let dangling = tokens.last?.kind == .operator
            return malformed || twoValues || dangling ? nil : context
        case .other:
            return context
        }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func numbersEndWhereTheServerEndsThem(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        var disagreements: [String] = []
        var readings: [String: Int] = [:]
        for prefix in Self.prefixes {
            for suffix in Self.suffixes {
                let text = prefix + suffix
                let reading = await read(session, "SELECT \(text)")
                readings[String(describing: reading).components(separatedBy: " ").first ?? "", default: 0] += 1
                if let disagreement = Self.disagreement(text, reading) { disagreements.append(disagreement) }
            }
        }
        #expect(disagreements.isEmpty, "\(target.label): \(disagreements.joined(separator: "\n"))")
        // Every kind of reading occurred, so none of the rules above is vacuous.
        #expect(Set(readings.keys).isSuperset(of: ["column", "unknown", "syntax"]), "\(target.label): \(readings)")
    }

    // What the read-only guard relies on, on the servers themselves: a keyword glued to a number is a keyword (1.2.0's guard
    // missed `SELECT 1.5into @v`, which really assigns the variable); a word with a character outside ASCII is never a
    // keyword (each probe is a syntax error, so `ſelect`, `aſ`, `exiſts`, `ınto` were read as names); and one query never
    // runs two statements (the client does not ask for multi-statements, so a `;` left after DELIMITER fails).
    @Test(arguments: IntegrationEnvironment.targets)
    func whatTheGuardReliesOnHoldsOnTheServer(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        for (sql, value) in [("SELECT 1.5into @ccinn_v", "1.5"), ("SELECT 1e2into @ccinn_v", "100"), ("SELECT x'41'into @ccinn_v", "A")] {
            _ = try await session.run(sql)
            #expect(await read(session, "SELECT @ccinn_v AS v") == .column("v"), "\(target.label)")
            let stored = try await session.run("SELECT @ccinn_v AS v").last?.scalar
            #expect(stored == value, "\(target.label): \(sql)")
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        }
        for sql in ["ſelect 1", "select 1 aſ x", "create table if not exiſts ccinn_never (a int)", "select 1 ınto @ccinn_v", "select 1 İnto @ccinn_v"] {
            #expect(await read(session, sql) == .syntaxError, "\(target.label): \(sql)")
        }
        #expect(await read(session, "select 1 ﬁrst") == .column("ﬁrst"), "\(target.label)")
        #expect(await read(session, "SELECT 1; SET @ccinn_w = 1") == .syntaxError, "\(target.label)")
        #expect(await read(session, "SELECT @ccinn_w IS NULL AS unset") == .column("unset"))
        #expect(try await session.run("SELECT @ccinn_w IS NULL AS unset").last?.scalar == "1", "\(target.label): the second statement never ran")
    }

    // Security review: MariaDB reads `\\N` as NULL and ends it after the N, so `\\Ninto @v` assigns the variable and
    // `\\Nlock in share mode` is a locking read; MySQL 8 rejects any `\\` outside strings. The lexer reads `\\N` the
    // MariaDB way (INTO is visible), and the guard and the formatter refuse the text whatever the server.
    @Test(arguments: IntegrationEnvironment.targets)
    func backslashNIsReadAsMariaDBReadsIt(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        let readsBackslashN = target.flavor == .mariadb
        #expect(await read(session, "SELECT \\Nx") == (readsBackslashN ? .column("x") : .syntaxError), "\(target.label)")
        _ = try await session.run("SET @ccinn_n = 'untouched'")
        _ = try? await session.run("SELECT \\Ninto @ccinn_n")
        let assigned = try await session.run("SELECT @ccinn_n IS NULL AS assigned").last?.scalar == "1"
        #expect(assigned == readsBackslashN, "\(target.label)")
        for sql in ["SELECT \\Nx", "SELECT \\Ninto @ccinn_n", "(SELECT 1 FROM dual WHERE 1 IS NOT \\Nlock in share mode)"] {
            let lexer = SQLLexer(sql)
            let texts = lexer.tokens().map { lexer.text(of: $0) }
            #expect(texts.contains("\\N") && !texts.contains { ["Nx", "Ninto", "Nlock"].contains($0) }, "\(sql): \(texts)")
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            #expect(SQLFormatter.format(sql) == nil, "\(sql)")
        }
        #expect(SQLLexer("SELECT \\Ninto @v").tokens().count == 4)
    }

    // Security review sweep: for every ASCII punctuation or control character P, `<prefix> P <letters> into @v` is sent to
    // the server. Wherever the server runs the INTO (the variable changes), the lexer must see that INTO, or the formatter
    // must refuse the text; and the read-only guard must refuse it in every case.
    @Test(arguments: IntegrationEnvironment.targets)
    func noPunctuationHidesAKeywordFromTheLexer(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        let punctuation = (UInt8(1)...UInt8(0x7F)).map { Character(Unicode.Scalar($0)) }.filter {
            !($0.isLetter || $0.isNumber) && $0 != "_" && $0 != "$"
        }
        var executed = 0
        var problems: [String] = []
        for prefix in ["SELECT ", "SELECT 1 ", "SELECT 1 IS NOT "] {
            for character in punctuation {
                for letters in ["", "N", "n", "x", "e", "0", "1"] {
                    let sql = prefix + String(character) + letters + "into @ccinn_sweep"
                    _ = try await session.run("SET @ccinn_sweep = 'untouched'")
                    _ = try? await session.run(sql)
                    let untouched = try await session.run("SELECT @ccinn_sweep <=> 'untouched' AS u").last?.scalar == "1"
                    guard !untouched else { continue }
                    executed += 1
                    let lexer = SQLLexer(sql)
                    let seesInto = lexer.tokens().contains { $0.kind == .keyword && lexer.text(of: $0).uppercased() == "INTO" }
                    if !seesInto, SQLFormatter.format(sql) != nil { problems.append("lexer misses INTO: \(sql.debugDescription)") }
                    if ReadOnlySQLGuard.check(sql) == nil { problems.append("guard allows: \(sql.debugDescription)") }
                }
            }
        }
        #expect(problems.isEmpty, "\(target.label): \(problems.joined(separator: "\n"))")
        // At least the whitespace characters and `.0` reach it on every server.
        #expect(executed >= 7, "\(target.label): the sweep must reach the server's INTO (\(executed))")
    }

    // After `name.` the server reads a name whatever it starts with (`t.5e` + 2); after a back-quoted name `.5` is a
    // number; a keyword before `.` is a name too.
    @Test(arguments: IntegrationEnvironment.targets)
    func memberAccessIsReadAsTheServerReadsIt(target: IntegrationEnvironment.Target) async throws {
        let client = try await MySQLClient.connect(IntegrationEnvironment.rootConfiguration(target), poolSize: 1)
        defer { Task { await client.close() } }
        let session = client.openSession(database: nil)
        defer { Task { await session.close() } }
        let cases: [(sql: String, reading: ServerReading, tokens: [String])] = [
            ("SELECT t.5e+2 FROM (SELECT 1 AS `5e`) t", .column("t.5e+2"), ["t", ".", "5e", "+", "2"]),
            ("SELECT t.1e2 FROM (SELECT 1 AS `1e2`) t", .column("1e2"), ["t", ".", "1e2"]),
            ("SELECT `t`.5 FROM (SELECT 1 AS `5`) t", .syntaxError, ["`t`", ".5"]),
            ("SELECT date.5", .unknownTable("date"), ["date", ".", "5"]),
        ]
        for (sql, expected, tokens) in cases {
            #expect(await read(session, sql) == expected, "\(target.label): \(sql)")
            let expression = String(sql.dropFirst("SELECT ".count).prefix { $0 != " " })
            let lexer = SQLLexer(expression)
            #expect(lexer.tokens().map { lexer.text(of: $0) } == tokens, "\(expression)")
        }
    }
}
