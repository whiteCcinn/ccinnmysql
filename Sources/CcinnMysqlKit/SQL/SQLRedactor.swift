import Foundation

/// Removes credentials from SQL before it is written to history or audit logs, or shown from `SHOW GRANTS`:
/// string literals after `IDENTIFIED [WITH plugin] BY`, `IDENTIFIED WITH plugin AS`, `IDENTIFIED VIA plugin USING`,
/// `…PASSWORD` / `…PASSWORD =` / `PASSWORD(` (also `MASTER_PASSWORD`, `SOURCE_PASSWORD`), and values of
/// credential-like options (`'password' = '…'`) become `'***'`.
public enum SQLRedactor {
    static let sensitiveKeyFragments = ["password", "passwd", "secret", "access_key", "accesskey", "token", "credential",
                                        "private_key", "privatekey", "auth"]

    public static func redact(_ sql: String) -> String {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var redactions: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where token.kind == .string {
            if isSecretLiteral(at: index, tokens: tokens, lexer: lexer) { redactions.append(token.range) }
        }
        guard !redactions.isEmpty else { return sql }
        var units = lexer.units
        for range in redactions.reversed() {
            let quote = units[range.lowerBound]
            let replacement: [UInt16] = quote == 0x27 || quote == 0x22 ? [quote] + Array("***".utf16) + [quote] : Array("'***'".utf16)
            units.replaceSubrange(range, with: replacement)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Removes the statement's secret literals from a server message that echoes the statement
    /// (e.g. `… near 'USR bob IDENTIFIED BY 'Hunter2'' at line 1`).
    public static func redact(message: String, statement: String) -> String {
        let lexer = SQLLexer(statement)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var message = message
        for (index, token) in tokens.enumerated() where token.kind == .string && isSecretLiteral(at: index, tokens: tokens, lexer: lexer) {
            let literal = lexer.text(of: token)
            guard literal.count >= 2 else { continue }
            let inner = String(literal.dropFirst().dropLast())
            guard !inner.isEmpty else { continue }
            message = message.replacingOccurrences(of: literal, with: "'***'")
            message = message.replacingOccurrences(of: "'\(inner)'", with: "'***'")
            if inner.count >= 4 { message = message.replacingOccurrences(of: inner, with: "***") }
        }
        return message
    }

    static func isSecretLiteral(at index: Int, tokens: [SQLToken], lexer: SQLLexer) -> Bool {
        func word(_ offset: Int) -> String {
            let position = index + offset
            guard tokens.indices.contains(position) else { return "" }
            return lexer.text(of: tokens[position]).uppercased()
        }
        func isPasswordWord(_ text: String) -> Bool { text == "PASSWORD" || text.hasSuffix("_PASSWORD") }
        // IDENTIFIED BY '…' / IDENTIFIED BY PASSWORD '…' / IDENTIFIED WITH plugin BY '…' / … AS '…' / IDENTIFIED VIA plugin USING '…'
        if word(-1) == "BY", word(-2) == "IDENTIFIED" || word(-4) == "IDENTIFIED" { return true }
        if word(-1) == "PASSWORD", word(-2) == "BY" { return true }
        if word(-1) == "AS", word(-3) == "WITH", word(-4) == "IDENTIFIED" { return true }
        if word(-1) == "USING", word(-3) == "VIA" || word(-3) == "WITH" { return true }
        // … IDENTIFIED BY 'new' REPLACE 'current'  /  SET PASSWORD = 'new' REPLACE 'current'
        if word(-1) == "REPLACE", index >= 2, tokens[index - 2].kind == .string { return true }
        // PASSWORD '…', SOURCE_PASSWORD = '…', PASSWORD('…'), SET PASSWORD FOR u = '…', OLD_PASSWORD('…')
        if isPasswordWord(word(-1)) || (word(-1) == "(" && (isPasswordWord(word(-2)) || word(-2) == "OLD_PASSWORD")) { return true }
        if word(-1) == "=", isPasswordWord(word(-2)) { return true }
        if word(-1) == "=", tokens.indices.contains(index - 2) {
            // SET PASSWORD FOR 'u'@'h' = '…'
            var position = index - 2
            var steps = 0
            while position >= 0, steps < 8 {
                if lexer.text(of: tokens[position]).uppercased() == "PASSWORD" { return true }
                position -= 1
                steps += 1
            }
        }
        // 'key' = 'value' with a credential-like key (CREATE SERVER OPTIONS, plugin options)
        if word(-1) == "=", index >= 2, tokens[index - 2].kind == .string || tokens[index - 2].kind == .identifier {
            let key = lexer.text(of: tokens[index - 2]).lowercased()
            return sensitiveKeyFragments.contains { key.contains($0) }
        }
        return false
    }

    // MARK: Other sessions' statements

    /// Every literal of another session's statement replaced with `?`, digest style: strings, numbers, hexadecimal and
    /// bit literals, and comments (which can hold anything). The statement was lexed by the server in that session's
    /// mode, unknown here, so every reading counts: whatever is a literal or comment under any combination of
    /// NO_BACKSLASH_ESCAPES and ANSI_QUOTES is replaced (`'C:\' , 'secret'` hides `secret` in both).
    /// A server message with everything from its first quote character (' " `) to its last replaced by `?` (to its end when
    /// there is only one). Messages such as the replication applier's last error quote another session's statement and
    /// values without escaping the quotes inside (`Error 'Duplicate entry 'x' …' … Query: 'INSERT … ('x')'`), so no lexer can
    /// tell where a value ends; the words around the quotes stay.
    public static func redactQuoted(_ text: String) -> String {
        let quotes: Set<Character> = ["'", "\"", "`"]
        guard let first = text.firstIndex(where: quotes.contains), let last = text.lastIndex(where: quotes.contains) else { return text }
        let rest = last > first ? String(text[text.index(after: last)...]) : ""
        return String(text[..<first]) + "?" + rest
    }

    public static func redactLiterals(_ sql: String) -> String {
        let units = Array(sql.utf16)
        var hidden = [Bool](repeating: false, count: units.count)
        for mode in SQLLexingMode.all {
            for token in SQLLexer(sql, mode: mode).tokens() where [.string, .number, .comment, .executableComment].contains(token.kind) {
                for index in token.range where index < hidden.count { hidden[index] = true }
            }
        }
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            if hidden[index] {
                output.append(0x3F) // ?
                while index < units.count, hidden[index] { index += 1 }
            } else {
                output.append(units[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// Lines of the deadlock section that describe structure only (transactions, lock structures, tables, indexes).
    static let innoDBStructurePrefixes = ["***", "TRANSACTION", "mysql tables in use", "LOCK WAIT", "RECORD LOCKS", "TABLE LOCK",
                                          "Record lock, heap no", "ROLLING BACK", "------", "LATEST DETECTED DEADLOCK"]

    /// The LATEST DETECTED DEADLOCK section of `SHOW ENGINE INNODB STATUS`, allow-list style: each statement (the lines
    /// after `MySQL thread id …` up to the next `***` line) with every literal replaced, structure lines as they are,
    /// and nothing else: the row dumps (`0: len 7; hex …; asc hunter2;;`, also when a value spans lines) hold the locked
    /// rows' values.
    public static func redactInnoDBStatus(_ text: String) -> String {
        var output: [String] = []
        var statement: [Substring]?
        func flushStatement() {
            if let lines = statement, !lines.isEmpty { output.append(redactLiterals(lines.joined(separator: "\n"))) }
            statement = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("***") { flushStatement() }
            if statement != nil {
                statement?.append(line)
            } else if line.hasPrefix("MySQL thread id") || line.hasPrefix("MariaDB thread id") {
                output.append(String(line))
                statement = []
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty || innoDBStructurePrefixes.contains(where: { line.hasPrefix($0) })
                        || line.first?.isNumber == true && line.dropFirst(4).hasPrefix("-") { // the timestamp line
                output.append(String(line))
            }
        }
        flushStatement()
        return output.joined(separator: "\n")
    }
}
