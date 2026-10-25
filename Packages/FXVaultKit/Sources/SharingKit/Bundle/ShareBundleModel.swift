import Foundation
import VaultCore

/// A project share (v0.9.0, schema `io.fractalx.fxvault.share` version 4, `scope: "bundle"`):
/// one or more repositories, each with its repository-level items, GitHub environments and runtime
/// destinations, plus optional folders (tasks/todo.md P1, P10).
///
/// Every export from 0.9 on writes this document; schemas 1–3 (``SharePackageModel``) stay
/// readable through ``ShareDocumentCoder``. Values are ``SecretBytes`` and are present only in a
/// full bundle; ``manifest()`` returns the same document with every value nil. `az` sessions and
/// the sender's `link_id`s never travel: linked copies inside the file share a
/// per-file ``ShareItemModel/linkToken``. Call ``wipeValues()`` once a bundle is no longer needed.
public struct ShareBundleModel: Sendable, Equatable {
    /// The `schemaVersion` of a bundle.
    public static let schemaVersion = 4
    /// The `scope` value of a bundle.
    public static let scopeIdentifier = "bundle"

    public var schema: String
    public var schemaVersion: Int
    /// `packageId`: random per export, used for replay detection (§9.5).
    public var packageID: SharePackageID
    public var createdAt: Date
    /// After this date FX Vault refuses to open the file (P6). Enforced by the app, not the
    /// cryptography.
    public var expiresAt: Date
    public var producer: ShareProducerModel
    /// The sender's display name (unverified).
    public var sender: ShareSenderModel
    /// The stages the sender chose, in their order. The receiver opens the Overview at the first
    /// one (P7).
    public var stages: [String]
    public var repositories: [ShareBundleRepositoryModel]
    public var folders: [ShareBundleFolderModel]

    public init(
        schema: String = SharePackageModel.schemaIdentifier,
        schemaVersion: Int = ShareBundleModel.schemaVersion,
        packageID: SharePackageID = SharePackageID(),
        createdAt: Date,
        expiresAt: Date,
        producer: ShareProducerModel,
        sender: ShareSenderModel,
        stages: [String] = [],
        repositories: [ShareBundleRepositoryModel] = [],
        folders: [ShareBundleFolderModel] = []
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.producer = producer
        self.sender = sender
        self.stages = stages
        self.repositories = repositories
        self.folders = folders
    }

    /// A bundle created at `createdAt` that expires after `expiry`.
    public init(
        packageID: SharePackageID = SharePackageID(),
        createdAt: Date,
        expiry: ShareExpiryChoice,
        producer: ShareProducerModel,
        sender: ShareSenderModel,
        stages: [String] = [],
        repositories: [ShareBundleRepositoryModel] = [],
        folders: [ShareBundleFolderModel] = []
    ) {
        self.init(
            packageID: packageID,
            createdAt: createdAt,
            expiresAt: expiry.expiry(from: createdAt),
            producer: producer,
            sender: sender,
            stages: stages,
            repositories: repositories,
            folders: folders
        )
    }

    /// A schema 1–3 package as a bundle (v0.9.0: every `.fxvault` file FX Vault writes is a
    /// bundle): a repository package becomes one repository without destinations, a folder
    /// package one folder. Same package id (replay detection), producer, sender and values (the
    /// buffers are shared: wipe one of them); created at `createdAt` (the date it is written, not
    /// the package's own) and expiring after `expiry`. No stages: the receiver opens the Overview
    /// without one.
    public init(package: SharePackageModel, createdAt: Date, expiry: ShareExpiryChoice) {
        var repositories: [ShareBundleRepositoryModel] = []
        var folders: [ShareBundleFolderModel] = []
        if package.isFolder, let folder = package.folder {
            folders = [ShareBundleFolderModel(
                name: folder.name,
                secrets: package.repository.secrets,
                variables: package.repository.variables
            )]
        } else {
            repositories = [ShareBundleRepositoryModel(repository: package.repository)]
        }
        self.init(
            packageID: package.packageID,
            createdAt: createdAt,
            expiry: expiry,
            producer: package.producer,
            sender: package.sender,
            repositories: repositories,
            folders: folders
        )
    }

