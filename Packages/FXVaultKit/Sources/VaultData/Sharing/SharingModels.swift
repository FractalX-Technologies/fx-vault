import Foundation
import GitHubKit
import os
import SharingKit
import VaultCore

/// What to share (§9.3 `scope`, §10 `ShareExportScreen` scope tree).
///
/// An environment's branch policy is shared only when the environment itself is selected
/// (`.environment`, `.repository`, or listed in a subset's `environmentIDs`); an environment
/// reached only through some of its items travels as a partial environment without a policy
/// (docs/SHARING-PROTOCOL.md §1.2).
public enum ShareSelectionModel: Sendable, Hashable {
    /// One secret or variable (`secret` scope). An environment-level item travels in a partial
    /// environment (no branch policy).
    case item(ConfigItemID)
    /// One environment with its policy and items (`environment` scope).
    case environment(EnvironmentID)
    /// Repository-level items and every environment (`repository` scope).
    case repository(RepoID)
    /// Any combination inside one repository (see ``ShareSubsetModel``).
    case subset(ShareSubsetModel)
    /// A copy of a folder with every item (`folder` scope, v0.7.0).
    case folder(FolderID)
}

/// Any combination of whole environments and individual items of one repository: repository
/// level only, one or more environments, repository level plus environments, or single items.
public struct ShareSubsetModel: Sendable, Hashable {
    public var repositoryID: RepoID
    /// Whole environments: the branch policy plus every live item at export time.
    public var environmentIDs: Set<EnvironmentID>
    /// Individual secrets and variables, at repository level or in environments that are not
    /// in ``environmentIDs`` (those travel as partial environments without their policy). An
    /// item inside a whole environment adds nothing.
    public var itemIDs: Set<ConfigItemID>

    public init(repositoryID: RepoID, environmentIDs: Set<EnvironmentID> = [], itemIDs: Set<ConfigItemID> = []) {
        self.repositoryID = repositoryID
        self.environmentIDs = environmentIDs
        self.itemIDs = itemIDs
    }

    /// True when nothing is selected.
    public var isEmpty: Bool {
        environmentIDs.isEmpty && itemIDs.isEmpty
    }
}

/// What an export would contain, for the confirmation step (names and counts, never values).
public struct ShareExportPreviewModel: Sendable, Hashable {
    public var scope: ShareScope
    /// `owner/name`; empty for a folder.
    public var repositoryFullName: String
    /// The folder's name for a folder copy (v0.7.0); nil otherwise.
    public var folderName: String?
    public var environmentNames: [String]
    public var itemCount: Int
    /// Secrets whose value is missing locally: shared by name only (§7.8).
    public var valueMissingNames: [String]
    /// Counts per scope: repository level, then each environment with whether its branch
    /// policy is included.
    public var summary: ShareContentSummaryModel

    public init(
        scope: ShareScope,
        repositoryFullName: String,
        environmentNames: [String],
        itemCount: Int,
        valueMissingNames: [String],
        summary: ShareContentSummaryModel,
        folderName: String? = nil
    ) {
        self.scope = scope
        self.repositoryFullName = repositoryFullName
        self.folderName = folderName
        self.environmentNames = environmentNames
        self.itemCount = itemCount
        self.valueMissingNames = valueMissingNames
        self.summary = summary
    }
}

/// A written `.fxvault` file (§9.1, §9.2).
public struct ShareFileExportResultModel: Sendable {
    public let fileURL: URL
    /// The fresh 6-word passphrase (`w1-…-w6`). Show it once with Copy and the "send it through
    /// another app" hint, then wipe it.
    public let passphrase: SecretBytes
    public let preview: ShareExportPreviewModel
}

/// A `.fxvault` file read from disk whose header passed §9.1 steps 1–6. Ask for the passphrase
/// only after this succeeded.
public struct ShareFileModel: Sendable, Hashable {
    public let data: Data
    public let header: FxVaultHeaderModel
}

/// What an import changed (§9.5). Names only.
public struct ShareImportResultModel: Sendable, Hashable {
    public var repositoryID: RepoID
    public var added: [String]
    public var addedWithoutValue: [String]
    public var filled: [String]
    public var overwritten: [String]
    /// Incoming variables without a value: a variable row always holds a value, so they are
    /// skipped.
    public var skippedVariablesWithoutValue: [String]
    public var environmentsCreated: [String]
    public var policiesChanged: [String]
    /// Values that lost trailing CR/LF on entry (D32 notice).
    public var strippedTrailingNewlines: [String]

    public init(repositoryID: RepoID) {
        self.repositoryID = repositoryID
        added = []
        addedWithoutValue = []
        filled = []
        overwritten = []
        skippedVariablesWithoutValue = []
        environmentsCreated = []
        policiesChanged = []
        strippedTrailingNewlines = []
    }

    /// Rows that now carry `provenance = share` ("from share, unverified").
    public var changedCount: Int {
        added.count + addedWithoutValue.count + filled.count + overwritten.count
    }
}

