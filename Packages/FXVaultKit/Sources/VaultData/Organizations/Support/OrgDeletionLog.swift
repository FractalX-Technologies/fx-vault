import Foundation
import os
import VaultCore

/// Organization items FX Vault's own Sync deleted, for D28's suppression (as a repository's
/// drift check does): GitHub's listing can still show a name right after its deletion, and
/// Refresh would report it as added on GitHub. Organization Sync keeps no journal, so the log
/// lives in memory for `Timeouts.recentDeletionSuppression`; Sync and Refresh share one.
public final class OrgDeletionLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[OrganizationID: [String: Date]]>(initialState: [:])

    public init() {}

    /// `key` is an ``OrgItemKey``.
    func record(_ key: String, organizationID: OrganizationID, at date: Date) {
        entries.withLock { $0[organizationID, default: [:]][key] = date }
    }

    /// The keys deleted within the suppression window before `now`.
    func recentKeys(organizationID: OrganizationID, now: Date) -> Set<String> {
        let since = now.addingTimeInterval(-Timeouts.recentDeletionSuppression.timeInterval)
        return entries.withLock { entries in
            let recent = (entries[organizationID] ?? [:]).filter { $0.value >= since }
            entries[organizationID] = recent
            return Set(recent.keys)
        }
    }
}
