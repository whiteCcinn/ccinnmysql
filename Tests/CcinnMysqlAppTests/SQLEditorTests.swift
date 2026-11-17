import AppKit
import CcinnMysqlKit
import SwiftUI
import Testing
@testable import CcinnMysql

/// An editor wired like `SQLWorkbenchView` wires it, with the binding and the model's diagnostics held
/// here, so tests can play the model's part (including lagging behind the text view).
@MainActor
private final class EditorHarness {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var diagnostics: [SQLDiagnostic] = []
    var reportedEdits: [SQLTextEdit] = []
    let textView: SQLTextView
    let coordinator: SQLEditor.Coordinator
    private let window: NSWindow

    init(_ text: String, diagnostics: [SQLDiagnostic] = []) {
        self.text = text
        self.diagnostics = diagnostics
        textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        coordinator = SQLEditor.Coordinator(SQLEditor(text: .constant(text), selection: .constant(selection)))
        coordinator.parent = editor
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.diagnostics = diagnostics
        window.contentView = textView
        window.makeFirstResponder(textView)
    }

    var editor: SQLEditor {
        SQLEditor(text: Binding(get: { self.text }, set: { self.text = $0 }),
                  selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
                  diagnostics: diagnostics,
                  onEdit: { self.reportedEdits += $0 })
    }

    /// What SwiftUI does on every re-render of the workbench.
    func render() { coordinator.update(from: editor) }

