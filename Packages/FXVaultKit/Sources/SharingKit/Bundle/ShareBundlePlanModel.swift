import Foundation
import VaultCore

// MARK: - Planner input

/// The receiver's local state for one bundle (v0.9.0, P7). Snapshots only: never values.
public struct ShareBundleLocalStateModel: Sendable {
    /// Per incoming repository, keyed by ``ShareBundleRepositoryModel/id`` (owner and name fold
    /// keys). A repository without an entry is planned as not checked (``ShareRepositoryNoAccessReason/notChecked``).
    public var repositories: [String: ShareBundleRepositoryStateModel]
    /// This vault's folders with the names they hold.
    public var folders: [ShareLocalFolderModel]
    /// `packageId`s already imported (`imported_share_packages`).
    public var importedPackageIDs: Set<SharePackageID>
    /// The current time (from ``VaultClock``).
    public var now: Date

    public init(
        repositories: [String: ShareBundleRepositoryStateModel] = [:],
        folders: [ShareLocalFolderModel] = [],
        importedPackageIDs: Set<SharePackageID> = [],
        now: Date
    ) {
        self.repositories = repositories
        self.folders = folders
        self.importedPackageIDs = importedPackageIDs
        self.now = now
    }
}

/// What this vault has for one incoming repository.
public struct ShareBundleRepositoryStateModel: Sendable {
    /// The local repository resolved by owner and name, or nil when it is not in the vault.
    public var repository: RepoModel?
    /// That repository's environments, including tombstoned ones.
    public var environments: [EnvironmentModel]
    /// That repository's config items with their stored value fingerprints.
    public var items: [ShareLocalItemModel]
    /// The latest GitHub listing of the repository (B3), when one is available.
    public var remote: ShareRemoteSnapshotModel?
    /// That repository's destinations with their items.
    public var destinations: [ShareLocalDestinationModel]
    /// For a repository not in the vault: whether one of this Mac's GitHub accounts can import it.
    public var access: ShareRepositoryAccess

    public init(
        repository: RepoModel?,
        environments: [EnvironmentModel] = [],
        items: [ShareLocalItemModel] = [],
        remote: ShareRemoteSnapshotModel? = nil,
        destinations: [ShareLocalDestinationModel] = [],
        access: ShareRepositoryAccess = .unknown
    ) {
        self.repository = repository
        self.environments = environments
        self.items = items
        self.remote = remote
        self.destinations = destinations
        self.access = access
    }
}

/// Whether a repository missing from the vault can be imported from GitHub (VaultData checks the
/// catalog of this Mac's accounts).
public enum ShareRepositoryAccess: Sendable, Hashable {
    /// An account on this Mac lists it; `accountLogin` is the one to import it with, when known.
    case importable(accountLogin: String?)
    /// No account on this Mac lists it.
    case notVisible
    /// GitHub could not be reached to check.
    case unreachable
    /// Not checked.
    case unknown
}

/// A local destination of the repository, with its items.
public struct ShareLocalDestinationModel: Sendable, Hashable {
    public var destination: DestinationModel
    public var items: [ShareLocalDestinationItemModel]

    public init(destination: DestinationModel, items: [ShareLocalDestinationItemModel]) {
        self.destination = destination
        self.items = items
    }
}

/// A local destination item plus its stored row-bound value fingerprint (`value_fp`), nil when
/// the value is missing.
public struct ShareLocalDestinationItemModel: Sendable, Hashable {
    public var item: DestinationItemModel
    public var fingerprint: Data?

    public init(item: DestinationItemModel, fingerprint: Data?) {
        self.item = item
        self.fingerprint = fingerprint
    }
}

/// A local folder and the names it holds (kind and name), to predict which incoming items a
/// merge keeps or replaces.
public struct ShareLocalFolderModel: Sendable, Hashable {
    public var folder: FolderModel
    public var items: [ShareLocalFolderItemModel]

