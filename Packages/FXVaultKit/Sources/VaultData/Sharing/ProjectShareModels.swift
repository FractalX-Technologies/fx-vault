import Foundation
import os
import SharingKit
import VaultCore

// MARK: - Export selection (v0.9.0, P1–P2)

/// What a project share file holds (v0.9.0): one or more repositories, each with the parts the
/// sender chose, plus optional folders, the stages the sender picked and the expiry.
///
/// Build one from stages with ``SharingRepository/selection(repositoryIDs:stages:includesRepositoryLevel:folderIDs:expiry:)``
/// and adjust it per repository; ``SharingRepository/previewBundle(_:)`` shows what it holds.
public struct ShareBundleSelectionModel: Sendable, Hashable {
    /// In the order the file lists them; each repository at most once.
    public var repositories: [ShareBundleRepositorySelectionModel]
    public var folderIDs: [FolderID]
    /// The stages the sender chose, in order (the receiver opens the Overview at the first).
    public var stages: [String]
    public var expiry: ShareExpiryChoice

    public init(
        repositories: [ShareBundleRepositorySelectionModel] = [],
        folderIDs: [FolderID] = [],
        stages: [String] = [],
        expiry: ShareExpiryChoice = .default
    ) {
        self.repositories = repositories
        self.folderIDs = folderIDs
        self.stages = stages
        self.expiry = expiry
    }

    /// True when no repository part and no folder is selected.
    public var isEmpty: Bool {
        folderIDs.isEmpty && repositories.allSatisfy(\.isEmpty)
    }
}

/// The parts of one repository in a ``ShareBundleSelectionModel``.
///
/// A whole environment carries its branch policy; an environment reached only through some of
/// its items travels as a partial environment (schema 2). A whole destination carries every live
/// item; individual destination items carry only themselves.
public struct ShareBundleRepositorySelectionModel: Sendable, Hashable {
    public var repositoryID: RepoID
    /// Every live repository-level secret and variable.
    public var includesRepositoryLevel: Bool
    /// Whole environments: the branch policy and every live item.
    public var environmentIDs: Set<EnvironmentID>
    /// Individual repository items (repository level, or in environments not in
    /// ``environmentIDs``).
    public var itemIDs: Set<ConfigItemID>
    /// Whole destinations: target, stage and every live item.
    public var destinationIDs: Set<DestinationID>
    /// Individual destination items of destinations not in ``destinationIDs``.
    public var destinationItemIDs: Set<ConfigItemID>

    public init(
        repositoryID: RepoID,
        includesRepositoryLevel: Bool = true,
        environmentIDs: Set<EnvironmentID> = [],
        itemIDs: Set<ConfigItemID> = [],
        destinationIDs: Set<DestinationID> = [],
        destinationItemIDs: Set<ConfigItemID> = []
    ) {
        self.repositoryID = repositoryID
        self.includesRepositoryLevel = includesRepositoryLevel
        self.environmentIDs = environmentIDs
        self.itemIDs = itemIDs
        self.destinationIDs = destinationIDs
        self.destinationItemIDs = destinationItemIDs
    }

    /// True when nothing of the repository is selected.
    public var isEmpty: Bool {
        !includesRepositoryLevel && environmentIDs.isEmpty && itemIDs.isEmpty
            && destinationIDs.isEmpty && destinationItemIDs.isEmpty
    }
}

/// One stage the share sheet offers (P2): the GitHub environment named like it and the
/// destinations of that stage, across the chosen repositories.
public struct ShareStageOptionModel: Sendable, Hashable, Identifiable {
    /// The first spelling found (repository order, then environments, then destinations).
    public var name: String
    /// ``StageRisk/isProduction(_:)``: unchecked by default and shared only behind its own
    /// confirmation (``ShareAuthorizationPurpose/productionFileExport``).
    public var isProduction: Bool
    /// The chosen repositories that have this stage.
    public var repositoryIDs: [RepoID]

    public init(name: String, isProduction: Bool, repositoryIDs: [RepoID]) {
        self.name = name
        self.isProduction = isProduction
        self.repositoryIDs = repositoryIDs
    }

    /// The stage's fold key.
    public var id: String {
        EnvironmentNameValidator.foldKey(name)
    }
}

/// What a project share would hold, for the share sheet's summary (names and counts only).
public struct ShareBundleExportPreviewModel: Sendable, Hashable {
    public var summary: ShareBundleSummaryModel
    public var stages: [String]
    /// Secrets whose value is missing locally: shared by name only (`owner/name · NAME`, or
    /// `Folder · NAME`).
    public var valueMissingNames: [String]
    /// Production places in the selection (environments and destinations, by name): the file
    /// needs a ``ShareAuthorizationPurpose/productionFileExport`` authorization while this is not
    /// empty.
    public var productionPlaces: [String]
    /// When the file would expire if written now.
    public var expiresAt: Date

    public init(
        summary: ShareBundleSummaryModel,
        stages: [String],
        valueMissingNames: [String],
        productionPlaces: [String],
        expiresAt: Date
    ) {
        self.summary = summary
        self.stages = stages
        self.valueMissingNames = valueMissingNames
        self.productionPlaces = productionPlaces
        self.expiresAt = expiresAt
    }

    public var itemCount: Int {
        summary.itemCount
    }

    /// True when the file needs the production confirmation.
    public var includesProduction: Bool {
        !productionPlaces.isEmpty
    }
}

