import Foundation
import GRDB
import VaultCore

/// One `environments` row (§6 `v3_config`).
///
/// `name_key` and `synced_name_key` are always ``EnvironmentNameValidator/foldKey(_:)`` of the
/// names: they are recomputed whenever a name is set, and cannot be assigned directly. The
/// unique index `environments_repo_name (repository_id, name_key)` therefore rejects
/// `Producción` next to `PRODUCCIÓN`.
public struct EnvironmentRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "environments"

    public var id: EnvironmentID
    public var repositoryID: RepoID
    public var name: String {
        didSet { nameKey = EnvironmentNameValidator.foldKey(name) }
    }
    public private(set) var nameKey: String
    public var syncedName: String? {
        didSet { syncedNameKey = syncedName.map(EnvironmentNameValidator.foldKey) }
    }
    public private(set) var syncedNameKey: String?
    public var isDeleted: Bool
    public var branchPolicy: BranchPolicyKind
    public var syncedBranchPolicy: BranchPolicyKind?
    public var foreignRulesJSON: String?
    public var githubEnvID: Int64?
    public var remoteUpdatedAt: Date?
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    /// The row for `model`. Pattern rows of a custom policy are separate
    /// (``BranchPatternRecord``).
    public init(_ model: EnvironmentModel) {
        id = model.id
        repositoryID = model.repositoryID
        name = model.name
        nameKey = model.nameKey
        syncedName = model.syncedName
        syncedNameKey = model.syncedNameKey
        isDeleted = model.isDeleted
        branchPolicy = model.branchPolicy.kind
        syncedBranchPolicy = model.syncedBranchPolicy
        foreignRulesJSON = model.foreignRulesJSON
        githubEnvID = model.githubEnvID
        remoteUpdatedAt = model.remoteUpdatedAt
        sortOrder = model.sortOrder
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    /// The domain model. `patterns` are this environment's pattern rows (tombstones included);
    /// they are attached only when the policy is custom.
    public func model(patterns: [BranchPatternModel]) -> EnvironmentModel {
        let policy: DeploymentBranchPolicyModel = switch branchPolicy {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(patterns)
        }
        return EnvironmentModel(
            id: id,
            repositoryID: repositoryID,
            name: name,
            syncedName: syncedName,
            isDeleted: isDeleted,
            branchPolicy: policy,
            syncedBranchPolicy: syncedBranchPolicy,
            foreignRulesJSON: foreignRulesJSON,
            githubEnvID: githubEnvID,
            remoteUpdatedAt: remoteUpdatedAt,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case repositoryID = "repository_id"
        case name
        case nameKey = "name_key"
        case syncedName = "synced_name"
        case syncedNameKey = "synced_name_key"
        case isDeleted = "is_deleted"
        case branchPolicy = "branch_policy"
        case syncedBranchPolicy = "synced_branch_policy"
        case foreignRulesJSON = "foreign_rules_json"
        case githubEnvID = "github_env_id"
        case remoteUpdatedAt = "remote_updated_at"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `deployment_branch_patterns` row (§6 `v5_create_policies`).
public struct BranchPatternRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "deployment_branch_patterns"

    public var id: BranchPatternID
    public var environmentID: EnvironmentID
    public var pattern: String
    public var type: BranchPatternType
    public var githubPolicyID: Int64?
    public var isDeleted: Bool

    public init(_ model: BranchPatternModel) {
        id = model.id
        environmentID = model.environmentID
        pattern = model.pattern
        type = model.type
        githubPolicyID = model.githubPolicyID
        isDeleted = model.isDeleted
    }

    /// The domain model.
    public var model: BranchPatternModel {
        BranchPatternModel(
            id: id,
            environmentID: environmentID,
            pattern: pattern,
            type: type,
            githubPolicyID: githubPolicyID,
            isDeleted: isDeleted
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case environmentID = "environment_id"
        case pattern
        case type
        case githubPolicyID = "github_policy_id"
        case isDeleted = "is_deleted"
    }
}
