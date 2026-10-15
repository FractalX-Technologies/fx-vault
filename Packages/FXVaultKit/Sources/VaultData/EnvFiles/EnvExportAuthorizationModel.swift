import Foundation

/// Proof that the user re-authenticated for a plaintext `.env` export (D30, §5.6).
///
/// Only VaultData can create one, through ``ReauthGate/authorizeEnvExport(with:session:)``, so
/// ``EnvFileRepository/export(repositoryID:scope:to:authorization:existingFile:headerComments:)``
/// cannot run without a fresh Touch ID or master-password check. It is single-use and only
/// valid for the session it was granted in, while that session's keys stay installed: a lock,
/// unlock or key rotation in between invalidates it.
public final class EnvExportAuthorizationModel: Sendable {
    private let ticket: ReauthTicket

    init(session: VaultSession) {
        ticket = ReauthTicket(session: session)
    }

    /// True until the authorization has been used.
    public var isUsable: Bool {
        ticket.isUsable
    }

    /// Marks the authorization used for `session`.
    ///
    /// - Throws: ``EnvFileError/authorizationInvalid`` when it was already used, belongs to
    ///   another session, or the session's keys changed since it was granted.
    func consume(for session: VaultSession) throws(EnvFileError) {
        guard ticket.consume(for: session) else { throw .authorizationInvalid }
    }
}
