import VaultCore

/// Formats of the identifiers only a manifest names: target names, and Vercel projects and teams
/// as written in `fxvault.yml` (lowercase slugs or ids). Key Vault vault names and Supabase
/// project refs use ``DestinationRules``, like every other destination. ASCII only.
public enum ManifestIdentifierValidator {
    /// Prefix of a Vercel project id (`prj_…`).
    public static let vercelProjectIDPrefix = "prj_"
    /// Prefix of a Vercel team id (`team_…`).
    public static let vercelTeamIDPrefix = "team_"

    private static let hyphen = UInt8(ascii: "-")
    private static let underscore = UInt8(ascii: "_")
    private static let period = UInt8(ascii: ".")

    /// `[a-z][a-z0-9-]{0,31}`.
    public static func isValidTargetName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, ASCII.isLowercaseLetter(first),
              bytes.count <= EnvToolsLimits.maxManifestTargetNameLength else { return false }
        return bytes.allSatisfy { ASCII.isLowercaseLetter($0) || ASCII.isDigit($0) || $0 == hyphen }
    }

    /// Vercel project: 1–100 characters of `[a-z0-9._-]`, or a `prj_` id (`prj_` and ASCII
    /// letters and digits, 100 characters at most).
    public static func isValidVercelProject(_ project: String) -> Bool {
        let bytes = Array(project.utf8)
        guard (1...DestinationRules.maxVercelIdentifierLength).contains(bytes.count) else { return false }
        if isID(bytes, prefix: vercelProjectIDPrefix) { return true }
        return bytes.allSatisfy {
            ASCII.isLowercaseLetter($0) || ASCII.isDigit($0) || $0 == period || $0 == underscore || $0 == hyphen
        }
    }

    /// Vercel team: 1–48 characters of `[a-z0-9-]`, or a `team_` id (`team_` and ASCII letters
    /// and digits, 48 characters at most).
    public static func isValidVercelTeam(_ team: String) -> Bool {
        let bytes = Array(team.utf8)
        guard (1...EnvToolsLimits.maxManifestVercelTeamLength).contains(bytes.count) else { return false }
        if isID(bytes, prefix: vercelTeamIDPrefix) { return true }
        return bytes.allSatisfy { ASCII.isLowercaseLetter($0) || ASCII.isDigit($0) || $0 == hyphen }
    }

    /// `prefix` followed by at least one ASCII letter or digit.
    private static func isID(_ bytes: [UInt8], prefix: String) -> Bool {
        let prefixBytes = Array(prefix.utf8)
        guard bytes.count > prefixBytes.count, bytes.starts(with: prefixBytes) else { return false }
        return bytes.dropFirst(prefixBytes.count).allSatisfy(ASCII.isAlphanumeric)
    }
}
