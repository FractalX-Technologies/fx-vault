/// Every numeric limit FX Vault enforces (tasks/todo.md §4.7: no magic numbers).
///
/// Counts, sizes and retry caps live here; durations live in ``Timeouts``.
/// Sources: GitHub's documented limits (secrets, variables, names), the plan's throttle and
/// retry policy (D12, §7.3), the key hierarchy (§5.1–§5.3), the `.fxvault` layout (§9.1) and
/// the nearby protocol (§9.4). Values marked "local choice" are not GitHub limits.
public enum Limits {
    // MARK: - Units

    /// Bytes in one KiB.
    public static let bytesPerKiB = 1024
    /// Bytes in one MiB.
    public static let bytesPerMiB = 1024 * 1024
    /// Bytes in one GiB.
    public static let bytesPerGiB = 1024 * 1024 * 1024

    // MARK: - Values (D32, §7.3)

    /// Largest value GitHub accepts for one secret or variable, in bytes, after trailing CR/LF
    /// normalization. GitHub documents "48 KB"; the plan fixes it at 48,000 bytes.
    public static let maxValueBytes = 48_000
    /// Combined size of repository variables above which preflight warns (GitHub: 256 KB per
    /// workflow run for organization plus repository variables).
    public static let repoVariablesWarningBytes = 256 * bytesPerKiB

    // MARK: - Items per scope (GitHub)

    /// Secrets per repository.
    public static let maxSecretsPerRepository = 100
    /// Secrets per environment.
    public static let maxSecretsPerEnvironment = 100
    /// Variables per repository.
    public static let maxVariablesPerRepository = 500
    /// Variables per environment.
    public static let maxVariablesPerEnvironment = 100

    /// The GitHub item limit for one kind at one scope level.
    public static func maxItems(kind: ConfigKind, level: ConfigScopeLevel) -> Int {
        switch (kind, level) {
        case (.secret, .repository): maxSecretsPerRepository
        case (.secret, .environment): maxSecretsPerEnvironment
        case (.variable, .repository): maxVariablesPerRepository
        case (.variable, .environment): maxVariablesPerEnvironment
        }
    }

    // MARK: - Names

    /// Longest secret or variable name (database CHECK; GitHub documents no smaller limit).
    public static let maxConfigNameLength = 255
    /// Longest environment name, in Unicode scalars (GitHub; matches SQLite `length()`).
    public static let maxEnvironmentNameLength = 255
    /// Longest repository name (GitHub).
    public static let maxRepoNameLength = 100
    /// Longest GitHub user or organization login on github.com. Enterprise Managed User logins
    /// (`handle_shortcode`) share it: GitHub counts the underscore and the short code toward the
    /// 39 characters ("Username considerations for external authentication").
    public static let maxOwnerLoginLength = 39
    /// Longest folder name, in Unicode scalars (v0.7.0). Local choice.
    public static let maxFolderNameLength = 64
    /// Longest deployment branch or tag pattern, in Unicode scalars.
    public static let maxBranchPatternLength = 255
    /// Most deployment branch patterns accepted per environment (share validator, §9.3).
    public static let maxBranchPatternsPerEnvironment = 50
    /// Largest sanitized display name, in UTF-8 bytes (nearby HELLO, §9.4).
    public static let maxDisplayNameBytes = 63
    /// Percent-decoding passes ``PathSegmentValidator`` applies when looking for hidden dot
    /// segments (`%2E`, `%252E`, ...). Local choice.
    public static let maxPercentDecodingPasses = 4

    // MARK: - Folders (v0.7.0)

    /// Most secrets and variables one folder holds. Local choice: keeps a folder within one
    /// share package and one chat card.
    public static let maxFolderItems = 1000

    // MARK: - Write throttle and retries (D12, §7.3)

    /// FX Vault's own cap on gh write commands per minute, per account.
    public static let writesPerMinute = 60
    /// FX Vault's own cap on gh write commands per hour, per account.
    public static let writesPerHour = 450
    /// Writes in one batch after which a gap of ``Timeouts/writeBatchGap`` is inserted.
    public static let writeBatchGapThreshold = 10
    /// Throttle cost of a write that issues one request.
    public static let defaultWriteCost = 1
    /// Throttle cost of `gh variable set` on an existing variable (POST, 409, then PATCH).
    public static let variableUpdateWriteCost = 2
    /// Retries after a rate-limit error before the run stops (each after
    /// ``Timeouts/rateLimitBackoff``).
    public static let rateLimitRetries = 2
    /// Retries of an idempotent command (set, delete, environment PUT) after a 5xx or
    /// network error.
    public static let idempotentRetries = 2
    /// Drift passes a `verify_state = pending` row survives before it counts as a failed push.
    /// Local choice; the M3 spike may refine it.
    public static let pendingVerifyChecks = 3
    /// `git clone` attempts after exit 128 (§8 D3).
    public static let cloneRetries = 3

    // MARK: - gh listing (§8 A5, B1)

    /// `--limit` for `gh repo list`. A result of exactly this size shows "List truncated".
    /// Local choice.
    public static let repoListMax = 1000
    /// `--limit` for `gh org list`. Local choice.
    public static let orgListMax = 300
    /// Minimum supported gh version (D5); parsed by GitHubKit.
    public static let minimumGHVersion = "2.97.0"

