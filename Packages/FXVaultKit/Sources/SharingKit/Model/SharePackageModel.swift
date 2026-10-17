import Foundation
import VaultCore

/// Tag for ids of entries inside a share package: config items and environments share one id
/// space so the nearby DECISION can list both (§9.4 step 8).
public enum ShareEntryTag {}

/// Id of a config item or environment inside a share package (not a vault row id).
public typealias ShareEntryID = Identifier<ShareEntryTag>

/// What a share package contains (§9.3). The scope only describes the contents; the receiver
/// merges every package the same way (nothing missing from a package is ever deleted).
public enum ShareScope: String, Sendable, Hashable, Codable, CaseIterable {
    /// Exactly one config item (a secret or a variable), at repository or environment level.
    case secret
    /// Exactly one environment with its branch policy and items; no repository-level items.
    case environment
    /// Any other combination: all or some repository-level items, whole environments (with
    /// their branch policy) and partial environments (selected items, no policy), in any mix.
    case repository
    /// A copy of a folder (v0.7.0, schema v3): its name and its secrets and variables, every one
    /// with a value. It belongs to no repository; the receiver saves it as a folder or imports it
    /// into a repository scope it chooses (``SharePackageModel/intoRepository(owner:name:githubRepoID:environmentName:)``).
    case folder
}

/// The sender's view of an item's sync state.
public enum ShareSyncState: String, Sendable, Hashable, Codable, CaseIterable {
    /// The sender's value is what GitHub has (verified push or imported).
    case synced
    /// The sender has a local change that was never pushed.
    case pending
}

/// A `.fxvault` / nearby share document, schema `io.fractalx.fxvault.share` v1 or v2 (§9.3).
///
/// Values are ``SecretBytes`` and are only present in a full package; the manifest
/// (``manifest()``) carries the same document with every value set to null. Value hashes are
/// never included. Call ``wipeValues()`` once a package is no longer needed.
///
/// **Schema versions** (docs/SHARING-PROTOCOL.md §1.1): v1 (FX Vault 0.1.x) requires a branch
/// policy on every environment; v2 (0.2.0) also allows a *partial* environment, one that carries
/// only selected items and `deploymentBranchPolicy: null`. A package is always written with the
/// lowest version that can hold it (``requiredSchemaVersion(for:)``), so anything 0.1.x can express
/// is still readable by 0.1.x. v3 (0.7.0) is a folder (scope ``ShareScope/folder``): on the wire a
/// `folder` object (`name`, `secrets`, `variables`) replaces `repository`; in memory the items are
/// at repository level of a ``repository`` with an empty owner and name, so manifests, filters,
/// summaries and wiping work unchanged. Older versions refuse v3 as an unsupported version.
public struct SharePackageModel: Sendable, Equatable {
    /// The only accepted `schema` value.
    public static let schemaIdentifier = "io.fractalx.fxvault.share"
    /// Every environment carries its branch policy (FX Vault 0.1.x).
    public static let wholeEnvironmentsSchemaVersion = 1
    /// Environments may omit their branch policy when only some of their items are shared.
    public static let partialEnvironmentsSchemaVersion = 2
    /// A folder (v0.7.0).
    public static let folderSchemaVersion = 3
    /// The newest `schemaVersion` this build reads and writes.
    public static let currentSchemaVersion = folderSchemaVersion
    /// Every `schemaVersion` this build accepts.
    public static let supportedSchemaVersions = wholeEnvironmentsSchemaVersion...currentSchemaVersion
    /// The versions a repository package (any scope but ``ShareScope/folder``) may carry.
    public static let repositorySchemaVersions = wholeEnvironmentsSchemaVersion...partialEnvironmentsSchemaVersion

    public var schema: String
    public var schemaVersion: Int
    /// `packageId`: random per export, used for replay detection (§9.5).
    public var packageID: SharePackageID
    public var createdAt: Date
    public var producer: ShareProducerModel
    public var sender: ShareSenderModel
    public var scope: ShareScope
    /// The repository and its items; for a folder (scope ``ShareScope/folder``) only the items
    /// count (owner and name are empty, no environments).
    public var repository: ShareRepositoryModel
    /// The folder's name; set exactly for scope ``ShareScope/folder`` (v0.7.0).
    public var folder: ShareFolderModel?

