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
/// is still readable by 0.1.x.
public struct SharePackageModel: Sendable, Equatable {
    /// The only accepted `schema` value.
    public static let schemaIdentifier = "io.fractalx.fxvault.share"
    /// Every environment carries its branch policy (FX Vault 0.1.x).
    public static let wholeEnvironmentsSchemaVersion = 1
    /// Environments may omit their branch policy when only some of their items are shared.
    public static let partialEnvironmentsSchemaVersion = 2
    /// The newest `schemaVersion` this build reads and writes.
    public static let currentSchemaVersion = partialEnvironmentsSchemaVersion
    /// Every `schemaVersion` this build accepts.
    public static let supportedSchemaVersions = wholeEnvironmentsSchemaVersion...currentSchemaVersion

    public var schema: String
    public var schemaVersion: Int
    /// `packageId`: random per export, used for replay detection (§9.5).
    public var packageID: SharePackageID
    public var createdAt: Date
    public var producer: ShareProducerModel
    public var sender: ShareSenderModel
    public var scope: ShareScope
    public var repository: ShareRepositoryModel

    /// - Parameter schemaVersion: nil writes ``requiredSchemaVersion(for:)`` of `repository`.
    public init(
        schema: String = SharePackageModel.schemaIdentifier,
        schemaVersion: Int? = nil,
        packageID: SharePackageID = SharePackageID(),
        createdAt: Date,
        producer: ShareProducerModel,
        sender: ShareSenderModel,
        scope: ShareScope,
        repository: ShareRepositoryModel
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion ?? Self.requiredSchemaVersion(for: repository)
        self.packageID = packageID
        self.createdAt = createdAt
        self.producer = producer
        self.sender = sender
        self.scope = scope
        self.repository = repository
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
        var result = repository.secrets.map {
            ShareLocatedItemModel(environmentName: nil, kind: .secret, item: $0)
        }
        result += repository.variables.map {
            ShareLocatedItemModel(environmentName: nil, kind: .variable, item: $0)
        }
        for environment in repository.environments {
            result += environment.secrets.map {
                ShareLocatedItemModel(environmentName: environment.name, kind: .secret, item: $0)
            }
            result += environment.variables.map {
                ShareLocatedItemModel(environmentName: environment.name, kind: .variable, item: $0)
            }
        }
        return result
    }

    /// Number of config items (not environments).
    public var itemCount: Int {
        flattenedItems.count
    }

    /// Counts per scope (repository level, then each environment) for summaries. Names and
    /// counts only, never values.
    public var contentSummary: ShareContentSummaryModel {
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

    public init(
        id: ShareEntryID = ShareEntryID(),
        name: String,
        value: SecretBytes?,
        valueState: ConfigValueState,
        githubUpdatedAt: Date?,
        syncState: ShareSyncState
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.valueState = valueState
        self.githubUpdatedAt = githubUpdatedAt
        self.syncState = syncState
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
