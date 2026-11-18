import Foundation
import MySQLKit

/// Read-only view of a knowledge base for queries (design D4, D10): the effective relationships (computed and
/// annotated, verdicts applied), adjacency, search, neighbourhoods and join paths. Immutable, so it is shared by
/// concurrent MCP calls without locks; derived once per file version by `KnowledgeStore`.
public struct KnowledgeGraph: Sendable {
    public struct Edge: Sendable, Hashable, Identifiable {
        public let relationship: KnowledgeRelationship
        /// After verdicts: confirmed by the user 1.0, by an AI at least 0.95.
        public let confidence: Double
        public let verdict: RelationshipVerdict?
        /// The note of an annotated relationship.
        public let note: String?

        public var id: String { relationship.id }
        public var isSolid: Bool { relationship.isDeclared || verdict?.status == .confirmed || relationship.sources.contains(.user) }

        func other(than table: String) -> String {
            relationship.from.table == table ? relationship.to.table : relationship.from.table
        }

        /// Columns of `table`'s side and of the other side when walking from `table`.
        func columns(from table: String) -> (own: [String], other: [String]) {
            relationship.from.table == table
                ? (relationship.from.columns, relationship.to.columns)
                : (relationship.to.columns, relationship.from.columns)
        }
    }

    public struct SearchHit: Sendable, Hashable {
        public let table: String
        public let score: Int
        public let reasons: [String]
    }

    public struct SearchResult: Sendable {
        public let tables: [SearchHit]
        public let glossary: [GlossaryTerm]
    }

    public struct JoinStep: Sendable, Hashable {
        public let edge: Edge
        /// Table already in the join.
        public let fromTable: String
        /// Table joined by this step.
        public let toTable: String

        public var conditions: [(joined: String, existing: String)] {
            let columns = edge.columns(from: fromTable)
            return zip(columns.other, columns.own).map { ($0, $1) }
        }

        public static func == (lhs: JoinStep, rhs: JoinStep) -> Bool {
            lhs.edge.id == rhs.edge.id && lhs.fromTable == rhs.fromTable && lhs.toTable == rhs.toTable
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(edge.id)
            hasher.combine(fromTable)
        }
    }

    public struct JoinPath: Sendable, Hashable {
        public let tables: [String]
        public let steps: [JoinStep]
        public let cost: Double

        public var minimumConfidence: Double { steps.map(\.edge.confidence).min() ?? 1 }

        /// `FROM a JOIN b ON b.x = a.y …`, names quoted only when they need it.
        public var sql: String {
            guard let first = tables.first else { return "" }
            var lines = ["FROM \(KnowledgeSQL.identifier(first))"]
            for step in steps {
                let on = step.conditions.map { condition in
                    "\(KnowledgeSQL.identifier(step.toTable)).\(KnowledgeSQL.identifier(condition.joined)) = \(KnowledgeSQL.identifier(step.fromTable)).\(KnowledgeSQL.identifier(condition.existing))"
                }.joined(separator: " AND ")
                lines.append("JOIN \(KnowledgeSQL.identifier(step.toTable)) ON \(on)")
            }
            return lines.joined(separator: "\n")
        }
    }

    public struct TableContext: Sendable {
        public let table: KnowledgeTable
        public let note: TableNote?
        public let columnNotes: [String: ColumnNote]
        public let edges: [Edge]
        public let references: [CodeReference]
    }

    public let database: String
    /// By exact name.
    public let tables: [String: KnowledgeTable]
    /// Sorted.
    public let tableNames: [String]
    public let edges: [Edge]
    /// Rejected by a verdict (still shown, never used for paths).
    public let rejected: [Edge]
    public let notes: KnowledgeNotes
    public let references: [String: [CodeReference]]
    private let lowercasedNames: [String: [String]]
    private let adjacency: [String: [Int]]

