import Foundation

/// Mermaid `erDiagram` of a focus set and its neighbourhood (design D10). Declared and confirmed relationships are
/// solid, inferred ones dotted. Names are sanitized to what every Mermaid version accepts.
public enum KnowledgeERD {
    public enum Columns: String, Sendable, CaseIterable {
        /// Primary, unique and foreign key columns (the first columns when a table has none).
        case keys
        case all
    }

    public struct Diagram: Sendable {
        public let text: String
        public let tables: [String]
        public var entities: Int { tables.count }
        /// More tables would have been included without the entity limit.
        public let truncated: Bool
    }

    public static let maxEntities = 60
    static let maxAttributes = 60

    public static func mermaid(_ graph: KnowledgeGraph, focus: [String], depth: Int = 1, columns: Columns = .keys,
                               maxEntities: Int = maxEntities) -> Diagram {
        let limit = max(1, maxEntities)
        let selected: [String]
        let truncated: Bool
        let resolved = focus.compactMap(graph.resolve)
        if resolved.isEmpty {
            let ordered = graph.tablesByDegree
            selected = Array(ordered.prefix(limit))
            truncated = ordered.count > limit
        } else {
            let around = graph.neighbourhood(of: resolved, depth: max(0, min(depth, 3)), limit: limit + 1)
            selected = Array(around.prefix(limit))
            truncated = around.count > limit
        }
        let included = Set(selected)
        let ids = identifiers(for: selected)
        let edges = graph.edges.filter { included.contains($0.relationship.from.table) && included.contains($0.relationship.to.table) }
        var foreignKeyColumns: [String: Set<String>] = [:]
        for edge in graph.edges where edge.cardinality != .unknown {
            foreignKeyColumns[edge.relationship.from.table, default: []].formUnion(edge.relationship.from.columns)
        }
        var lines = ["erDiagram"]
        for name in selected {
            guard let table = graph.tables[name], let id = ids[name] else { continue }
            let attributes = attributeLines(table, foreignKeys: foreignKeyColumns[name] ?? [], columns: columns)
            guard !attributes.isEmpty else { continue }
            lines.append("    \(id) {")
            lines += attributes.map { "        " + $0 }
            lines.append("    }")
        }
        for edge in edges {
            guard let from = ids[edge.relationship.from.table], let to = ids[edge.relationship.to.table] else { continue }
            let nullable = edge.relationship.from.columns.contains { column in
                graph.tables[edge.relationship.from.table]?.column(named: column)?.nullable == true
            }
            let left: String
            let right: String
            switch edge.cardinality {
            case .manyToOne:
                left = nullable ? "|o" : "||"
                right = "o{"
            case .oneToOne:
                left = nullable ? "|o" : "||"
                right = "o|"
            case .unknown:
                left = "}o"
                right = "o{"
            }
            let line = edge.isSolid ? "--" : ".."
            lines.append("    \(to) \(left)\(line)\(right) \(from) : \"\(label(edge.relationship.from.columns.joined(separator: ", ")))\"")
        }
        return Diagram(text: lines.joined(separator: "\n"), tables: selected, truncated: truncated)
    }

    static func attributeLines(_ table: KnowledgeTable, foreignKeys: Set<String>, columns: Columns) -> [String] {
        let primary = Set(table.primaryKey)
        let unique = Set(table.uniqueKeys.filter { $0.count == 1 }.map { $0[0] })
        func keys(_ column: KnowledgeColumn) -> [String] {
            var keys: [String] = []
            if primary.contains(column.name) { keys.append("PK") }
            if foreignKeys.contains(column.name) { keys.append("FK") }
            if unique.contains(column.name), !primary.contains(column.name) { keys.append("UK") }
            return keys
        }
        var shown: [KnowledgeColumn]
        switch columns {
        case .all:
            shown = Array(table.columns.prefix(maxAttributes))
        case .keys:
            shown = table.columns.filter { !keys($0).isEmpty }
            if shown.isEmpty { shown = Array(table.columns.prefix(3)) }
        }
        return shown.map { column in
            var parts = [identifier(column.dataType.isEmpty ? "unknown" : column.dataType), identifier(column.name)]
            let markers = keys(column)
            if !markers.isEmpty { parts.append(markers.joined(separator: ", ")) }
            if let comment = column.comment.map(label), !comment.isEmpty { parts.append("\"\(comment)\"") }
            return parts.joined(separator: " ")
        }
    }

