import AppKit
@testable import CcinnMysqlKit
import SwiftUI
import Testing
@testable import CcinnMysql

/// How often the editor asked its completion provider.
@MainActor
private final class CallCounter {
    var count = 0
    /// The text of every request.
    var texts: [String] = []
}

/// An editor wired like `SQLWorkbenchView` wires it, with the binding and the model's diagnostics held
/// here, so tests can play the model's part (including lagging behind the text view).
@MainActor
private final class EditorHarness {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var diagnostics: [SQLDiagnostic] = []
    var reportedEdits: [SQLTextEdit] = []
    var completionProvider: CompletionProvider?
    let completionRequests: CallCounter
    let textView: SQLTextView
    let coordinator: SQLEditor.Coordinator
    private let window: NSWindow

    /// `providerDelay` plays a provider that waits for the server before it answers.
    init(_ text: String, diagnostics: [SQLDiagnostic] = [], completionSchema: SchemaSnapshot? = nil, providerDelay: Duration = .zero) {
        self.text = text
        self.diagnostics = diagnostics
        let requests = CallCounter()
        completionRequests = requests
        if let completionSchema {
            completionProvider = { text, cursor, deliver in
                requests.count += 1
                requests.texts.append(text)
                if providerDelay > .zero { try? await Task.sleep(for: providerDelay) }
                deliver(CompletionEngine.complete(text: text, cursor: cursor, schema: completionSchema))
            }
        }
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
                  completionProvider: completionProvider,
                  onEdit: { self.reportedEdits += $0 })
    }

    /// What SwiftUI does on every re-render of the workbench.
    func render() { coordinator.update(from: editor) }

    func type(_ string: String, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        selection = textView.selectedRange()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    /// Types `string` at the end, one key at a time.
    func typeAtEnd(_ string: String) {
        for character in string { type(String(character), at: (textView.string as NSString).length) }
    }

    /// Waits until the popup lists exactly `labels`.
    func waitForCompletions(_ labels: [String], within timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while coordinator.visibleCompletions?.map(\.label) != labels, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Labels of the completion popup once it shows something, `nil` if it stays hidden.
    func shownCompletions(within timeout: Duration = .seconds(2)) async throws -> [String]? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let items = coordinator.visibleCompletions { return items.map(\.label) }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
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

    // Final review A/B: an unmodelled sql_mode or a session character set other than UTF-8/latin1/ASCII refuses with a
    // notice that names it.
    @Test func unsupportedSessionsSayWhy() async throws {
        let harness = EditorHarness("select a, b from t")
        let formatting = formatting(harness)
        var options = SQLFormatOptions()
        options.lexingMode = SQLLexingMode(sqlMode: "ORACLE,PIPES_AS_CONCAT")
        await formatting.start(options: options, detached: detached(""))?.value
        #expect(formatting.notice == .unmodelledSQLMode("ORACLE, PIPES_AS_CONCAT"))
        #expect(formatting.notice?.message.contains("ORACLE") == true)
        await formatting.start(options: SQLFormatOptions(sessionCharset: "gbk"), detached: detached(""))?.value
        #expect(formatting.notice == .unsupportedCharset("gbk"))
        #expect(formatting.notice?.message.contains("gbk") == true)
        #expect(harness.textView.string == "select a, b from t")
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

// MARK: - Completion

@Suite("SQL completion popup", .serialized)
@MainActor
struct CompletionPopupTests {
    static let schema = SchemaSnapshot(
        currentDatabase: "demo", databases: ["demo"],
        objectsByDatabase: ["demo": ["crm_contact", "crm_pipeline", "dw_sales_crm_funnel_daily", "mv_report_crm_hour"]
            .map { SchemaSnapshot.ObjectEntry(name: $0, kind: .table) }])

    private func item(_ label: String) -> CompletionItem { CompletionItem(kind: .keyword, label: label, insertText: label, detail: nil) }

    private func runLoop(for seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pixels(of panel: NSPanel) throws -> Data {
        let view = try #require(panel.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    /// What a panel shows for `items`, drawn by a panel that never showed anything else.
    private func freshRendering(of items: [CompletionItem], frame: NSRect) throws -> Data {
        let model = CompletionListModel()
        model.update(items: items, prefix: "")
        let panel = CompletionPanel(model: model)
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        runLoop()
        return try pixels(of: panel)
    }

    // The popup kept drawing the first list it showed: `from` listed SELECT/SET, `crm_pipeline` the `crm` list.
    @Test func theListDrawsTheLatestResult() throws {
        _ = NSApplication.shared
        let first = ["SELECT", "SET"].map(item)
        let second = ["FROM", "from_unixtime"].map(item)
        let model = CompletionListModel()
        let panel = CompletionPanel(model: model)
        model.update(items: first, prefix: "se")
        let frame = NSRect(origin: NSPoint(x: 240, y: 320), size: model.preferredSize)
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        runLoop()
        model.update(items: second, prefix: "from")
        runLoop()
        let shown = try pixels(of: panel)
        panel.orderOut(nil)

        let expected = try freshRendering(of: second, frame: frame)
        #expect(try freshRendering(of: first, frame: frame) != expected, "the two lists must look different for this test to mean anything")
        #expect(shown == expected)
    }

    // Spec "Tables after FROM": the list opens on the space, before any letter is typed.
    @Test func spaceAfterFromListsTheTables() async throws {
        let harness = EditorHarness("select * from", completionSchema: Self.schema)
        harness.typeAtEnd(" ")
        let labels = try #require(try await harness.shownCompletions())
        #expect(Array(labels.prefix(4)) == ["crm_contact", "crm_pipeline", "dw_sales_crm_funnel_daily", "mv_report_crm_hour"])
    }

    @Test func spaceElsewhereKeepsTheListClosed() async throws {
        for text in ["select *", "select * from crm_contact", "select * from crm_contact order by id desc"] {
            let harness = EditorHarness(text, completionSchema: Self.schema)
            harness.typeAtEnd(" ")
            #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil, "\(text)")
        }
    }

    // Return is pressed twice for a blank line; a list opened by the first would take the second.
    @Test func returnOrTabAfterFromKeepsTheListClosed() async throws {
        for typed in ["\n", "    "] {
            let harness = EditorHarness("select *\nfrom", completionSchema: Self.schema)
            harness.type(typed, at: (harness.textView.string as NSString).length)
            #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil, "\(typed.debugDescription)")
        }
    }

    // A list computed for `crm` must not stay up (and be accepted with Return) once a space ends the name.
    @Test func whitespaceClosesTheListAtOnce() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("crm")
        #expect(try await harness.shownCompletions()?.first == "crm_contact")
        harness.typeAtEnd(" ")
        #expect(harness.coordinator.visibleCompletions == nil)
        #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil)
    }

    // Spec "Suggestions follow typing": the list follows each key at once, and Return takes the name typed.
    @Test func theListFollowsEveryKeyAndReturnTakesTheNameTyped() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("crm")
        #expect(try await harness.shownCompletions()?.count == 4)
        harness.typeAtEnd("_p")
        #expect(harness.coordinator.visibleCompletions?.map(\.label) == ["crm_pipeline"], "no wait for another request")
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "select * from crm_pipeline")
    }

    @Test func burstTypingShowsAListAfterEveryKey() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("c")
        #expect(try await harness.shownCompletions() != nil)
        for character in "rm_pi" {
            harness.typeAtEnd(String(character))
            #expect(harness.coordinator.visibleCompletions != nil, "after \(character)")
        }
        #expect(harness.coordinator.visibleCompletions?.map(\.label) == ["crm_pipeline"])
    }

    // Spec "Backspace keeps the list".
    @Test func backspaceNarrowsTheListInsteadOfClosingIt() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("crm_p")
        #expect(try await harness.shownCompletions() == ["crm_pipeline"])
        harness.textView.deleteBackward(nil)
        #expect(harness.coordinator.visibleCompletions?.map(\.label).prefix(2) == ["crm_contact", "crm_pipeline"])
        for _ in 0..<4 { harness.textView.deleteBackward(nil) }
        #expect(harness.coordinator.visibleCompletions?.map(\.label) == ["crm_contact", "crm_pipeline", "dw_sales_crm_funnel_daily",
                                                                         "mv_report_crm_hour", "demo"],
                "an empty name after FROM lists every table, and the databases")
        harness.textView.deleteBackward(nil)
        #expect(harness.coordinator.visibleCompletions == nil, "the space after FROM is gone")
    }

    // A server round trip outlasts several keys: its answer is narrowed to what was typed since, not thrown away.
    @Test func aLateAnswerIsNarrowedToTheTextTypedSinceTheRequest() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema, providerDelay: .milliseconds(150))
        harness.typeAtEnd("c")
        try await Task.sleep(for: .milliseconds(30))
        harness.typeAtEnd("rm_p")
        #expect(try await harness.shownCompletions() == ["crm_pipeline"])
        #expect(harness.completionRequests.count == 1, "the keys typed while it ran did not ask again")
    }

    // The provider answers with what it knows, then again once missing tables have loaded.
    @Test func aSecondAnswerReplacesTheFirst() async throws {
        let harness = EditorHarness("select * from ")
        let empty = SchemaSnapshot(currentDatabase: "demo", databases: ["demo"], objectsByDatabase: ["demo": []])
        harness.completionProvider = { text, cursor, deliver in
            deliver(CompletionEngine.complete(text: text, cursor: cursor, schema: empty))
            try? await Task.sleep(for: .milliseconds(80))
            deliver(CompletionEngine.complete(text: text, cursor: cursor, schema: Self.schema))
        }
        harness.render()
        harness.typeAtEnd("crm_p")
        #expect(try await harness.shownCompletions() == ["crm_pipeline"])
    }

    // Spec "Back-quoted name": the editor closes the back-quote; the name inside is completed back-quoted.
    @Test func aBackQuotedNameIsCompletedInsideItsQuotes() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("`")
        #expect(harness.textView.string == "select * from ``")
        for character in "crm_p" { harness.type(String(character), at: harness.textView.selectedRange().location) }
        #expect(try await harness.shownCompletions() == ["crm_pipeline"])
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "select * from `crm_pipeline`")
    }

    @Test func typingInsideANameReplacesTheWholeName() async throws {
        let harness = EditorHarness("select * from crm_con", completionSchema: Self.schema)
        harness.type("p", at: 18)
        #expect(try await harness.shownCompletions() == ["crm_pipeline"])
        harness.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(harness.textView.string == "select * from crm_pipeline")
    }

    @Test func anEditBeforeTheNameClosesTheList() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("crm")
        #expect(try await harness.shownCompletions() != nil)
        harness.type("x", at: 0)
        #expect(harness.coordinator.visibleCompletions == nil)
        #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil)
    }

    /// Answers first from a schema with only `first` tables, then, 80 ms later, from the whole schema.
    private static func twoAnswers(first: [String]) -> CompletionProvider {
        let partial = SchemaSnapshot(currentDatabase: "demo", databases: ["demo"],
                                     objectsByDatabase: ["demo": first.map { SchemaSnapshot.ObjectEntry(name: $0, kind: .table) }])
        return { text, cursor, deliver in
            deliver(CompletionEngine.complete(text: text, cursor: cursor, schema: partial))
            try? await Task.sleep(for: .milliseconds(80))
            deliver(CompletionEngine.complete(text: text, cursor: cursor, schema: Self.schema))
        }
    }

    // Review #1: the first answer's top row was still selected after the second answer, so Return took a worse match.
    @Test func theBestMatchIsSelectedWhenTheSecondAnswerArrives() async throws {
        let harness = EditorHarness("select * from ")
        harness.completionProvider = Self.twoAnswers(first: ["crm_pipeline", "mv_report_crm_hour"])
        harness.render()
        harness.typeAtEnd("crm")
        #expect(try await harness.shownCompletions() == ["crm_pipeline", "mv_report_crm_hour"])
        try await harness.waitForCompletions(["crm_contact", "crm_pipeline", "dw_sales_crm_funnel_daily", "mv_report_crm_hour"])
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "select * from crm_contact")
    }

    @Test func aSelectionTheUserMovedSurvivesTheSecondAnswer() async throws {
        let harness = EditorHarness("select * from ")
        harness.completionProvider = Self.twoAnswers(first: ["crm_pipeline", "mv_report_crm_hour"])
        harness.render()
        harness.typeAtEnd("crm")
        #expect(try await harness.shownCompletions() == ["crm_pipeline", "mv_report_crm_hour"])
        harness.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await harness.waitForCompletions(["crm_contact", "crm_pipeline", "dw_sales_crm_funnel_daily", "mv_report_crm_hour"])
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "select * from mv_report_crm_hour")
    }

    // Review #4: the back-quote the editor closes opens the table list right away.
    @Test func aBackQuoteAfterFromOpensTheList() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("`")
        #expect(try await harness.shownCompletions()?.first == "crm_contact")
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "select * from `crm_contact`")
    }

    // Review #5: Backspace before the first answer arrived dropped the request.
    @Test func backspaceWhileTheFirstAnswerIsOnItsWayKeepsIt() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema, providerDelay: .milliseconds(150))
        harness.typeAtEnd("crm_p")
        harness.textView.deleteBackward(nil)
        #expect(try await harness.shownCompletions()?.prefix(2) == ["crm_contact", "crm_pipeline"])
        #expect(harness.completionRequests.count == 1)
    }

    // Review #7: every request lexed the whole script; the engine now gets the statement at the cursor.
    @Test func onlyTheStatementAtTheCursorGoesToTheEngine() async throws {
        let script = String(repeating: "SELECT 1;\n", count: 500)
        let harness = EditorHarness(script + "select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("crm_p")
        #expect(try await harness.shownCompletions() == ["crm_pipeline"])
        #expect(harness.completionRequests.texts.allSatisfy { ($0 as NSString).length < 100 }, "\(harness.completionRequests.texts.map(\.count))")
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == script + "select * from crm_pipeline")
    }

    @Test func typingNarrowsTheListUntilOnlyTheExactNameIsLeft() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("crm")
        #expect(try await harness.shownCompletions()?.count == 4)
        harness.typeAtEnd("_p")
        let deadline = ContinuousClock.now + .seconds(2)
        while harness.coordinator.visibleCompletions?.map(\.label) != ["crm_pipeline"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.coordinator.visibleCompletions?.map(\.label) == ["crm_pipeline"])
        harness.typeAtEnd("ipeline")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.coordinator.visibleCompletions == nil, "only the exact name is left")
    }
}
