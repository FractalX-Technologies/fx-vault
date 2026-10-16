/// Every duration FX Vault uses (tasks/todo.md §4.7: no magic numbers).
///
/// Values are `Duration`s so they work with ``VaultClock/sleep(for:)`` and `Task.sleep(for:)`.
/// Integer seconds are provided where a value must appear in an argv string.
public enum Timeouts {
    // MARK: - Units

    /// Seconds in one minute.
    public static let secondsPerMinute: Int64 = 60
    /// Seconds in one hour.
    public static let secondsPerHour: Int64 = 60 * secondsPerMinute
    /// Seconds in one day.
    public static let secondsPerDay: Int64 = 24 * secondsPerHour

    // MARK: - Process runner (§5.10)

    /// `gh auth token`.
    public static let ghAuthToken: Duration = .seconds(60)
    /// Every other gh command.
    public static let ghDefault: Duration = .seconds(30)
    /// `gh repo list`.
    public static let ghRepoList: Duration = .seconds(120)
    /// `ssh -T` alias verification.
    public static let sshVerify: Duration = .seconds(15)
    /// Login-shell environment probe.
    public static let shellProbe: Duration = .seconds(5)
    /// `git clone`.
    public static let gitClone: Duration = .seconds(300)
    /// Grace period between SIGTERM and SIGKILL after a timeout.
    public static let processKillGrace: Duration = .seconds(2)
    /// `ConnectTimeout` passed to ssh inside `GIT_SSH_COMMAND` (argv, seconds).
    public static let gitSSHConnectTimeoutSeconds = 15
    /// `ConnectTimeout` passed to `ssh -T` when verifying an alias (argv, seconds).
    public static let sshVerifyConnectTimeoutSeconds = 10

    // MARK: - Sync (D12, §7.3)

    /// Fixed wait after a rate-limit error (gh exposes no `retry-after`).
    public static let rateLimitBackoff: Duration = .seconds(60)
    /// Base wait before retrying an idempotent command after a 5xx or network error.
    /// Local choice; doubled for the second retry.
    public static let idempotentRetryBackoff: Duration = .seconds(2)
    /// Gap between writes once a batch exceeds ``Limits/writeBatchGapThreshold``.
    public static let writeBatchGap: Duration = .seconds(1)
    /// Window for the per-minute write throttle.
    public static let throttleMinuteWindow: Duration = .seconds(secondsPerMinute)
    /// Window for the per-hour write throttle (also seeds it from the journal).
    public static let throttleHourWindow: Duration = .seconds(secondsPerHour)
    /// Interval between verification re-lists after a write.
    public static let verifyRetryInterval: Duration = .seconds(2)
    /// Total time spent re-listing before a write stays `verify_state = pending`.
    public static let verifyRetryWindow: Duration = .seconds(60)
    /// Window after a repository create during which "not found" is a propagation delay.
    public static let freshRepoWindow: Duration = .seconds(90)
    /// Interval between "not found" retries inside the freshRepo window.
    public static let freshRepoRetryInterval: Duration = .seconds(1)
    /// Longest time "not found" is retried inside the freshRepo window.
    public static let freshRepoRetryWindow: Duration = .seconds(60)
    /// Wait between `git clone` attempts after exit 128.
    public static let cloneRetryInterval: Duration = .seconds(3)
    /// Journal rows older than this are deleted at launch (the latest run is kept).
    public static let syncJournalRetention: Duration = .seconds(secondsPerDay)

    // MARK: - Drift (§7.7)

    /// Minimum time between automatic drift checks of one repository.
    public static let driftDebounce: Duration = .seconds(2 * secondsPerMinute)
    /// Names deleted this recently (per the journal) are not reported as "remote added".
    public static let recentDeletionSuppression: Duration = .seconds(10 * secondsPerMinute)

    // MARK: - Lock and authentication (§5.5, §5.7)

    /// Default inactivity auto-lock.
    public static let autoLockDefault: Duration = .seconds(5 * secondsPerMinute)
    /// Auto-lock choices offered in Preferences, in minutes.
    public static let autoLockOptionMinutes: [Int] = [1, 2, 5, 10, 15, 30, 60]
    /// Default auto-lock choice, in minutes (stored in UserDefaults).
    public static let autoLockDefaultMinutes = 5
    /// How often the inactivity timer checks the last interaction.
    public static let autoLockCheckInterval: Duration = .seconds(15)
    /// Longest time since the last master-password unlock before Touch ID is refused.
    public static let passwordMaxAge: Duration = .seconds(14 * secondsPerDay)

    /// The auto-lock duration for a minutes value from Preferences.
    public static func autoLock(minutes: Int) -> Duration {
        .seconds(Int64(minutes) * secondsPerMinute)
    }

    // MARK: - Clipboard and reveal (§5.9, §5.11)

    /// The clipboard is cleared this long after a copy, if nothing else wrote to it.
    public static let clipboardClear: Duration = .seconds(30)
    /// A revealed value is masked again after this long.
    public static let revealRemask: Duration = .seconds(30)

    // MARK: - Sharing (§9.4, §9.5)

    /// Nearby handshake (HELLO through REVEAL).
    public static let nearbyHandshake: Duration = .seconds(30)
    /// Time the users have to compare the SAS.
    public static let nearbySAS: Duration = .seconds(120)
    /// Longest silence on an established nearby session.
    public static let nearbyIdle: Duration = .seconds(30)
    /// Longest nearby session.
    public static let nearbySession: Duration = .seconds(10 * secondsPerMinute)
    /// A share package older than this raises the replay warning.
    public static let shareReplayMaxAge: Duration = .seconds(7 * secondsPerDay)

    // MARK: - Shared spaces (v0.6.0, S6)

    /// Longest space sync session between two teammates (handshake, heads, every version).
    public static let spaceSyncSession: Duration = .seconds(2 * secondsPerMinute)
    /// How often an unlocked Mac syncs its spaces with the teammates it can reach.
    public static let spaceSyncInterval: Duration = .seconds(2 * secondsPerMinute)
}
