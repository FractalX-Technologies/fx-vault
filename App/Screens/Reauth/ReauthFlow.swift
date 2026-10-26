import Foundation

/// A sheet that asks "Confirm it's you" before one action (Copy All, Reveal in the notes): Touch
/// ID once when it appears, again on request, or the master password; the action runs on yes.
protocol ReauthFlow: AnyObject {
    associatedtype Authorization: ReauthAuthorization

    /// The check to answer; nil when there is nothing to confirm (done, or no request).
    var pendingReauth: ReauthModel<Authorization>? { get }

    /// `ReauthGate` said yes: take the single-use authorization and act. It may arrive after
    /// the request was cancelled or replaced, so check that the authorization is still yours.
    func reauthorized()
}

extension ReauthFlow {
    /// Tries Touch ID once when the sheet appears; a Mac without it shows the password field.
    func start() async {
        await authenticateWithTouchID(automatic: true)
    }

    func authenticateWithTouchID(automatic: Bool = false) async {
        guard let reauth = pendingReauth else { return }
        if await reauth.authorizeWithTouchID(automatic: automatic) {
            reauthorized()
        }
    }

    func authenticateWithPassword() async {
        guard let reauth = pendingReauth else { return }
        if await reauth.authorizeWithPassword() {
            reauthorized()
        }
    }
}
