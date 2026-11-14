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
}
