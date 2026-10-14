import Foundation
import VaultCore

/// One repository from `gh repo list/view --json <B1 fields>` (tasks/todo.md §8 B1, B2).
public struct GHRepoDTO: Sendable, Hashable, Decodable {
    public struct OwnerDTO: Sendable, Hashable, Decodable {
        public let login: String
    }

    public struct BranchRefDTO: Sendable, Hashable, Decodable {
        public let name: String
    }

    /// GraphQL node id.
    public let id: String
    public let name: String
    public let nameWithOwner: String
    public let owner: OwnerDTO
    public let isPrivate: Bool
    /// `PUBLIC`, `PRIVATE` or `INTERNAL`.
    public let visibility: String?
    public let isArchived: Bool
    public let isFork: Bool
    /// `ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, `READ`, or empty.
    public let viewerPermission: String?
    public let viewerCanAdminister: Bool?
    /// `{"name": ""}` for an empty repository.
    public let defaultBranchRef: BranchRefDTO?
    public let sshUrl: String?
    public let createdAt: Date?

    /// The `--json` field list for B1 and B2.
    public static let jsonFields = [
        "id", "name", "nameWithOwner", "owner", "isPrivate", "visibility", "isArchived", "isFork",
        "viewerPermission", "viewerCanAdminister", "defaultBranchRef", "sshUrl", "createdAt",
    ].joined(separator: ",")

    /// The validated owner and name, or nil when either fails validation (such rows are
    /// skipped and logged, §8 B1).
    public var repoRef: GHRepoRef? {
        try? GHRepoRef(owner: owner.login, name: name)
    }

    /// Parsed `viewerPermission`; nil when absent or unknown (treated as no access).
    public var permission: ViewerPermission? {
        viewerPermission.flatMap(ViewerPermission.init(ghValue:))
    }

    /// The default branch, or nil for an empty repository.
    public var defaultBranch: String? {
        guard let name = defaultBranchRef?.name, !name.isEmpty else { return nil }
        return name
    }

    /// Visibility, falling back to `isPrivate`.
    public var repoVisibility: RepoVisibility {
        visibility.flatMap { RepoVisibility(rawValue: $0.uppercased()) } ?? RepoVisibility(isPrivate: isPrivate)
    }

    /// A new `RepoModel` for this listing, or nil when the names fail validation.
    /// `ownerType` comes from which list the repository was in (§8 B1).
    public func makeRepoModel(accountLogin: String, ownerType: OwnerType, importedAt: Date) -> RepoModel? {
        guard let ref = repoRef else { return nil }
        let permission = permission
        return RepoModel(
            accountLogin: accountLogin,
            githubID: id,
            ownerLogin: ref.owner,
            ownerType: ownerType,
            name: ref.name,
            visibility: repoVisibility,
            isArchived: isArchived,
            isFork: isFork,
            defaultBranch: defaultBranch,
            hasAdmin: permission?.hasAdmin ?? false,
            hasPush: permission?.hasPush ?? false,
            origin: .imported,
            importedAt: importedAt,
            lastRefreshedAt: importedAt,
            createdAtGitHub: createdAt
        )
    }
}
