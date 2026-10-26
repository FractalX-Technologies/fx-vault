import Foundation
import Observation
import VaultCore
import VaultData

/// One place's lines in the quick vault (board QuickVault-Place): the place's notes from N1
/// (``NotesPlaceModel``) without what it inherits, each with Copy. A variable copies at once; a
/// secret asks for Touch ID or the master password first, unless it shows revealed, through
/// the place's ``NotesRevealModel`` as the table's Copy Value does (1.0 T1).
@Observable
final class QuickVaultPlaceViewModel {
    let place: QuickVaultPlaceModel
    /// The place's detail view model, as the main window has it: its notes and their Reveal.
    let source: any NotesPlaceModel
    /// The last line copied: its Copy says so.
    private(set) var copiedID: ConfigItemID?
    var error: ErrorPresentationModel?

    @ObservationIgnored private let copyValue: (ConfigItemID) throws(ConfigRepositoryError) -> Void

    /// - Parameter copyValue: decrypts one item of the place and copies it through `ClipboardManager`.
    init(
        place: QuickVaultPlaceModel,
        source: any NotesPlaceModel,
        copyValue: @escaping (ConfigItemID) throws(ConfigRepositoryError) -> Void
    ) {
        self.place = place
        self.source = source
        self.copyValue = copyValue
    }

    /// The place's own `KEY = value` lines (an organization's items a repository gets are read
    /// only, and copied from the organization).
    var lines: [NotesItemLineModel] {
        source.notes.items.filter { !$0.isInherited }
    }

    var reveal: NotesRevealModel {
        source.notesReveal
    }

    /// A Touch ID prompt or a password check is running: losing the focus must not close it.
    var isAuthorizing: Bool {
        reveal.reauth?.isAuthorizing == true
    }

    func canCopy(_ line: NotesItemLineModel) -> Bool {
        !line.isInherited && line.value != .missing
    }

    /// A secret asks first, unless revealed: its value is on screen already.
    func asksBeforeCopy(_ line: NotesItemLineModel) -> Bool {
        line.kind == .secret && !reveal.values.isRevealed(line.id)
    }

    func copy(_ line: NotesItemLineModel) {
        guard canCopy(line) else { return }
        reveal.copy(line.id, name: line.name, kind: line.kind) { [weak self] in self?.copyNow($0) }
    }

    /// The place goes away: nothing stays revealed or asked for.
    func close() {
        reveal.cancel()
        reveal.values.remaskAll()
        reveal.values.clearVariables()
    }

    private func copyNow(_ id: ConfigItemID) {
        error = nil
        do {
            try copyValue(id)
            copiedID = id
        } catch {
            self.error = error.presentation
        }
    }
}
