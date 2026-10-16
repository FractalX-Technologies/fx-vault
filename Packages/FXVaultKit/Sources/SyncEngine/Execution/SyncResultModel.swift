import Foundation
import GitHubKit
import VaultCore

/// Why a change was not run (tasks/todo.md §7.1, §7.3 preflight, D27). Wraps the pure model's
/// ``ChangeBlockReason`` and adds the reasons only preflight can know.
public enum SyncBlockReason: Sendable, Hashable {
    /// From the change set (value missing, rename needs values, remote changed, dependency).
    case change(ChangeBlockReason)
    /// The account cannot change this scope (`RepoCapabilityModel`, §2 Permissions).
    case readOnly(RepoCapabilityModel.ReadOnlyReason)
    /// The account's token lacks these scopes (§8 A3).
    case missingScopes([String])
    /// A name failed `GitHubNameValidator` / `EnvironmentNameValidator` / `PathSegmentValidator`.
    case invalidName(ValidationError)
    /// The value is empty or too large after D32 normalization.
    case invalidValue(ValidationError)
    /// The scope would exceed GitHub's item limit (`ScopeCapacityValidator`).
    case scopeFull(ValidationError)
    /// Preflight could not re-list the scopes the change touches (D27 needs them).
    case listingFailed(GHError)
    /// A policy change on an environment that has other protection rules on GitHub (reviewers,
    /// wait timer, app rules). C2 sends only `deployment_branch_policy`, and whether GitHub keeps
    /// the omitted rules is not verified yet (docs/API.md Q6), so FX Vault does not PUT it.
    case protectionRulesPresent
    /// Depends on a change blocked by preflight.
    case dependsOn(changeID: String)
    /// The scope is shared with teammates and its gate does not allow a push (v0.6.0, S5): a
    /// member published versions this Mac does not have, is publishing now, or the marker is
    /// forked or invalid.
    case space(SyncSpaceBlockModel)
    /// A rename or deletion of an environment shared with teammates (not supported in v0.6).
    case sharedEnvironment

    /// True for the reason "Review drift" resolves (§7.4).
    public var isRemoteChanged: Bool {
        self == .change(.remoteChanged)
    }
}

/// Why an executed change failed (§7.4). Failed items stay pending.
public enum SyncFailureReason: Sendable, Hashable {
    /// gh failed; the error says why (admin required, SAML, plan-gated, validation, ...).
    case github(GHError)
    /// The write may or may not have reached GitHub and no re-list confirmed it; launch
    /// reconciliation checks it again (§7.3).
    case indeterminate
    /// The local value is missing (`value_ct IS NULL`).
    case valueMissing
    /// The value is empty or too large after D32 normalization.
    case invalidValue(ValidationError)
    /// The new environment of a guided rename has the old environment's id (§7.6 step 4).
    case renameTargetIsSource
    /// A guided rename's copies were not all verified; the old environment is kept (§7.3).
    case renameNotVerified
    /// An indeterminate `gh repo create` could not be adopted (owner or visibility differ, or
    /// no preflight lookup recorded that the name was free).
    case createConflict
    /// The vault locked mid-change.
    case locked
}

/// Why a change did not run.
public enum SyncSkipReason: Sendable, Hashable {
    /// A change it depends on failed (repository create, environment PUT, rename).
    case dependencyFailed(changeID: String)
    /// The rename partner (the set of the new name) was not verified, so the old name is kept.
    case pairNotVerified(changeID: String)
    /// The run stopped before reaching it.
    case runStopped(SyncStopReason)
    /// The user did not confirm the deletion (§7.5).
    case deletionNotConfirmed
}

/// Why a run stopped early; the remaining changes stay pending (§7.3, §7.4).
public enum SyncStopReason: Sendable, Hashable {
    /// GitHub's rate limit persisted after `Limits.rateLimitRetries` fixed backoffs.
    case rateLimited
    /// FX Vault's own hourly write budget is used up (D12).
    case writeBudgetExhausted
    /// The token stayed invalid after one refresh (§7.3 tokens).
    case tokenRevoked
    /// gh has no logged-in account for the repository's account.
    case notAuthenticated
    /// ``SyncExecutor/cancel()``.
    case cancelled
    /// The vault locked.
    case locked
    /// The journal or the rows could not be written.
    case persistenceFailed

    /// The stop reason a gh failure implies, or nil when the run can continue.
    static func from(_ error: GHError) -> SyncStopReason? {
        switch error {
        case .rateLimited: .rateLimited
        case .writeBudgetExhausted: .writeBudgetExhausted
        case .tokenRevoked: .tokenRevoked
        case .notAuthenticated, .notInstalled, .untrustedBinary, .versionTooOld, .launchFailed: .notAuthenticated
        case .cancelled: .cancelled
        default: nil
        }
    }

    static func from(_ error: SyncError) -> SyncStopReason {
        switch error {
        case .locked, .valueUnavailable: .locked
        case .github(let ghError): from(ghError) ?? .persistenceFailed
        case .accountUnavailable: .notAuthenticated
        case .persistenceFailed, .alreadyRunning: .persistenceFailed
        }
    }
}

