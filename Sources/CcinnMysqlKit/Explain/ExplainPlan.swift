import Foundation

/// Something in a plan that usually deserves attention.
public enum PlanWarning: String, Sendable, Hashable, CaseIterable {
    case fullTableScan, fullIndexScan, filesort, temporaryTable, joinBuffer, dependentSubquery, noUsableIndex, estimateMismatch

    public var title: String {
        switch self {
        case .fullTableScan: "Full table scan"
        case .fullIndexScan: "Full index scan"
        case .filesort: "Filesort"
        case .temporaryTable: "Temporary table"
        case .joinBuffer: "Join buffer (no index for the join)"
        case .dependentSubquery: "Dependent subquery (runs per outer row)"
        case .noUsableIndex: "Possible indexes not used"
        case .estimateMismatch: "Row estimate off by more than 10×"
        }
    }
}

/// One operation of a query plan.
public struct PlanNode: Sendable, Identifiable {
    public let id: Int
    public var title: String
    public var table: String?
    public var accessType: String?
    public var key: String?
    public var possibleKeys: [String] = []
    public var usedKeyParts: [String] = []
    /// Rows the optimizer expects to read (per loop).
    public var estimatedRows: Double?
    /// Rows the operation produces (after filtering), when reported.
    public var producedRows: Double?
    public var filtered: Double?
    public var cost: Double?
    /// EXPLAIN ANALYZE / MariaDB ANALYZE: actual rows (per loop) and loops.
    public var actualRows: Double?
    public var loops: Double?
    public var actualTimeMilliseconds: Double?
    public var condition: String?
    public var details: [String] = []
    public var warnings: Set<PlanWarning> = []
    public var children: [PlanNode] = []

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
    }

    /// Depth-first list of this node and its descendants.
    public var flattened: [PlanNode] { [self] + children.flatMap(\.flattened) }
}

public struct ExplainPlan: Sendable {
    public enum Format: String, Sendable {
        case mysqlJSON, mysqlJSONTree, mariadbJSON, tree
    }

    public let root: PlanNode
    public let format: Format
    public let totalCost: Double?
    /// The plan includes measured (ANALYZE) values.
    public let isAnalyzed: Bool

    public var nodes: [PlanNode] { root.flattened }
    public var warnings: Set<PlanWarning> { nodes.reduce(into: Set<PlanWarning>()) { $0.formUnion($1.warnings) } }
}

public struct ExplainParseError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

/// Parses `EXPLAIN FORMAT=JSON` (MySQL v1 and v2 formats, MariaDB, MariaDB `ANALYZE FORMAT=JSON`) and
/// `EXPLAIN ANALYZE` / `EXPLAIN FORMAT=TREE` text into a bounded plan tree (design D12).
public enum ExplainParser {
    public static let maxDepth = 64
    public static let maxNodes = 10_000

