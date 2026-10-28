import Foundation
import Observation
import VaultCore
import VaultData

/// Proof that `ReauthGate` said yes to one Reveal; ``ReauthModel`` hands it out once.
nonisolated final class NotesRevealAuthorization: ReauthAuthorization {
    // No session binding needed: `reauthorized()` takes it and reveals in the same main-actor
    // turn, and decrypting fails while the vault is locked.
    let isUsable = true
}

/// The secret waiting for "Confirm it's you" (the sheet's item).
struct NotesRevealRequestModel: Identifiable, Hashable {
    /// What the secret is asked for: its eye or Reveal, the table's Copy Value (1.0 T1), or
    /// Reveal All of these secrets (then `id` is the first and `name` the place).
    enum Action: Hashable {
        case reveal
        case copy
        case revealAll([ConfigItemID])
    }

    let id: ConfigItemID
    let name: String
    var action = Action.reveal

    /// The confirmation's title and message, the same in the main window and the quick vault.
    var title: String {
        switch action {
        case .reveal: NotesCopy.reveal(name)
        case .copy: NotesCopy.copy(name)
        case .revealAll: NotesCopy.revealAllTitle
        }
    }

    var message: String {
        switch action {
        case .reveal: NotesCopy.revealMessage
        case .copy: NotesCopy.copyMessage
        case .revealAll: NotesCopy.revealAllMessage(place: name)
        }
    }
}

/// Reveal in a place's notes (1.0 B9; board Place-Reveal) and in its table (1.0 T1): "Confirm
/// it's you" first (Touch ID at once, then the master password), then ``ConfigValueRevealer``
/// decrypts the one secret and masks it again after `Timeouts.revealRemask`, on resign active,
/// on another place and on lock. The table's Copy Value of a secret asks the same way, and
/// Reveal All shows every secret of the place under one `Timeouts.revealAllRemask` countdown.
@Observable
final class NotesRevealModel: LockObserving, ReauthFlow {
    private(set) var request: NotesRevealRequestModel?
    /// A fresh check per request: Touch ID's status may have changed since the last one.
    private(set) var reauth: ReauthModel<NotesRevealAuthorization>?
    var alert: ErrorPresentationModel?
    let values: ConfigValueRevealer
    /// The last item Copy Value put on the clipboard: its line says Copied under Reveal All.
    private(set) var copiedID: ConfigItemID?

    @ObservationIgnored private let dependencies: FeatureDependencies
    /// What Copy Value does once the gate says yes: the place's own copy, true when it copied.
    @ObservationIgnored private var copyValue: ((ConfigItemID) -> Bool)?

    init(values: ConfigValueRevealer, dependencies: FeatureDependencies) {
        self.values = values
        self.dependencies = dependencies
        dependencies.actions.addLockObserver(self)
    }

    /// Asks for Reveal of `line`; a revealed or read-only line asks nothing.
    func ask(_ line: NotesItemLineModel) {
        guard line.canReveal else { return }
        ask(revealOf: line.id, name: line.name)
    }

    /// Asks for Reveal of the place's own secret `id`; a revealed one asks nothing.
    func ask(revealOf id: ConfigItemID, name: String) {
        guard !values.isRevealed(id) else { return }
        start(NotesRevealRequestModel(id: id, name: name), reason: .reveal)
    }

    /// The secrets Reveal All shows: the place's own, with a value here.
    static func revealAllIDs(_ notes: NotesDocumentModel) -> [ConfigItemID] {
        notes.items.filter(\.canReveal).map(\.id)
    }

    static func canRevealAll(_ notes: NotesDocumentModel) -> Bool {
        !revealAllIDs(notes).isEmpty
    }

    /// The header's Reveal All | Hide All: Hide All always, Reveal All with a secret to show.
    func canToggleRevealAll(_ notes: NotesDocumentModel) -> Bool {
        isRevealingAll || Self.canRevealAll(notes)
    }

    /// Reveal All of the notes' secrets after the gate, or Hide All while they show.
    func toggleRevealAll(_ notes: NotesDocumentModel, place: String) {
        if isRevealingAll {
            hideAll()
            return
        }
        let ids = Self.revealAllIDs(notes)
        guard let first = ids.first else { return }
        start(NotesRevealRequestModel(id: first, name: place, action: .revealAll(ids)), reason: .revealAll)
    }

    var isRevealingAll: Bool {
        values.isRevealingAll
    }

    /// When Reveal All's values hide (its countdown above the notes).
    var revealAllHideDate: Date? {
        values.allHideDate
    }

    /// The table's eye: Hide for a value that shows, else Reveal after the gate.
    func toggle(_ id: ConfigItemID, name: String) {
        if values.isRevealed(id) {
            values.hide(id)
        } else {
            ask(revealOf: id, name: name)
        }
    }

    /// Copy Value: a secret asks first, unless it shows (its value is on screen already); a
    /// variable copies at once. `copy` is the place's own copy, run once per yes; it returns
    /// false when it failed (and showed why), so the line never says Copied for nothing.
    func copy(_ id: ConfigItemID, name: String, kind: ConfigKind, copy: @escaping (ConfigItemID) -> Bool) {
        let copy = { [weak self] (id: ConfigItemID) -> Bool in
            let copied = copy(id)
            if copied {
                self?.copiedID = id
            }
            return copied
        }
        guard kind == .secret, !values.isRevealed(id) else {
            _ = copy(id)
            return
        }
        start(NotesRevealRequestModel(id: id, name: name, action: .copy), reason: .copyValue)
        copyValue = copy
    }

    private func start(_ request: NotesRevealRequestModel, reason: ReauthPurpose) {
        cancel()
        let gate = dependencies.reauth
        reauth = ReauthModel(
            prompt: FeatureDependencies.reauthPrompt(for: reason),
            touchIDStatus: dependencies.touchIDStatus()
        ) { credential in
            try await gate.authorize(reason, with: credential)
            return NotesRevealAuthorization()
        }
        self.request = request
    }

    var pendingReauth: ReauthModel<NotesRevealAuthorization>? {
        reauth
    }

    /// Drops the request and its typed password (Cancel, the sheet closed, lock).
    func cancel() {
        reauth?.reset()
        reauth = nil
        request = nil
        copyValue = nil
    }

    func hide(_ id: ConfigItemID) {
        values.hide(id)
    }

    /// Masks every revealed value (an edit of the notes starts, 1.0 N2).
    func hideAll() {
        values.remaskAll()
    }

    func hideDate(of id: ConfigItemID) -> Date? {
        values.hideDates[id]
    }

    func vaultDidLock() {
        cancel()
    }

    /// Reveals or copies the request's secret. A check that ends after Cancel, another scope or
    /// a lock finds no request; one that ends after a new request finds that request's own,
    /// unanswered check: neither reveals nor copies anything.
    func reauthorized() {
        guard let request, reauth?.takeAuthorization() != nil else { return }
        let copy = copyValue
        cancel()
        switch request.action {
        case .reveal:
            do {
                try values.reveal(request.id)
            } catch {
                alert = error.presentation
            }
        case .copy:
            _ = copy?(request.id)
        case .revealAll(let ids):
            // A copy from before (the table, an earlier Reveal All) says nothing about this one.
            copiedID = nil
            do {
                try values.revealAll(ids)
            } catch {
                alert = error.presentation
            }
        }
    }
}
