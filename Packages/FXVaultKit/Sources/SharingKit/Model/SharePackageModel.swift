import Foundation
import VaultCore

/// Tag for ids of entries inside a share package: config items and environments share one id
/// space so the nearby DECISION can list both (§9.4 step 8).
public enum ShareEntryTag {}

/// Id of a config item or environment inside a share package (not a vault row id).
public typealias ShareEntryID = Identifier<ShareEntryTag>

/// What a share package contains (§9.3).
public enum ShareScope: String, Sendable, Hashable, Codable, CaseIterable {
    /// Exactly one config item (a secret or a variable), at repository or environment level.
    case secret
    /// Exactly one environment with its items and policy; no repository-level items.
    case environment
    /// Any mix of repository-level items and environments.
    case repository
}

/// The sender's view of an item's sync state.
public enum ShareSyncState: String, Sendable, Hashable, Codable, CaseIterable {
    /// The sender's value is what GitHub has (verified push or imported).
    case synced
    /// The sender has a local change that was never pushed.
    case pending
}

/// A `.fxvault` / nearby share document, schema `io.fractalx.fxvault.share` v1 (§9.3).
///
/// Values are ``SecretBytes`` and are only present in a full package; the manifest
/// (``manifest()``) carries the same document with every value set to null. Value hashes are
/// never included. Call ``wipeValues()`` once a package is no longer needed.
public struct SharePackageModel: Sendable, Equatable {
    /// The only accepted `schema` value.
    public static let schemaIdentifier = "io.fractalx.fxvault.share"
    /// The only accepted `schemaVersion` value.
    public static let currentSchemaVersion = 1

    public var schema: String
    public var schemaVersion: Int
    /// `packageId`: random per export, used for replay detection (§9.5).
    public var packageID: SharePackageID
    public var createdAt: Date
    public var producer: ShareProducerModel
    public var sender: ShareSenderModel
    public var scope: ShareScope
    public var repository: ShareRepositoryModel

    public init(
        schema: String = SharePackageModel.schemaIdentifier,
        schemaVersion: Int = SharePackageModel.currentSchemaVersion,
        packageID: SharePackageID = SharePackageID(),
        createdAt: Date,
        producer: ShareProducerModel,
        sender: ShareSenderModel,
        scope: ShareScope,
        repository: ShareRepositoryModel
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.packageID = packageID
        self.createdAt = createdAt
        self.producer = producer
        self.sender = sender
        self.scope = scope
        self.repository = repository
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
    /// kept when its own id is selected or any of its items is; only selected items are kept.
    public func filtered(to ids: Set<ShareEntryID>) -> SharePackageModel {
        var copy = self
        copy.repository.secrets = repository.secrets.filter { ids.contains($0.id) }
        copy.repository.variables = repository.variables.filter { ids.contains($0.id) }
        copy.repository.environments = repository.environments.compactMap { environment in
            var kept = environment
            kept.secrets = environment.secrets.filter { ids.contains($0.id) }
            kept.variables = environment.variables.filter { ids.contains($0.id) }
            let isSelected = ids.contains(environment.id)
            return isSelected || !kept.secrets.isEmpty || !kept.variables.isEmpty ? kept : nil
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
public struct ShareEnvironmentModel: Sendable, Equatable, Identifiable {
    public var id: ShareEntryID
    public var name: String
    public var deploymentBranchPolicy: ShareBranchPolicyModel
    public var secrets: [ShareItemModel]
    public var variables: [ShareItemModel]

    public init(
        id: ShareEntryID = ShareEntryID(),
        name: String,
        deploymentBranchPolicy: ShareBranchPolicyModel,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = []
    ) {
        self.id = id
        self.name = name
        self.deploymentBranchPolicy = deploymentBranchPolicy
        self.secrets = secrets
        self.variables = variables
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