    public static func parse(_ text: String) throws -> ExplainPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return try parseJSON(trimmed) }
        if trimmed.hasPrefix("->") { return parseTree(trimmed) }
        throw ExplainParseError(description: "Not an EXPLAIN FORMAT=JSON or EXPLAIN ANALYZE output")
    }

    // MARK: JSON

    public static func parseJSON(_ text: String) throws -> ExplainPlan {
        guard text.utf8.count <= 64 * 1024 * 1024 else { throw ExplainParseError(description: "The plan is too large") }
        let data = Data(text.utf8)
        // JSONSerialization recurses per nesting level; hostile depth would overflow the stack.
        guard !JSONValue.nestingExceeds(data, limit: 256) else { throw ExplainParseError(description: "The plan is nested too deeply") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ExplainParseError(description: "The plan is not valid JSON: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else { throw ExplainParseError(description: "Unexpected plan shape") }
        var builder = Builder()
        if dictionary["query_block"] == nil, dictionary["inputs"] != nil || dictionary["operation"] != nil {
            let root = builder.treeNode(dictionary, depth: 0)
            return ExplainPlan(root: root, format: .mysqlJSONTree, totalCost: root.cost, isAnalyzed: builder.sawActuals)
        }
        let isMariaDB = containsKey(dictionary, anyOf: ["r_loops", "r_total_time_ms", "read_sorted_file", "block-nl-join", "query_optimization"], depth: 0)
            || (dictionary["query_block"] as? [String: Any]).map { containsKey($0, anyOf: ["filesort", "temporary_table"], depth: 0) } == true
        var root = builder.objectNode(dictionary, title: "Query", depth: 0)
        if root.children.count == 1, let only = root.children.first { root = only }
        let cost = ((dictionary["query_block"] as? [String: Any])?["cost_info"] as? [String: Any]).flatMap { number($0["query_cost"]) }
        return ExplainPlan(root: root, format: isMariaDB ? .mariadbJSON : .mysqlJSON, totalCost: cost ?? root.cost, isAnalyzed: builder.sawActuals)
    }

    static func containsKey(_ object: Any, anyOf keys: Set<String>, depth: Int) -> Bool {
        guard depth < maxDepth else { return false }
        if let dictionary = object as? [String: Any] {
            if dictionary.keys.contains(where: keys.contains) { return true }
            return dictionary.values.contains { containsKey($0, anyOf: keys, depth: depth + 1) }
        }
        if let array = object as? [Any] { return array.contains { containsKey($0, anyOf: keys, depth: depth + 1) } }
        return false
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let string as String:
            guard let double = Double(string.trimmingCharacters(in: .whitespaces)), double.isFinite else { return nil }
            return double
        default:
            return nil
        }
    }

    static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string.lowercased() == "true" }
        return false
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.prefix(256).compactMap { $0 as? String } ?? []
    }

    struct Builder {
        var nextID = 0
        var count = 0
        var sawActuals = false

        mutating func make(_ title: String) -> PlanNode {
            defer { nextID += 1 }
            count += 1
            return PlanNode(id: nextID, title: title)
        }

        var full: Bool { count >= ExplainParser.maxNodes }

        /// Operation keys that become plan nodes, in display order.
        static let operations: [(key: String, title: String)] = [
            ("union_result", "Union"), ("ordering_operation", "Order"), ("filesort", "Filesort"), ("grouping_operation", "Group"),
            ("duplicates_removal", "Remove duplicates"), ("windowing", "Window functions"), ("buffer_result", "Buffer result"),
            ("temporary_table", "Temporary table"), ("read_sorted_file", "Read sorted file"), ("having_condition", ""),
            ("query_block", "Query block"), ("nested_loop", "Nested loop"), ("block-nl-join", "Block nested loop join"),
            ("table", ""), ("materialized_from_subquery", "Materialized subquery"), ("query_specifications", ""),
            ("attached_subqueries", "Subqueries"), ("subqueries", "Subqueries"), ("optimized_away_subqueries", "Optimized-away subqueries"),
            ("order_by_subqueries", "Order-by subqueries"), ("group_by_subqueries", "Group-by subqueries"), ("having_subqueries", "Having subqueries"),
            ("select_list_subqueries", "Select-list subqueries"), ("update_value_subqueries", "Update subqueries"),
        ]

        /// A JSON object that may contain several operations: becomes a node titled `title` with its operations as children.
        mutating func objectNode(_ object: [String: Any], title: String, depth: Int) -> PlanNode {
            var node = make(title)
            guard depth < ExplainParser.maxDepth, !full else { return node }
            if let selectID = number(object["select_id"]) { node.title = "\(title) #\(Int(selectID))" }
            if let cost = (object["cost_info"] as? [String: Any]).flatMap({ ExplainParser.number($0["query_cost"]) }) { node.cost = cost }
            if ExplainParser.flag(object["using_filesort"]) { node.warnings.insert(.filesort) }
            if ExplainParser.flag(object["using_temporary_table"]) { node.warnings.insert(.temporaryTable) }
            if ExplainParser.flag(object["dependent"]) { node.warnings.insert(.dependentSubquery) }
            if let rows = ExplainParser.number(object["r_rows"] ?? object["r_output_rows"]) { node.actualRows = rows; sawActuals = true }
            if let loops = ExplainParser.number(object["r_loops"]) { node.loops = loops }
            if let time = ExplainParser.number(object["r_total_time_ms"]) { node.actualTimeMilliseconds = time; sawActuals = true }
            if let sortKey = object["sort_key"] as? String { node.details.append("Sort key: \(sortKey)") }
            if let having = object["having_condition"] as? String { node.condition = having }
            for (key, title) in Self.operations {
                guard let value = object[key], !full else { continue }
                switch key {
                case "table":
                    if let table = value as? [String: Any] { node.children.append(tableNode(table, depth: depth + 1)) }
                case "nested_loop":
                    var loop = make(title)
                    for item in (value as? [Any] ?? []).prefix(1_000) {
                        guard let element = item as? [String: Any], !full else { continue }
                        loop.children += childNodes(of: element, depth: depth + 2)
                    }
                    node.children.append(loop)
                case "query_specifications":
                    for item in (value as? [Any] ?? []).prefix(1_000) {
                        guard let element = item as? [String: Any], !full else { continue }
                        node.children += childNodes(of: element, depth: depth + 1)
                    }
                case "having_condition":
                    continue
                default:
                    if let array = value as? [Any] {
                        var group = make(title)
                        for item in array.prefix(1_000) {
                            guard let element = item as? [String: Any], !full else { continue }
                            group.children += childNodes(of: element, depth: depth + 2)
                        }
                        node.children.append(group)
                    } else if let child = value as? [String: Any] {
                        var childNode = objectNode(child, title: title, depth: depth + 1)
                        if key == "union_result" || key == "temporary_table" { childNode.warnings.insert(.temporaryTable) }
                        if key == "filesort" || key == "read_sorted_file" { childNode.warnings.insert(.filesort) }
                        if key == "block-nl-join" { childNode.warnings.insert(.joinBuffer) }
                        if key == "union_result", let table = child["table_name"] as? String { childNode.details.append(table) }
                        node.children.append(childNode)
                    }
                }
            }
            return node
        }

        /// Children of an element of an array such as `nested_loop` (`{"table": …}` or `{"query_block": …}`).
        mutating func childNodes(of element: [String: Any], depth: Int) -> [PlanNode] {
            if element.count == 1, let table = element["table"] as? [String: Any] { return [tableNode(table, depth: depth)] }
            let wrapper = objectNode(element, title: "Block", depth: depth)
            return wrapper.children.isEmpty ? [wrapper] : (wrapper.children.count == 1 && wrapper.cost == nil ? wrapper.children : [wrapper])
        }

        mutating func tableNode(_ table: [String: Any], depth: Int) -> PlanNode {
            let name = table["table_name"] as? String ?? "?"
            var node = make(name)
            node.table = name
            node.accessType = (table["access_type"] as? String).map { $0.uppercased() == "ALL" ? "ALL" : $0 }
            node.key = table["key"] as? String
            node.possibleKeys = ExplainParser.strings(table["possible_keys"])
            node.usedKeyParts = ExplainParser.strings(table["used_key_parts"])
            node.estimatedRows = ExplainParser.number(table["rows_examined_per_scan"] ?? table["rows"])
            node.producedRows = ExplainParser.number(table["rows_produced_per_join"])
            node.filtered = ExplainParser.number(table["filtered"])
            if let cost = table["cost_info"] as? [String: Any] { node.cost = ExplainParser.number(cost["prefix_cost"] ?? cost["read_cost"]) }
            if let rows = ExplainParser.number(table["r_rows"]) { node.actualRows = rows; sawActuals = true }
            if let loops = ExplainParser.number(table["r_loops"]) { node.loops = loops }
            if let time = ExplainParser.number(table["r_table_time_ms"] ?? table["r_total_time_ms"]) { node.actualTimeMilliseconds = time; sawActuals = true }
            node.condition = (table["attached_condition"] as? String) ?? (table["index_condition"] as? String)
            if let access = node.accessType { node.title = "\(name) · \(access)" }
            if ExplainParser.flag(table["using_index"]) { node.details.append("Covering index") }
            if let ref = table["ref"] as? [Any] { node.details.append("ref: " + ref.compactMap { $0 as? String }.joined(separator: ", ")) }
            if let join = table["using_join_buffer"] as? String {
                node.details.append("Join buffer: \(join)")
                node.warnings.insert(.joinBuffer)
            }
            if ExplainParser.flag(table["using_temporary_table"]) { node.warnings.insert(.temporaryTable) }
            if ExplainParser.flag(table["using_filesort"]) { node.warnings.insert(.filesort) }
            switch node.accessType?.uppercased() {
            case "ALL": node.warnings.insert(.fullTableScan)
            case "INDEX": node.warnings.insert(.fullIndexScan)
            default: break
            }
            if node.key == nil, !node.possibleKeys.isEmpty { node.warnings.insert(.noUsableIndex) }
            markMismatch(&node)
            if depth < ExplainParser.maxDepth, let materialized = table["materialized_from_subquery"] as? [String: Any] {
                node.children.append(objectNode(materialized, title: "Materialized subquery", depth: depth + 1))
            }
            for key in ["attached_subqueries"] where depth < ExplainParser.maxDepth {
                for item in (table[key] as? [Any] ?? []).prefix(100) {
                    if let element = item as? [String: Any] { node.children += childNodes(of: element, depth: depth + 1) }
                }
            }
            return node
        }

        /// MySQL `explain_json_format_version=2` / EXPLAIN ANALYZE FORMAT=JSON: iterator tree with `inputs`.
        mutating func treeNode(_ object: [String: Any], depth: Int) -> PlanNode {
            var node = make(object["operation"] as? String ?? "Query")
            node.table = object["table_name"] as? String
            node.accessType = object["access_type"] as? String
            node.key = object["index_name"] as? String
            node.estimatedRows = ExplainParser.number(object["estimated_rows"])
            node.cost = ExplainParser.number(object["estimated_total_cost"])
            node.condition = object["condition"] as? String
            if let rows = ExplainParser.number(object["actual_rows"]) { node.actualRows = rows; sawActuals = true }
            node.loops = ExplainParser.number(object["actual_loops"])
            if let time = ExplainParser.number(object["actual_last_row_ms"]) { node.actualTimeMilliseconds = time }
            classifyOperation(&node)
            if ExplainParser.flag(object["covering"]) { node.details.append("Covering index") }
            markMismatch(&node)
            guard depth < ExplainParser.maxDepth else { return node }
            for key in ["inputs", "subqueries"] {
                for item in (object[key] as? [Any] ?? []).prefix(1_000) {
                    guard let child = item as? [String: Any], !full else { continue }
                    node.children.append(treeNode(child, depth: depth + 1))
                }
            }
            return node
        }

        mutating func markMismatch(_ node: inout PlanNode) {
            guard let actual = node.actualRows, let estimate = node.estimatedRows, max(actual, estimate) >= 100 else { return }
            let ratio = (max(actual, estimate) + 1) / (min(actual, estimate) + 1)
            if ratio > 10 { node.warnings.insert(.estimateMismatch) }
        }
    }

    /// Warnings derived from an iterator description ("Table scan on orders", "Sort: …", "temporary").
    static func classifyOperation(_ node: inout PlanNode) {
        let title = node.title.lowercased()
        if title.hasPrefix("table scan on"), !title.contains("<") { node.warnings.insert(.fullTableScan) }
        if title.hasPrefix("index scan on") { node.warnings.insert(.fullIndexScan) }
        if title.hasPrefix("sort") { node.warnings.insert(.filesort) }
        if title.contains("temporary") { node.warnings.insert(.temporaryTable) }
        if title.contains("hash join") || title.contains("block nested loop") { node.warnings.insert(.joinBuffer) }
        if node.table == nil, let range = node.title.range(of: " on ", options: .caseInsensitive) {
            let name = node.title[range.upperBound...].split(separator: " ").first.map(String.init)
            if let name, !name.hasPrefix("<") { node.table = name }
        }
    }

    // MARK: Tree text (EXPLAIN ANALYZE / FORMAT=TREE)

    public static func parseTree(_ text: String) -> ExplainPlan {
        var builder = Builder()
        var root = builder.make("Query")
        // Stack of (indent, path of child indices from the root).
        var stack: [(indent: Int, path: [Int])] = []
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(maxNodes) {
            let line = String(rawLine)
            guard let arrow = line.range(of: "-> ") else { continue }
            let indent = line.distance(from: line.startIndex, to: arrow.lowerBound)
            var node = builder.make("")
            fill(&node, from: String(line[arrow.upperBound...]))
            if node.actualRows != nil { builder.sawActuals = true }
            builder.markMismatch(&node)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let parentPath = stack.last?.path ?? []
            guard parentPath.count < maxDepth else { continue }
            let index = append(node, to: &root, at: parentPath)
            stack.append((indent, parentPath + [index]))
        }
        if root.children.count == 1, let only = root.children.first { root = only }
        return ExplainPlan(root: root, format: .tree, totalCost: root.cost, isAnalyzed: builder.sawActuals)
    }

    private static func append(_ node: PlanNode, to root: inout PlanNode, at path: [Int]) -> Int {
        guard let first = path.first else {
            root.children.append(node)
            return root.children.count - 1
        }
        guard root.children.indices.contains(first) else {
            root.children.append(node)
            return root.children.count - 1
        }
        return append(node, to: &root.children[first], at: Array(path.dropFirst()))
    }

    /// `Filter: (o.amount > 100)  (cost=202 rows=667) (actual time=0.07..0.28 rows=2000 loops=1)`
    static func fill(_ node: inout PlanNode, from text: String) {
        var title = text
        if let paren = text.range(of: "  (") { title = String(text[..<paren.lowerBound]) }
        node.title = title.trimmingCharacters(in: .whitespaces)
        if let match = text.firstMatch(of: /\(cost=([0-9.e+]+)(?:\.\.([0-9.e+]+))? rows=([0-9.e+]+)\)/) {
            node.cost = Double(match.output.2.map(String.init) ?? String(match.output.1)).flatMap { $0.isFinite ? $0 : nil }
            node.estimatedRows = Double(String(match.output.3)).flatMap { $0.isFinite ? $0 : nil }
        }
        if let match = text.firstMatch(of: /\(actual time=([0-9.e+]+)\.\.([0-9.e+]+) rows=([0-9.e+]+) loops=([0-9.e+]+)\)/) {
            node.actualTimeMilliseconds = Double(String(match.output.2)).flatMap { $0.isFinite ? $0 : nil }
            node.actualRows = Double(String(match.output.3)).flatMap { $0.isFinite ? $0 : nil }
            node.loops = Double(String(match.output.4)).flatMap { $0.isFinite ? $0 : nil }
        } else if text.contains("(never executed)") {
            node.details.append("Never executed")
        }
        if title.hasPrefix("Filter: ") { node.condition = String(title.dropFirst(8)) }
        classifyOperation(&node)
    }
}