    /// - Parameter schemaVersion: nil writes ``requiredSchemaVersion(for:)`` of `repository`, or
    ///   ``folderSchemaVersion`` for a folder.
    public init(
        schema: String = SharePackageModel.schemaIdentifier,
        schemaVersion: Int? = nil,
        packageID: SharePackageID = SharePackageID(),
        createdAt: Date,
        producer: ShareProducerModel,
        sender: ShareSenderModel,
        scope: ShareScope,
        repository: ShareRepositoryModel,
        folder: ShareFolderModel? = nil
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
            ?? (scope == .folder ? Self.folderSchemaVersion : Self.requiredSchemaVersion(for: repository))
        self.packageID = packageID
        self.createdAt = createdAt
        self.producer = producer
        self.sender = sender
        self.scope = scope
        self.repository = repository
        self.folder = folder
    }

    /// A folder package (v0.7.0): `secrets` and `variables` with their values.
    public static func folder(
        named name: String,
        secrets: [ShareItemModel],
        variables: [ShareItemModel],
        packageID: SharePackageID = SharePackageID(),
        createdAt: Date,
        producer: ShareProducerModel,
        sender: ShareSenderModel
    ) -> SharePackageModel {
        SharePackageModel(
            packageID: packageID,
            createdAt: createdAt,
            producer: producer,
            sender: sender,
            scope: .folder,
            repository: ShareFolderModel.container(secrets: secrets, variables: variables),
            folder: ShareFolderModel(name: name)
        )
    }

    /// True for a folder (v0.7.0).
    public var isFolder: Bool {
        scope == .folder
    }

    /// A folder package as a repository package for `owner/name` (v0.7.0 "Import Into…"): its
    /// items at repository level, or in `environmentName` as a partial environment (no branch
    /// policy, schema v2), so the usual import planner, preview and merge apply. Same package id,
    /// sender and values (the buffers are shared: wipe one of them). Nil for a package that is
    /// not a folder.
    public func intoRepository(owner: String, name: String, githubRepoID: String?, environmentName: String?) -> SharePackageModel? {
        guard isFolder else { return nil }
        var target = ShareRepositoryModel(owner: owner, name: name, githubRepoID: githubRepoID)
        if let environmentName {
            target.environments = [ShareEnvironmentModel(
                name: environmentName,
                deploymentBranchPolicy: nil,
                secrets: repository.secrets,
                variables: repository.variables
            )]
        } else {
            target.secrets = repository.secrets
            target.variables = repository.variables
        }
        return SharePackageModel(
            packageID: packageID,
            createdAt: createdAt,
            producer: producer,
            sender: sender,
            scope: .repository,
            repository: target
        )
    }

    /// The lowest schema version that can hold `repository`: v2 only when an environment omits
    /// its branch policy.
    public static func requiredSchemaVersion(for repository: ShareRepositoryModel) -> Int {
        repository.environments.allSatisfy(\.includesBranchPolicy)
            ? wholeEnvironmentsSchemaVersion
            : partialEnvironmentsSchemaVersion
    }

    // MARK: - Manifest and filtering

    /// The same document with every value set to null (`valueState` is kept), used for the
    /// nearby MANIFEST and the preview. The returned package shares no value buffers.
    public func manifest() -> SharePackageModel {
        var copy = self
        copy.repository = repository.mapItems { item in
            var stripped = item
            stripped.value = nil
            return stripped
        }
        return copy
    }

    /// Every entry id: repository-level items, environments and environment items.
    public var allEntryIDs: Set<ShareEntryID> {
        var ids = Set(repository.secrets.map(\.id) + repository.variables.map(\.id))
        for environment in repository.environments {
            ids.insert(environment.id)
            ids.formUnion(environment.secrets.map(\.id) + environment.variables.map(\.id))
        }
        return ids
    }

