import CcinnMysqlKit
import MySQLKit
import SwiftUI

/// Visual EXPLAIN (design D12): an indented tree of operations with access types, keys, row estimates
/// (and actual rows for ANALYZE), relative cost bars and warning chips; details of the selected node on the right.
struct PlanView: View {
    let plan: ExplainPlan
    @State private var selectedID: Int?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                summary
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows, id: \.node.id) { row in
                            PlanRow(node: row.node, depth: row.depth, maxRows: maxRows, maxCost: maxCost, analyzed: plan.isAnalyzed,
                                    selected: selectedID == row.node.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = row.node.id }
                        }
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 420)
            NodeDetail(node: rows.first { $0.node.id == selectedID }?.node ?? plan.root)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Text(formatName).font(.callout.weight(.semibold))
            if let cost = plan.totalCost { Badge(text: "cost \(Self.number(cost))", color: Theme.accent) }
            ForEach(plan.warnings.sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
                Badge(text: warning.title, color: Self.color(warning), systemImage: "exclamationmark.triangle")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var formatName: String {
        switch plan.format {
        case .mysqlJSON: plan.isAnalyzed ? "Plan (analyzed)" : "Plan · EXPLAIN FORMAT=JSON"
        case .mysqlJSONTree: "Plan · iterator tree"
        case .mariadbJSON: plan.isAnalyzed ? "Plan · ANALYZE FORMAT=JSON" : "Plan · EXPLAIN FORMAT=JSON"
        case .tree: plan.isAnalyzed ? "Plan · EXPLAIN ANALYZE" : "Plan · FORMAT=TREE"
        }
    }

    private var rows: [(node: PlanNode, depth: Int)] {
        var result: [(PlanNode, Int)] = []
        func walk(_ node: PlanNode, _ depth: Int) {
            guard result.count < 5_000 else { return }
            result.append((node, depth))
            for child in node.children { walk(child, depth + 1) }
        }
        walk(plan.root, 0)
        return result
    }

    private var maxRows: Double { max(1, plan.nodes.compactMap { $0.actualRows ?? $0.estimatedRows }.max() ?? 1) }
    private var maxCost: Double { max(1, plan.nodes.compactMap(\.cost).max() ?? 1) }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", value / 1_000) }
        return value.rounded() == value ? String(Int64(clamping: Int64(value.rounded()))) : String(format: "%.2f", value)
    }

    static func color(_ warning: PlanWarning) -> Color {
        switch warning {
        case .fullTableScan, .dependentSubquery, .estimateMismatch: .red
        case .filesort, .temporaryTable, .joinBuffer, .noUsableIndex: .orange
        case .fullIndexScan: .yellow
        }
    }
}

private struct PlanRow: View {
    let node: PlanNode
    let depth: Int
    let maxRows: Double
    let maxCost: Double
    let analyzed: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(min(depth, 30)) * 16, height: 1)
            Image(systemName: icon).foregroundStyle(iconColor).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(node.title).font(.callout.weight(node.table != nil ? .semibold : .regular)).lineLimit(2)
                    if let key = node.key { Badge(text: key, color: .teal, systemImage: "key") }
                    ForEach(node.warnings.sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PlanView.color(warning)).help(warning.title)
                    }
                }
                HStack(spacing: 10) {
                    if let rows = node.estimatedRows { metric("est. rows", PlanView.number(rows)) }
                    if let rows = node.actualRows { metric("actual rows", PlanView.number(rows)) }
                    if let loops = node.loops, loops > 1 { metric("loops", PlanView.number(loops)) }
                    if let time = node.actualTimeMilliseconds { metric("time", Format.duration(milliseconds: time)) }
                    if let cost = node.cost { metric("cost", PlanView.number(cost)) }
                }
            }
            Spacer(minLength: 8)
            if let rows = node.actualRows ?? node.estimatedRows {
                ProgressView(value: min(1, log10(rows + 1) / log10(maxRows + 1)))
                    .tint(node.warnings.contains(.fullTableScan) ? .red : Theme.accent)
                    .frame(width: 80)
                    .help("Rows, relative to the largest step (log scale)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selected ? Theme.accent.opacity(0.12) : node.warnings.contains(.fullTableScan) ? Color.red.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var icon: String {
        if node.table != nil { return node.warnings.contains(.fullTableScan) ? "tablecells.badge.ellipsis" : "tablecells" }
        let title = node.title.lowercased()
        if title.contains("join") || title.contains("nested loop") { return "arrow.triangle.merge" }
        if title.contains("sort") || title.hasPrefix("order") { return "arrow.up.arrow.down" }
        if title.contains("group") || title.contains("aggregate") { return "square.stack.3d.up" }
        if title.contains("union") { return "rectangle.on.rectangle" }
        if title.contains("filter") { return "line.3.horizontal.decrease" }
        if title.contains("subquer") || title.contains("materialize") { return "square.dashed.inset.filled" }
        return "circle.grid.cross"
    }

    private var iconColor: Color {
        if node.warnings.contains(.fullTableScan) { return .red }
        if !node.warnings.isEmpty { return .orange }
        return node.table != nil ? Color(nsColor: .kindTable) : .secondary
    }
}

private struct NodeDetail: View {
    let node: PlanNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(node.title).font(.headline).textSelection(.enabled)
                KeyValueList(items: items, monospacedValues: true)
                if !node.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(node.warnings.sorted { $0.rawValue < $1.rawValue }, id: \.self) { warning in
                            Label(warning.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(PlanView.color(warning)).font(.callout)
                        }
                    }
                }
                if let condition = node.condition {
                    Text("Condition").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(condition).font(Theme.monospacedSmall).textSelection(.enabled)
                }
                ForEach(node.details, id: \.self) { detail in
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var items: [(String, String)] {
        var items: [(String, String)] = []
        if let table = node.table { items.append(("Table", table)) }
        if let access = node.accessType { items.append(("Access", access)) }
        if let key = node.key { items.append(("Key", key)) }
        if !node.usedKeyParts.isEmpty { items.append(("Key parts", node.usedKeyParts.joined(separator: ", "))) }
        if !node.possibleKeys.isEmpty { items.append(("Possible keys", node.possibleKeys.joined(separator: ", "))) }
        if let rows = node.estimatedRows { items.append(("Estimated rows", PlanView.number(rows))) }
        if let rows = node.producedRows { items.append(("Rows produced", PlanView.number(rows))) }
        if let filtered = node.filtered { items.append(("Filtered", String(format: "%.1f%%", filtered))) }
        if let rows = node.actualRows { items.append(("Actual rows", PlanView.number(rows))) }
        if let loops = node.loops { items.append(("Loops", PlanView.number(loops))) }
        if let time = node.actualTimeMilliseconds { items.append(("Time", Format.duration(milliseconds: time))) }
        if let cost = node.cost { items.append(("Cost", PlanView.number(cost))) }
        return items
    }
}