    // MARK: - Process runner (§5.10)

    /// Largest stdout captured from a child process.
    public static let maxStdoutBytes = 32 * bytesPerMiB
    /// Largest stderr captured from a child process.
    public static let maxStderrBytes = 1 * bytesPerMiB

    // MARK: - Master password and recovery (D8, D9, §5.3)

    /// Shortest accepted master password, in characters.
    public static let minPasswordLength = 12
    /// Lowest accepted estimated password strength, in bits.
    public static let minPasswordStrengthBits = 60
    /// Words in a generated passphrase (master password suggestion and `.fxvault` passphrase).
    public static let passphraseWordCount = 6
    /// Recovery key size in bytes.
    public static let recoveryKeyBytes = 32
    /// Recovery key checksum size in bytes.
    public static let recoveryChecksumBytes = 3
    /// Recovery key length in Crockford Base32 characters.
    public static let recoveryKeyCharacters = 56
    /// Characters per displayed recovery key group.
    public static let recoveryKeyGroupSize = 4
    /// Groups in a displayed recovery key.
    public static let recoveryKeyGroupCount = 14
    /// Groups the user re-enters during onboarding.
    public static let recoveryConfirmGroupCount = 2

    // MARK: - Key hierarchy (§5.1, §5.2)

    /// DEK size in bytes (AES-256).
    public static let dekBytes = 32
    /// Size of `vault_id` in bytes.
    public static let vaultIDBytes = 16
    /// Size of the key-check value in bytes.
    public static let kcvBytes = 16
    /// Argon2id salt size in bytes.
    public static let kdfSaltBytes = 16
    /// AES-GCM nonce size in bytes.
    public static let gcmNonceBytes = 12
    /// AES-GCM tag size in bytes.
    public static let gcmTagBytes = 16
    /// Size of `key_wraps.wrapped_dek` in bytes.
    public static let wrappedDEKBytes = 62
    /// Argon2id operations limit for the master password (moderate).
    public static let passwordKDFOpsLimit = 3
    /// Argon2id memory limit for the master password, in bytes (256 MiB).
    public static let passwordKDFMemoryBytes = 256 * bytesPerMiB
    /// Lowest accepted stored Argon2id operations limit.
    public static let passwordKDFOpsLimitMin = 2
    /// Highest accepted stored Argon2id operations limit.
    public static let passwordKDFOpsLimitMax = 10
    /// Lowest accepted stored Argon2id memory limit, in bytes (64 MiB).
    public static let passwordKDFMemoryBytesMin = 64 * bytesPerMiB
    /// Highest accepted stored Argon2id memory limit, in bytes (1 GiB).
    public static let passwordKDFMemoryBytesMax = 1 * bytesPerGiB
    /// Argon2id operations limit for tests and previews only (libsodium's minimum). Outside the
    /// production bounds on purpose; only `KDFBounds.testing` accepts it.
    public static let passwordKDFTestingOpsLimit = 1
    /// Argon2id memory limit for tests and previews only, in bytes (8 MiB).
    public static let passwordKDFTestingMemoryBytes = 8 * bytesPerMiB

    // MARK: - Sharing (§9.1, §9.3)

    /// Largest decrypted share payload (JSON), in bytes.
    public static let maxSharePayloadBytes = 16 * bytesPerMiB
    /// Fixed `.fxvault` v1 header length.
    public static let shareHeaderBytes = 64
    /// Largest accepted `.fxvault` file: payload plus header plus GCM tag.
    public static let maxShareFileBytes = maxSharePayloadBytes + shareHeaderBytes + gcmTagBytes
    /// Argon2id operations limit written into new `.fxvault` files.
    public static let shareKDFOpsLimit = 3
    /// Argon2id memory limit written into new `.fxvault` files, in KiB (64 MiB).
    public static let shareKDFMemoryKiB = 64 * bytesPerKiB
    /// Lowest accepted `.fxvault` operations limit.
    public static let shareKDFOpsLimitMin = 1
    /// Highest accepted `.fxvault` operations limit.
    public static let shareKDFOpsLimitMax = 10
    /// Lowest accepted `.fxvault` memory limit, in KiB.
    public static let shareKDFMemoryKiBMin = 8 * bytesPerKiB
    /// Highest accepted `.fxvault` memory limit, in KiB (1 GiB).
    public static let shareKDFMemoryKiBMax = 1 * bytesPerMiB

    // MARK: - Nearby (§9.4)

    /// Largest plaintext handshake frame.
    public static let maxNearbyHandshakeFrameBytes = 512
    /// Largest encrypted frame.
    public static let maxNearbyEncryptedFrameBytes = 64 * bytesPerKiB
    /// Largest nearby payload.
    public static let maxNearbyPayloadBytes = 16 * bytesPerMiB
    /// Exclusive upper bound for frame sequence numbers.
    public static let maxNearbySequence: UInt64 = 1 << 32
    /// Digits in the short authentication string.
    public static let nearbySASDigits = 6
    /// Failed handshakes in a row after which the interception warning is shown.
    public static let nearbyFailedHandshakeWarningThreshold = 2
}
