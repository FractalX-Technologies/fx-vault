import Foundation

/// Proof of a fresh Touch ID or master-password check before Save As… of a folder file (v23,
/// D30). Only ``ReauthGate/authorizeFileSave(with:session:)`` makes one, so
/// ``FolderRepository/saveFile(_:to:authorization:)`` writes no file without it. Single-use and
/// bound to one session: a lock, unlock or key rotation in between invalidates it.
public final class FolderFileSaveAuthorizationModel: Sendable {
    private let ticket: ReauthTicket

    init(session: VaultSession) {
        ticket = ReauthTicket(session: session)
    }

    /// True until the authorization has been used.
    public var isUsable: Bool {
        ticket.isUsable
    }

    func consume(for session: VaultSession) throws(FolderFileError) {
        guard ticket.consume(for: session) else { throw .authorizationInvalid }
    }
}

extension ReauthGate {
    /// Re-authenticates for Save As… of a folder file and returns the single-use authorization
    /// ``FolderRepository/saveFile(_:to:authorization:)`` requires, bound to `session`.
    ///
    /// - Throws: whatever ``authorize(_:with:)`` throws (`.locked`, `.wrongPassword`, `.cancelled`, ...).
    public func authorizeFileSave(with credential: ReauthCredential, session: VaultSession) async throws -> FolderFileSaveAuthorizationModel {
        try await authorize(.saveFile, with: credential)
        return FolderFileSaveAuthorizationModel(session: session)
    }
}