    func type(_ string: String, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        selection = textView.selectedRange()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}

@Suite("SQL editor", .serialized)
@MainActor
struct SQLEditorTests {
    @Test func formattingIsOneUndoableEditThatEditTrackingSees() throws {
        let original = "select a, b from t"
        let harness = EditorHarness(original)
        let undo = try #require(harness.textView.undoManager)
        undo.groupsByEvent = false
        let formatted = try #require(SQLFormatter.format(original))
        let length = (original as NSString).length
        undo.beginUndoGrouping()
        #expect(harness.textView.replace(NSRange(location: 0, length: length), of: original, with: formatted, actionName: "Format SQL",
                                         selecting: NSRange(location: 3, length: 0)) == .replaced)
        undo.endUndoGrouping()
        #expect(harness.textView.string == formatted)
        #expect(harness.text == formatted, "the binding is updated like typing")
        #expect(!harness.reportedEdits.isEmpty, "edit tracking sees the replacement")
        #expect(harness.textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(undo.undoActionName == "Format SQL")
        undo.undo()
        #expect(harness.textView.string == original, "one ⌘Z restores the original")
        // Out-of-date ranges are refused instead of trapping, NSNotFound included.
        #expect(harness.textView.replace(NSRange(location: 0, length: 10_000), of: original, with: "x", actionName: "Format SQL",
                                         selecting: NSRange(location: 0, length: 0)) == .textChanged)
        #expect(harness.textView.replace(NSRange(location: NSNotFound, length: 1), of: original, with: "x", actionName: "Format SQL",
                                         selecting: NSRange(location: 0, length: 0)) == .textChanged)
    }

    // Review (2): a format result is never applied while an input method composes (the composition would be committed or
    // destroyed), nor to a text other than the one it was computed from.
    @Test func formattingNeverInterruptsAComposition() throws {
        let original = "select a, b from t"
        let harness = EditorHarness(original)
        let formatted = try #require(SQLFormatter.format(original))
        harness.textView.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.hasMarkedText())
        let controller = SQLEditorController()
        controller.textView = harness.textView
        #expect(controller.snapshot?.isComposing == true)
        let live = try #require(controller.snapshot?.text)
        #expect(controller.replace(NSRange(location: 0, length: (live as NSString).length), of: live, with: formatted, actionName: "Format SQL",
                                   selecting: NSRange(location: 0, length: 0)) == .composing)
        #expect(harness.textView.hasMarkedText(), "the composition goes on")
        #expect(harness.textView.string == original + " ni")
    }

    // Review (2): the live text is compared unit by unit. `é` and `e` + U+0301 are equal for Swift's `==` but their
    // offsets differ, so an edit computed for one must not be applied to the other.
    @Test func formattingAppliesOnlyToTheTextItWasComputedFrom() throws {
        let decomposed = "select 'e\u{301}' from t"
        let precomposed = "select '\u{E9}' from t"
        #expect(decomposed == precomposed, "canonically equivalent")
        let harness = EditorHarness(decomposed)
        let controller = SQLEditorController()
        #expect(controller.replace(NSRange(location: 0, length: 1), of: decomposed, with: "S", actionName: "Format SQL",
                                   selecting: NSRange(location: 0, length: 0)) == .noEditor)
        controller.textView = harness.textView
        let formatted = try #require(SQLFormatter.format(precomposed))
        #expect(controller.replace(NSRange(location: 0, length: (precomposed as NSString).length), of: precomposed, with: formatted,
                                   actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)) == .textChanged)
        #expect(harness.textView.string == decomposed)
        #expect(controller.replace(NSRange(location: 0, length: 6), of: decomposed, with: "SELECT", actionName: "Format SQL",
                                   selecting: NSRange(location: 0, length: 0)) == .replaced)
        #expect(harness.textView.string.hasPrefix("SELECT 'e\u{301}'"))
    }

    // Formatting moves a server marker on a later statement instead of dropping it, like any edit before it.
    @Test func formattingAStatementKeepsMarkersOfOthersOnTheirText() throws {
        let text = "select a,b from t;\nSELECT 1 FORM shop.orders"
        let marked = (text as NSString).range(of: "shop")
        let scope = (text as NSString).range(of: "SELECT 1 FORM shop.orders")
        let failure = SQLDiagnostic(range: marked.location..<NSMaxRange(marked), scope: scope.location..<NSMaxRange(scope),
                                    severity: .error, source: .server, message: "Syntax error near 'shop'")
        let harness = EditorHarness(text, diagnostics: [failure])
        let first = (text as NSString).range(of: "select a,b from t")
        let edit = try #require(SQLFormatter.formatSelection(in: text, range: first))
        #expect(edit.range == first)
        #expect(harness.textView.replace(edit.range, of: text, with: edit.replacement, actionName: "Format SQL", selecting: first) == .replaced)
        let moved = try #require(harness.coordinator.diagnostics.first)
        #expect((harness.textView.string as NSString).substring(with: NSRange(location: moved.range.lowerBound, length: moved.range.count)) == "shop")
    }

    // MARK: Format SQL feedback

    private func formatting(_ harness: EditorHarness?) -> SQLFormatting {
        let controller = SQLEditorController()
        controller.textView = harness?.textView
        return SQLFormatting(editor: controller)
    }

    private func detached(_ text: String, store: @escaping @MainActor (String, String, NSRange) -> Bool = { _, _, _ in true }) -> SQLFormatting.Detached {
        SQLFormatting.Detached(text: text, selection: NSRange(location: 0, length: 0), store: store)
    }

    // Final review: a format that changes nothing says why in the status bar instead of returning silently.
    @Test func aFormattedTextLeavesNoNotice() async throws {
        let harness = EditorHarness("select a, b from t")
        let formatting = formatting(harness)
        let task = try #require(formatting.start(options: SQLFormatOptions(), detached: detached("")))
        #expect(formatting.isRunning)
        await task.value
        #expect(!formatting.isRunning)
        #expect(harness.textView.string == "SELECT\n  a,\n  b\nFROM t")
        #expect(formatting.notice == nil)
    }

    @Test func aTextThatCannotBeProvenSaysSo() async throws {
        let harness = EditorHarness("select case when a then 1.end")
        let formatting = formatting(harness)
        await formatting.start(options: SQLFormatOptions(), detached: detached(""))?.value
        #expect(harness.textView.string == "select case when a then 1.end")
        #expect(formatting.notice == .unsafe)
        #expect(formatting.notice?.message.isEmpty == false)
    }

    @Test func composingSaysSoBeforeAndAfterFormatting() async throws {
        let harness = EditorHarness("select a, b from t")
        let formatting = formatting(harness)
        harness.textView.setSelectedRange(NSRange(location: 18, length: 0))
        harness.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(formatting.start(options: SQLFormatOptions(), detached: detached("")) == nil, "nothing starts while composing")
        #expect(formatting.notice == .composing)
        harness.textView.unmarkText()
        let task = try #require(formatting.start(options: SQLFormatOptions(), detached: detached("")))
        #expect(formatting.notice == nil, "a new format clears the notice")
        // An input method starts composing while the format runs: the result waits for nobody, it is dropped.
        harness.textView.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await task.value
        #expect(harness.textView.hasMarkedText())
        #expect(formatting.notice == .composing)
    }

    @Test func aTextChangedWhileFormattingSaysSo() async throws {
        // Reported edit (the model calls textDidChange): the running format is cancelled.
        let reported = EditorHarness("select a, b from t")
        let first = formatting(reported)
        let task = try #require(first.start(options: SQLFormatOptions(), detached: detached("")))
        reported.type("x", at: 0)
        first.textDidChange()
        await task.value
        #expect(reported.textView.string == "xselect a, b from t")
        #expect(first.notice == .textChanged)
        #expect(!first.isRunning)
        // An edit not reported yet: the editor refuses the stale result.
        let unreported = EditorHarness("select a, b from t")
        let second = formatting(unreported)
        let pending = try #require(second.start(options: SQLFormatOptions(), detached: detached("")))
        unreported.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "y")
        await pending.value
        #expect(unreported.textView.string == "yselect a, b from t")
        #expect(second.notice == .textChanged)
        // Closing the tab cancels without a notice.
        let closing = formatting(EditorHarness("select a, b from t"))
        let cancelled = try #require(closing.start(options: SQLFormatOptions(), detached: detached("")))
        closing.cancel()
        await cancelled.value
        #expect(closing.notice == nil)
    }

    @Test func withoutAnEditorTheTextIsStoredIfUnchanged() async throws {
        var stored: (source: String, result: String)?
        let formatting = formatting(nil)
        await formatting.start(options: SQLFormatOptions(), detached: detached("select a from t") { source, result, _ in
            stored = (source, result)
            return true
        })?.value
        #expect(stored?.source == "select a from t")
        #expect(stored?.result == "SELECT a\nFROM t")
        #expect(formatting.notice == nil)
        await formatting.start(options: SQLFormatOptions(), detached: detached("select a from t") { _, _, _ in false })?.value
        #expect(formatting.notice == .textChanged)
    }

    @Test func aNoticeGoesAwayOnItsOwn() async throws {
        let harness = EditorHarness("select 1.end")
        let formatting = formatting(harness)
        formatting.noticeDuration = .milliseconds(50)
        await formatting.start(options: SQLFormatOptions(), detached: detached(""))?.value
        #expect(formatting.notice == .unsafe)
        for _ in 0..<100 where formatting.notice != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(formatting.notice == nil)
    }

    // Review #5b: before the session's sql_mode is known, text that some mode reads differently is refused with its own
    // notice; other text formats.
    @Test func anUnknownSessionModeSaysSo() async throws {
        let harness = EditorHarness("select 'C:\\' as d, 1")
        let formatting = formatting(harness)
        await formatting.start(options: SQLFormatOptions(sessionModeKnown: false), detached: detached(""))?.value
        #expect(harness.textView.string == "select 'C:\\' as d, 1")
        #expect(formatting.notice == .modeUnknown)
        let plain = EditorHarness("select a, b from t")
        let other = self.formatting(plain)
        await other.start(options: SQLFormatOptions(sessionModeKnown: false), detached: detached(""))?.value
        #expect(plain.textView.string == "SELECT\n  a,\n  b\nFROM t")
        #expect(other.notice == nil)
    }

    // Review #4/#5: Run, Run All and EXPLAIN split the script as the session does. Under NO_BACKSLASH_ESCAPES `'C:\'` ends
    // at its second quote; under ANSI_QUOTES `"a\"` is a name.
    @Test func runPathsSplitAsTheSessionDoes() {
        let script = "SELECT 'C:\\' AS d;\nSELECT 2;\nSELECT \"a\\\";\nSELECT 3"
        let noEscapes = SQLLexingMode(backslashEscapes: false)
        let ansi = SQLLexingMode(ansiQuotes: true)
        let none = NSRange(location: 0, length: 0)
        #expect(SQLTabModel.statementsToRun(in: script, selection: none, all: true, mode: noEscapes).map(\.sql)
            == ["SELECT 'C:\\' AS d", "SELECT 2", "SELECT \"a\\\"", "SELECT 3"])
        #expect(SQLTabModel.statementsToRun(in: script, selection: none, all: true, mode: .standard).count == 1)
        #expect(SQLTabModel.statementsToRun(in: "SELECT \"a\\\"; SELECT 3", selection: none, all: true, mode: ansi).map(\.sql)
            == ["SELECT \"a\\\"", "SELECT 3"])
        let second = (script as NSString).range(of: "SELECT 2")
        let atCursor = SQLTabModel.statementsToRun(in: script, selection: NSRange(location: second.location + 2, length: 0), all: false, mode: noEscapes)
        #expect(atCursor == [SQLTabModel.PlannedStatement(sql: "SELECT 2", editorOffset: second.location)])
        let selected = SQLTabModel.statementsToRun(in: script, selection: NSRange(location: 0, length: second.upperBound), all: false, mode: noEscapes)
        #expect(selected.map(\.sql) == ["SELECT 'C:\\' AS d", "SELECT 2"])
        let explained = SQLTabModel.statementToExplain(in: script, selection: NSRange(location: second.location, length: 0), mode: noEscapes)
        #expect(explained?.sql == "SELECT 2" && explained?.editorOffset == second.location)
        // An out-of-range selection is not a selection (and never traps): the statement at the cursor is used.
        #expect(SQLTabModel.statementsToRun(in: script, selection: NSRange(location: NSNotFound, length: 3), all: false, mode: noEscapes).count == 1)
    }

    // Review #2: a re-render while an input method composes must not overwrite the marked text.
    @Test func compositionSurvivesARenderWithLaggingText() {
        let harness = EditorHarness("SELECT 1")
        harness.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.hasMarkedText())
        // The 300 ms lint lands while composing: the model's text is behind the storage.
        harness.diagnostics = SQLLinter.diagnose("SELECT (")
        harness.render()
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "SELECT 1 ni")
        // Committing reports every edit, in order, and the binding catches up.
        harness.textView.insertText(" 你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.text == "SELECT 1 你")
        var index = SQLLineIndex("SELECT 1")
        for edit in harness.reportedEdits { index.apply(edit) }
        #expect(index.length == ("SELECT 1 你" as NSString).length)
    }

    // Review #2: storage edits that get no textDidChange are reported instead of being overwritten.
    @Test func unreportedStorageEditsCatchUp() async throws {
        let harness = EditorHarness("SELECT 1")
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- c\n")
        #expect(harness.coordinator.hasPendingEdits)
        harness.render()
        #expect(harness.textView.string == "-- c\nSELECT 1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.text == "-- c\nSELECT 1")
        #expect(!harness.coordinator.hasPendingEdits)
    }

    // Review #3: Return after a failed statement keeps its marker; typing onto its last token does not.
    @Test func returnAfterTheStatementKeepsItsMarker() {
        let failure = SQLDiagnostic(range: 14..<18, scope: 0..<25, severity: .error, source: .server, message: "Unexpected input 'shop'")
        let harness = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        harness.type("\n", at: 25)
        #expect(harness.coordinator.diagnostics == [failure])
        let glued = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        glued.type("x", at: 25)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // Review #3: text typed right before a statement only moves it when it stays a separate token.
    @Test func typingBeforeAStatement() {
        let failure = SQLDiagnostic(range: 18..<22, scope: 9..<24, severity: .error, source: .server, message: "m")
        let newline = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        newline.type("\n", at: 9)
        #expect(newline.coordinator.diagnostics.map(\.range) == [19..<23])
        let glued = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        glued.type("x", at: 9)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // The underline covers exactly the marked token (it used to run up to 32 characters from an offset).
    @Test func underlinesCoverExactlyTheMarkedText() throws {
        let failure = SQLDiagnostic(range: 14..<18, scope: 0..<25, severity: .error, source: .server, message: "Syntax error near 'shop.orders'")
        let harness = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        harness.coordinator.textChanged()
        let layoutManager = try #require(harness.textView.layoutManager)
        func underlined(_ index: Int) -> Bool {
            layoutManager.temporaryAttribute(.underlineStyle, atCharacterIndex: index, effectiveRange: nil) != nil
        }
        #expect(underlined(14) && underlined(17))
        #expect(!underlined(13) && !underlined(18))
    }

    // Review #6: a local marker stays put while the user types elsewhere in its statement.
    @Test func localMarkersDoNotBlinkWhileTyping() {
        let text = "SELECT count(1 FROM t"
        let harness = EditorHarness(text, diagnostics: SQLLinter.diagnose(text))
        harness.type(" ", at: 21)
        harness.type("W", at: 22)
        #expect(harness.coordinator.diagnostics.map(\.range) == [12..<13])
    }
}
