import Foundation
import VaultCore

/// What a share authorization allows (D30).
public enum ShareAuthorizationPurpose: String, Sendable, Hashable, CaseIterable {
    /// Writing a `.fxvault` file (``ReauthPurpose/share``).
    case fileExport
    /// Writing a `.fxvault` file that includes production (1.0, tasks/todo.md B3b): the user
    /// confirmed production on its own, so a file without it may use it too.
    case productionFileExport

    var reauthPurpose: ReauthPurpose {
        switch self {
        case .fileExport, .productionFileExport: .share
        }
    }

    /// Whether this purpose may write `includesProduction`.
    func allows(includesProduction: Bool) -> Bool {
        !includesProduction || self == .productionFileExport
    }
}

/// Proof that the user re-authenticated (Touch ID or master password) right before a share
/// (D30, §5.6, §9.1, §9.4).
///
/// Only VaultData can create one, through ``ReauthGate/authorizeShare(_:with:session:)``. It is
/// single-use, valid only for its purpose and for the session it was granted in while that
/// session's keys stay installed: a lock, unlock or key rotation in between invalidates it.
public final class ShareAuthorizationModel: Sendable {
    public let purpose: ShareAuthorizationPurpose
    private let ticket: ReauthTicket

    init(purpose: ShareAuthorizationPurpose, session: VaultSession) {
        self.purpose = purpose
        ticket = ReauthTicket(session: session)
    }

    /// True until the authorization has been used.
    public var isUsable: Bool {
        ticket.isUsable
    }

    /// Marks the authorization used for `purpose` in `session`.
    ///
    /// - Throws: ``SharingError/authorizationInvalid`` when it was already used, is for another
    ///   purpose or session, or the session's keys changed since it was granted.
    func consume(_ purpose: ShareAuthorizationPurpose, for session: VaultSession) throws(SharingError) {
        guard purpose == self.purpose, ticket.consume(for: session) else { throw .authorizationInvalid }
    }
}
