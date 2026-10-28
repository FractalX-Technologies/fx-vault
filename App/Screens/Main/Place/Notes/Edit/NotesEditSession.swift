import Foundation
import Observation
import VaultCore
import VaultData

/// What an edit of a place's notes needs from the place (1.0 N2).
struct NotesEditTargetModel {
    let kind: NotesEditPlaceKind
    /// The place's name, as the Review's title says it ("production").
    let title: String
    /// Its parent before the change count ("api-service · 4 changes"); nil for none.
    let parent: String?
    /// Saves the Review's edits in one transaction.
    let save: (PlaceItemEditsModel) throws(ConfigRepositoryError) -> Void
}

/// A line the editor starts with.
enum NotesEditInitialLineModel: Hashable {
    case heading(ConfigKind)
    case blank
    /// `NAME = value`; `itemID` marks a variable's characters as its item's.
    case item(name: String, value: NotesEditValueModel, itemID: ConfigItemID?)
}

/// The secret or multi-line variable whose value Set value… edits (board Place-SecretValue).
struct NotesValueRequestModel: Identifiable, Hashable {
    let id: NotesTokenID
    /// The line's name, for the popover's title.
    let name: String
    let kind: ConfigKind
    /// A new line's token: its kind can still change.
    let isNew: Bool
    /// The item is on GitHub or in Key Vault: its kind is fixed.
    let isSynced: Bool
    /// An existing secret: an empty field keeps its value.
    let keepsCurrentValue: Bool
    /// What the field starts with: the key that opened it, or a pasted value. Never in the text.
    var startText = ""
}

/// The editor's text view, as the edit drives it.
protocol NotesEditorCommands: AnyObject {
    /// Sets `value` on `token`'s line as one undo step; returns the token now on the line.
    @discardableResult
    func setValue(_ value: SecretBytes, on token: NotesTokenID) throws(ValidationError) -> NotesTokenID
    /// Redraws the tokens after a value was set.
    func tokensDidChange()
    /// Moves a new secret's line under `# Variables` with `value` as its text.
    func moveLineToVariables(token: NotesTokenID, value: String)
    /// Puts a removed item's line back at the end of its section (Undo).
    func restore(_ line: NotesEditInitialLineModel, kind: ConfigKind)
}

/// One edit of a place's notes (1.0 N2; boards Place-Edit through Place-Review): the editor's
/// lines read as notes, the values behind its tokens, the Review and the save. Values never reach
/// the text, its undo or a log; they are wiped when the edit ends.
@Observable
final class NotesEditSession {
    let target: NotesEditTargetModel
    let origins: [NotesEditOriginModel]
    /// The organization items a repository gets (B7a), read only under the editor.
    let inherited: NotesSectionModel?
    /// The lines the editor starts with (its tokens are in ``tokens``).
    let initialLines: [NotesEditInitialLineModel]
    private(set) var analysis = NotesEditAnalysisModel()
    /// Where the editor drew each line.
    var layout = NotesEditLayoutModel()
    /// The value Set value… is editing.
    var valueRequest: NotesValueRequestModel?
    var review: NotesReviewModel?
    /// "3 values set from the clipboard · clipboard cleared" (board Place-Paste).
    var toast: String?
    var alert: ErrorPresentationModel?

    @ObservationIgnored let tokens: NotesTokenStore
    /// Undo lives only while editing.
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored weak var editor: (any NotesEditorCommands)?
    /// The editor's text as it last changed: an editor made again (SwiftUI may) goes on from it.
    @ObservationIgnored var text: NSAttributedString?
    /// What the editor last copied, for a paste inside it: tokens paste whole.
    @ObservationIgnored var copiedFragment: (changeCount: Int, text: NSAttributedString)?
    /// The line (from 1) the caret starts at the end of; nil for the end of the text.
    @ObservationIgnored var caretLine: Int?
    /// Called once the edit is saved or cancelled.
    @ObservationIgnored var onFinish: () -> Void = {}
    /// Called after Save with the names of the secrets whose values this edit set.
    @ObservationIgnored var onSaved: (Set<String>) -> Void = { _ in }
    @ObservationIgnored private var paragraphs: [NotesParagraphModel] = []
    @ObservationIgnored private(set) var isFinished = false

    init(target: NotesEditTargetModel, origins: [NotesEditOriginModel], inherited: NotesSectionModel? = nil) {
        self.target = target
        self.origins = origins
        self.inherited = inherited
        let tokens = NotesTokenStore()
        self.tokens = tokens
        var lines: [NotesEditInitialLineModel] = []
        for (index, kind) in target.kind.kinds.enumerated() {
            if index > 0 {
                lines.append(.blank)
            }
            lines.append(.heading(kind))
            for origin in origins where origin.kind == kind {
                lines.append(Self.line(for: origin, tokens: tokens))
            }
        }
        initialLines = lines
    }

    /// A kept item's line: a variable in text when it fits one line, anything else as a token.
    private static func line(for origin: NotesEditOriginModel, tokens: NotesTokenStore) -> NotesEditInitialLineModel {
        if origin.kind == .variable, let text = origin.text {
            return .item(name: origin.name, value: .text(text), itemID: origin.id)
        }
        let id = tokens.make(
            kind: origin.kind,
            origin: origin.id,
            originHasValue: origin.hasValue,
            value: origin.variableValue.map { SecretBytes(utf8: $0) },
            file: origin.file
        )
        return .item(name: origin.name, value: .token(id), itemID: nil)
    }

    // MARK: - Reading the editor