/// One opened share package and its preview (§9.5), from a `.fxvault` file or a nearby
/// MANIFEST or PAYLOAD.
///
/// Holds the package's values (payload) until ``SharingRepository/apply(_:plan:confirmReplay:)``
/// or ``discard()``, then wipes them; it also wipes them when released. The UI edits a copy of
/// ``plan`` (`select`, `overwriteAll`, `setPolicyDecision`) and passes it back to apply.
public final class ShareImportDraftModel: Sendable {
    /// The preview with default actions.
    public let plan: ShareImportPlanModel
    /// The package without values, for display.
    public let manifest: SharePackageModel
    let package: SharePackageModel
    let mode: SharePackageValidator.Mode
    /// What GitHub listed when the draft was planned (B3, B6–B9), or nil.
    let remote: ShareRemoteContextModel?
    /// The keyring generation the plan's fingerprints were computed under.
    let generation: UInt64
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    init(
        plan: ShareImportPlanModel,
        package: SharePackageModel,
        mode: SharePackageValidator.Mode,
        remote: ShareRemoteContextModel?,
        generation: UInt64
    ) {
        self.plan = plan
        manifest = package.manifest()
        self.package = package
        self.mode = mode
        self.remote = remote
        self.generation = generation
    }

    deinit {
        package.wipeValues()
    }

    /// Rejects the import: wipes the values. Idempotent.
    public func discard() {
        isClosed.withLock { $0 = true }
        package.wipeValues()
    }

    /// True once applied or discarded.
    public var isClosedForApply: Bool {
        isClosed.withLock { $0 }
    }

    /// Closes the draft for apply; throws when it was already closed.
    func close() throws(SharingError) {
        let wasClosed = isClosed.withLock { closed in
            defer { closed = true }
            return closed
        }
        if wasClosed { throw .draftClosed }
    }
}

/// A `.fxvault` file opened with its passphrase (v0.7.0): a repository package planned against
/// this vault, or a copy of a folder to save as a folder or import into a repository scope.
public enum ShareOpenedFileModel: Sendable {
    case repository(ShareImportDraftModel)
    case folder(ShareFolderDraftModel)
}

/// A copy of a folder opened from a `.fxvault` file (v0.7.0), waiting for "Save as Folder" or
/// "Import Into…". Holds the values until one of them, ``discard()`` or release wipes them.
public final class ShareFolderDraftModel: Sendable {
    /// The package without values, for display.
    public let manifest: SharePackageModel
    /// True when this package was imported or saved before (shown as a note, never a block).
    public let wasImported: Bool
    let package: SharePackageModel
    private let isClosedState = OSAllocatedUnfairLock(initialState: false)

    init(package: SharePackageModel, wasImported: Bool) {
        self.package = package
        manifest = package.manifest()
        self.wasImported = wasImported
    }

    deinit {
        package.wipeValues()
    }

    /// The sender's folder name.
    public var folderName: String {
        manifest.folder?.name ?? ""
    }

    /// Rejects the copy: wipes the values. Idempotent.
    public func discard() {
        isClosedState.withLock { $0 = true }
        package.wipeValues()
    }

    /// True once saved, imported or discarded.
    public var isClosed: Bool {
        isClosedState.withLock { $0 }
    }

    /// Closes the draft and wipes its values; throws when it was already closed.
    func close() throws(SharingError) {
        let wasClosed = isClosedState.withLock { closed in
            defer { closed = true }
            return closed
        }
        if wasClosed { throw .draftClosed }
        package.wipeValues()
    }
}

/// GitHub's view of the target repository when a draft was planned: the planner's
/// `ShareRemoteSnapshotModel`, the row ids its variable fingerprints are bound to, and the
/// listed environments (an environment GitHub already has is created locally as synced).
struct ShareRemoteContextModel: Sendable {
    let snapshot: ShareRemoteSnapshotModel
    /// Fingerprint row ids of listed variables, by ``ShareRemoteKeyModel``.
    let rowIDs: [ShareRemoteKeyModel: ConfigItemID]
    /// Listed environments by fold key.
    let environments: [String: GHEnvironmentDTO]
    /// Listed custom deployment patterns (B5) by environment fold key: a partial environment
    /// GitHub already has is created with GitHub's policy.
    var patterns: [String: [GHBranchPolicyDTO]] = [:]
}

/// A listed item's identity: environment fold key ("" at repository level), kind and name fold
/// key.
struct ShareRemoteKeyModel: Sendable, Hashable {
    let environmentKey: String
    let kind: ConfigKind
    let nameKey: String

    init(environmentName: String?, kind: ConfigKind, name: String) {
        environmentKey = environmentName.map(EnvironmentNameValidator.foldKey) ?? ""
        self.kind = kind
        nameKey = GitHubNameValidator.foldKey(name)
    }

    init(_ key: ShareItemKeyModel) {
        self.init(environmentName: key.environmentName, kind: key.kind, name: key.name)
    }
}