    /// The package restricted to `ids` (nearby step 9: manifest ∩ itemIds). An environment is
    /// kept when any of its items is selected, or when its own id is and it carries a branch
    /// policy (a partial environment without items would say nothing); only selected items are
    /// kept. The branch policy and `schemaVersion` stay as they are: the receiver's choice never
    /// adds or removes a policy.
    public func filtered(to ids: Set<ShareEntryID>) -> SharePackageModel {
        var copy = self
        copy.repository.secrets = repository.secrets.filter { ids.contains($0.id) }
        copy.repository.variables = repository.variables.filter { ids.contains($0.id) }
        copy.repository.environments = repository.environments.compactMap { environment in
            var kept = environment
            kept.secrets = environment.secrets.filter { ids.contains($0.id) }
            kept.variables = environment.variables.filter { ids.contains($0.id) }
            let keepsPolicy = ids.contains(environment.id) && environment.includesBranchPolicy
            return keepsPolicy || kept.itemCount > 0 ? kept : nil
        }
        return copy
    }

    /// Every config item with its location, repository level first, in document order.
    public var flattenedItems: [ShareLocatedItemModel] {
        repository.flattenedItems
    }

    /// Number of config items (not environments).
    public var itemCount: Int {
        flattenedItems.count
    }

    /// Counts per scope (repository level, then each environment) for summaries. Names and
    /// counts only, never values.
    public var contentSummary: ShareContentSummaryModel {
        Self.summary(of: repository)
    }

    /// Counts per scope of `repository` (also used by bundles, v0.9.0).
    static func summary(of repository: ShareRepositoryModel) -> ShareContentSummaryModel {
        ShareContentSummaryModel(
            repositoryLevel: ShareItemCountModel(
                secrets: repository.secrets.count,
                variables: repository.variables.count
            ),
            environments: repository.environments.map { environment in
                ShareEnvironmentSummaryModel(
                    name: environment.name,
                    counts: ShareItemCountModel(
                        secrets: environment.secrets.count,
                        variables: environment.variables.count
                    ),
                    includesBranchPolicy: environment.includesBranchPolicy
                )
            }
        )
    }

    /// Zeroes every value buffer in place. Copies of this package share the same buffers.
    public func wipeValues() {
        for located in flattenedItems {
            located.item.value?.wipe()
        }
    }
}

/// `folder`: what a folder package (v0.7.0) says about the folder besides its items.
public struct ShareFolderModel: Sendable, Hashable {
    /// The sender's folder name (``FolderNameValidator``, NFC).
    public var name: String

    public init(name: String) {
        self.name = name
    }

    /// The in-memory holder of a folder's items: a repository block with no owner, name or
    /// environments.
    static func container(secrets: [ShareItemModel], variables: [ShareItemModel]) -> ShareRepositoryModel {
        ShareRepositoryModel(owner: "", name: "", githubRepoID: nil, secrets: secrets, variables: variables)
    }
}

/// `producer`: the app that wrote the package.
public struct ShareProducerModel: Sendable, Hashable, Codable {
    /// The producer name written by FX Vault.
    public static let fxVaultAppName = "FX Vault"

    public var app: String
    public var version: String

    public init(app: String = ShareProducerModel.fxVaultAppName, version: String) {
        self.app = app
        self.version = version
    }
}

/// `sender`: the sender's display name. Unverified: the UI labels it as such.
public struct ShareSenderModel: Sendable, Hashable, Codable {
    public var displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }
}

/// `repository`: the target repository plus its shared items and environments.
public struct ShareRepositoryModel: Sendable, Equatable {
    /// Always `github.com` (D29).
    public var host: String
    public var owner: String
    public var name: String
    /// `githubRepoId`: the GraphQL node id (`R_…`) when the sender knows it.
    public var githubRepoID: String?
    public var secrets: [ShareItemModel]
    public var variables: [ShareItemModel]
    public var environments: [ShareEnvironmentModel]

    public init(
        host: String = GitHubHostValidator.host,
        owner: String,
        name: String,
        githubRepoID: String?,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = [],
        environments: [ShareEnvironmentModel] = []
    ) {
        self.host = host
        self.owner = owner
        self.name = name
        self.githubRepoID = githubRepoID
        self.secrets = secrets
        self.variables = variables
        self.environments = environments
    }

