import Foundation
import MySQLKit

/// A stored routine or view that runs with its definer's rights (`SQL SECURITY DEFINER`, the default) and that the
/// current account can reach. The read-only check sees `SELECT f()` or `SELECT * FROM v`, never what runs inside, so
/// such an object defined by a privileged account is an accepted risk that the app reports instead of refusing.
public struct DefinerRightsObject: Sendable, Equatable, Hashable {
    /// `FUNCTION`, `PROCEDURE` or `VIEW`.
    public let kind: String
    public let schema: String
    public let name: String
    /// `user@host`.
    public let definer: String
    /// Whether the definer is privileged (`AccountPrivileges`); `nil` when this account cannot see the definer's grants.
    public let definerPrivileged: Bool?

    public init(kind: String, schema: String, name: String, definer: String, definerPrivileged: Bool?) {
        self.kind = kind
        self.schema = schema
        self.name = name
        self.definer = definer
        self.definerPrivileged = definerPrivileged
    }

    public var label: String {
        "\(schema).\(name) (\(kind.lowercased()), definer \(definer)\(definerPrivileged == nil ? ", privileges not visible" : ""))"
    }
}

public enum DefinerRights {
    /// Schemas the read-only tools never read, so their objects are not reachable through `run_query`.
    static let unreachableSchemas: Set<String> = ["mysql", "performance_schema", "sys", "information_schema"]
    static let limit = 500

    /// Definer-rights routines and views the current account can execute or select, whose definer is another account that
    /// is privileged or whose privileges this account cannot see.
    public static func load(run: @Sendable (String) async throws -> [ResultSet]) async throws -> [DefinerRightsObject] {
        func rows(_ sql: String) async throws -> [[String?]] { try await run(sql).flatMap(\.rows) }
        let current = try await rows("SELECT CURRENT_USER()").first?.first ?? nil
        let candidates = try await rows("""
            SELECT ROUTINE_TYPE, ROUTINE_SCHEMA, ROUTINE_NAME, DEFINER FROM information_schema.ROUTINES WHERE SECURITY_TYPE = 'DEFINER'
            """) + rows("SELECT 'VIEW', TABLE_SCHEMA, TABLE_NAME, DEFINER FROM information_schema.VIEWS WHERE SECURITY_TYPE = 'DEFINER'")
        var privileged: [String: Bool?] = [:]
        var objects: [DefinerRightsObject] = []
        for row in candidates where row.count == 4 {
            guard let kind = row[0], let schema = row[1], let name = row[2], let definer = row[3],
                  !unreachableSchemas.contains(SQLNameFolding.skeleton(schema)), definer.lowercased() != current?.lowercased() else { continue }
            if privileged[definer] == nil {
                let grants = try? await rows("SHOW GRANTS FOR \(quotedAccount(definer))").compactMap { $0.first ?? nil }
                privileged[definer] = .some(grants.map { AccountPrivileges(grants: $0).isPrivileged })
            }
            let definerPrivileged = privileged[definer] ?? nil
            guard definerPrivileged != false else { continue }
            objects.append(DefinerRightsObject(kind: kind.uppercased(), schema: schema, name: name, definer: definer, definerPrivileged: definerPrivileged))
            if objects.count >= limit { break }
        }
        return objects.sorted { ($0.schema, $0.name) < ($1.schema, $1.name) }
    }

    /// `user@host` as `'user'@'host'`.
    static func quotedAccount(_ account: String) -> String {
        let at = account.lastIndex(of: "@")
        let user = at.map { String(account[..<$0]) } ?? account
        let host = at.map { String(account[account.index(after: $0)...]) } ?? "%"
        return SQLText.literal(user) + "@" + SQLText.literal(host)
    }

    /// The notice read-only tools add to their results, `nil` when there is nothing to report.
    public static func notice(for objects: [DefinerRightsObject]) -> String? {
        guard !objects.isEmpty else { return nil }
        let shown = objects.prefix(5).map(\.label).joined(separator: "; ")
        let more = objects.count > 5 ? "; and \(objects.count - 5) more" : ""
        let one = objects.count == 1
        return "\(objects.count) definer-rights routine\(one ? "" : "s") or view\(one ? "" : "s") \(one ? "runs" : "run") with a privileged "
            + "account's rights; the read-only check can't see inside \(one ? "it" : "them"): \(shown)\(more)."
    }
}

/// What read-only AI access through an account means, for Settings → MCP: whether the tools refuse the account
/// (`AccountPrivileges`) and which definer-rights objects it can reach (`DefinerRights`).
public struct AIAccessReport: Sendable, Equatable {
    public let privileges: AccountPrivileges
    public let definerRights: [DefinerRightsObject]

    public init(privileges: AccountPrivileges, definerRights: [DefinerRightsObject]) {
        self.privileges = privileges
        self.definerRights = definerRights
    }

    public static func load(client: MySQLClient) async throws -> AIAccessReport {
        let run: @Sendable (String) async throws -> [ResultSet] = { try await client.query($0) }
        return AIAccessReport(privileges: try await AccountPrivileges.load(flavor: client.serverInfo.flavor, run: run),
                              definerRights: try await DefinerRights.load(run: run))
    }

    /// One paragraph for the settings pane.
    public func summary(allowsPrivilegedAccount: Bool) -> String {
        var parts: [String] = []
        if privileges.isPrivileged {
            parts.append(allowsPrivilegedAccount
                ? "Privileged account (\(privileges.reasons.prefix(4).joined(separator: ", "))): allowed for read-only AI access."
                : "Privileged account (\(privileges.reasons.prefix(4).joined(separator: ", "))): read-only AI tools refuse it.")
        } else {
            parts.append("Not a privileged account: read-only AI tools accept it.")
        }
        parts.append(DefinerRights.notice(for: definerRights) ?? "No definer-rights routines or views run with another account's rights.")
        return parts.joined(separator: " ")
    }
}

/// Definer-rights objects per connection, refreshed every five minutes (routines and views change rarely; the notice is
/// informational, the refusal of privileged accounts is checked on every call).
actor DefinerRightsCache {
    private var entries: [UUID: (at: ContinuousClock.Instant, objects: [DefinerRightsObject])] = [:]

    func objects(for id: UUID, ttl: Duration = .seconds(300),
                 load: @Sendable () async throws -> [DefinerRightsObject]) async -> [DefinerRightsObject]? {
        if let entry = entries[id], ContinuousClock.now - entry.at < ttl { return entry.objects }
        guard let objects = try? await load() else { return nil }
        entries[id] = (ContinuousClock.now, objects)
        return objects
    }
}
