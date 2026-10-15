import GitHubKit
import os

/// Constants of the vault core (no magic numbers, §4.7). Limits and durations shared with other
/// modules live in VaultCore `Limits` / `Timeouts`.
enum VaultManagerConstants {
    /// The `vault` logger (§4.5). Logs states, counts and OSStatus codes; never keys, passwords,
    /// recovery keys or values.
    static let log = Logger(subsystem: GHConstants.logSubsystem, category: "vault")
    /// Label of the queue that runs blocking Touch ID keychain reads.
    static let keychainQueueLabel = GHConstants.logSubsystem + ".keychain"
}
