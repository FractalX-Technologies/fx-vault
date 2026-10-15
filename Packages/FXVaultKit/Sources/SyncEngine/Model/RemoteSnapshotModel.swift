import Foundation
import GitHubKit
import VaultCore

/// What GitHub has for one repository, from full native re-lists (tasks/todo.md §7.7, D13):
/// B3 environments (+ B5 patterns), B6/B7 secrets and B8/B9 variables, every page.
///
/// Holds no values. Variable values are reduced to row-bound fingerprints (§5.4) for every local
/// row that could be compared with them; secrets carry only `updatedAt`.
public struct RemoteSnapshotModel: Sendable, Hashable {
    /// Repository-level items, or nil when that scope was not listed.
    public var repository: RemoteScopeListingModel?
    /// Every environment GitHub listed (valid names only).
    public var environments: [RemoteEnvironmentModel]
    /// Environment names GitHub listed that fail `EnvironmentNameValidator` (D29). They are
    /// left out of ``environments``; the caller logs their count, never acts on them.
    public var ignoredEnvironmentNames: [String]

    public init(
        repository: RemoteScopeListingModel?,
        environments: [RemoteEnvironmentModel],
        ignoredEnvironmentNames: [String] = []
    ) {
        self.repository = repository
        self.environments = environments
        self.ignoredEnvironmentNames = ignoredEnvironmentNames
    }

    /// The environment whose name folds to `scope`'s key.
    public func environment(_ scope: RemoteScopeKeyModel) -> RemoteEnvironmentModel? {
        guard let key = scope.environmentKey else { return nil }
        return environments.first { $0.scope.environmentKey == key }
    }

    /// The listing of `scope`, or nil when it was not listed (or the environment is absent).
    public func listing(_ scope: RemoteScopeKeyModel) -> RemoteScopeListingModel? {
        if scope.environmentKey == nil { return repository }
        return environment(scope)?.listing
    }
}

/// The secrets and variables of one scope.
public struct RemoteScopeListingModel: Sendable, Hashable {
    public var secrets: [RemoteSecretModel]
    public var variables: [RemoteVariableModel]

    public init(secrets: [RemoteSecretModel], variables: [RemoteVariableModel]) {
        self.secrets = secrets
        self.variables = variables
    }

    /// The secret whose name folds to `nameKey`.
    public func secret(nameKey: String) -> RemoteSecretModel? {
        secrets.first { $0.nameKey == nameKey }
    }

    /// The variable whose name folds to `nameKey`.
    public func variable(nameKey: String) -> RemoteVariableModel? {
        variables.first { $0.nameKey == nameKey }
    }

    /// The listed item of `kind` whose name folds to `nameKey`.
    public func item(kind: ConfigKind, nameKey: String) -> RemoteItemModel? {
        switch kind {
        case .secret: secret(nameKey: nameKey).map(RemoteItemModel.secret)
        case .variable: variable(nameKey: nameKey).map(RemoteItemModel.variable)
        }
    }

    /// Every listed item.
    public var items: [RemoteItemModel] {
        secrets.map(RemoteItemModel.secret) + variables.map(RemoteItemModel.variable)
    }
}

/// One listed secret (B6/B7). Secret values can never be read back.
public struct RemoteSecretModel: Sendable, Hashable {
    public var name: String
    public var updatedAt: Date?

    public init(name: String, updatedAt: Date?) {
        self.name = name
        self.updatedAt = updatedAt
    }

    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}

/// One listed variable (B8/B9), reduced to fingerprints.
public struct RemoteVariableModel: Sendable, Hashable {
    public var name: String
    public var updatedAt: Date?
    /// `fp(listed value)` bound to each local row it may be compared with (§5.4: fingerprints
    /// are row-bound, so there is one per candidate row).
    public var fingerprints: [ConfigItemID: Data]

    public init(name: String, updatedAt: Date?, fingerprints: [ConfigItemID: Data]) {
        self.name = name
        self.updatedAt = updatedAt
        self.fingerprints = fingerprints
    }

    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }

    /// The listed value's fingerprint under `rowID`, if it was computed.
    public func fingerprint(for rowID: ConfigItemID) -> Data? {
        fingerprints[rowID]
    }
}

