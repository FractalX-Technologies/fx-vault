import Foundation
import VaultCore

// MARK: - Planner input

/// The receiver's local state for one import (§9.5). Snapshots only: never values.
public struct ShareLocalStateModel: Sendable {
    /// The local repository resolved by the package's owner/name, or nil when not imported.
    public var repository: RepoModel?
    /// That repository's environments, including tombstoned ones.
    public var environments: [EnvironmentModel]
    /// That repository's config items with their stored value fingerprints.
    public var items: [ShareLocalItemModel]
    /// The latest GitHub listing of the repository (B3), when one is available.
    public var remote: ShareRemoteSnapshotModel?
    /// `packageId`s already imported (`imported_share_packages`).
    public var importedPackageIDs: Set<SharePackageID>
    /// The current time (from ``VaultClock``).
    public var now: Date

    public init(
        repository: RepoModel?,
        environments: [EnvironmentModel] = [],
        items: [ShareLocalItemModel] = [],
        remote: ShareRemoteSnapshotModel? = nil,
        importedPackageIDs: Set<SharePackageID> = [],
        now: Date
    ) {
        self.repository = repository
        self.environments = environments
        self.items = items
        self.remote = remote
        self.importedPackageIDs = importedPackageIDs
        self.now = now
    }
}

/// A local config item plus its stored row-bound value fingerprint (`value_fp`), nil when
/// the value is missing.
public struct ShareLocalItemModel: Sendable, Hashable {
    public var item: ConfigItemModel
    public var fingerprint: Data?

    public init(item: ConfigItemModel, fingerprint: Data?) {
        self.item = item
        self.fingerprint = fingerprint
    }
}

/// What GitHub listed for the repository (names and metadata, plus variable value
/// fingerprints computed by VaultData).
public struct ShareRemoteSnapshotModel: Sendable, Hashable {
    public var environmentNames: [String]
    public var items: [ShareRemoteItemModel]

    public init(environmentNames: [String], items: [ShareRemoteItemModel]) {
        self.environmentNames = environmentNames
        self.items = items
    }
}

/// One listed secret or variable.
public struct ShareRemoteItemModel: Sendable, Hashable {
    public var key: ShareItemKeyModel
    /// GitHub `updatedAt`.
    public var updatedAt: Date?
    /// Variables only: fingerprint of the listed value, comparable with what the
    /// ``ShareFingerprinter`` returns for `.remote(key)`.
    public var valueFingerprint: Data?

    public init(key: ShareItemKeyModel, updatedAt: Date?, valueFingerprint: Data? = nil) {
        self.key = key
        self.updatedAt = updatedAt
        self.valueFingerprint = valueFingerprint
    }
}

/// Where an item lives: environment (nil for repository level), kind and name.
public struct ShareItemKeyModel: Sendable, Hashable {
    public var environmentName: String?
    public var kind: ConfigKind
    public var name: String

    public init(environmentName: String?, kind: ConfigKind, name: String) {
        self.environmentName = environmentName
        self.kind = kind
        self.name = name
    }

    /// Case- and normalization-insensitive identity (environment and item fold keys).
    var matchKey: ShareMatchKey {
        ShareMatchKey(
            environmentKey: environmentName.map(EnvironmentNameValidator.foldKey) ?? "",
            kind: kind,
            nameKey: GitHubNameValidator.foldKey(name)
        )
    }
}

struct ShareMatchKey: Hashable {
    var environmentKey: String
    var kind: ConfigKind
    var nameKey: String
}

/// What to fingerprint an incoming value against.
public enum ShareFingerprintSubject: Sendable, Hashable {
    /// Bound to this local row, comparable with its stored fingerprint.
    case local(ConfigItemModel)
    /// Bound to a listed remote variable, comparable with its `valueFingerprint`.
    case remote(ShareItemKeyModel)
}

/// Computes the fingerprint of an incoming value for a subject (VaultData, keyed HMAC).
/// Returns nil when it cannot (for example the vault locked): the planner then treats the
/// values as different.
public typealias ShareFingerprinter = @Sendable (ShareFingerprintSubject, SecretBytes) -> Data?

// MARK: - Plan

/// Why an import cannot proceed.
public enum ShareImportBlockReason: Sendable, Hashable {
    /// The repository is not in the vault: offer a one-click import through an account with
    /// access (B2), or reject.
    case repositoryNotImported
    /// The resolved local repository is not the package's owner/name.
    case repositoryNameMismatch
    /// The package's `githubRepoId` differs from the local `github_id` (§9.5).
    case repositoryIDMismatch
}

