extension ReauthGate {
    /// Re-authenticates for a `.env` export (``ReauthPurpose/export``) and returns the
    /// single-use authorization ``EnvFileRepository`` requires.
    ///
    /// - Parameter session: the session the export will read from (the app's only session).
    /// - Throws: whatever ``authorize(_:with:)`` throws (`VaultError.locked`, `.wrongPassword`,
    ///   `.cancelled`, `.passwordRequired`, ...).
    public func authorizeEnvExport(
        with credential: ReauthCredential,
        session: VaultSession
    ) async throws -> EnvExportAuthorizationModel {
        try await authorize(.export, with: credential)
        return EnvExportAuthorizationModel(session: session)
    }
}