/// A listed secret or variable.
public enum RemoteItemModel: Sendable, Hashable {
    case secret(RemoteSecretModel)
    case variable(RemoteVariableModel)

    public var kind: ConfigKind {
        switch self {
        case .secret: .secret
        case .variable: .variable
        }
    }

    public var name: String {
        switch self {
        case .secret(let secret): secret.name
        case .variable(let variable): variable.name
        }
    }

    public var updatedAt: Date? {
        switch self {
        case .secret(let secret): secret.updatedAt
        case .variable(let variable): variable.updatedAt
        }
    }

    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}

/// One environment GitHub listed (B3), with its patterns and items when they were listed.
public struct RemoteEnvironmentModel: Sendable, Hashable {
    /// GitHub's numeric id (`github_env_id`).
    public var githubID: Int64
    /// The name as GitHub stores it (GitHub keeps the case it was created with).
    public var name: String
    public var updatedAt: Date?
    public var branchPolicy: BranchPolicyKind
    /// B5 patterns; nil when not listed (not custom, or not fetched).
    public var patterns: [RemoteBranchPatternModel]?
    /// Rules other than `branch_policy`, canonical JSON (read-only, §6 `foreign_rules_json`).
    public var foreignRulesJSON: String?
    /// The environment's items; nil when its scopes were not listed.
    public var listing: RemoteScopeListingModel?

    public init(
        githubID: Int64,
        name: String,
        updatedAt: Date? = nil,
        branchPolicy: BranchPolicyKind,
        patterns: [RemoteBranchPatternModel]? = nil,
        foreignRulesJSON: String? = nil,
        listing: RemoteScopeListingModel?
    ) {
        self.githubID = githubID
        self.name = name
        self.updatedAt = updatedAt
        self.branchPolicy = branchPolicy
        self.patterns = patterns
        self.foreignRulesJSON = foreignRulesJSON
        self.listing = listing
    }

    public var scope: RemoteScopeKeyModel {
        .environment(named: name)
    }
}

/// One deployment branch or tag policy GitHub listed (B5).
public struct RemoteBranchPatternModel: Sendable, Hashable {
    public var githubPolicyID: Int64
    public var pattern: String
    public var type: BranchPatternType

    public init(githubPolicyID: Int64, pattern: String, type: BranchPatternType) {
        self.githubPolicyID = githubPolicyID
        self.pattern = pattern
        self.type = type
    }
}

// MARK: - Building from GitHubKit listings

/// The raw listings of one scope, as GitHubKit returns them.
public struct RemoteScopeListingInputModel: Sendable {
    public var secrets: [GHSecretDTO]
    /// Values stay owned by the caller (it may need them for "Accept GitHub"); the builder only
    /// fingerprints them and never wipes them.
    public var variables: [GHVariableListingModel]

    public init(secrets: [GHSecretDTO], variables: [GHVariableListingModel]) {
        self.secrets = secrets
        self.variables = variables
    }
}

/// One listed environment with its optional B5 patterns and B7/B9 listings.
public struct RemoteEnvironmentInputModel: Sendable {
    public var environment: GHEnvironmentDTO
    public var branchPolicies: [GHBranchPolicyDTO]?
    public var listing: RemoteScopeListingInputModel?

    public init(
        environment: GHEnvironmentDTO,
        branchPolicies: [GHBranchPolicyDTO]? = nil,
        listing: RemoteScopeListingInputModel?
    ) {
        self.environment = environment
        self.branchPolicies = branchPolicies
        self.listing = listing
    }
}

