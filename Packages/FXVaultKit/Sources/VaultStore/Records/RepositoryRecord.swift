import Foundation
import GRDB
import VaultCore

/// One `repositories` row (§6 `v2_accounts_repos` + `v5_create_policies`).
///
/// Visibility is stored as `is_private` only, so ``RepoVisibility/internal`` reads back as
/// ``RepoVisibility/private``.
public struct RepositoryRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repositories"

    public var id: RepoID
    public var accountLogin: String
    /// GraphQL node id (`gh --json id`); nil until a created repository exists on GitHub.
    public var githubID: String?
    public var ownerLogin: String
    public var ownerType: OwnerType
    public var name: String
    public var description: String?
    public var isPrivate: Bool
    public var isArchived: Bool
    public var isFork: Bool
    public var defaultBranch: String?
    public var hasAdmin: Bool
    public var hasPush: Bool
    public var origin: RepoOrigin
    public var isEnvPlanGated: Bool
    public var isUnavailable: Bool
    public var importedAt: Date
    public var lastRefreshedAt: Date?
    public var createdAtGitHub: Date?
    /// `create_spec_json`: JSON with snake_case keys (`auto_init`, …).
    public var createSpec: RepoCreateSpecModel?
    public var clonePath: String?

    public init(_ model: RepoModel) {
        id = model.id
        accountLogin = model.accountLogin
        githubID = model.githubID
        ownerLogin = model.ownerLogin
        ownerType = model.ownerType
        name = model.name
        description = model.description
        isPrivate = model.visibility.isPrivate
        isArchived = model.isArchived
        isFork = model.isFork
        defaultBranch = model.defaultBranch
        hasAdmin = model.hasAdmin
        hasPush = model.hasPush
        origin = model.origin
        isEnvPlanGated = model.isEnvPlanGated
        isUnavailable = model.isUnavailable
        importedAt = model.importedAt
        lastRefreshedAt = model.lastRefreshedAt
        createdAtGitHub = model.createdAtGitHub
        createSpec = model.createSpec
        clonePath = model.clonePath
    }

    /// The domain model.
    public var model: RepoModel {
        RepoModel(
            id: id,
            accountLogin: accountLogin,
            githubID: githubID,
            ownerLogin: ownerLogin,
            ownerType: ownerType,
            name: name,
            description: description,
            visibility: RepoVisibility(isPrivate: isPrivate),
            isArchived: isArchived,
            isFork: isFork,
            defaultBranch: defaultBranch,
            hasAdmin: hasAdmin,
            hasPush: hasPush,
            origin: origin,
            isEnvPlanGated: isEnvPlanGated,
            isUnavailable: isUnavailable,
            importedAt: importedAt,
            lastRefreshedAt: lastRefreshedAt,
            createdAtGitHub: createdAtGitHub,
            createSpec: createSpec,
            clonePath: clonePath
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case accountLogin = "account_login"
        case githubID = "github_id"
        case ownerLogin = "owner_login"
        case ownerType = "owner_type"
        case name
        case description
        case isPrivate = "is_private"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case defaultBranch = "default_branch"
        case hasAdmin = "has_admin"
        case hasPush = "has_push"
        case origin
        case isEnvPlanGated = "is_env_plan_gated"
        case isUnavailable = "is_unavailable"
        case importedAt = "imported_at"
        case lastRefreshedAt = "last_refreshed_at"
        case createdAtGitHub = "created_at_github"
        case createSpec = "create_spec_json"
        case clonePath = "clone_path"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