    public init(folder: FolderModel, items: [ShareLocalFolderItemModel]) {
        self.folder = folder
        self.items = items
    }
}

/// One item name of a local folder.
public struct ShareLocalFolderItemModel: Sendable, Hashable {
    public var kind: ConfigKind
    public var name: String

    public init(kind: ConfigKind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// Computes the fingerprint of an incoming value bound to a local destination row (VaultData,
/// keyed HMAC), comparable with its stored fingerprint. Nil when it cannot: the values then count
/// as different.
public typealias ShareDestinationFingerprinter = @Sendable (DestinationItemModel, SecretBytes) -> Data?

// MARK: - Plan

/// Why an incoming repository cannot be imported now.
public enum ShareRepositoryNoAccessReason: Sendable, Hashable {
    /// No GitHub account on this Mac can see it.
    case notVisible
    /// GitHub could not be reached to check.
    case unreachable
    /// Access was not checked.
    case notChecked
}

/// The per-repository line of the open sheet (P7: ✓ ⇣ ✕).
public enum ShareBundleRepositoryStatus: Sendable, Hashable {
    /// ✓ In the vault: its GitHub scopes and destinations are planned.
    case inVault
    /// ⇣ Not in the vault; it will be imported from GitHub (with `accountLogin`, when known) and
    /// then planned again.
    case willImportFromGitHub(accountLogin: String?)
    /// ✕ Skipped: this Mac cannot import it. Opening the file again later imports it.
    case noAccess(ShareRepositoryNoAccessReason)
    /// ✕ The vault has a different repository under this name (§9.5): nothing is imported into it.
    case blocked(ShareImportBlockReason)

    /// Whether anything of this repository is imported now.
    public var isImportedNow: Bool {
        self == .inVault
    }
}

/// What happens to an incoming destination.
public enum ShareDestinationAction: Sendable, Hashable {
    /// Created in the vault without a connection: Sync leaves it alone until the receiver connects
    /// their own account.
    case create
    /// Merged into this local destination of the repository (same target key). Its stage and
    /// connection stay as they are.
    case useExisting(DestinationID)
}

/// The plan for one incoming destination item. Chips, defaults and actions follow
/// ``ShareItemPlanModel`` (keep mine by default when the values differ).
public struct ShareDestinationItemPlanModel: Sendable, Hashable, Identifiable {
    public let id: ShareEntryID
    public let kind: ConfigKind
    public let name: String
    /// The matching local row (same name), if any.
    public let localItemID: ConfigItemID?
    public let chip: ShareItemChip
    public let defaultAction: ShareItemAction
    public let allowedActions: [ShareItemAction]
    public let warnings: Set<ShareItemWarning>
    /// The selected action; starts at ``defaultAction``.
    public internal(set) var action: ShareItemAction

    init(
        id: ShareEntryID,
        kind: ConfigKind,
        name: String,
        localItemID: ConfigItemID?,
        chip: ShareItemChip,
        defaultAction: ShareItemAction,
        allowedActions: [ShareItemAction],
        warnings: Set<ShareItemWarning> = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.localItemID = localItemID
        self.chip = chip
        self.defaultAction = defaultAction
        self.allowedActions = allowedActions
        self.warnings = warnings
        action = defaultAction
    }

    /// The effect of the selected action. A destination has no "GitHub agrees" shortcut: every
    /// write is pending, and VaultData holds the rows the remote does not have (P8).
    public var outcome: ShareItemOutcome {
        outcome(for: action)
    }

    /// The effect `action` would have.
    public func outcome(for action: ShareItemAction) -> ShareItemOutcome {
        switch action {
        case .add: .added(pending: true)
        case .addWithoutValue: .addedWithoutValue
        case .fill: .filled(pending: true)
        case .overwrite: .overwritten
        case .skip, .keepMine: .unchanged
        }
    }

    /// Whether the selected action writes a row. A variable must hold a value, so adding one
    /// without its value is skipped by the importer.
    public var writesRow: Bool {
        switch outcome {
        case .unchanged: false
        case .addedWithoutValue: kind == .secret
        case .added, .filled, .overwritten: true
        }
    }
}

/// The plan for one incoming destination and its items.
public struct ShareDestinationPlanModel: Sendable, Hashable, Identifiable {
    public let id: ShareEntryID
    public let target: DestinationTargetModel
    /// The sender's stage for it.
    public let stage: String?
    public let action: ShareDestinationAction
    public internal(set) var items: [ShareDestinationItemPlanModel]

    /// The local destination this merges into, if any.
    public var localDestinationID: DestinationID? {
        if case .useExisting(let id) = action { return id }
        return nil
    }
}

/// The plan for one incoming repository.
public struct ShareBundleRepositoryPlanModel: Sendable, Hashable, Identifiable {
    /// ``ShareBundleRepositoryModel/id``.
    public let id: String
    public let owner: String
    public let name: String
    public let githubRepoID: String?
    public let status: ShareBundleRepositoryStatus
    /// Names and counts, for the open sheet.
    public let summary: ShareBundleRepositorySummaryModel
    /// The GitHub scopes plan (status ``ShareBundleRepositoryStatus/inVault`` only); VaultData
    /// applies it with ``ShareBundleModel/githubPackage(for:)``.
    public internal(set) var githubPlan: ShareImportPlanModel?
    /// The destinations plan: merged or created for a repository in the vault, all created for one
    /// that will be imported, empty for a skipped one.
    public internal(set) var destinations: [ShareDestinationPlanModel]

    public var fullName: String {
        "\(owner)/\(name)"
    }
}

/// The receiver's choice for an existing folder with an incoming item it already has.
public enum ShareFolderConflictChoice: String, Sendable, Hashable, CaseIterable {
    case keepMine
    case replace
}

/// What happens to an incoming folder (VaultData applies it through "Save as Folder").
public enum ShareFolderPlanAction: Sendable, Hashable {
    /// A new folder with this name.
    case createNew(name: String)
    /// Merged into this folder; names it already has are kept or replaced.
    case mergeInto(FolderID, conflicts: ShareFolderConflictChoice)
    /// Not imported.
    case skip
}

/// The plan for one incoming folder.
public struct ShareBundleFolderPlanModel: Sendable, Hashable, Identifiable {
    public let id: ShareEntryID
    public let name: String
    public let counts: ShareItemCountModel
    /// The local folder with the same name (case-insensitive), if any.
    public let existingFolderID: FolderID?
    /// Incoming items whose kind and name the existing folder already holds.
    public let conflictingItemIDs: Set<ShareEntryID>
    public let defaultAction: ShareFolderPlanAction
    /// The selected action; starts at ``defaultAction``.
    public internal(set) var action: ShareFolderPlanAction
}

/// One linked-copy group to recreate on the receiver (P9): the entries of one `link` token that
/// the selected actions write. VaultData gives them one fresh `link_id`.
public struct ShareLinkGroupModel: Sendable, Hashable {
    public let token: String
    public let memberIDs: [ShareEntryID]
}

/// The full bundle preview and the user's selections. Pure data: VaultData applies it in one
/// transaction (GitHub scopes per repository with the existing importer, destinations, folders,
/// links, holds and the `imported_share_packages` row).
public struct ShareBundlePlanModel: Sendable, Hashable {
    public let packageID: SharePackageID
    /// Provenance for added or filled rows: package id and the (unverified) sender name.
    public let origin: ShareOriginModel
    public let mode: SharePackageValidator.Mode
    /// The stages the sender chose; the Overview opens at the first one after the import.
    public let stages: [String]
    public let replayWarnings: Set<ShareReplayWarning>
    public internal(set) var repositories: [ShareBundleRepositoryPlanModel]
    public internal(set) var folders: [ShareBundleFolderPlanModel]
    /// The `link` token of every incoming entry that carries one.
    let linkTokens: [ShareEntryID: String]

    /// Whether the replay warning must be confirmed before applying.
    public var requiresReplayConfirmation: Bool {
        !replayWarnings.isEmpty
    }

    /// The repositories that will be imported from GitHub first (⇣); plan again afterwards.
    public var repositoriesToImport: [ShareBundleRepositoryPlanModel] {
        repositories.filter {
            if case .willImportFromGitHub = $0.status { return true }
            return false
        }
    }

    /// The repositories imported now (✓).
    public var importedRepositories: [ShareBundleRepositoryPlanModel] {
        repositories.filter(\.status.isImportedNow)
    }

    /// The first stage the sender chose, for the Overview.
    public var firstStage: String? {
        stages.first
    }

    // MARK: Selections

    /// Selects `action` for the GitHub or destination item `id`. Throws `.importActionNotAllowed`
    /// if the action is not allowed for it or the item is not in a repository imported now.
    public mutating func select(_ action: ShareItemAction, forItem id: ShareEntryID) throws(ShareError) {
        for repositoryIndex in repositories.indices where repositories[repositoryIndex].status.isImportedNow {
            if var plan = repositories[repositoryIndex].githubPlan, plan.allItems.contains(where: { $0.id == id }) {
                try plan.select(action, forItem: id)
                repositories[repositoryIndex].githubPlan = plan
                return
            }
            for destinationIndex in repositories[repositoryIndex].destinations.indices {
                let items = repositories[repositoryIndex].destinations[destinationIndex].items
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                guard items[index].allowedActions.contains(action) else { throw .importActionNotAllowed }
                repositories[repositoryIndex].destinations[destinationIndex].items[index].action = action
                return
            }
        }
        throw .importActionNotAllowed
    }

    /// "Overwrite all": every GitHub and destination item that differs is overwritten.
    public mutating func overwriteAll() {
        for repositoryIndex in repositories.indices {
            repositories[repositoryIndex].githubPlan?.overwriteAll()
            for destinationIndex in repositories[repositoryIndex].destinations.indices {
                for index in repositories[repositoryIndex].destinations[destinationIndex].items.indices
                    where repositories[repositoryIndex].destinations[destinationIndex].items[index].chip == .differs {
                    repositories[repositoryIndex].destinations[destinationIndex].items[index].action = .overwrite
                }
            }
        }
    }

    /// Chooses the policy for a differing environment of the repository `repositoryID`
    /// (``SharePolicyDifferenceModel``; widening needs `wideningConfirmed`).
    public mutating func setPolicyDecision(
        _ decision: SharePolicyDecision,
        forEnvironment environmentID: ShareEntryID,
        inRepository repositoryID: String,
        wideningConfirmed: Bool = false
    ) throws(ShareError) {
        guard let index = repositories.firstIndex(where: { $0.id == repositoryID }),
              var plan = repositories[index].githubPlan
        else { throw .importActionNotAllowed }
        try plan.setPolicyDecision(decision, forEnvironment: environmentID, wideningConfirmed: wideningConfirmed)
        repositories[index].githubPlan = plan
    }

    /// Chooses what happens to the folder `id`: a new folder (any name), a merge into the folder
    /// with the same name only, or skip. Throws `.importActionNotAllowed` otherwise.
    public mutating func setFolderAction(_ action: ShareFolderPlanAction, forFolder id: ShareEntryID) throws(ShareError) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw .importActionNotAllowed }
        if case .mergeInto(let folderID, _) = action, folderID != folders[index].existingFolderID {
            throw .importActionNotAllowed
        }
        folders[index].action = action
    }

