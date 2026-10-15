import Foundation
import GitHubKit
import VaultCore

/// Everything `CreateRepoScreen` collects (§10, M4). Staged locally by
/// ``RepoCreationRepository/stage(_:)`` so that **one** Sync creates the repository, its
/// environments and their items. Values are the caller's: it wipes them after staging.
public struct RepoCreationDraftModel: Sendable {
    /// The gh account that creates (and later manages) the repository.
    public var accountLogin: String
    /// The account itself or one of its organizations (A5).
    public var ownerLogin: String
    public var ownerType: OwnerType
    public var name: String
    public var description: String?
    public var visibility: RepoVisibility
    /// README, .gitignore and license templates, and "Clone to my Mac" (`create_spec_json`).
    public var spec: RepoCreateSpecModel
    /// Repository-level secrets and variables.
    public var items: [RepoCreationItemDraftModel]
    public var environments: [RepoCreationEnvironmentDraftModel]

    public init(
        accountLogin: String,
        ownerLogin: String,
        ownerType: OwnerType,
        name: String,
        description: String? = nil,
        visibility: RepoVisibility,
        spec: RepoCreateSpecModel,
        items: [RepoCreationItemDraftModel] = [],
        environments: [RepoCreationEnvironmentDraftModel] = []
    ) {
        self.accountLogin = accountLogin
        self.ownerLogin = ownerLogin
        self.ownerType = ownerType
        self.name = name
        self.description = description
        self.visibility = visibility
        self.spec = spec
        self.items = items
        self.environments = environments
    }
}

/// One environment of a new repository.
public struct RepoCreationEnvironmentDraftModel: Sendable {
    public var name: String
    public var policy: BranchPolicyDraftModel
    public var items: [RepoCreationItemDraftModel]

    public init(name: String, policy: BranchPolicyDraftModel = .all, items: [RepoCreationItemDraftModel] = []) {
        self.name = name
        self.policy = policy
        self.items = items
    }
}

/// One secret or variable of a new repository. The value is normalized on staging (D32).
public struct RepoCreationItemDraftModel: Sendable {
    public var kind: ConfigKind
    public var name: String
    public var value: SecretBytes

    public init(kind: ConfigKind, name: String, value: SecretBytes) {
        self.kind = kind
        self.name = name
        self.value = value
    }
}

/// The staged repository.
public struct RepoStagingResultModel: Sendable, Hashable {
    public var repositoryID: RepoID
    /// Items whose value lost trailing CR/LF on entry (D32 notice), as `environment/NAME` or
    /// `NAME` at repository level. Names only.
    public var strippedTrailingNewlines: [String]

    public init(repositoryID: RepoID, strippedTrailingNewlines: [String]) {
        self.repositoryID = repositoryID
        self.strippedTrailingNewlines = strippedTrailingNewlines
    }
}

/// The live name check of `CreateRepoScreen` (§8 B2). gh returns "Could not resolve to a
/// Repository" both for a free name and for one the token cannot see, so a free name is only
/// "probably available"; the create error is the authoritative check.
public enum RepoNameAvailabilityModel: Sendable, Hashable {
    case probablyAvailable
    case taken
    /// The owner or name breaks a rule (no gh call was made).
    case invalid(ValidationError)
    /// The check itself failed (offline, token, ...).
    case unknown(GHError)
}

/// One owner the new repository can belong to: the account, then its organizations (A5).
public struct RepoOwnerChoiceModel: Sendable, Hashable, Identifiable {
    public var login: String
    public var ownerType: OwnerType

    public init(login: String, ownerType: OwnerType) {
        self.login = login
        self.ownerType = ownerType
    }

    public var id: String {
        OwnerLoginValidator.foldKey(login)
    }
}

/// What happened to one clone a Sync requested (§7.3 step 8).
public struct RepoCloneOutcomeModel: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Cloned to this folder.
        case cloned(URL)
        case failed(RepoCreationError)
        /// No clone folder (or no cloner) was given; offer the Clone button instead.
        case notAttempted
    }

    public var repositoryID: RepoID
    public var state: State

    public init(repositoryID: RepoID, state: State) {
        self.repositoryID = repositoryID
        self.state = state
    }

    public var id: RepoID {
        repositoryID
    }
}

/// Clones a repository of the vault through its account's SSH alias (§8 D3, D18). Implemented
/// by ``RepoCreationRepository``; ``SyncRepository`` uses it for "clone after".
public protocol RepoCloning: Sendable {
    /// Clones the repository into `<folder>/<name>` and records the path. Returns that path.
    func clone(_ repositoryID: RepoID, into folder: URL) async throws(RepoCreationError) -> URL
}