/// A written project share file (format 2, schema 4).
public struct ShareBundleExportResultModel: Sendable {
    public let fileURL: URL
    /// The fresh 6-word passphrase (show it once with the "send it another way" hint, then wipe
    /// it).
    public let passphrase: SecretBytes
    public let preview: ShareBundleExportPreviewModel
    /// The `sent_shares` row written for it (names only).
    public let sentShare: SentShareModel
}

// MARK: - Opening (v0.9.0, P3, P7)

/// A share file read from disk whose header passed the format checks (`.fxvault` format 1 or 2).
public struct ShareInspectedFileModel: Sendable, Hashable {
    public let data: Data
    public let info: FxVaultFileInfo
}

/// Who sent an opened share file.
public struct ShareFileSenderModel: Sendable, Hashable {
    /// The name the file states (unverified).
    public var displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }
}

/// The contents of an opened share file.
public enum ShareOpenedDocumentModel: Sendable {
    /// A schema 1–2 repository package (files from FX Vault 0.8 and earlier), planned as before.
    case repository(ShareImportDraftModel)
    /// A schema 3 copy of a folder (FX Vault 0.7 and 0.8).
    case folder(ShareFolderDraftModel)
    /// A schema 4 project share (FX Vault 0.9).
    case bundle(ShareBundleDraftModel)
}

/// An opened share file: its contents and who sent it.
public struct ShareOpenedShareFileModel: Sendable {
    public let document: ShareOpenedDocumentModel
    public let sender: ShareFileSenderModel
}

/// One opened project share and its preview (P7).
///
/// Holds the bundle's values until ``SharingRepository/applyBundle(_:plan:confirmReplay:)`` or
/// ``discard()``, then wipes them; it also wipes them when released. The UI edits a copy of
/// ``plan`` (`select`, `overwriteAll`, `setPolicyDecision`, `setFolderAction`) and passes it back
/// to apply.
public final class ShareBundleDraftModel: Sendable {
    /// The preview with default actions.
    public let plan: ShareBundlePlanModel
    /// The bundle without values, for display.
    public let manifest: ShareBundleModel
    public let sender: ShareFileSenderModel
    let bundle: ShareBundleModel
    /// GitHub's listing per repository (``ShareBundleRepositoryModel/id``) when it was planned.
    let remotes: [String: ShareRemoteContextModel]
    /// The listed variables' fingerprint row ids, shared by every repository of the bundle.
    let remoteRowIDs: [ShareRemoteKeyModel: ConfigItemID]
    /// Whether a repository missing from the vault can be imported (by repository id).
    let access: [String: ShareRepositoryAccess]
    /// The keyring generation the plan's fingerprints were computed under.
    let generation: UInt64
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    init(
        plan: ShareBundlePlanModel,
        bundle: ShareBundleModel,
        sender: ShareFileSenderModel,
        remotes: [String: ShareRemoteContextModel],
        remoteRowIDs: [ShareRemoteKeyModel: ConfigItemID],
        access: [String: ShareRepositoryAccess],
        generation: UInt64
    ) {
        self.plan = plan
        manifest = bundle.manifest()
        self.bundle = bundle
        self.sender = sender
        self.remotes = remotes
        self.remoteRowIDs = remoteRowIDs
        self.access = access
        self.generation = generation
    }

    deinit {
        bundle.wipeValues()
    }

    /// Rejects the import: wipes the values. Idempotent.
    public func discard() {
        isClosed.withLock { $0 = true }
        bundle.wipeValues()
    }

    /// True once applied, re-planned or discarded.
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

/// The ⇣ repositories of a bundle imported from GitHub, and the draft planned again afterwards.
public struct ShareBundleRepositoryImportModel: Sendable {
    public let draft: ShareBundleDraftModel
    /// `owner/name` of the repositories whose import failed (they stay ✕ or ⇣ in the new plan).
    public let failedRepositories: [String]
}

/// What a project share import changed. Names and counts only.
public struct ShareBundleImportResultModel: Sendable, Hashable {
    /// The GitHub scopes of each repository imported now.
    public var repositories: [ShareImportResultModel]
    /// Destinations created without a connection, by label.
    public var destinationsCreated: [String]
    /// Destination rows added, filled or overwritten.
    public var destinationItemsWritten: Int
    /// Folders created or merged, by name.
    public var folders: [String]
    /// Rows waiting in Sync's From Files review (`share_hold`), GitHub and destinations.
    public var heldCount: Int
    /// Linked-copy groups recreated (P9).
    public var linkGroupCount: Int
    /// The repository to open afterwards (the first one imported now), and the stage.
    public var firstRepositoryID: RepoID?
    public var firstStage: String?

    public init() {
        repositories = []
        destinationsCreated = []
        destinationItemsWritten = 0
        folders = []
        heldCount = 0
        linkGroupCount = 0
    }

    /// Every row the import changed.
    public var changedCount: Int {
        repositories.reduce(0) { $0 + $1.changedCount } + destinationItemsWritten
    }
}

// MARK: - Repository access (P7)

/// Whether this Mac can import a bundle's repository that is not in the vault, and the import
/// itself (the one-click import of §9.5, for each ⇣ repository).
public protocol ShareRepositoryAccessChecking: Sendable {
    /// Looks `owner/name` up with this Mac's GitHub accounts. Never throws: a failure is
    /// ``ShareRepositoryAccess/unreachable``.
    func access(owner: String, name: String) async -> ShareRepositoryAccess
    /// Imports `owner/name` into the vault (through `accountLogin` when given) and returns its id,
    /// also when it is already there.
    func importRepository(owner: String, name: String, accountLogin: String?) async throws -> RepoID
}