extension RemoteSnapshotModel {
    /// Builds the snapshot from GitHubKit listings.
    ///
    /// Each listed variable is fingerprinted once for every local variable row in the matching
    /// scope whose `name` or `synced_name` folds to the listed name: those are the only rows
    /// drift detection, optimistic concurrency and the pending-verification pass compare it
    /// with. A local environment matches a remote one by `synced_name_key` or `name_key`.
    ///
    /// - Parameters:
    ///   - local: the local snapshot of the same repository.
    ///   - repository: B6 + B8, or nil when the repository scope was not listed.
    ///   - environments: B3 (+ B5, B7, B9) for every listed environment.
    ///   - fingerprint: the row-bound fingerprint (`UnlockedKeys.fingerprint(_:rowID:)`).
    public init(
        local: RepoSnapshotModel,
        repository: RemoteScopeListingInputModel?,
        environments: [RemoteEnvironmentInputModel],
        fingerprint: (SecretBytes, ConfigItemID) -> Data
    ) {
        let candidates = VariableCandidateIndex(local: local)
        let repositoryListing = repository.map {
            Self.listing(from: $0, scope: .repository, candidates: candidates, fingerprint: fingerprint)
        }
        var remoteEnvironments: [RemoteEnvironmentModel] = []
        var ignored: [String] = []
        for input in environments {
            let dto = input.environment
            guard dto.hasValidName else {
                ignored.append(dto.name)
                continue
            }
            let scope = RemoteScopeKeyModel.environment(named: dto.name)
            remoteEnvironments.append(RemoteEnvironmentModel(
                githubID: dto.id,
                name: dto.name,
                updatedAt: dto.updatedAt,
                branchPolicy: dto.branchPolicyKind,
                patterns: input.branchPolicies?.map {
                    RemoteBranchPatternModel(githubPolicyID: $0.id, pattern: $0.name, type: $0.type)
                },
                foreignRulesJSON: dto.foreignRulesJSON,
                listing: input.listing.map {
                    Self.listing(from: $0, scope: scope, candidates: candidates, fingerprint: fingerprint)
                }
            ))
        }
        self.init(repository: repositoryListing, environments: remoteEnvironments, ignoredEnvironmentNames: ignored)
    }

    private static func listing(
        from input: RemoteScopeListingInputModel,
        scope: RemoteScopeKeyModel,
        candidates: VariableCandidateIndex,
        fingerprint: (SecretBytes, ConfigItemID) -> Data
    ) -> RemoteScopeListingModel {
        let secrets = input.secrets.map { RemoteSecretModel(name: $0.name, updatedAt: $0.updatedAt) }
        let variables = input.variables.map { listed in
            let key = RemoteItemKeyModel(scope: scope, kind: .variable, name: listed.name)
            var fingerprints: [ConfigItemID: Data] = [:]
            for rowID in candidates.rows(for: key) {
                fingerprints[rowID] = fingerprint(listed.value, rowID)
            }
            return RemoteVariableModel(name: listed.name, updatedAt: listed.updatedAt, fingerprints: fingerprints)
        }
        return RemoteScopeListingModel(secrets: secrets, variables: variables)
    }
}

/// Local variable rows by every remote key they may be compared with.
private struct VariableCandidateIndex {
    private var rowsByKey: [RemoteItemKeyModel: [ConfigItemID]] = [:]

    init(local: RepoSnapshotModel) {
        var scopeKeysByEnvironment: [EnvironmentID: Set<RemoteScopeKeyModel>] = [:]
        for environment in local.environments {
            var keys: Set<RemoteScopeKeyModel> = [.environment(named: environment.name)]
            if let syncedName = environment.syncedName {
                keys.insert(.environment(named: syncedName))
            }
            scopeKeysByEnvironment[environment.id] = keys
        }
        for item in local.items where item.kind == .variable {
            let scopes: Set<RemoteScopeKeyModel> = switch item.scope {
            case .repository: [.repository]
            case .environment(let id): scopeKeysByEnvironment[id] ?? []
            }
            let names = [item.name] + (item.syncedName.map { [$0] } ?? [])
            var keys: Set<RemoteItemKeyModel> = []
            for scope in scopes {
                for name in names {
                    keys.insert(RemoteItemKeyModel(scope: scope, kind: .variable, name: name))
                }
            }
            for key in keys {
                rowsByKey[key, default: []].append(item.id)
            }
        }
    }

    func rows(for key: RemoteItemKeyModel) -> [ConfigItemID] {
        rowsByKey[key] ?? []
    }
}
