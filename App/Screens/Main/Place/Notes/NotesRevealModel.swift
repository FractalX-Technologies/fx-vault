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
    let id: ConfigItemID
    let name: String
}

/// Reveal in a place's notes (1.0 B9; board Place-Reveal): "Confirm it's you" first (Touch ID
/// at once, then the master password), then ``ConfigValueRevealer`` decrypts the one secret and
/// masks it again after `Timeouts.revealRemask`, on resign active, on another place and on lock.
@Observable
final class NotesRevealModel: LockObserving, ReauthFlow {
    private(set) var request: NotesRevealRequestModel?
    /// A fresh check per request: Touch ID's status may have changed since the last one.
    private(set) var reauth: ReauthModel<NotesRevealAuthorization>?
    var alert: ErrorPresentationModel?
    let values: ConfigValueRevealer

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(values: ConfigValueRevealer, dependencies: FeatureDependencies) {
        self.values = values
        self.dependencies = dependencies
        dependencies.actions.addLockObserver(self)
    }

    /// Asks for Reveal of `line`; a revealed or read-only line asks nothing.
    func ask(_ line: NotesItemLineModel) {
        guard line.canReveal, !values.isRevealed(line.id) else { return }
        let gate = dependencies.reauth
        reauth = ReauthModel(
            prompt: FeatureDependencies.reauthPrompt(for: .reveal),
            touchIDStatus: dependencies.touchIDStatus()
        ) { credential in
            try await gate.authorize(.reveal, with: credential)
            return NotesRevealAuthorization()
        }
        request = NotesRevealRequestModel(id: line.id, name: line.name)
    }

    var pendingReauth: ReauthModel<NotesRevealAuthorization>? {
        reauth
    }

    /// Drops the request and its typed password (Cancel, the sheet closed, lock).
    func cancel() {
        reauth?.reset()
        reauth = nil
        request = nil
    }

    func hide(_ id: ConfigItemID) {
        values.hide(id)
    }

    func hideDate(of id: ConfigItemID) -> Date? {
        values.hideDates[id]
    }

    func vaultDidLock() {
        cancel()
    }

    /// Reveals the request's secret. A check that ends after Cancel, another scope or a lock
    /// finds no request; one that ends after a new request finds that request's own, unanswered
    /// check: neither reveals anything.
    func reauthorized() {
        guard let request, reauth?.takeAuthorization() != nil else { return }
        cancel()
        do {
            try values.reveal(request.id)
        } catch {
            alert = error.presentation
        }
    }
}