    /// Unique, sanitized entity names.
    static func identifiers(for tables: [String]) -> [String: String] {
        var used = Set<String>()
        var result: [String: String] = [:]
        for table in tables {
            let base = identifier(table)
            var candidate = base
            var suffix = 2
            while !used.insert(candidate.lowercased()).inserted {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            result[table] = candidate
        }
        return result
    }

    /// `[A-Za-z0-9_]`, starting with a letter or `_`; `table` when nothing is left.
    static func identifier(_ name: String) -> String {
        var text = String(name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") ? Character(scalar) : "_"
        })
        if text.allSatisfy({ $0 == "_" }) { text = "table" + (text.isEmpty ? "" : "_\(name.unicodeScalars.count)") }
        if let first = text.first, first.isNumber { text = "t_" + text }
        return text
    }

    /// Text inside a quoted Mermaid label: no quotes or line breaks, at most 80 characters.
    static func label(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 80 ? String(cleaned.prefix(79)) + "…" : cleaned
    }
}

/// A Markdown document of a knowledge base for repositories and AI tools without MCP. It names projects but never
/// their local paths, and contains no host, user or connection details.
public enum KnowledgeMarkdown {
    public static func render(_ knowledge: KnowledgeBase, graph: KnowledgeGraph, generatedAt: Date = Date()) -> String {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]
        var out: [String] = []
        let tables = graph.tableNames.compactMap { graph.tables[$0] }
        let baseTables = tables.filter { $0.kind == .table }.count
        out.append("# \(literal(knowledge.database)) — database knowledge")
        out.append("")
        var facts = "Generated by CcinnMysql on \(date.string(from: generatedAt))."
        if let snapshot = knowledge.snapshot {
            facts += " Schema read \(date.string(from: snapshot.takenAt))\(snapshot.serverVersion.map { " from \($0)" } ?? ""):"
            facts += " " + [Plural.phrase(baseTables, "table"), Plural.phrase(tables.count - baseTables, "view"),
                            Plural.phrase(graph.edges.count, "relationship")].joined(separator: ", ") + "."
        }
        out.append(facts)
        out.append("")
        out.append("> Relationships not declared as foreign keys were inferred from naming conventions, view and routine definitions, code or notes. Their sources and confidence are listed; verify a dubious one before relying on it. Notes marked *AI* were written by an AI assistant.")
        out.append("")
        if !graph.tableNames.isEmpty {
            out.append("## ER diagram")
            out.append("")
            let diagram = KnowledgeERD.mermaid(graph, focus: [], columns: .keys)
            if diagram.truncated {
                out.append("The \(diagram.entities) most connected of \(graph.tableNames.count) tables.")
                out.append("")
            }
            out.append("```mermaid")
            out.append(diagram.text)
            out.append("```")
            out.append("")
        }

        out.append("## Tables")
        out.append("")
        out.append("| Table | Kind | Rows (est.) | Purpose |")
        out.append("|---|---|---:|---|")
        for table in tables {
            let purpose = graph.notes.tables[table.name]?.summary ?? table.comment ?? ""
            out.append("| [\(cell(table.name))](#\(anchor(table.name))) | \(table.kind.rawValue) | \(table.rowsEstimate.map(String.init) ?? "") | \(cell(purpose)) |")
        }
        out.append("")
        for table in tables {
            out += section(for: table, graph: graph, date: date)
        }

        out.append("## Relationships")
        out.append("")
        if graph.edges.isEmpty {
            out.append("None recorded.")
        } else {
            out.append("| Relationship | Cardinality | Sources | Confidence | Evidence |")
            out.append("|---|---|---|---:|---|")
            for edge in graph.edges {
                out.append("| \(cell(relationship(edge.relationship))) | \(edge.cardinality.rawValue) | \(edge.relationship.sources.map(\.rawValue).joined(separator: ", "))\(edge.verdict?.status == .confirmed ? " (confirmed)" : "") | \(String(format: "%.2f", edge.confidence)) | \(cell(edge.relationship.evidence.prefix(3).map(exportLabel).joined(separator: "; "))) |")
            }
        }
        out.append("")
        if !graph.rejected.isEmpty {
            out.append("Rejected (do not use):")
            out.append("")
            for edge in graph.rejected {
                out.append("- \(literal(relationship(edge.relationship)))\(edge.verdict?.reason.map { " — \(literal($0))" } ?? "")")
            }
            out.append("")
        }