    // MARK: - Freshness

    /// Throws ``ShareError/expired`` once `expiresAt` has passed (with ``Timeouts/shareClockSkew``
    /// of tolerance) and `.invalidPackage(.createdInFuture)` for a `createdAt` further ahead of
    /// `now` than the skew. Run after decrypting, before the preview.
    public func checkFreshness(now: Date) throws(ShareError) {
        let skew = Timeouts.shareClockSkew.timeInterval
        if createdAt.timeIntervalSince(now) > skew {
            throw .invalidPackage(.createdInFuture)
        }
        if now.timeIntervalSince(expiresAt) > skew {
            throw .expired
        }
    }

    // MARK: - Manifest

    /// The same document with every value set to nil (`valueState` is kept). The returned bundle
    /// shares no value buffers.
    public func manifest() -> ShareBundleModel {
        var copy = self
        copy.repositories = repositories.map { $0.mapItems(ShareBundleModel.stripValue) }
        copy.folders = folders.map { $0.mapItems(ShareBundleModel.stripValue) }
        return copy
    }

    private static func stripValue(_ item: ShareItemModel) -> ShareItemModel {
        var stripped = item
        stripped.value = nil
        return stripped
    }

    // MARK: - Contents

    /// Every item of the bundle with where it lives, in document order: per repository its
    /// repository level, environments and destinations, then the folders.
    public var allItems: [ShareBundleLocatedItemModel] {
        var result: [ShareBundleLocatedItemModel] = []
        for (repositoryIndex, entry) in repositories.enumerated() {
            for located in entry.repository.flattenedItems {
                let place: ShareBundleItemPlace = located.environmentName.map {
                    .environment(repository: repositoryIndex, name: $0)
                } ?? .repositoryLevel(repository: repositoryIndex)
                result.append(ShareBundleLocatedItemModel(place: place, kind: located.kind, item: located.item))
            }
            for destination in entry.destinations {
                let place = ShareBundleItemPlace.destination(repository: repositoryIndex, id: destination.id)
                result += destination.secrets.map { ShareBundleLocatedItemModel(place: place, kind: .secret, item: $0) }
                result += destination.variables.map { ShareBundleLocatedItemModel(place: place, kind: .variable, item: $0) }
            }
        }
        for folder in folders {
            let place = ShareBundleItemPlace.folder(id: folder.id)
            result += folder.secrets.map { ShareBundleLocatedItemModel(place: place, kind: .secret, item: $0) }
            result += folder.variables.map { ShareBundleLocatedItemModel(place: place, kind: .variable, item: $0) }
        }
        return result
    }

    /// Number of secrets and variables in the bundle.
    public var itemCount: Int {
        allItems.count
    }

    /// Every entry id: environments, destinations, folders and items.
    public var allEntryIDs: [ShareEntryID] {
        var ids: [ShareEntryID] = []
        for entry in repositories {
            ids += entry.repository.environments.map(\.id)
            ids += entry.destinations.map(\.id)
        }
        ids += folders.map(\.id)
        ids += allItems.map(\.item.id)
        return ids
    }

    /// The items of each link token (only tokens used by at least two items are valid).
    public var linkGroups: [String: [ShareEntryID]] {
        var groups: [String: [ShareEntryID]] = [:]
        for located in allItems {
            if let token = located.item.linkToken {
                groups[token, default: []].append(located.item.id)
            }
        }
        return groups
    }