    // MARK: Results

    /// Items and destinations whose selected action changes something.
    public var changedItemCount: Int {
        var count = 0
        for repository in importedRepositories {
            count += repository.githubPlan?.changedItems.count ?? 0
            count += repository.destinations.flatMap(\.items).filter { $0.outcome != .unchanged }.count
        }
        return count
    }

    /// Linked-copy groups to recreate (P9): for each `link` token, the entries whose selected
    /// action writes a row, kept only when at least two are written. Rows the receiver keeps keep
    /// their own links. Sorted by token.
    public var linkGroups: [ShareLinkGroupModel] {
        let written = writtenEntryIDs
        var members: [String: [ShareEntryID]] = [:]
        for (id, token) in linkTokens where written.contains(id) {
            members[token, default: []].append(id)
        }
        return members
            .filter { $0.value.count >= 2 }
            .map { ShareLinkGroupModel(token: $0.key, memberIDs: $0.value.sorted()) }
            .sorted { $0.token < $1.token }
    }

    /// Every entry whose selected action writes a row.
    var writtenEntryIDs: Set<ShareEntryID> {
        var ids = Set<ShareEntryID>()
        for repository in importedRepositories {
            if let plan = repository.githubPlan, plan.blockReason == nil {
                ids.formUnion(plan.allItems.filter(\.writesRow).map(\.id))
            }
            ids.formUnion(repository.destinations.flatMap(\.items).filter(\.writesRow).map(\.id))
        }
        for folder in folders {
            ids.formUnion(folder.writtenItemIDs(allItemIDs: folderItemIDs[folder.id] ?? []))
        }
        return ids
    }

