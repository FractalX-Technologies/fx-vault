import Foundation
import Observation
import VaultCore
import VaultData

/// Proof that `ReauthGate` said yes to one Copy; ``ReauthModel`` hands it out once.
nonisolated final class QuickVaultCopyAuthorization: ReauthAuthorization {
    // Taken and used in the same main-actor turn, and decrypting fails while locked.
    let isUsable = true
}

/// One place's lines in the quick vault (board QuickVault-Place): the place's notes from N1
/// (``NotesPlaceModel``) without what it inherits, each with Copy. A variable copies at once; a
/// secret asks for Touch ID or the master password first, unless it shows revealed.
@Observable
final class QuickVaultPlaceViewModel: ReauthFlow, LockObserving {
    let place: QuickVaultPlaceModel
    /// The place's detail view model, as the main window has it: its notes and their Reveal.
    let source: any NotesPlaceModel
    /// The secret waiting for "Confirm it's you" before its Copy.
    private(set) var copyRequest: NotesRevealRequestModel?
    private(set) var copyReauth: ReauthModel<QuickVaultCopyAuthorization>?
    /// The last line copied: its Copy says so.
    private(set) var copiedID: ConfigItemID?
    var error: ErrorPresentationModel?

    @ObservationIgnored private let copyValue: (ConfigItemID) throws(ConfigRepositoryError) -> Void
    @ObservationIgnored private let dependencies: FeatureDependencies

    /// - Parameter copyValue: decrypts one item of the place and copies it through `ClipboardManager`.
    init(
        place: QuickVaultPlaceModel,
        source: any NotesPlaceModel,
        dependencies: FeatureDependencies,
        copyValue: @escaping (ConfigItemID) throws(ConfigRepositoryError) -> Void
    ) {
        self.place = place
        self.source = source
        self.dependencies = dependencies
        self.copyValue = copyValue
        dependencies.actions.addLockObserver(self)
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
        copyReauth?.isAuthorizing == true || reveal.reauth?.isAuthorizing == true
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
        guard asksBeforeCopy(line) else {
            copyNow(line.id)
            return
        }
        reveal.cancel()
        let gate = dependencies.reauth
        copyReauth = ReauthModel(
            prompt: FeatureDependencies.reauthPrompt(for: .copyValue),
            touchIDStatus: dependencies.touchIDStatus()
        ) { credential in
            try await gate.authorize(.copyValue, with: credential)
            return QuickVaultCopyAuthorization()
        }
        copyRequest = NotesRevealRequestModel(id: line.id, name: line.name)
    }

    var pendingReauth: ReauthModel<QuickVaultCopyAuthorization>? {
        copyReauth
    }

    /// Copies the request's secret. A check that ends after Cancel or a lock finds no request.
    func reauthorized() {
        guard let request = copyRequest, copyReauth?.takeAuthorization() != nil else { return }
        cancelCopy()
        copyNow(request.id)
    }

    /// Drops the request and its typed password (Cancel, back, close, lock).
    func cancelCopy() {
        copyReauth?.reset()
        copyReauth = nil
        copyRequest = nil
    }

    /// The place goes away: nothing stays revealed or asked for.
    func close() {
        cancelCopy()
        reveal.cancel()
        reveal.values.remaskAll()
        reveal.values.clearVariables()
    }

    func vaultDidLock() {
        cancelCopy()
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