/// Replay signals that need an explicit confirmation (§9.5).
public enum ShareReplayWarning: String, Sendable, Hashable, CaseIterable {
    /// This `packageId` was already imported.
    case alreadyImported
    /// `createdAt` is older than ``Timeouts/shareReplayMaxAge``.
    case olderThanMaxAge
    /// `createdAt` is older than a matching local row's `updated_at`.
    case olderThanLocalChanges
}

/// The preview chip of one incoming item (§9.5). Same/Differs only exist once values are
/// known (payload mode).
public enum ShareItemChip: String, Sendable, Hashable, CaseIterable {
    case new
    case fillsMissingValue
    case valueNotIncluded
    /// Manifest mode: a local item with a value exists; Same/Differs needs the payload.
    case existsLocally
    case same
    case differs
    /// The same name exists locally as the other kind; skipped with a warning.
    case otherKindExists
    /// The matching local row (or its environment) is pending deletion; skipped.
    case deletedLocally
}

/// What to do with one incoming item.
public enum ShareItemAction: String, Sendable, Hashable, CaseIterable {
    case add
    /// Add the name without a value (incoming value missing).
    case addWithoutValue
    case fill
    case skip
    case keepMine
    case overwrite
}

/// The effect of the selected action.
public enum ShareItemOutcome: Sendable, Hashable {
    case unchanged
    case added(pending: Bool)
    /// Added as value-missing; not pending (it exists on GitHub).
    case addedWithoutValue
    case filled(pending: Bool)
    /// Pending modify.
    case overwritten

    /// Whether the outcome creates a pending change.
    public var isPending: Bool {
        switch self {
        case .added(let pending), .filled(let pending): pending
        case .overwritten: true
        case .unchanged, .addedWithoutValue: false
        }
    }

    /// Whether the row gets `provenance = share` with the package id and sender name.
    public var setsShareProvenance: Bool {
        self != .unchanged
    }
}

/// Per-item notes shown next to the chip.
public enum ShareItemWarning: String, Sendable, Hashable, CaseIterable {
    case otherKindExists
    case deletedLocally
    /// The local row changed after the package was created.
    case localChangedSincePackage
}

/// The plan for one incoming item.
public struct ShareItemPlanModel: Sendable, Hashable, Identifiable {
    public let id: ShareEntryID
    public let key: ShareItemKeyModel
    /// The matching local row (same kind), if any.
    public let localItemID: ConfigItemID?
    public let chip: ShareItemChip
    public let defaultAction: ShareItemAction
    public let allowedActions: [ShareItemAction]
    public let warnings: Set<ShareItemWarning>
    /// The selected action; starts at ``defaultAction``.
    public internal(set) var action: ShareItemAction
    let addIsSynced: Bool
    let fillIsSynced: Bool

    init(
        id: ShareEntryID,
        key: ShareItemKeyModel,
        localItemID: ConfigItemID?,
        chip: ShareItemChip,
        defaultAction: ShareItemAction,
        allowedActions: [ShareItemAction],
        warnings: Set<ShareItemWarning> = [],
        addIsSynced: Bool = false,
        fillIsSynced: Bool = false
    ) {
        self.id = id
        self.key = key
        self.localItemID = localItemID
        self.chip = chip
        self.defaultAction = defaultAction
        self.allowedActions = allowedActions
        self.warnings = warnings
        action = defaultAction
        self.addIsSynced = addIsSynced
        self.fillIsSynced = fillIsSynced
    }

    /// The effect of the selected action.
    public var outcome: ShareItemOutcome {
        outcome(for: action)
    }

    /// The effect `action` would have.
    public func outcome(for action: ShareItemAction) -> ShareItemOutcome {
        switch action {
        case .add: .added(pending: !addIsSynced)
        case .addWithoutValue: .addedWithoutValue
        case .fill: .filled(pending: !fillIsSynced)
        case .overwrite: .overwritten
        case .skip, .keepMine: .unchanged
        }
    }
}

/// What happens to an incoming environment.
public enum ShareEnvironmentAction: Sendable, Hashable {
    /// Created locally with the incoming policy; pending create unless GitHub has it (B3).
    case create(pending: Bool)
    /// Merged into the existing local environment.
    case useExisting
    /// The local environment is pending deletion: nothing in it is imported.
    case blockedDeletedLocally
}

/// The receiver's choice for a differing deployment branch policy.
public enum SharePolicyDecision: String, Sendable, Hashable, CaseIterable {
    case keepMine
    case useIncoming
}