    /// Item ids of each incoming folder.
    let folderItemIDs: [ShareEntryID: [ShareEntryID]]

    // MARK: Preview comparison

    /// Whether `other` (a fresh plan made inside the write transaction) shows the same preview as
    /// this one, ignoring the user's selections. VaultData refuses with `.planOutdated` otherwise.
    public func isSamePreview(as other: ShareBundlePlanModel) -> Bool {
        resettingSelections() == other.resettingSelections()
    }

    private func resettingSelections() -> ShareBundlePlanModel {
        var copy = self
        for repositoryIndex in copy.repositories.indices {
            if var plan = copy.repositories[repositoryIndex].githubPlan {
                plan.resetSelections()
                copy.repositories[repositoryIndex].githubPlan = plan
            }
            for destinationIndex in copy.repositories[repositoryIndex].destinations.indices {
                for index in copy.repositories[repositoryIndex].destinations[destinationIndex].items.indices {
                    let item = copy.repositories[repositoryIndex].destinations[destinationIndex].items[index]
                    copy.repositories[repositoryIndex].destinations[destinationIndex].items[index].action = item.defaultAction
                }
            }
        }
        for index in copy.folders.indices {
            copy.folders[index].action = copy.folders[index].defaultAction
        }
        return copy
    }
}

extension ShareBundleFolderPlanModel {
    /// The incoming items the selected action writes: all of them for a new folder or a replacing
    /// merge, those the folder does not have yet for a merge that keeps mine, none when skipped.
    func writtenItemIDs(allItemIDs: [ShareEntryID]) -> Set<ShareEntryID> {
        switch action {
        case .skip:
            []
        case .createNew, .mergeInto(_, .replace):
            Set(allItemIDs)
        case .mergeInto(_, .keepMine):
            Set(allItemIDs).subtracting(conflictingItemIDs)
        }
    }
}

extension ShareImportPlanModel {
    /// Every selection back to its default (preview comparison).
    mutating func resetSelections() {
        for index in repositoryItems.indices {
            repositoryItems[index].action = repositoryItems[index].defaultAction
        }
        for environmentIndex in environments.indices {
            for index in environments[environmentIndex].items.indices {
                environments[environmentIndex].items[index].action = environments[environmentIndex].items[index].defaultAction
            }
            environments[environmentIndex].policyDifference?.decision = .keepMine
        }
    }
}
