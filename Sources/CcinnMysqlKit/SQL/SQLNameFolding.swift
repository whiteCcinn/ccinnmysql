import Foundation

/// How MySQL and MariaDB may read a name, for the deny and allow lists of read-only access, which must match a name the
/// way the server does. The servers fold names in ways the app cannot model exactly: `processlıst` (ı), `PROCESSLİST`
/// (İ) and `proceſſlist` (ſ) resolve to PROCESSLIST, MariaDB also folds `ınformation_schema`, `performance_ſchema` and
/// the Kelvin sign, and MySQL compares some names by collation weights, which fold accents (`@@sql_modé`).
public enum SQLNameFolding {
    /// A non-ASCII letter whose upper, lower or title case contains an ASCII letter: in current Unicode the 19 letters
    /// ß İ ı ŉ ſ ǰ ẖ ẗ ẘ ẙ ẚ K ﬀ ﬁ ﬂ ﬃ ﬄ ﬅ ﬆ. A name holding one cannot be compared with a deny list the way the server
    /// reads it, so read-only access refuses it.
    public static func caseMapsToASCII(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.isASCII, scalar.properties.changesWhenCaseMapped else { return false }
        let properties = scalar.properties
        return [properties.uppercaseMapping, properties.lowercaseMapping, properties.titlecaseMapping].contains { mapping in
            mapping.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        }
    }

    /// The first letter in `text` that case-maps to ASCII, `nil` when there is none.
    public static func firstLetterFoldingToASCII(in text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first(where: caseMapsToASCII)
    }

    /// Why read-only access refuses `name`, which holds `letter`.
    public static func refusal(name: String, letter: Unicode.Scalar) -> String {
        "`\(name)` contains \(letter) (\(String(format: "U+%04X", letter.value))), which MySQL and MariaDB may read as an ASCII letter "
            + "(ı as I, ſ as S, K as K), so the name cannot be checked the way the server reads it. Write names in plain letters."
    }

    /// The name's ASCII skeleton, lower-case: each character upper-cased, then lower-cased, then decomposed (NFKD), with
    /// combining marks dropped. `processlıst`, `PROCESSLİST` and `proceſſlist` become processlist, `LOAD_ﬁLE` load_file,
    /// `sql_modé` sql_mode, `ｍｙｓｑｌ` mysql. Deny lists compare skeletons, so a folded or accented spelling of a denied
    /// name matches it (the safe direction), while an ordinary name such as `café` matches nothing and stays usable.
    public static func skeleton(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                folded.append(asciiLowercased(scalar))
                continue
            }
            let mapped = scalar.properties.uppercaseMapping.lowercased().decomposedStringWithCompatibilityMapping
            for part in mapped.unicodeScalars where !isCombiningMark(part) { folded.append(part) }
        }
        return String(folded)
    }

    /// `skeleton(text)` with its ASCII letters upper-cased, for the upper-case keyword and function lists.
    public static func upperSkeleton(_ text: String) -> String {
        var upper = String.UnicodeScalarView()
        for scalar in skeleton(text).unicodeScalars {
            upper.append(("a"..."z").contains(scalar) ? Unicode.Scalar(UInt8(truncatingIfNeeded: scalar.value) - 32) : scalar)
        }
        return String(upper)
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(UInt8(truncatingIfNeeded: scalar.value) + 32) : scalar
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}
