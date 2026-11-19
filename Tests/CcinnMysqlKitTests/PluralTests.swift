import Testing
@testable import CcinnMysqlKit

@Suite("Plural")
struct PluralTests {
    @Test func exactlyOneIsSingular() {
        #expect(Plural.phrase(0, "table") == "0 tables")
        #expect(Plural.phrase(1, "table") == "1 table")
        #expect(Plural.phrase(2, "view") == "2 views")
        #expect(Plural.phrase(1_000, "row") == "1000 rows")
        #expect(Plural.noun(-1, "degree") == "degrees")
    }

    @Test func irregularPluralsAreGiven() {
        #expect(Plural.noun(1, "entry", plural: "entries") == "entry")
        #expect(Plural.phrase(3, "entry", plural: "entries") == "3 entries")
    }
}
