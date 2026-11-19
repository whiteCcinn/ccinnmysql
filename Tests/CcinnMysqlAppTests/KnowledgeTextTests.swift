import Testing
@testable import CcinnMysql

@Suite("Knowledge texts")
struct KnowledgeTextTests {
    // The 1.5.0 header read "1 views".
    @Test func headerCountsUseTheSingularForOne() {
        #expect(KnowledgeModel.summaryCounts(tables: 11, views: 1, relationships: 12, declared: 2, notes: 1)
            == "11 tables · 1 view · 12 relationships (2 declared) · 1 note")
        #expect(KnowledgeModel.summaryCounts(tables: 1, views: 0, relationships: 1, declared: 1, notes: 0)
            == "1 table · 0 views · 1 relationship (1 declared) · 0 notes")
    }

    @Test func countedTextsUseTheSingularForOne() {
        #expect(Format.counted(1, "file") == "1 file")
        #expect(Format.counted(2, "file") == "2 files")
        #expect(Format.counted(1, "knowledge base") == "1 knowledge base")
    }
}