    public init(_ knowledge: KnowledgeBase) {
        database = knowledge.database
        let snapshotTables = knowledge.snapshot?.tables ?? []
        tables = Dictionary(snapshotTables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        tableNames = tables.keys.sorted()
        var lowered: [String: [String]] = [:]
        for name in tableNames { lowered[name.lowercased(), default: []].append(name) }
        lowercasedNames = lowered
        notes = knowledge.notes
        references = knowledge.references

        var merged: [String: KnowledgeRelationship] = [:]
        var order: [String] = []
        func add(_ relationship: KnowledgeRelationship) {
            let id = relationship.id
            if let existing = merged[id] {
                merged[id] = existing.merged(with: relationship)
            } else {
                merged[id] = relationship
                order.append(id)
            }
        }
        knowledge.computed.forEach(add)
        knowledge.notes.relationships.keys.sorted().compactMap { knowledge.notes.relationships[$0]?.relationship }.forEach(add)

        let tables = tables
        func exists(_ end: RelationshipEnd) -> Bool {
            guard let table = tables[end.table] else { return false }
            return !end.columns.isEmpty && end.columns.allSatisfy { column in table.columns.contains { $0.name == column } }
        }
        var effective: [Edge] = []
        var rejected: [Edge] = []
        for id in order {
            guard let relationship = merged[id], exists(relationship.from), exists(relationship.to) else { continue }
            let verdict = knowledge.notes.verdicts[relationship.pairID]
            let note = knowledge.notes.relationships[id]?.note
            if verdict?.status == .rejected, !relationship.isDeclared {
                rejected.append(Edge(relationship: relationship, confidence: relationship.confidence, verdict: verdict, note: note))
                continue
            }
            var confidence = relationship.confidence
            if verdict?.status == .confirmed { confidence = verdict?.author == .user ? 1 : max(confidence, 0.95) }
            effective.append(Edge(relationship: relationship, confidence: confidence, verdict: verdict, note: note))
        }
        effective.sort { ($0.confidence, $1.id) > ($1.confidence, $0.id) }
        edges = effective
        self.rejected = rejected.sorted { $0.id < $1.id }
        var adjacency: [String: [Int]] = [:]
        for (index, edge) in effective.enumerated() {
            adjacency[edge.relationship.from.table, default: []].append(index)
            if edge.relationship.to.table != edge.relationship.from.table {
                adjacency[edge.relationship.to.table, default: []].append(index)
            }
        }
        self.adjacency = adjacency
    }

    // MARK: Lookup

    /// The exact name, else the only case-insensitive match.
    public func resolve(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        if tables[trimmed] != nil { return trimmed }
        let candidates = lowercasedNames[trimmed.lowercased()] ?? []
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Up to 10 names containing `name`, for "did you mean" messages.
    public func similar(to name: String) -> [String] {
        let lowered = name.lowercased()
        return tableNames.filter { $0.lowercased().contains(lowered) || lowered.contains($0.lowercased()) }.prefix(10).map { $0 }
    }

    public func edges(of table: String) -> [Edge] {
        (adjacency[table] ?? []).map { edges[$0] }
    }

    public func context(for table: String) -> TableContext? {
        guard let detail = tables[table] else { return nil }
        return TableContext(table: detail, note: notes.tables[table], columnNotes: notes.columns[table] ?? [:], edges: edges(of: table),
                            references: references[table] ?? [])
    }

    /// The focus tables, then their neighbours breadth-first (stronger edges first) up to `depth`, at most `limit` names.
    public func neighbourhood(of focus: [String], depth: Int, limit: Int) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        var frontier: [String] = []
        for table in focus where tables[table] != nil && seen.insert(table).inserted {
            ordered.append(table)
            frontier.append(table)
        }
        var level = 0
        while level < depth, !frontier.isEmpty, ordered.count < limit {
            var next: [String] = []
            for table in frontier {
                for edge in edges(of: table) {
                    let other = edge.other(than: table)
                    guard ordered.count < limit else { break }
                    if seen.insert(other).inserted {
                        ordered.append(other)
                        next.append(other)
                    }
                }
            }
            frontier = next
            level += 1
        }
        return Array(ordered.prefix(limit))
    }

    /// Tables with the most relationships first (for diagrams without a focus).
    public var tablesByDegree: [String] {
        tableNames.sorted { lhs, rhs in
            let left = adjacency[lhs]?.count ?? 0
            let right = adjacency[rhs]?.count ?? 0
            return left != right ? left > right : lhs < rhs
        }
    }

    // MARK: Search

    /// Search terms with weights: words (2), and two-character pieces of longer non-ASCII words (1), so
    /// `广告主收入` also finds a comment `广告主ID`.
    static func terms(_ query: String) -> [(text: String, weight: Int)] {
        let words = query.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        var terms: [(String, Int)] = []
        var seen = Set<String>()
        for word in words where word.count >= 2 || words.count == 1 {
            if seen.insert(word).inserted { terms.append((word, 2)) }
        }
        for word in words where word.count > 2 && word.unicodeScalars.contains(where: { !$0.isASCII }) {
            let characters = Array(word)
            for index in 0..<(characters.count - 1) {
                let piece = String(characters[index...index + 1])
                if seen.insert(piece).inserted { terms.append((piece, 1)) }
            }
        }
        return Array(terms.prefix(32))
    }

    public func search(_ query: String, limit: Int) -> SearchResult {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return SearchResult(tables: [], glossary: []) }
        let glossary = notes.glossary.values.sorted { $0.term < $1.term }
        var matchingGlossary: [(GlossaryTerm, Int)] = []
        var glossaryBoost: [String: (score: Int, terms: [String])] = [:]
        for entry in glossary {
            let haystack = (entry.term + "\n" + entry.definition).lowercased()
            let score = terms.reduce(0) { $0 + (haystack.contains($1.text) ? $1.weight : 0) }
            guard score > 0 else { continue }
            matchingGlossary.append((entry, score))
            for table in entry.tables {
                guard let name = resolve(table) else { continue }
                glossaryBoost[name, default: (0, [])].score += 5 * score
                glossaryBoost[name, default: (0, [])].terms.append(entry.term)
            }
        }
        var hits: [SearchHit] = []
        for name in tableNames {
            guard let table = tables[name] else { continue }
            var score = 0
            var reasons: [String] = []
            func reason(_ text: String) {
                if !reasons.contains(text), reasons.count < 6 { reasons.append(text) }
            }
            let lowerName = name.lowercased()
            let comment = table.comment?.lowercased() ?? ""
            let note = notes.tables[name]?.summary.lowercased() ?? ""
            let columnNotes = notes.columns[name] ?? [:]
            for term in terms {
                var termScore = 0
                if lowerName == term.text {
                    termScore += 10
                    reason("name")
                } else if lowerName.contains(term.text) {
                    termScore += 6
                    reason("name")
                }
                if comment.contains(term.text) {
                    termScore += 4
                    reason("comment")
                }
                if note.contains(term.text) {
                    termScore += 4
                    reason("note")
                }
                var columnScore = 0
                var matchedColumns = 0
                for column in table.columns {
                    let lowerColumn = column.name.lowercased()
                    var best = 0
                    if lowerColumn == term.text { best = 4 } else if lowerColumn.contains(term.text) { best = 2 }
                    if best == 0, column.comment?.lowercased().contains(term.text) == true { best = 2 }
                    if best == 0, let annotated = columnNotes[column.name] {
                        let text = ([annotated.note ?? ""] + annotated.values.map { "\($0.key) \($0.value)" }).joined(separator: "\n").lowercased()
                        if text.contains(term.text) { best = 2 }
                    }
                    guard best > 0 else { continue }
                    matchedColumns += 1
                    columnScore = max(columnScore, best)
                    reason("column \(column.name)")
                }
                termScore += columnScore + min(max(matchedColumns - 1, 0), 3)
                score += termScore * term.weight
            }
            if let boost = glossaryBoost[name] {
                score += boost.score
                for term in boost.terms { reason("glossary: \(term)") }
            }
            if score > 0 { hits.append(SearchHit(table: name, score: score, reasons: reasons)) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.table < $1.table }
        matchingGlossary.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.term < $1.0.term }
        return SearchResult(tables: Array(hits.prefix(max(1, limit))), glossary: matchingGlossary.prefix(10).map(\.0))
    }

