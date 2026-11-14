import Foundation

/// Maps MySQL/MariaDB syntax errors (`… near 'FORM t' at line 2`) to a UTF-16 offset inside the statement.
public enum SQLErrorLocator {
    public static func offset(in statement: String, message: String) -> Int? {
        guard let lineMatch = message.firstMatch(of: /' at line (\d+)\s*$/), let line = Int(lineMatch.output.1.prefix(9)), line >= 1,
              let nearRange = message.range(of: "near '") else { return nil }
        let snippetEnd = lineMatch.range.lowerBound
        guard nearRange.upperBound <= snippetEnd else { return nil }
        let snippet = String(message[nearRange.upperBound..<snippetEnd])
        let units = Array(statement.utf16)
        // Start of the reported (1-based) line.
        var currentLine = 1
        var lineStart = 0
        var index = 0
        while currentLine < line, index < units.count {
            if units[index] == 0x0A {
                currentLine += 1
                lineStart = index + 1
            }
            index += 1
        }
        guard currentLine == line else { return nil }
        // An empty snippet means the statement ended unexpectedly.
        let needle = Array(snippet.utf16.prefix(40))
        guard !needle.isEmpty else { return units.count }
        if let found = firstIndex(of: needle, in: units, from: lineStart) { return found }
        return lineStart
    }

    static func firstIndex(of needle: [UInt16], in haystack: [UInt16], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }
}
