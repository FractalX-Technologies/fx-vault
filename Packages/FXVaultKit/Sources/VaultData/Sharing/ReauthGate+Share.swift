import Foundation
import VaultCore

extension ReauthGate {
    /// Re-authenticates for a share (``ReauthPurpose/share`` or ``ReauthPurpose/nearbySend``)
    /// and returns the single-use authorization ``SharingRepository`` requires.
    ///
    /// - Parameter session: the session the share reads from (the app's only session).
    /// - Throws: whatever ``authorize(_:with:)`` throws (`VaultError.locked`, `.wrongPassword`,
    ///   `.cancelled`, `.passwordRequired`, ...).
    public func authorizeShare(
        _ purpose: ShareAuthorizationPurpose,
        with credential: ReauthCredential,
        session: VaultSession
    ) async throws -> ShareAuthorizationModel {
        try await authorize(purpose.reauthPurpose, with: credential)
        return ShareAuthorizationModel(purpose: purpose, session: session)
    }
}