    /// The editor's text changed.
    func update(_ paragraphs: [NotesParagraphModel]) {
        self.paragraphs = paragraphs
        refresh()
    }

    private func refresh() {
        analysis = NotesEditAnalysis.analyze(paragraphs: paragraphs, origins: origins, tokens: tokens.models, place: target.kind)
    }

    var changeCount: Int {
        analysis.plan.count
    }

    var errorCount: Int {
        analysis.errorCount
    }

    var canReview: Bool {
        errorCount == 0 && changeCount > 0
    }

    /// The header's subline (boards Place-Edit, Place-Errors).
    var subline: String {
        errorCount > 0 ? NotesEditCopy.errorsSubline(errorCount) : NotesEditCopy.editingSubline
    }

    // MARK: - Set value…

    /// Opens Set value… for the token on line `name`, its field starting with `startText`.
    func requestValue(for id: NotesTokenID, name: String, startText: String = "") {
        guard let kind = tokens.kind(of: id) else { return }
        let origin = tokens.origin(of: id).flatMap { id in origins.first { $0.id == id } }
        valueRequest = NotesValueRequestModel(
            id: id,
            name: name,
            kind: kind,
            isNew: origin == nil,
            isSynced: origin?.isSynced == true,
            keepsCurrentValue: kind == .secret && origin?.hasValue == true,
            startText: startText
        )
    }

    /// What Set value… starts with: the request's own text, a variable's value, else nothing.
    func currentText(of request: NotesValueRequestModel) -> String {
        guard request.startText.isEmpty else { return request.startText }
        guard let value = tokens.variableValue(request.id) else { return "" }
        defer { value.wipe() }
        return value.utf8String() ?? ""
    }

    /// Done in Set value…: `text` becomes the token's value. Empty keeps what it had.
    func commitValue(_ text: String, for id: NotesTokenID) {
        valueRequest = nil
        guard !text.isEmpty else { return }
        let value = SecretBytes(utf8: text)
        defer { value.wipe() }
        do {
            if let editor {
                try editor.setValue(value, on: id)
            } else {
                try tokens.setValue(value, for: id)
                refresh()
            }
        } catch {
            // Only line breaks: the line keeps what it had.
        }
    }

    /// Kind › Variable in Set value… for a new line: it moves under `# Variables`.
    func moveToVariables(_ id: NotesTokenID, text: String) {
        valueRequest = nil
        editor?.moveLineToVariables(token: id, value: text)
    }

    /// Values a paste set (``NotesTextView``): the board's toast, which says the clipboard was
    /// cleared only when it was (nothing was copied since).
    func didPasteValues(_ count: Int, clearedClipboard: Bool) {
        refresh()
        editor?.tokensDidChange()
        toast = clearedClipboard ? NotesEditCopy.pastedValues(count) : NotesEditCopy.pastedValuesKept(count)
    }

    // MARK: - Removed items

    /// Puts a removed item's line back (its "Undo").
    func restore(_ origin: NotesEditOriginModel) {
        editor?.restore(Self.line(for: origin, tokens: tokens), kind: origin.kind)
    }

    // MARK: - Review and save

    /// Review ⌘S: the changes, or nothing while a line can't be saved.
    func requestReview() {
        guard canReview else { return }
        review = NotesReviewModel(session: self)
    }

    /// Save in the Review: one transaction through the place's repository, then the notes are
    /// read only again with the changes pending.
    func save() {
        let edits = makeEdits()
        defer { edits.wipe() }
        let secretNames = savedSecretNames
        do {
            try target.save(edits)
        } catch {
            review = nil
            alert = error.presentation
            return
        }
        review = nil
        onSaved(secretNames)
        finish()
    }

    /// The secrets whose values showed in their tokens, by the name they are saved under: a
    /// value drawn `••••` (line breaks, over the limit) was never on screen and still asks.
    private var savedSecretNames: Set<String> {
        let plan = analysis.plan
        let added = plan.additions.filter { $0.kind == .secret && showsValue($0.value) }.map(\.name)
        let changed = plan.changes.filter { change in
            change.origin.kind == .secret && change.value.map(showsValue) == true
        }.map { $0.name ?? $0.origin.name }
        return Set(added + changed)
    }

    private func showsValue(_ value: NotesEditValueModel) -> Bool {
        guard case .token(let id) = value, case .visible = display(of: id) else { return false }
        return true
    }

    /// Cancel: drops every edit.
    func cancel() {
        finish()
    }

    /// Wipes the values and ends the edit (also on lock and on another place).
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        valueRequest = nil
        review = nil
        tokens.wipe()
        undoManager.removeAllActions()
        copiedFragment = nil
        text = nil
        onFinish()
    }

    func makeEdits() -> PlaceItemEditsModel {
        let plan = analysis.plan
        return PlaceItemEditsModel(
            deletions: plan.removals.map(\.id),
            changes: plan.changes.map { change in
                .init(id: change.origin.id, name: change.name, value: change.value.flatMap(bytes))
            },
            additions: plan.additions.compactMap { addition in
                bytes(addition.value).map { .init(kind: addition.kind, name: addition.name, value: $0) }
            }
        )
    }

    private func bytes(_ value: NotesEditValueModel) -> SecretBytes? {
        switch value {
        case .text(let text): SecretBytes(utf8: text)
        case .token(let id): tokens.valueToSave(id)
        }
    }
}

extension NotesEditSession: NotesTokenRenderer {
    /// How a token draws in the text.
    func display(of token: NotesTokenID) -> NotesTokenStore.Display {
        tokens.display(token, maxValueBytes: target.kind.maxValueBytes)
    }
}