/// The "Deployment branches differ" row (§9.5).
public struct SharePolicyDifferenceModel: Sendable, Hashable {
    public let localPolicy: ShareBranchPolicyModel
    public let incomingPolicy: ShareBranchPolicyModel
    /// Accepting would allow deployments from more refs: show the security warning and
    /// require a second confirmation.
    public let isWidening: Bool
    public internal(set) var decision: SharePolicyDecision = .keepMine

    /// Pending only if the incoming policy is accepted.
    public var isPending: Bool {
        decision == .useIncoming
    }
}

/// The plan for one incoming environment and its items.
public struct ShareEnvironmentPlanModel: Sendable, Hashable, Identifiable {
    public let id: ShareEntryID
    public let name: String
    public let localEnvironmentID: EnvironmentID?
    public let action: ShareEnvironmentAction
    public let incomingPolicy: ShareBranchPolicyModel
    /// Set when an existing local environment has a different policy.
    public internal(set) var policyDifference: SharePolicyDifferenceModel?
    public internal(set) var items: [ShareItemPlanModel]
}

/// The full import preview and the user's selections (§9.5). Pure data: `ShareImporter`
/// (VaultData) applies it in one transaction.
public struct ShareImportPlanModel: Sendable, Hashable {
    public let packageID: SharePackageID
    /// Provenance for added or filled rows: package id and the (unverified) sender name.
    public let origin: ShareOriginModel
    public let mode: SharePackageValidator.Mode
    /// Non-nil when nothing can be imported.
    public let blockReason: ShareImportBlockReason?
    public let replayWarnings: Set<ShareReplayWarning>
    public internal(set) var repositoryItems: [ShareItemPlanModel]
    public internal(set) var environments: [ShareEnvironmentPlanModel]

    /// Whether the replay warning must be confirmed before applying.
    public var requiresReplayConfirmation: Bool {
        !replayWarnings.isEmpty
    }

    /// Every item plan, repository level first.
    public var allItems: [ShareItemPlanModel] {
        repositoryItems + environments.flatMap(\.items)
    }

    /// Items whose selected action changes something.
    public var changedItems: [ShareItemPlanModel] {
        allItems.filter { $0.outcome != .unchanged }
    }

    /// Pending changes the import would create (items, environment creates, policies).
    public var pendingChangeCount: Int {
        let items = allItems.filter(\.outcome.isPending).count
        let environments = environments.filter { plan in
            if case .create(pending: true) = plan.action { return true }
            return plan.policyDifference?.isPending == true
        }.count
        return items + environments
    }

    /// Selects `action` for the item `id`. Throws `.importActionNotAllowed` if the action is
    /// not in its ``ShareItemPlanModel/allowedActions``.
    public mutating func select(_ action: ShareItemAction, forItem id: ShareEntryID) throws(ShareError) {
        if let index = repositoryItems.firstIndex(where: { $0.id == id }) {
            guard repositoryItems[index].allowedActions.contains(action) else { throw .importActionNotAllowed }
            repositoryItems[index].action = action
            return
        }
        for environmentIndex in environments.indices {
            let items = environments[environmentIndex].items
            if let index = items.firstIndex(where: { $0.id == id }) {
                guard items[index].allowedActions.contains(action) else { throw .importActionNotAllowed }
                environments[environmentIndex].items[index].action = action
                return
            }
        }
        throw .importActionNotAllowed
    }

    /// "Overwrite all": every item that differs is overwritten.
    public mutating func overwriteAll() {
        for index in repositoryItems.indices where repositoryItems[index].chip == .differs {
            repositoryItems[index].action = .overwrite
        }
        for environmentIndex in environments.indices {
            for index in environments[environmentIndex].items.indices
                where environments[environmentIndex].items[index].chip == .differs {
                environments[environmentIndex].items[index].action = .overwrite
            }
        }
    }

    /// Chooses the policy for a differing environment. A widening change needs
    /// `wideningConfirmed` (the second confirmation), otherwise `.importActionNotAllowed`.
    public mutating func setPolicyDecision(
        _ decision: SharePolicyDecision,
        forEnvironment id: ShareEntryID,
        wideningConfirmed: Bool = false
    ) throws(ShareError) {
        guard let index = environments.firstIndex(where: { $0.id == id }),
              let difference = environments[index].policyDifference
        else { throw .importActionNotAllowed }
        if decision == .useIncoming, difference.isWidening, !wideningConfirmed {
            throw .importActionNotAllowed
        }
        environments[index].policyDifference?.decision = decision
    }
}
