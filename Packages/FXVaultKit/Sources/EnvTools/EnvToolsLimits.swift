import VaultCore

/// Numeric limits and heuristic thresholds used by EnvTools (tasks/todo.md §4.7: no magic
/// numbers). Thresholds marked "local choice" are FX Vault decisions, not GitHub limits.
public enum EnvToolsLimits {
    // MARK: - .env files

    /// Largest `.env` file the parser accepts, in bytes (local choice). A scope holds at most
    /// 500 items of at most 48,000 bytes, so real files are far smaller.
    public static let maxEnvFileBytes = 8 * Limits.bytesPerMiB

    // MARK: - Key fixes

    /// Highest numeric suffix ``KeyNormalizer/uniqueKey(from:avoiding:)`` tries (`KEY_2` ...
    /// `KEY_99`) before giving up (local choice).
    public static let maxUniqueKeySuffix = 99
    /// First numeric suffix tried for a colliding key (`KEY_2`).
    public static let firstUniqueKeySuffix = 2

    // MARK: - Credential heuristics (§5.13)

    /// Minimum length, in characters, of a value judged by entropy alone.
    public static let entropyMinimumLength = 20
    /// Minimum Shannon entropy, in bits per character, for a value to look random.
    public static let entropyThresholdBitsPerCharacter = 3.5
    /// Minimum number of character classes (lowercase, uppercase, digit) a value judged by
    /// entropy must mix. Rules out long single-case words and paths (local choice).
    public static let entropyMinimumCharacterClasses = 2

    /// Minimum length of a JWT header segment (`eyJ...`); `{"alg":"x"}` is 16 base64url chars.
    public static let jwtMinimumHeaderLength = 10
    /// Minimum length of a JWT payload segment.
    public static let jwtMinimumPayloadLength = 2

    /// Characters required after `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` and `github_pat_`
    /// (matches the StderrRedactor patterns, §4.5).
    public static let gitHubTokenMinimumTailLength = 20
    /// Characters required after `sk_live_`.
    public static let stripeKeyMinimumTailLength = 16
    /// Characters required after `AKIA` (AWS access key IDs are 20 characters in total).
    public static let awsAccessKeyTailLength = 16
    /// Characters required after `xoxb-` / `xoxp-`.
    public static let slackTokenMinimumTailLength = 10
}