    /// Counts per repository and folder for summaries. Names and counts only, never values.
    public var contentSummary: ShareBundleSummaryModel {
        ShareBundleSummaryModel(
            repositories: repositories.map { entry in
                ShareBundleRepositorySummaryModel(
                    owner: entry.repository.owner,
                    name: entry.repository.name,
                    content: SharePackageModel.summary(of: entry.repository),
                    destinations: entry.destinations.map { destination in
                        ShareDestinationSummaryModel(
                            target: destination.target,
                            stage: destination.stage,
                            counts: ShareItemCountModel(
                                secrets: destination.secrets.count,
                                variables: destination.variables.count
                            )
                        )
                    },
                    retiredDestinations: entry.retiredDestinations
                )
            },
            folders: folders.map { folder in
                ShareBundleFolderSummaryModel(
                    name: folder.name,
                    counts: ShareItemCountModel(secrets: folder.secrets.count, variables: folder.variables.count)
                )
            }
        )
    }

    /// Zeroes every value buffer in place. Copies of this bundle share the same buffers.
    public func wipeValues() {
        for located in allItems {
            located.item.value?.wipe()
        }
    }
}

/// One repository of a bundle: its GitHub scopes (repository level and environments, whole or
/// partial as in schema 2) and its runtime destinations.
public struct ShareBundleRepositoryModel: Sendable, Equatable, Identifiable {
    public var repository: ShareRepositoryModel
    public var destinations: [ShareDestinationModel]
    /// Labels of the Supabase and Vercel destinations a 0.9 file carried, dropped on decode (1.0
    /// keeps Key Vault only) so the preview can say so. Never encoded.
    public var retiredDestinations: [String]

    public init(repository: ShareRepositoryModel, destinations: [ShareDestinationModel] = [], retiredDestinations: [String] = []) {
        self.repository = repository
        self.destinations = destinations
        self.retiredDestinations = retiredDestinations
    }

    /// The case-insensitive `owner/name` identity (owner and repository fold keys).
    public var id: String {
        "\(OwnerLoginValidator.foldKey(repository.owner))/\(RepoNameValidator.foldKey(repository.name))"
    }

    func mapItems(_ transform: (ShareItemModel) -> ShareItemModel) -> ShareBundleRepositoryModel {
        var copy = self
        copy.repository = repository.mapItems(transform)
        copy.destinations = destinations.map { $0.mapItems(transform) }
        return copy
    }
}

/// A runtime destination in a bundle (v0.9.0): where it is, its stage and its items with values.
public struct ShareDestinationModel: Sendable, Equatable, Identifiable {
    public var id: ShareEntryID
    public var target: DestinationTargetModel
    /// ``EnvironmentNameValidator`` rules, or nil.
    public var stage: String?
    public var secrets: [ShareItemModel]
    /// Always empty from 1.0: Key Vault holds secrets only (R3).
    public var variables: [ShareItemModel]

    public init(
        id: ShareEntryID = ShareEntryID(),
        target: DestinationTargetModel,
        stage: String?,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = []
    ) {
        self.id = id
        self.target = target
        self.stage = stage
        self.secrets = secrets
        self.variables = variables
    }

    public var provider: DestinationProvider {
        target.provider
    }

    /// Secrets and variables together.
    public var itemCount: Int {
        secrets.count + variables.count
    }

    func mapItems(_ transform: (ShareItemModel) -> ShareItemModel) -> ShareDestinationModel {
        var copy = self
        copy.secrets = secrets.map(transform)
        copy.variables = variables.map(transform)
        return copy
    }
}

/// A folder in a bundle (v0.9.0): its name and items, every one with a value (as in schema 3).
public struct ShareBundleFolderModel: Sendable, Equatable, Identifiable {
    public var id: ShareEntryID
    /// The sender's folder name (``FolderNameValidator``, NFC).
    public var name: String
    public var secrets: [ShareItemModel]
    public var variables: [ShareItemModel]

    public init(
        id: ShareEntryID = ShareEntryID(),
        name: String,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = []
    ) {
        self.id = id
        self.name = name
        self.secrets = secrets
        self.variables = variables
    }

    /// Secrets and variables together.
    public var itemCount: Int {
        secrets.count + variables.count
    }

