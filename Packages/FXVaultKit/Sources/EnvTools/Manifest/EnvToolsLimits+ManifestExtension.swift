import VaultCore

/// Limits for `fxvault.yml` manifests (``ManifestParser``). Counts and sizes are local choices;
/// identifier lengths follow the providers' documented formats.
extension EnvToolsLimits {
    // MARK: - fxvault.yml manifests

    /// Largest manifest the parser reads, in UTF-8 bytes. A manifest lists names only, so even
    /// the largest allowed one (``maxManifestVars`` variables) fits easily.
    public static let maxManifestBytes = 64 * Limits.bytesPerKiB
    /// Most stages a manifest may declare.
    public static let maxManifestStages = 20
    /// Most targets a manifest may define.
    public static let maxManifestTargets = 64
    /// Most variables a manifest may list.
    public static let maxManifestVars = 1_000
    /// Deepest nesting of mappings and sequences the reader accepts (the root mapping is 1).
    public static let maxManifestNestingDepth = 8

    // MARK: - Manifest identifiers

    /// Longest target name (`[a-z][a-z0-9-]{0,31}`).
    public static let maxManifestTargetNameLength = 32
    /// Longest Vercel team slug or `team_` id in a manifest (Vercel's slug limit). Projects use
    /// ``DestinationRules/maxVercelIdentifierLength``.
    public static let maxManifestVercelTeamLength = 48
}