        let glossary = graph.notes.glossary.values.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        if !glossary.isEmpty {
            out.append("## Glossary")
            out.append("")
            for term in glossary {
                out.append("### \(literal(term.term))")
                out.append("")
                out.append(literal(term.definition) + author(term.author, term.updatedAt, date))
                if !term.tables.isEmpty {
                    out.append("")
                    out.append("Tables: " + term.tables.map { "[\(literal($0))](#\(anchor($0)))" }.joined(separator: ", "))
                }
                if let sql = term.sql {
                    // A fence longer than any run of back quotes in the recipe cannot be closed by it.
                    let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: sql) + 1))
                    out.append("")
                    out.append(fence + "sql")
                    out.append(sql)
                    out.append(fence)
                }
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    static func section(for table: KnowledgeTable, graph: KnowledgeGraph, date: ISO8601DateFormatter) -> [String] {
        var out = ["### \(literal(table.name))", ""]
        if let note = graph.notes.tables[table.name] {
            out.append(literal(note.summary) + author(note.author, note.updatedAt, date))
            out.append("")
        }
        if let comment = table.comment, comment != graph.notes.tables[table.name]?.summary {
            out.append("Comment: \(literal(comment))")
            out.append("")
        }
        let notes = graph.notes.columns[table.name] ?? [:]
        let foreignKeys = Set(graph.edges(of: table.name).filter { $0.relationship.from.table == table.name }.flatMap(\.relationship.from.columns))
        out.append("| Column | Type | Null | Key | Meaning |")
        out.append("|---|---|---|---|---|")
        for column in table.columns {
            var keys: [String] = []
            if table.primaryKey.contains(column.name) { keys.append("PK") }
            if table.uniqueKeys.contains(where: { $0 == [column.name] }) { keys.append("UK") }
            if foreignKeys.contains(column.name) { keys.append("FK") }
            // Each part escaped on its own; the export's own AI marker is added after escaping.
            var meaning: [String] = []
            if let comment = column.comment { meaning.append(literal(comment)) }
            if let note = notes[column.name] {
                if let text = note.note { meaning.append(literal(text) + (note.author == .ai ? " *(AI)*" : "")) }
                if !note.values.isEmpty {
                    let values = note.values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                    meaning.append("values: " + values.map { literal("\($0.key) = \($0.value)") }.joined(separator: ", "))
                }
            }
            out.append("| \(cell(column.name)) | \(cell(column.type)) | \(column.nullable ? "YES" : "NO") | \(keys.joined(separator: ", ")) | \(meaning.joined(separator: "; ")) |")
        }
        out.append("")
        let edges = graph.edges(of: table.name)
        if !edges.isEmpty {
            out.append("Relationships:")
            out.append("")
            for edge in edges {
                out.append("- \(literal(relationship(edge.relationship))) — \(edge.relationship.sources.map(\.rawValue).joined(separator: ", ")), \(String(format: "%.2f", edge.confidence))")
            }
            out.append("")
        }
        if let references = graph.references[table.name], !references.isEmpty {
            out.append("Used in: " + references.prefix(8).map { literal("\($0.project):\($0.path):\($0.line)") }.joined(separator: ", "))
            out.append("")
        }
        return out
    }

    static func relationship(_ relationship: KnowledgeRelationship) -> String {
        "\(relationship.from.label) → \(relationship.to.label)"
    }

    static func author(_ author: KnowledgeAuthor, _ date: Date, _ formatter: ISO8601DateFormatter) -> String {
        " *(\(author == .ai ? "AI" : "user"), \(formatter.string(from: date)))*"
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Text from annotations, comments or names as plain text: one line, Markdown and HTML neutralised, so a note
    /// can neither add structure (headings, fences, HTML) nor imitate the author labels the export adds.
    static func literal(_ text: String) -> String {
        var out = ""
        let characters = Array(oneLine(text))
        for (index, character) in characters.enumerated() {
            switch character {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "\\", "`", "*", "[", "]", "#", "|", "~", "!":
                out += "\\" + String(character)
            case "_":
                // Inside a word an underscore is literal in GitHub Markdown (`order_items`); elsewhere it could emphasise.
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + 1 < characters.count ? characters[index + 1] : " "
                out += (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber) ? "_" : "\\_"
            default:
                out.append(character)
            }
        }
        return out
    }

    static func cell(_ text: String) -> String {
        literal(text)
    }

    /// Evidence as exported: locations and generated descriptions only; what an AI typed (queries, notes) stays local.
    static func exportLabel(_ evidence: KnowledgeEvidence) -> String {
        switch evidence.kind {
        case .code, .schema, .definition: evidence.label
        case .naming: "naming convention"
        case .query: "verified by a query"
        case .note: "note"
        }
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for each in text {
            current = each == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    /// GitHub-style heading anchor.
    static func anchor(_ heading: String) -> String {
        String(heading.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" { return Character(scalar) }
            if scalar == " " { return "-" }
            return nil
        })
    }
}

extension KnowledgeGraph.Edge {
    public var cardinality: RelationshipCardinality { relationship.cardinality }
}