    // MARK: Join paths

    /// Edge cost: one per hop plus a penalty for doubt, so a sure two-hop path beats a dubious direct one
    /// (0.9 + 0.83 costs 3.08, a 0.3 shortcut 3.8): a wrong join silently produces wrong numbers.
    static func cost(_ edge: Edge) -> Double { 1 + 4 * (1 - edge.confidence) }

    /// The cheapest join path between two tables within `maxHops`, then alternatives that avoid one edge of it.
    public func joinPaths(from start: String, to goal: String, maxPaths: Int = 3, maxHops: Int = 6) -> [JoinPath] {
        guard tables[start] != nil, tables[goal] != nil, start != goal else { return [] }
        guard let best = cheapestPath(from: start, to: goal, maxHops: maxHops, banned: []) else { return [] }
        var paths = [best]
        if maxPaths > 1 {
            var alternatives: [JoinPath] = []
            for step in best.steps {
                if let path = cheapestPath(from: start, to: goal, maxHops: maxHops, banned: [step.edge.id]),
                   !paths.contains(path), !alternatives.contains(path) {
                    alternatives.append(path)
                }
            }
            alternatives.sort { $0.cost != $1.cost ? $0.cost < $1.cost : $0.steps.count < $1.steps.count }
            paths += alternatives.prefix(maxPaths - 1)
        }
        return paths
    }

