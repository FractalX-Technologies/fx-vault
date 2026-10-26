import Foundation

/// Where a plaintext export authorization lets the values go (D30).
public enum EnvExportPurpose: String, Sendable, Hashable, CaseIterable {
    /// A `.env` file (``ReauthPurpose/export``).
    case file
    /// The clipboard, as Copy All's `.env` text (1.0 D6c4, ``ReauthPurpose/copyAll``).
    case clipboard

    var reauthPurpose: ReauthPurpose {
        switch self {
        case .file: .export
        case .clipboard: .copyAll
        }
    }
}

/// Proof of a fresh Touch ID or master-password check before a plaintext export (D30, §5.6).
/// Only ``ReauthGate/authorizeEnvExport(_:with:session:)`` makes one, so ``EnvFileRepository``
/// writes no `.env` file and builds no Copy All text without it. Single-use, for one purpose and
/// one session: a lock, unlock or key rotation in between invalidates it.
public final class EnvExportAuthorizationModel: Sendable {
    public let purpose: EnvExportPurpose
    private let ticket: ReauthTicket

    init(purpose: EnvExportPurpose = .file, session: VaultSession) {
        self.purpose = purpose
        ticket = ReauthTicket(session: session)
    }

    /// True until the authorization has been used.
    public var isUsable: Bool {
        ticket.isUsable
    }

    /// Marks the authorization used for `purpose` in `session`.
    ///
    /// - Throws: ``EnvFileError/authorizationInvalid`` when it was already used, is for another
    ///   purpose or session, or the session's keys changed since it was granted.
    func consume(_ purpose: EnvExportPurpose, for session: VaultSession) throws(EnvFileError) {
        guard purpose == self.purpose, ticket.consume(for: session) else { throw .authorizationInvalid }
    }
}
