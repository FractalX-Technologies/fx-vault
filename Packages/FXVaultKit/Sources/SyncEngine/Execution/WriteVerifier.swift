import Foundation
import GitHubKit
import VaultCore

/// Verification by native re-list (tasks/todo.md §7.3 step 6, D13). Pure rules plus the
/// pending-verification pass that runs before ``DriftDetector`` on every drift run (§7.7).
///
/// - Variable: verified when the listed value's fingerprint equals the fingerprint of the bytes
///   gh received (the normalized value, D32).
/// - Secret: verified when it is listed and its `updatedAt` differs from the pre-write value
///   (`pre_write_updated_at`; nil means the name was not listed before the write, so being
///   listed is enough). Then `remote_updated_at := updatedAt`.
public enum WriteVerifier {
    /// The secret rule.
    public static func isSecretVerified(listed: RemoteSecretModel?, preWriteUpdatedAt: Date?) -> Bool {
        guard let listed else { return false }
        guard let preWriteUpdatedAt else { return true }
        return !DriftDetector.isSameTimestamp(listed.updatedAt, preWriteUpdatedAt)
    }

    /// The variable rule.
    public static func isVariableVerified(listedFingerprint: Data?, expected: Data) -> Bool {
        listedFingerprint == expected
    }

    /// The pending-verification pass (§7.3 step 6) over one repository's fresh re-list.
    ///
    /// For every `verify_state = pending` row whose scope was listed:
    /// - variable: listed fingerprint equals `synced_fp` (the pushed fingerprint) → verified;
    /// - secret: listed with `updatedAt` ≠ `pre_write_updated_at` → verified,
    ///   `remote_updated_at := updatedAt`;
    /// - otherwise, with `countsMisses`, the row's miss count grows; at
    ///   `Limits.pendingVerifyChecks` the row becomes verified as a failed push: a secret gets
    ///   `force_push := 1` (pending re-push) and `remote_updated_at := pre_write_updated_at`
    ///   (the base its write was checked against), a variable is left to ``DriftDetector``.
    ///
    /// The miss counts are the caller's (the schema has no column for them); pass the previous
    /// result's ``PendingVerificationPassModel/failedChecks``. Sync preflight runs the pass with
    /// `countsMisses: false`, so only drift runs count.
    public static func pendingVerificationPass(
        local: RepoSnapshotModel,
        remote: RemoteSnapshotModel,
        failedChecks: [ConfigItemID: Int] = [:],
        countsMisses: Bool = true
    ) -> PendingVerificationPassModel {
        var snapshot = local
        var checks = failedChecks
        var effects: [SyncStateEffectModel] = []
        var verified: [ConfigItemID] = []
        var expired: [ConfigItemID] = []
        let environments = Dictionary(local.environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for index in snapshot.items.indices where snapshot.items[index].verifyState == .pending {
            let row = snapshot.items[index]
            guard let listing = listing(of: row, environments: environments, remote: remote) else { continue }
            let nameKey = row.syncedNameKey ?? row.nameKey
            if let remoteUpdatedAt = verifiedTimestamp(row, nameKey: nameKey, listing: listing) {
                effects.append(.itemVerified(itemID: row.id, remoteUpdatedAt: remoteUpdatedAt))
                snapshot.items[index].verifyState = .verified
                snapshot.items[index].remoteUpdatedAt = remoteUpdatedAt
                checks[row.id] = nil
                verified.append(row.id)
                continue
            }
            guard countsMisses else { continue }
            let misses = (checks[row.id] ?? 0) + 1
            guard misses >= Limits.pendingVerifyChecks else {
                checks[row.id] = misses
                continue
            }
            let forcePush = row.kind == .secret
            effects.append(.itemVerificationExpired(itemID: row.id, forcePush: forcePush))
            snapshot.items[index].verifyState = .verified
            if forcePush {
                snapshot.items[index].forcePush = true
                if let baseline = row.preWriteUpdatedAt { snapshot.items[index].remoteUpdatedAt = baseline }
            }
            checks[row.id] = nil
            expired.append(row.id)
        }
        return PendingVerificationPassModel(
            snapshot: snapshot,
            effects: effects,
            failedChecks: checks,
            verified: verified,
            expired: expired
        )
    }

    /// `.some(updatedAt)` when the row's write is confirmed by `listing`, nil otherwise.
    private static func verifiedTimestamp(
        _ row: ConfigItemSnapshotModel,
        nameKey: String,
        listing: RemoteScopeListingModel
    ) -> Date?? {
        switch row.kind {
        case .secret:
            let listed = listing.secret(nameKey: nameKey)
            guard isSecretVerified(listed: listed, preWriteUpdatedAt: row.preWriteUpdatedAt) else { return nil }
            return .some(listed?.updatedAt)
        case .variable:
            guard let listed = listing.variable(nameKey: nameKey),
                  let expected = row.syncedFingerprint,
                  isVariableVerified(listedFingerprint: listed.fingerprint(for: row.id), expected: expected)
            else { return nil }
            return .some(listed.updatedAt)
        }
    }

    private static func listing(
        of row: ConfigItemSnapshotModel,
        environments: [EnvironmentID: EnvironmentModel],
        remote: RemoteSnapshotModel
    ) -> RemoteScopeListingModel? {
        guard let environmentID = row.scope.environmentID else { return remote.repository }
        guard let environment = environments[environmentID] else { return nil }
        return remote.listing(.environment(named: environment.syncedName ?? environment.name))
    }
}

/// The outcome of ``WriteVerifier/pendingVerificationPass(local:remote:failedChecks:countsMisses:)``.
public struct PendingVerificationPassModel: Sendable, Hashable {
    /// The input snapshot with the resolved rows updated: pass it to ``DriftDetector``.
    public var snapshot: RepoSnapshotModel
    /// Commit these (``SyncPersisting/commit(_:)``) before acting on drift findings.
    public var effects: [SyncStateEffectModel]
    /// Miss counts of rows still pending; keep them for the next pass.
    public var failedChecks: [ConfigItemID: Int]
    public var verified: [ConfigItemID]
    /// Rows that gave up (secrets now `force_push`).
    public var expired: [ConfigItemID]
}
