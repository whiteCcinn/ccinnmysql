import CcinnMysqlKit
import Foundation
import Observation

/// Format SQL for one editor: formats off the main actor, is cancelled by any edit, applies its result only to exactly
/// the text it was computed from, and is never silent: when the result does not apply, `notice` says why, for the
/// editor's status bar.
@MainActor
@Observable
final class SQLFormatting {
    /// Why the last format changed nothing.
    enum Notice: Equatable {
        /// An input method was composing: it owns the text until it commits.
        case composing
        /// The text changed while it was being formatted.
        case textChanged
        /// The editor does not accept edits.
        case readOnly
        /// The formatter could not prove the result means the same (a syntax error such as `1.end` included).
        case unsafe
        /// The text reads differently depending on the session's sql_mode or character set (a backslash in a string, a
        /// `"…"` token, a character outside ASCII), and they have not been read from the server.
        case modeUnknown
        /// The session's sql_mode has modes the formatter does not model (their names).
        case unmodelledSQLMode(String)
        /// The session's character set is not one in which the app's UTF-8 text reads as written.
        case unsupportedCharset(String)

        var message: String {
            switch self {
            case .composing: "Not formatted: finish typing with the input method first, then format again."
            case .textChanged: "Not formatted: the text changed while it was being formatted. Format again."
            case .readOnly: "Not formatted: this editor is read-only."
            case .unsafe: "Not formatted: the result could not be proven to mean the same as this text (check it for errors)."
            case .modeUnknown:
                "Not formatted: backslashes in strings, double quotes and characters outside ASCII depend on the session's sql_mode and character set, which could not be read yet. Run a statement, then format again."
            case let .unmodelledSQLMode(modes):
                "Not formatted: the session's sql_mode has \(modes), which changes how MySQL reads SQL. Format SQL supports the default reading, NO_BACKSLASH_ESCAPES and ANSI_QUOTES."
            case let .unsupportedCharset(charset):
                "Not formatted: the session's character set is \(charset); in it, text written in UTF-8 can read differently. Run SET NAMES utf8mb4 first."
            }
        }
    }

    /// The text to format when no editor is attached yet (a tab opened from launch arguments), and where the result goes:
    /// `store(source, result, selection)` replaces the text if it is still `source` and says whether it did.
    struct Detached {
        let text: String
        let selection: NSRange
        let store: @MainActor (_ source: String, _ result: String, _ selection: NSRange) -> Bool
    }

    let editor: SQLEditorController
    /// Why the last format changed nothing; cleared by the next format, or after `noticeDuration`.
    private(set) var notice: Notice?
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the running format, so a cancelled one cannot touch the state of the next.
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var noticeExpiry: Task<Void, Never>?
    @ObservationIgnored var noticeDuration: Duration = .seconds(8)

    init(editor: SQLEditorController) {
        self.editor = editor
    }

    /// Formats the editor's selection, or its whole text when nothing is selected, as one undoable edit. Starts from the
    /// editor's live text (a binding can lag behind it), never while an input method composes. Returns the running
    /// work (tests await it), `nil` when nothing started.
    @discardableResult
    func start(options: SQLFormatOptions, detached: Detached) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        show(nil)
        let live = editor.snapshot
        if live?.isComposing == true {
            show(.composing)
            return nil
        }
        let source = live?.text ?? detached.text
        let cursor = live?.selection ?? detached.selection
        let length = (source as NSString).length
        let formatsSelection = cursor.length > 0 && cursor.location >= 0 && cursor.location <= length && cursor.length <= length - cursor.location
        generation &+= 1
        let generation = generation
        isRunning = true
        let task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> SQLFormatEdit? in
                if formatsSelection {
                    // Snapped to whole tokens and checked in the context of the whole text.
                    return SQLFormatter.formatSelection(in: source, range: cursor, options: options)
                }
                return SQLFormatter.format(source, options: options).map { SQLFormatEdit(range: NSRange(location: 0, length: length), replacement: $0) }
            }
            let edit = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            // Cancelled meanwhile (an edit, closing the tab): `stop` has already said why, if anything.
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.isRunning = false
            self.task = nil
            self.apply(edit, to: source, cursor: cursor, formatsSelection: formatsSelection, options: options, detached: detached)
        }
        self.task = task
        return task
    }

    /// The text is changing: a running format no longer applies, and the status bar says so.
    func textDidChange() {
        guard isRunning else { return }
        stop()
        show(.textChanged)
    }

    /// Stops a running format without a notice (the tab is closing).
    func cancel() {
        guard isRunning else { return }
        stop()
    }

    private func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        generation &+= 1
    }

    private func apply(_ edit: SQLFormatEdit?, to source: String, cursor: NSRange, formatsSelection: Bool, options: SQLFormatOptions,
                       detached: Detached) {
        guard let edit else { return show(Self.refusal(of: source, options: options)) }
        let original = (source as NSString).substring(with: edit.range)
        guard !(original as NSString).isEqual(to: edit.replacement) else { return } // already formatted
        let newSelection = formatsSelection
            ? NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
            : NSRange(location: SQLFormatter.mapOffset(cursor.location, from: source, to: edit.replacement), length: 0)
        switch editor.replace(edit.range, of: source, with: edit.replacement, actionName: "Format SQL", selecting: newSelection) {
        case .replaced:
            break
        case .composing:
            show(.composing)
        case .textChanged:
            show(.textChanged)
        case .readOnly:
            show(.readOnly)
        case .noEditor:
            let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            if !detached.store(source, result, newSelection) { show(.textChanged) }
        }
    }

    /// Why the formatter returned nothing for `source`.
    static func refusal(of source: String, options: SQLFormatOptions) -> Notice {
        if !options.unmodelledSQLModes.isEmpty { return .unmodelledSQLMode(options.unmodelledSQLModes.joined(separator: ", ")) }
        if !options.sessionCharsetIsSafe, let charset = options.sessionCharset { return .unsupportedCharset(charset) }
        if !options.sessionModeKnown, SQLFormatter.dependsOnSession(source) { return .modeUnknown }
        return .unsafe
    }

    private func show(_ notice: Notice?) {
        noticeExpiry?.cancel()
        noticeExpiry = nil
        self.notice = notice
        guard notice != nil else { return }
        let duration = noticeDuration
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
