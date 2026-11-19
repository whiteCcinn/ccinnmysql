/// English counts for UI and export texts: "1 table", "0 tables", "12 views".
public enum Plural {
    /// `singular` for exactly one, `plural` otherwise (by default `singular` + "s").
    public static func noun(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        count == 1 ? singular : plural ?? singular + "s"
    }

    /// The count in plain digits and its noun.
    public static func phrase(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(noun(count, singular, plural: plural))"
    }
}