    /// `owner/name`.
    public var fullName: String {
        "\(owner)/\(name)"
    }

    /// This repository with the entry ids of `other` (v0.4.0 chat configurations): entry ids are
    /// random per package, so a package rebuilt from the vault for an offer's payload takes the
    /// offer's ids before both are compared. Nil when the two differ in shape (environments or
    /// items added, removed or reordered); names, states, policies and values are not compared.
    public func withEntryIDs(of other: ShareRepositoryModel) -> ShareRepositoryModel? {
        func items(_ items: [ShareItemModel], _ others: [ShareItemModel]) -> [ShareItemModel]? {
            guard items.count == others.count else { return nil }
            return zip(items, others).map { item, other in
                var copy = item
                copy.id = other.id
                return copy
            }
        }
        guard environments.count == other.environments.count,
              let secrets = items(secrets, other.secrets),
              let variables = items(variables, other.variables)
        else { return nil }
        var copy = self
        copy.secrets = secrets
        copy.variables = variables
        copy.environments = []
        for (environment, otherEnvironment) in zip(environments, other.environments) {
            guard let secrets = items(environment.secrets, otherEnvironment.secrets),
                  let variables = items(environment.variables, otherEnvironment.variables)
            else { return nil }
            var renumbered = environment
            renumbered.id = otherEnvironment.id
            renumbered.secrets = secrets
            renumbered.variables = variables
            copy.environments.append(renumbered)
        }
        return copy
    }

    /// Every config item with its location, repository level first, in document order.
    public var flattenedItems: [ShareLocatedItemModel] {
        var result = secrets.map {
            ShareLocatedItemModel(environmentName: nil, kind: .secret, item: $0)
        }
        result += variables.map {
            ShareLocatedItemModel(environmentName: nil, kind: .variable, item: $0)
        }
        for environment in environments {
            result += environment.secrets.map {
                ShareLocatedItemModel(environmentName: environment.name, kind: .secret, item: $0)
            }
            result += environment.variables.map {
                ShareLocatedItemModel(environmentName: environment.name, kind: .variable, item: $0)
            }
        }
        return result
    }

    func mapItems(_ transform: (ShareItemModel) -> ShareItemModel) -> ShareRepositoryModel {
        var copy = self
        copy.secrets = secrets.map(transform)
        copy.variables = variables.map(transform)
        copy.environments = environments.map { environment in
            var mapped = environment
            mapped.secrets = environment.secrets.map(transform)
            mapped.variables = environment.variables.map(transform)
            return mapped
        }
        return copy
    }
}

/// One secret or variable in a package. The kind comes from the list it is in.
public struct ShareItemModel: Sendable, Equatable, Identifiable {
    public var id: ShareEntryID
    /// GitHub name, uppercase.
    public var name: String
    /// The value, or nil when not included (manifest) or missing at the sender.
    public var value: SecretBytes?
    /// Whether the sender has a value. In a full package, `present` ⇔ `value != nil`.
    public var valueState: ConfigValueState
    /// GitHub's `updatedAt` for this item as last seen by the sender.
    public var githubUpdatedAt: Date?
    public var syncState: ShareSyncState
    /// `link` (schema 4 only, v0.9.0): a per-file token shared by the items of one linked-copy
    /// group inside a bundle (at least two of them). Never the sender's `link_id`; nil in
    /// schemas 1–3, where the validator rejects it.
    public var linkToken: String?

    public init(
        id: ShareEntryID = ShareEntryID(),
        name: String,
        value: SecretBytes?,
        valueState: ConfigValueState,
        githubUpdatedAt: Date?,
        syncState: ShareSyncState,
        linkToken: String? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.valueState = valueState
        self.githubUpdatedAt = githubUpdatedAt
        self.syncState = syncState
        self.linkToken = linkToken
    }
}