/// Whether a succeeded write was confirmed by a re-list (§7.3 step 6).
public enum SyncVerificationState: String, Sendable, Hashable, CaseIterable {
    /// The re-list showed the expected state.
    case verified
    /// Not confirmed within `Timeouts.verifyRetryWindow`: `verify_state = pending`, finished by
    /// the pending-verification pass.
    case pending
    /// Nothing to verify (environment, patterns, deletes confirmed by exit code or re-list).
    case notApplicable
}

/// The outcome of one change.
public enum SyncChangeOutcomeModel: Sendable, Hashable {
    case succeeded(SyncVerificationState)
    case failed(SyncFailureReason)
    case skipped(SyncSkipReason)
    case blocked(SyncBlockReason)

    public var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}

/// One change and its outcome.
public struct SyncChangeResultModel: Sendable, Hashable, Identifiable {
    public var change: ConfigChangeModel
    public var outcome: SyncChangeOutcomeModel

    public init(change: ConfigChangeModel, outcome: SyncChangeOutcomeModel) {
        self.change = change
        self.outcome = outcome
    }

    public var id: String {
        change.id
    }
}

/// Something the user should know that is not a failure (§7.3 step 2, D32).
public enum SyncWarningModel: Sendable, Hashable {
    /// Trailing CR/LF were stripped from this value before the push (D32).
    case valueNormalized(itemID: ConfigItemID, name: String)
    /// The environment's protection rules other than the branch policy changed on GitHub since
    /// they were stored (reviewers, wait timer, app rules).
    case foreignRulesChanged(environmentID: EnvironmentID, name: String)
    /// `gh repo create` succeeded but B2 did not confirm it within the freshRepo window; the
    /// next Sync adopts it (§8 C1).
    case repositoryNotConfirmed(repositoryID: RepoID, name: String)
    /// A repository created with "clone after" (§8 D3); the app clones it with `GitService`.
    case cloneRequested(repositoryID: RepoID)
    /// The shared space's version was recorded but its `published` marker was not confirmed on
    /// GitHub (or the version could not be recorded); the next Sync or launch finishes it.
    case spaceNotPublished(spaceID: SpaceID)
    /// Right after this Mac published, GitHub's marker named another member's version: two
    /// members published at once (S5 residual risk). The scope shows Forked.
    case spaceForked(spaceID: SpaceID)
}

/// The result of one repository.
public struct RepoSyncResultModel: Sendable, Hashable, Identifiable {
    public var repositoryID: RepoID
    public var fullName: String
    /// Every change in canonical order with its outcome.
    public var entries: [SyncChangeResultModel]

    public init(repositoryID: RepoID, fullName: String, entries: [SyncChangeResultModel]) {
        self.repositoryID = repositoryID
        self.fullName = fullName
        self.entries = entries
    }

    public var id: RepoID {
        repositoryID
    }
}

/// The result view's data (§7.4): **Succeeded / Failed / Skipped / Blocked**.
public struct SyncResultModel: Sendable, Hashable {
    public var runID: SyncRunID
    public var repositories: [RepoSyncResultModel]
    /// Set when the run stopped early.
    public var stopReason: SyncStopReason?
    public var warnings: [SyncWarningModel]

    public init(
        runID: SyncRunID,
        repositories: [RepoSyncResultModel],
        stopReason: SyncStopReason?,
        warnings: [SyncWarningModel]
    ) {
        self.runID = runID
        self.repositories = repositories
        self.stopReason = stopReason
        self.warnings = warnings
    }

    public var entries: [SyncChangeResultModel] {
        repositories.flatMap(\.entries)
    }

    public var succeeded: [SyncChangeResultModel] {
        entries.filter(\.outcome.isSucceeded)
    }

    public var failed: [SyncChangeResultModel] {
        entries.filter { if case .failed = $0.outcome { true } else { false } }
    }

    public var skipped: [SyncChangeResultModel] {
        entries.filter { if case .skipped = $0.outcome { true } else { false } }
    }

    public var blocked: [SyncChangeResultModel] {
        entries.filter { if case .blocked = $0.outcome { true } else { false } }
    }

    /// The outcome of the change with `id`.
    public func outcome(of id: String) -> SyncChangeOutcomeModel? {
        entries.first { $0.change.id == id }?.outcome
    }
}

/// Progress of a running sync (``SyncExecutor/progress``).
public enum SyncProgressEventModel: Sendable, Hashable {
    /// The run started with this many changes to attempt.
    case started(total: Int)
    /// A gh command for this change is about to run.
    case changeStarted(changeID: String)
    /// The change reached its final outcome.
    case changeFinished(SyncChangeResultModel, completed: Int, total: Int)
    /// Re-listing a scope to verify its writes.
    case verifying(RemoteScopeKeyModel)
    /// The run finished; the stream ends after this event.
    case finished(SyncResultModel)
}