    /// This folder as a schema 3 folder package, so VaultData's existing "Save as Folder" applies
    /// it. Same values (the buffers are shared: wipe one of them); link tokens are dropped.
    public func folderPackage(
        packageID: SharePackageID,
        createdAt: Date,
        producer: ShareProducerModel,
        sender: ShareSenderModel
    ) -> SharePackageModel {
        let withoutLinks = mapItems { item in
            var copy = item
            copy.linkToken = nil
            return copy
        }
        return SharePackageModel.folder(
            named: name,
            secrets: withoutLinks.secrets,
            variables: withoutLinks.variables,
            packageID: packageID,
            createdAt: createdAt,
            producer: producer,
            sender: sender
        )
    }

    func mapItems(_ transform: (ShareItemModel) -> ShareItemModel) -> ShareBundleFolderModel {
        var copy = self
        copy.secrets = secrets.map(transform)
        copy.variables = variables.map(transform)
        return copy
    }
}

/// Where an item of a bundle lives.
public enum ShareBundleItemPlace: Sendable, Hashable {
    /// Repository level of `repositories[repository]`.
    case repositoryLevel(repository: Int)
    /// The environment `name` of `repositories[repository]`.
    case environment(repository: Int, name: String)
    /// The destination `id` of `repositories[repository]`.
    case destination(repository: Int, id: ShareEntryID)
    /// The folder `id`.
    case folder(id: ShareEntryID)
}

/// An item of a bundle with its place and kind.
public struct ShareBundleLocatedItemModel: Sendable, Equatable {
    public var place: ShareBundleItemPlace
    public var kind: ConfigKind
    public var item: ShareItemModel

    public init(place: ShareBundleItemPlace, kind: ConfigKind, item: ShareItemModel) {
        self.place = place
        self.kind = kind
        self.item = item
    }
}

// MARK: - Summary

/// What a bundle holds (``ShareBundleModel/contentSummary``). Names and counts only.
public struct ShareBundleSummaryModel: Sendable, Hashable {
    public var repositories: [ShareBundleRepositorySummaryModel]
    public var folders: [ShareBundleFolderSummaryModel]

    public init(repositories: [ShareBundleRepositorySummaryModel], folders: [ShareBundleFolderSummaryModel]) {
        self.repositories = repositories
        self.folders = folders
    }

    /// Every secret and variable.
    public var itemCount: Int {
        repositories.map(\.itemCount).reduce(0, +) + folders.map(\.counts.total).reduce(0, +)
    }
}

/// One repository in a ``ShareBundleSummaryModel``.
public struct ShareBundleRepositorySummaryModel: Sendable, Hashable {
    public var owner: String
    public var name: String
    public var content: ShareContentSummaryModel
    public var destinations: [ShareDestinationSummaryModel]
    /// ``ShareBundleRepositoryModel/retiredDestinations``.
    public var retiredDestinations: [String]

    public init(
        owner: String,
        name: String,
        content: ShareContentSummaryModel,
        destinations: [ShareDestinationSummaryModel],
        retiredDestinations: [String] = []
    ) {
        self.owner = owner
        self.name = name
        self.content = content
        self.destinations = destinations
        self.retiredDestinations = retiredDestinations
    }

    public var fullName: String {
        "\(owner)/\(name)"
    }

    /// Secrets and variables in GitHub scopes and destinations.
    public var itemCount: Int {
        content.itemCount + destinations.map(\.counts.total).reduce(0, +)
    }
}

/// One destination in a ``ShareBundleRepositorySummaryModel``.
public struct ShareDestinationSummaryModel: Sendable, Hashable {
    public var target: DestinationTargetModel
    public var stage: String?
    public var counts: ShareItemCountModel

    public init(target: DestinationTargetModel, stage: String?, counts: ShareItemCountModel) {
        self.target = target
        self.stage = stage
        self.counts = counts
    }
}

/// One folder in a ``ShareBundleSummaryModel``.
public struct ShareBundleFolderSummaryModel: Sendable, Hashable {
    public var name: String
    public var counts: ShareItemCountModel

    public init(name: String, counts: ShareItemCountModel) {
        self.name = name
        self.counts = counts
    }
}