/// One environment in a package, with its deployment branch policy and items.
///
/// A **whole** environment (the sender selected the environment itself) carries its policy. A
/// **partial** environment (the sender selected only some of its items, schema v2) carries
/// `deploymentBranchPolicy == nil` and at least one item; the receiver then leaves its own
/// policy alone.
public struct ShareEnvironmentModel: Sendable, Equatable, Identifiable {
    public var id: ShareEntryID
    public var name: String
    /// Nil for a partial environment (schema v2): the policy is not shared.
    public var deploymentBranchPolicy: ShareBranchPolicyModel?
    public var secrets: [ShareItemModel]
    public var variables: [ShareItemModel]

    public init(
        id: ShareEntryID = ShareEntryID(),
        name: String,
        deploymentBranchPolicy: ShareBranchPolicyModel?,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = []
    ) {
        self.id = id
        self.name = name
        self.deploymentBranchPolicy = deploymentBranchPolicy
        self.secrets = secrets
        self.variables = variables
    }

    /// True for a whole environment (its branch policy is shared).
    public var includesBranchPolicy: Bool {
        deploymentBranchPolicy != nil
    }

    /// Number of config items in the environment.
    public var itemCount: Int {
        secrets.count + variables.count
    }
}

/// `deploymentBranchPolicy`: `{type: all|protected|custom, patterns: [{name, type}]}`.
public struct ShareBranchPolicyModel: Sendable, Hashable, Codable {
    public var type: BranchPolicyKind
    /// Only for `custom`; empty otherwise.
    public var patterns: [ShareBranchPatternModel]

    public init(type: BranchPolicyKind, patterns: [ShareBranchPatternModel] = []) {
        self.type = type
        self.patterns = patterns
    }

    /// The package form of a vault policy (tombstoned patterns are left out).
    public init(_ policy: DeploymentBranchPolicyModel) {
        type = policy.kind
        patterns = policy.activePatterns.map {
            ShareBranchPatternModel(name: $0.pattern, type: $0.type)
        }
    }

    /// The patterns as a set, for order-insensitive comparison.
    public var patternSet: Set<ShareBranchPatternModel> {
        Set(patterns)
    }
}

/// One deployment branch or tag pattern.
public struct ShareBranchPatternModel: Sendable, Hashable, Codable {
    public var name: String
    public var type: BranchPatternType

    public init(name: String, type: BranchPatternType) {
        self.name = name
        self.type = type
    }
}

/// An item together with where it lives in the package.
public struct ShareLocatedItemModel: Sendable, Equatable {
    /// Nil for repository-level items.
    public var environmentName: String?
    public var kind: ConfigKind
    public var item: ShareItemModel

    public init(environmentName: String?, kind: ConfigKind, item: ShareItemModel) {
        self.environmentName = environmentName
        self.kind = kind
        self.item = item
    }

    public var level: ConfigScopeLevel {
        environmentName == nil ? .repository : .environment
    }
}

// MARK: - Summary

/// Secrets and variables in one scope.
public struct ShareItemCountModel: Sendable, Hashable {
    public var secrets: Int
    public var variables: Int

    public init(secrets: Int, variables: Int) {
        self.secrets = secrets
        self.variables = variables
    }

    public var total: Int {
        secrets + variables
    }
}

/// One environment in a ``ShareContentSummaryModel``.
public struct ShareEnvironmentSummaryModel: Sendable, Hashable {
    public var name: String
    public var counts: ShareItemCountModel
    /// False for a partial environment: only the counted items travel, not the policy.
    public var includesBranchPolicy: Bool

    public init(name: String, counts: ShareItemCountModel, includesBranchPolicy: Bool) {
        self.name = name
        self.counts = counts
        self.includesBranchPolicy = includesBranchPolicy
    }
}

/// What a package holds per scope (``SharePackageModel/contentSummary``). Names and counts only.
public struct ShareContentSummaryModel: Sendable, Hashable {
    public var repositoryLevel: ShareItemCountModel
    public var environments: [ShareEnvironmentSummaryModel]

    public init(repositoryLevel: ShareItemCountModel, environments: [ShareEnvironmentSummaryModel]) {
        self.repositoryLevel = repositoryLevel
        self.environments = environments
    }

    /// Every config item.
    public var itemCount: Int {
        repositoryLevel.total + environments.map(\.counts.total).reduce(0, +)
    }
}
