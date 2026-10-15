import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultStore

/// One drift check of a repository (§7.7): the findings plus what could not be compared.
public struct DriftReportModel: Sendable, Hashable, Identifiable {
    public var repositoryID: RepoID
    /// When the re-list ran (the banner's "checked at").
    public var checkedAt: Date
    /// Findings, sorted by target; each carries both resolutions.
    public var drifts: [DriftModel]
    /// Reads that failed for the viewer's rights or the plan (admin required, SAML, ...): those
    /// scopes were not compared. An `.environments` failure means environments were not
    /// compared at all.
    public var unreadable: [ImportReadFailureModel]
    /// Rows the pending-verification pass confirmed (§7.3 step 6).
    public var verifiedItems: [ConfigItemID]
    /// Rows the pass gave up on after `Limits.pendingVerifyChecks` checks (a secret is pushed
    /// again, a variable is left to drift).
    public var expiredItems: [ConfigItemID]
    /// Remote names the vault cannot hold (D29), never acted on.
    public var skippedNames: [SkippedRemoteNameModel]

    public init(
        repositoryID: RepoID,
        checkedAt: Date,
        drifts: [DriftModel] = [],
        unreadable: [ImportReadFailureModel] = [],
        verifiedItems: [ConfigItemID] = [],
        expiredItems: [ConfigItemID] = [],
        skippedNames: [SkippedRemoteNameModel] = []
    ) {
        self.repositoryID = repositoryID
        self.checkedAt = checkedAt
        self.drifts = drifts
        self.unreadable = unreadable
        self.verifiedItems = verifiedItems
        self.expiredItems = expiredItems
        self.skippedNames = skippedNames
    }

    public var id: RepoID {
        repositoryID
    }

    /// The banner count ("3 changes on GitHub — Review").
    public var count: Int {
        drifts.count
    }

    /// Findings that are also pending locally (§7.7 "Conflict").
    public var conflicts: [DriftModel] {
        drifts.filter(\.isConflict)
    }
}

/// What a resolution did, and what the UI does next.
public struct DriftResolutionResultModel: Sendable, Hashable {
    /// The resolved finding.
    public var driftID: String
    public var option: DriftResolutionOption
    /// `promptFillValue(id)`: open the value editor in fill mode and call
    /// ``DriftRepository/enterNewValue(_:value:pushOnNextSync:)`` (§7.7 secret "Accept GitHub").
    public var followUp: DriftFollowUpModel?

    public init(driftID: String, option: DriftResolutionOption, followUp: DriftFollowUpModel?) {
        self.driftID = driftID
        self.option = option
        self.followUp = followUp
    }
}

/// Why a ``DriftRepository`` operation failed (§4.4). No names, values or localized text.
public enum DriftRepositoryError: Error, Sendable, Hashable {
    case repositoryNotFound
    /// The chosen resolution cannot be applied (for example "Keep local" without a value).
    case resolutionUnavailable(DriftUnavailableReason)
    /// GitHub changed again since the check (or the local row changed): refresh and review.
    case stale
    case github(GHError)
    /// The value entered for a secret was refused (empty, too large, not value-missing, ...).
    case config(ConfigRepositoryError)
    /// A listed name the vault cannot hold.
    case validation(ValidationError)
    case vault(VaultError)
    case store(StoreError)
    case sync(SyncError)
    /// An error of an unknown type (never expected).
    case unexpected

    static func wrap(_ error: any Error) -> DriftRepositoryError {
        switch error {
        case let error as DriftRepositoryError: error
        case let error as GHError: .github(error)
        case let error as ConfigRepositoryError: .config(error)
        case let error as ValidationError: .validation(error)
        case let error as VaultError: .vault(error)
        case let error as SyncError: error == .locked ? .vault(.locked) : .sync(error)
        case let error as StoreError: .store(error)
        default: .unexpected
        }
    }
}

/// Runs `body`, mapping whatever it throws to ``DriftRepositoryError``.
func performDrift<Result>(_ body: () throws -> Result) throws(DriftRepositoryError) -> Result {
    do {
        return try body()
    } catch {
        throw DriftRepositoryError.wrap(error)
    }
}

// MARK: - Remote state for a resolution

/// A secret or variable GitHub lists, re-read for a resolution. The value is a variable's
/// listed value (never a secret's: GitHub cannot return those).
struct DriftListedItemModel: Sendable {
    let name: String
    let updatedAt: Date?
    let value: SecretBytes?
}

/// What GitHub has **now** for the subject of one finding. A resolution is applied only when
/// it still matches what the finding saw (else ``DriftRepositoryError/stale``), and values come
/// from this fresh read, never from memory kept since the check.
struct DriftRemoteStateModel: Sendable {
    /// Item findings: the scope was listed. The listed item, or nil when GitHub has none.
    var item: DriftListedItemModel?
    /// Environment findings: the environment as listed (B3, B5, B7, B9), nil when absent.
    var environment: RemoteEnvironmentConfigModel?

    func wipe() {
        item?.value?.wipe()
        environment?.variables.forEach { $0.wipe() }
    }
}