    /// Hop-bounded shortest path (layered relaxation: exact within `maxHops`, costs are positive so the result is simple).
    private func cheapestPath(from start: String, to goal: String, maxHops: Int, banned: Set<String>) -> JoinPath? {
        struct State {
            let cost: Double
            let parent: String?
            let edge: Int?
        }
        let hops = min(max(maxHops, 1), 12)
        var layers: [[String: State]] = [[start: State(cost: 0, parent: nil, edge: nil)]]
        var bestLayer: Int?
        var bestCost = Double.infinity
        for layer in 1...hops {
            var next: [String: State] = [:]
            for (table, state) in layers[layer - 1] {
                for index in adjacency[table] ?? [] {
                    let edge = edges[index]
                    guard !banned.contains(edge.id) else { continue }
                    let other = edge.other(than: table)
                    guard other != table, other != start else { continue }
                    let cost = state.cost + Self.cost(edge)
                    if cost < (next[other]?.cost ?? .infinity) { next[other] = State(cost: cost, parent: table, edge: index) }
                }
            }
            layers.append(next)
            if let reached = next[goal], reached.cost < bestCost - 1e-9 {
                bestCost = reached.cost
                bestLayer = layer
            }
            if next.isEmpty { break }
        }
        guard var layer = bestLayer else { return nil }
        var tablesReversed = [goal]
        var steps: [JoinStep] = []
        var current = goal
        while layer > 0, let state = layers[layer][current], let parent = state.parent, let index = state.edge {
            steps.append(JoinStep(edge: edges[index], fromTable: parent, toTable: current))
            tablesReversed.append(parent)
            current = parent
            layer -= 1
        }
        guard current == start else { return nil }
        let path = JoinPath(tables: tablesReversed.reversed(), steps: steps.reversed(), cost: bestCost)
        // A table twice would need aliases; with positive costs this cannot be optimal, but never return one.
        return Set(path.tables).count == path.tables.count ? path : nil
    }
}

/// SQL text helpers for generated snippets.
public enum KnowledgeSQL {
    /// The name as is when it is a plain identifier that no server reserves, otherwise back-quoted.
    public static func identifier(_ name: String) -> String {
        let plain = name.first.map { !$0.isNumber } == true
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$") }
        return plain && !SQLKeywords.reserved.contains(name.uppercased()) ? name : SQLText.quoteIdentifier(name)
    }
}
