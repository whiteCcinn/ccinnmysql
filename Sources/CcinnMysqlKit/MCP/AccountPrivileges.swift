import Foundation
import MySQLKit

/// Whether a MySQL / MariaDB account can do through an existing stored function what the read-only statement check
/// cannot see: write or read server files (FILE), change server state (SUPER, and every privilege outside the reviewed static
/// and harmless lists, such as `*_ADMIN` or INNODB_REDO_LOG_ARCHIVE), or read credentials and other
/// sessions' statements (PROCESS, through any view or routine over the process list; global ALL; SELECT or ALL on `*.*`,
/// `mysql.*`, `performance_schema.*` or `sys.*`, also through a database pattern that matches one, such as `%`, `my%`,
/// `m_sql`). Its own grants and those of every role it holds count, also roles granted to roles.
public struct AccountPrivileges: Sendable, Equatable {
    /// What makes the account privileged, e.g. `FILE`, `SUPER`, `PROCESS`, `BINLOG_ADMIN`, `ALL PRIVILEGES ON *.*`, `SELECT ON mysql.*`;
    /// empty when nothing does.
    public let reasons: [String]

    public var isPrivileged: Bool { !reasons.isEmpty }

    public init(reasons: [String]) {
        self.reasons = reasons
    }

    public init(grants: [String]) {
        self.init(reasons: Self.reasons(in: grants))
    }

    /// Shown when read-only AI tools refuse such an account.
    public var refusal: String {
        let shown = reasons.prefix(4).joined(separator: ", ") + (reasons.count > 4 ? ", …" : "")
        return "This account can write or read server files or other sessions' data through functions or views, which a read-only check can't "
            + "prevent (it has \(shown)). Use a less privileged account, or allow it for this connection in CcinnMysql's AI settings."
    }

    // MARK: Reading the grants

    /// Reads the account's effective grants with `run` (on the connection or session the tools use). MySQL: `SHOW GRANTS
    /// FOR CURRENT_USER() USING <every granted and mandatory role>`, which expands roles granted to roles. MariaDB: `SHOW
    /// GRANTS` plus `SHOW GRANTS FOR` every role it holds or has enabled, followed through roles granted to roles. Any
    /// error is thrown: the caller refuses (fails closed).
    public static func load(flavor: ServerFlavor, run: @Sendable (String) async throws -> [ResultSet]) async throws -> AccountPrivileges {
        func lines(_ sql: String) async throws -> [String] {
            try await run(sql).flatMap(\.rows).compactMap { $0.first ?? nil }
        }
        var grants = try await lines(flavor == .mariadb ? "SHOW GRANTS" : "SHOW GRANTS FOR CURRENT_USER()")
        if flavor == .mariadb {
            let direct = Set(directRoles(in: grants).map { $0.lowercased() })
            var pending = roles(in: grants)
            pending += try await lines("SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES").map(quoted)
            var seen = Set<String>()
            while let role = pending.popLast(), seen.count < 64 {
                guard seen.insert(role.lowercased()).inserted else { continue }
                let roleGrants: [String]
                do {
                    roleGrants = try await lines("SHOW GRANTS FOR \(role)")
                } catch {
                    // A role granted directly that can't be read is a failure of its own; one held through a role is the
                    // known MariaDB limit. Both refuse.
                    guard !direct.contains(role.lowercased()) else { throw error }
                    throw NestedRoleError(role: role, serverMessage: (error as? MySQLError)?.message ?? error.localizedDescription)
                }
                grants += roleGrants
                pending += roles(in: roleGrants)
            }
        } else {
            var using = roles(in: grants)
            let mandatory = try? await lines("SELECT @@GLOBAL.mandatory_roles").first // MySQL 8.0+ only
            if let mandatory, !mandatory.trimmingCharacters(in: .whitespaces).isEmpty { using.append(mandatory) }
            if !using.isEmpty { grants += try await lines("SHOW GRANTS FOR CURRENT_USER() USING \(using.joined(separator: ", "))") }
        }
        return AccountPrivileges(grants: grants)
    }

