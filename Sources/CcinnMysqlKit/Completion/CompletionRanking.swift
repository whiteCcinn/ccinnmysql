import Foundation
import MySQLKit

/// Every candidate for one cursor position, with labels lower-cased once, so each key typed re-ranks them cheaply.
/// Immutable; shared between a result and the results narrowed from it.
final class CompletionPool: Sendable {
    let items: [CompletionItem]
    /// `items[i].label`, lower-cased, as UTF-8.
    let keys: [[UInt8]]

    static let empty = CompletionPool([])

    /// Keeps the first of items with the same kind, label and detail.
    init(_ candidates: [CompletionItem]) {
        var seen = Set<Identity>()
        seen.reserveCapacity(candidates.count)
        var items: [CompletionItem] = []
        items.reserveCapacity(candidates.count)
        for item in candidates where seen.insert(Identity(kind: item.kind, label: item.label, detail: item.detail)).inserted {
            items.append(item)
        }
        self.items = items
        keys = items.map { Array($0.label.lowercased().utf8) }
    }

    private struct Identity: Hashable {
        let kind: CompletionItem.Kind
        let label: String
        let detail: String?
    }
}

/// Matching and ordering of completion candidates against the typed prefix.
enum CompletionRanking {
    /// How well `label` matches `needle` (both lower-cased UTF-8), best first; 0 is no match:
    /// 6 the whole label, 5 a prefix, 4 a later word's prefix (`crm` → `dw_crm_hour`), 3 the words' initials
    /// (`gc` → `group_concat`), 2 a substring of three letters or more, 1 the letters in order from a word start
    /// (`ordit` → `order_items`). An empty needle matches everything equally.
    static func score(_ label: [UInt8], _ needle: [UInt8]) -> Int {
        guard let first = needle.first else { return 1 }
        guard needle.count <= label.count else { return 0 }
        if label == needle { return 6 }
        if label.starts(with: needle) { return 5 }
        var wordPrefix = false
        var initials = 0
        var initialsInOrder = true
        var anchor: Int?
        for index in label.indices {
            let isWordStart = index == 0 || (isSeparator(label[index - 1]) && !isSeparator(label[index]))
            guard isWordStart else { continue }
            if index > 0, !wordPrefix, hasPrefix(label, needle, at: index) { wordPrefix = true }
            if initialsInOrder, initials < needle.count {
                if label[index] == needle[initials] { initials += 1 } else { initialsInOrder = false }
            }
            if anchor == nil, label[index] == first { anchor = index }
        }
        if wordPrefix { return 4 }
        if initials == needle.count { return 3 }
        if needle.count >= 3, contains(label, needle) { return 2 }
        if needle.count >= 2, let anchor, isSubsequence(needle.dropFirst(), of: label, from: anchor + 1) { return 1 }
        return 0
    }

    /// The `limit` best candidates for `prefix`: by match, then kind (columns first), then (once something is typed)
    /// shorter labels, then natural order (`t2` before `t10`). Back-quoted when the name being completed is.
    static func rank(_ pool: CompletionPool, prefix: String, limit: Int, quoted: Bool) -> [CompletionItem] {
        let needle = Array(prefix.lowercased().utf8)
        let keys = pool.keys
        let items = pool.items
        let matches = keys.indices.lazy.compactMap { index -> Match? in
            let score = score(keys[index], needle)
            return score > 0 ? Match(index: index, score: score) : nil
        }
        let shorterFirst = !needle.isEmpty
        let best = TopK.select(matches, count: max(0, limit)) { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsKind = items[lhs.index].kind.rawValue
            let rhsKind = items[rhs.index].kind.rawValue
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            let lhsKey = keys[lhs.index]
            let rhsKey = keys[rhs.index]
            if shorterFirst, lhsKey.count != rhsKey.count { return lhsKey.count < rhsKey.count }
            let order = naturalCompare(lhsKey, rhsKey)
            if order != 0 { return order < 0 }
            return lhs.index < rhs.index
        }
        return best.map { quoted ? backQuoted(items[$0.index]) : items[$0.index] }
    }

    private struct Match {
        let index: Int
        let score: Int
    }

    /// Names go back-quoted into a back-quoted name; keywords and functions never stand inside back-quotes.
    static func backQuoted(_ item: CompletionItem) -> CompletionItem {
        switch item.kind {
        case .keyword, .function: item
        case .column, .alias, .table, .view, .routine, .database:
            CompletionItem(kind: item.kind, label: item.label, insertText: SQLText.quoteIdentifier(item.label), detail: item.detail)
        }
    }

    /// -1, 0 or 1. Runs of digits compare by value (`t2` < `t10`); everything else by UTF-8 unit.
    static func naturalCompare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        var left = 0
        var right = 0
        while left < lhs.count, right < rhs.count {
            if isDigit(lhs[left]), isDigit(rhs[right]) {
                let leftRun = digitRun(lhs, from: left)
                let rightRun = digitRun(rhs, from: right)
                let leftLength = leftRun.end - leftRun.significant
                let rightLength = rightRun.end - rightRun.significant
                if leftLength != rightLength { return leftLength < rightLength ? -1 : 1 }
                for offset in 0..<leftLength where lhs[leftRun.significant + offset] != rhs[rightRun.significant + offset] {
                    return lhs[leftRun.significant + offset] < rhs[rightRun.significant + offset] ? -1 : 1
                }
                left = leftRun.end
                right = rightRun.end
                continue
            }
            if lhs[left] != rhs[right] { return lhs[left] < rhs[right] ? -1 : 1 }
            left += 1
            right += 1
        }
        let leftRest = lhs.count - left
        let rightRest = rhs.count - right
        return leftRest == rightRest ? 0 : (leftRest < rightRest ? -1 : 1)
    }

    /// The digits starting at `start`: where they end, and where they start once leading zeros (but the last) are skipped.
    private static func digitRun(_ units: [UInt8], from start: Int) -> (significant: Int, end: Int) {
        var end = start
        while end < units.count, isDigit(units[end]) { end += 1 }
        var significant = start
        while significant < end - 1, units[significant] == 0x30 { significant += 1 }
        return (significant, end)
    }

    private static func isDigit(_ unit: UInt8) -> Bool { unit >= 0x30 && unit <= 0x39 }

    /// `_`, space, `.` and `-` separate words.
    private static func isSeparator(_ unit: UInt8) -> Bool { unit == 0x5F || unit == 0x20 || unit == 0x2E || unit == 0x2D }

    private static func hasPrefix(_ label: [UInt8], _ needle: [UInt8], at start: Int) -> Bool {
        guard label.count - start >= needle.count else { return false }
        for offset in needle.indices where label[start + offset] != needle[offset] { return false }
        return true
    }

    private static func contains(_ label: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= label.count else { return false }
        for start in 0...(label.count - needle.count) where hasPrefix(label, needle, at: start) { return true }
        return false
    }

    private static func isSubsequence(_ needle: ArraySlice<UInt8>, of label: [UInt8], from start: Int) -> Bool {
        var remaining = needle.startIndex
        var index = start
        while remaining < needle.endIndex, index < label.count {
            if label[index] == needle[remaining] { remaining += 1 }
            index += 1
        }
        return remaining == needle.endIndex
    }
}
