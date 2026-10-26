extension ReauthGate {
    /// Re-authenticates for a `.env` file or Copy All and returns the single-use authorization
    /// ``EnvFileRepository`` requires, bound to `session` (the one the export reads from).
    ///
    /// - Throws: whatever ``authorize(_:with:)`` throws (`.locked`, `.wrongPassword`, `.cancelled`, ...).
    public func authorizeEnvExport(
        _ purpose: EnvExportPurpose = .file,
        with credential: ReauthCredential,
        session: VaultSession
    ) async throws -> EnvExportAuthorizationModel {
        try await authorize(purpose.reauthPurpose, with: credential)
        return EnvExportAuthorizationModel(purpose: purpose, session: session)
    }
}