    /// MariaDB shows an account the grants of the roles granted to it, not of the roles those roles hold (`SHOW GRANTS FOR`
    /// fails), so such an account can't be checked: the caller refuses, and says why.
    public struct NestedRoleError: Error, LocalizedError, Sendable {
        /// The role as written in the grant, e.g. `` `inner` ``.
        public let role: String
        /// What the server answered.
        public let serverMessage: String

        public var message: String {
            "This account holds the role \(role) through another role (\(serverMessage)): nested roles can't be inspected, so read-only "
                + "AI calls are refused; allow this connection in CcinnMysql's AI settings if that's intended."
        }

        public var errorDescription: String? { message }
    }

    private static func quoted(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    // MARK: Classifying grants

    /// The static privileges of MySQL and MariaDB: plain, except FILE, SUPER, PROCESS, and SELECT or ALL on a secret schema
    /// (handled before these).
    static let staticPrivileges: Set<String> = [
        "ALTER", "ALTER ROUTINE", "CREATE", "CREATE ROUTINE", "CREATE ROLE", "CREATE TEMPORARY TABLES", "CREATE VIEW", "CREATE USER", "CREATE TABLESPACE",
        "DELETE", "DELETE HISTORY", "DROP", "DROP ROLE", "EVENT", "EXECUTE", "GRANT OPTION", "INDEX", "INSERT", "LOCK TABLES", "PROXY", "REFERENCES",
        "RELOAD", "REPLICATION CLIENT", "REPLICATION SLAVE", "SELECT", "SHOW DATABASES", "SHOW VIEW", "SHUTDOWN", "TRIGGER", "UPDATE", "USAGE",
    ]

    /// Dynamic privileges reviewed as harmless for read-only AI access: the statements they allow are refused by the
    /// read-only check and cannot run inside a function (FLUSH …, resource groups), or show replication positions only
    /// (MariaDB's equivalents of REPLICATION CLIENT; SHOW REPLICA STATUS is refused and get_replication_status redacts).
    static let harmlessPrivileges: Set<String> = [
        "FLUSH_OPTIMIZER_COSTS", "FLUSH_PRIVILEGES", "FLUSH_STATUS", "FLUSH_TABLES", "FLUSH_USER_RESOURCES", "RESOURCE_GROUP_USER",
        "BINLOG MONITOR", "SLAVE MONITOR", "REPLICA MONITOR",
    ]

    /// Dynamic privileges reviewed as privileged (any privilege outside the two lists above counts as privileged anyway; this
    /// list records the review, so the per-version integration test can tell a new privilege from a reviewed one).
    static let reviewedPrivilegedDynamic: Set<String> = [
        "ALLOW_NONEXISTENT_DEFINER", "APPLICATION_PASSWORD_ADMIN", "AUDIT_ABORT_EXEMPT", "AUDIT_ADMIN", "AUTHENTICATION_POLICY_ADMIN",
        "BACKUP_ADMIN", "BINLOG_ADMIN", "BINLOG_ENCRYPTION_ADMIN", "CLONE_ADMIN", "CONNECTION_ADMIN", "ENCRYPTION_KEY_ADMIN", "FIREWALL_ADMIN",
        "FIREWALL_EXEMPT", "FIREWALL_USER", "GROUP_REPLICATION_ADMIN", "GROUP_REPLICATION_STREAM", "INNODB_REDO_LOG_ARCHIVE",
        "INNODB_REDO_LOG_ENABLE", "MASKING_DICTIONARIES_ADMIN", "NDB_STORED_USER", "OPTIMIZE_LOCAL_TABLE", "PASSWORDLESS_USER_ADMIN",
        "PERSIST_RO_VARIABLES_ADMIN", "REPLICATION_APPLIER", "REPLICATION_SLAVE_ADMIN", "RESOURCE_GROUP_ADMIN", "ROLE_ADMIN",
        "SENSITIVE_VARIABLES_OBSERVER", "SERVICE_CONNECTION_ADMIN", "SESSION_VARIABLES_ADMIN", "SET_ANY_DEFINER", "SET_USER_ID",
        "SHOW_ROUTINE", "SKIP_QUERY_REWRITE", "SYSTEM_USER", "SYSTEM_VARIABLES_ADMIN", "TABLE_ENCRYPTION_ADMIN", "TELEMETRY_LOG_ADMIN",
        "TP_CONNECTION_ADMIN", "TRANSACTION_GTID_TAG", "VERSION_TOKEN_ADMIN", "XA_RECOVER_ADMIN",
        "BINLOG ADMIN", "BINLOG REPLAY", "CONNECTION ADMIN", "FEDERATED ADMIN", "READ_ONLY ADMIN", "REPLICATION MASTER ADMIN",
        "REPLICATION SLAVE ADMIN", "SET USER",
    ]

    /// Every privilege name reviewed here.
    public static let reviewedPrivileges: Set<String> = staticPrivileges.union(harmlessPrivileges).union(reviewedPrivilegedDynamic)
        .union(["FILE", "SUPER", "PROCESS"])

    /// Schemas where reading exposes credentials (mysql) or other sessions' statements (performance_schema, and sys, which
    /// reads it).
    static let secretSchemas = ["mysql", "performance_schema", "sys"]

    /// Whether a grant's schema, as SHOW GRANTS prints it (quotes removed, escapes kept), covers a secret schema: `*`, or a
    /// pattern whose unescaped `%` and `_` match one, compared by ASCII skeleton (`%`, `my%`, `m_sql`, `performance\_schema`,
    /// `performance_ſchema`, `PERFORMANCE_SCHEMA`). Database
    /// grants take these wildcards; reading other grants' schemas as patterns too only over-blocks odd names.
    static func coversSecretSchema(_ schema: String) -> Bool {
        schema == "*" || secretSchemas.contains { likeMatches(pattern: SQLNameFolding.skeleton(schema), name: $0) }
    }

    /// SQL LIKE with `\` as the escape character, as the servers match database grants: `%` matches any run of characters,
    /// `_` exactly one, `\x` the character x (a trailing `\` itself). Linear in the pattern times the name.
    static func likeMatches(pattern: String, name: String) -> Bool {
        enum Piece { case anyRun, one, literal(Character) }
        var pieces: [Piece] = []
        var escaping = false
        for character in pattern {
            if escaping {
                pieces.append(.literal(character))
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                pieces.append(character == "%" ? .anyRun : character == "_" ? .one : .literal(character))
            }
        }
        if escaping { pieces.append(.literal("\\")) }
        let text = Array(name)
        // matched[j]: the pieces so far match the first j characters.
        var matched = [Bool](repeating: false, count: text.count + 1)
        matched[0] = true
        for piece in pieces {
            var next = [Bool](repeating: false, count: text.count + 1)
            for end in 0...text.count {
                switch piece {
                case .anyRun: next[end] = matched[end] || (end > 0 && next[end - 1])
                case .one: next[end] = end > 0 && matched[end - 1]
                case let .literal(character): next[end] = end > 0 && matched[end - 1] && text[end - 1] == character
                }
            }
            matched = next
        }
        return matched[text.count]
    }

    /// Why the `GRANT … ON … TO …` lines make an account privileged (role grants and other lines are skipped).
    public static func reasons(in grants: [String]) -> [String] {
        var reasons: [String] = []
        for line in grants {
            guard let grant = Grant(line), let object = grant.object else { continue }
            let schema = object.schema
            for privilege in grant.privileges {
                let reason: String?
                switch privilege {
                case "FILE", "SUPER", "PROCESS":
                    reason = privilege
                case "ALL", "ALL PRIVILEGES":
                    reason = coversSecretSchema(schema) ? "ALL PRIVILEGES ON \(object.display)" : nil
                case "SELECT":
                    reason = coversSecretSchema(schema) ? "SELECT ON \(object.display)" : nil
                case _ where staticPrivileges.contains(privilege) || harmlessPrivileges.contains(privilege):
                    reason = nil
                default:
                    // Every other privilege (MySQL's dynamic ones, MariaDB's newer ones, any a later version adds) until reviewed:
                    // INNODB_REDO_LOG_ARCHIVE has no _ADMIN suffix and let a SELECT start a server-side file write.
                    reason = privilege
                }
                if let reason, !reasons.contains(reason) { reasons.append(reason) }
            }
        }
        return reasons
    }

    /// Roles granted to the account itself (`GRANT <role> TO user@host`), not to another role (`GRANT <role> TO <role>`,
    /// which MariaDB's SHOW GRANTS also prints while a role is enabled; roles have no host there).
    static func directRoles(in grants: [String]) -> [String] {
        grants.compactMap(Grant.init).filter { $0.object == nil && $0.grantsToAccount }.flatMap(\.rawItems)
    }

    /// Roles granted in `GRANT <role>[, <role>] TO …` lines (no `ON`), as written (already quoted).
    public static func roles(in grants: [String]) -> [String] {
        grants.compactMap(Grant.init).filter { $0.object == nil }.flatMap(\.rawItems)
    }

    /// One `GRANT` line: its items (privileges, or roles when there is no `ON`) and its object.
    struct Grant {
        struct Object {
            /// The schema without quotes, escapes kept (`performance\_schema`), `*` for `*.*`.
            let schema: String
            let display: String
        }

        /// Upper-case privilege names without column lists.
        let privileges: [String]
        /// The items as written (roles keep their quoting and host).
        let rawItems: [String]
        let object: Object?
        /// What follows `TO`: the grantee, then options (`IDENTIFIED BY …`, `WITH …`).
        let grantee: String

        /// Whether the grantee is an account (`` `u`@`%` ``) rather than a MariaDB role (no host): an `@` outside quotes
        /// in its first word.
        var grantsToAccount: Bool {
            let characters = Array(grantee)
            let end = Self.topLevel(" ", in: characters) ?? characters.count
            return Self.topLevel("@", in: Array(characters[..<end])) != nil
        }

        init?(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("GRANT ") else { return nil }
            let body = Array(trimmed.dropFirst(6))
            guard let to = Self.topLevel(" TO ", in: body) else { return nil }
            let on = Self.topLevel(" ON ", in: Array(body[..<to]))
            let items = String(body[..<(on ?? to)])
            grantee = String(body[(to + 4)...]).trimmingCharacters(in: .whitespaces)
            rawItems = Self.splitTopLevel(items)
            privileges = rawItems.map { item in
                let name = item.firstIndex(of: "(").map { String(item[..<$0]) } ?? item // `SELECT (a, b)`
                return name.trimmingCharacters(in: .whitespaces).uppercased()
            }
            if let on {
                var target = String(body[(on + 4)..<to]).trimmingCharacters(in: .whitespaces)
                for kind in ["TABLE ", "FUNCTION ", "PROCEDURE "] where target.uppercased().hasPrefix(kind) {
                    target = String(target.dropFirst(kind.count))
                }
                object = Object(schema: Self.schemaPart(of: target), display: target.replacingOccurrences(of: "`", with: ""))
            } else {
                object = nil
            }
        }

        /// The schema of `` `db`.`t` ``, `db.*` or `*.*`: a back-quoted (or, under ANSI_QUOTES, double-quoted) name up to its
        /// closing quote, with doubled quotes inside, else everything up to the first `.`.
        static func schemaPart(of target: String) -> String {
            guard let quote = target.first, quote == "`" || quote == "\"" else { return String(target.prefix { $0 != "." }) }
            var schema = ""
            var characters = target.dropFirst()[...]
            while let character = characters.popFirst() {
                guard character == quote else {
                    schema.append(character)
                    continue
                }
                guard characters.first == quote else { break }
                schema.append(quote)
                characters.removeFirst()
            }
            return schema
        }

        /// Offset of `needle` (case-insensitive) outside back-quotes, quotes and parentheses.
        static func topLevel(_ needle: String, in text: [Character]) -> Int? {
            let target = Array(needle)
            var quote: Character?
            var depth = 0
            var index = 0
            while index < text.count {
                let character = text[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "`" || character == "'" || character == "\"" {
                    quote = character
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if depth == 0, index + target.count <= text.count,
                          String(text[index..<(index + target.count)]).uppercased() == needle.uppercased() {
                    return index
                }
                index += 1
            }
            return nil
        }

        /// Items separated by commas outside back-quotes, quotes and parentheses.
        static func splitTopLevel(_ text: String) -> [String] {
            var items: [String] = []
            var current = ""
            var quote: Character?
            var depth = 0
            for character in text {
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "`" || character == "'" || character == "\"" {
                    quote = character
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if character == ",", depth == 0 {
                    items.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
                current.append(character)
            }
            let last = current.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty { items.append(last) }
            return items.filter { !$0.isEmpty }
        }
    }
}
