import Foundation

/// A GitHub repository tracked in the vault (`repositories` row, §6 `v2_accounts_repos`, `v5`).
public struct RepoModel: Sendable, Hashable, Identifiable {
    public var id: RepoID
    /// The gh account used for every call on this repository.
    public var accountLogin: String
    /// gh `--json id` (GraphQL node id). Nil until a created repository exists on GitHub.
    public var githubID: String?
    public var ownerLogin: String
    public var ownerType: OwnerType
    public var name: String
    public var description: String?
    public var visibility: RepoVisibility
    public var isArchived: Bool
    public var isFork: Bool
    public var defaultBranch: String?
    /// The viewer has admin rights (`viewerPermission` ADMIN).
    public var hasAdmin: Bool
    /// The viewer can push (`viewerPermission` ADMIN, MAINTAIN or WRITE).
    public var hasPush: Bool
    public var origin: RepoOrigin
    /// Clearable hint: an environment write failed because of the GitHub plan.
    public var isEnvPlanGated: Bool
    /// The repository could not be read (for example SAML not authorized, or no longer listed).
    public var isUnavailable: Bool
    public var importedAt: Date
    public var lastRefreshedAt: Date?
    public var createdAtGitHub: Date?
    /// The creation options for a repository FX Vault creates (`create_spec_json`, M4).
    public var createSpec: RepoCreateSpecModel?
    /// Where the repository was cloned, if FX Vault cloned it (`clone_path`, M4).
    public var clonePath: String?

    public init(
        id: RepoID = RepoID(),
        accountLogin: String,
        githubID: String?,
        ownerLogin: String,
        ownerType: OwnerType,
        name: String,
        description: String? = nil,
        visibility: RepoVisibility,
        isArchived: Bool = false,
        isFork: Bool = false,
        defaultBranch: String? = nil,
        hasAdmin: Bool = false,
        hasPush: Bool = false,
        origin: RepoOrigin,
        isEnvPlanGated: Bool = false,
        isUnavailable: Bool = false,
        importedAt: Date,
        lastRefreshedAt: Date? = nil,
        createdAtGitHub: Date? = nil,
        createSpec: RepoCreateSpecModel? = nil,
        clonePath: String? = nil
    ) {
        self.id = id
        self.accountLogin = accountLogin
        self.githubID = githubID
        self.ownerLogin = ownerLogin
        self.ownerType = ownerType
        self.name = name
        self.description = description
        self.visibility = visibility
        self.isArchived = isArchived
        self.isFork = isFork
        self.defaultBranch = defaultBranch
        self.hasAdmin = hasAdmin
        self.hasPush = hasPush
        self.origin = origin
        self.isEnvPlanGated = isEnvPlanGated
        self.isUnavailable = isUnavailable
        self.importedAt = importedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.createdAtGitHub = createdAtGitHub
        self.createSpec = createSpec
        self.clonePath = clonePath
    }

    /// `owner/name`.
    public var fullName: String {
        "\(ownerLogin)/\(name)"
    }

    /// True once the repository exists on GitHub (a created repository is pending until then).
    public var existsOnGitHub: Bool {
        githubID != nil
    }

    /// What the viewer may change, with the default WRITE policy (§2, Q6).
    public var capability: RepoCapabilityModel {
        capability(writePolicy: .default)
    }

    /// What the viewer may change, with an explicit WRITE policy.
    public func capability(writePolicy: WriteCollaboratorPolicy) -> RepoCapabilityModel {
        RepoCapabilityModel(
            hasAdmin: hasAdmin,
            hasPush: hasPush,
            isArchived: isArchived,
            isUnavailable: isUnavailable,
            writePolicy: writePolicy
        )
    }
}

/// `repositories.owner_type`.
public enum OwnerType: String, Sendable, Hashable, Codable, CaseIterable {
    case user = "User"
    case organization = "Organization"
}

/// Repository visibility as gh reports it (`visibility`: PUBLIC, PRIVATE, INTERNAL).
///
/// The database stores only `is_private`, so ``internal`` is read back as ``private``.
public enum RepoVisibility: String, Sendable, Hashable, Codable, CaseIterable {
    case `public` = "PUBLIC"
    case `private` = "PRIVATE"
    case `internal` = "INTERNAL"

    /// Database form: anything that is not public is private.
    public init(isPrivate: Bool) {
        self = isPrivate ? .private : .public
    }

    /// `repositories.is_private`.
    public var isPrivate: Bool {
        self != .public
    }
}

/// How the repository entered the vault (`repositories.origin`).
public enum RepoOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case imported
    case created
}

/// gh `viewerPermission` (§8 B1).
public enum ViewerPermission: String, Sendable, Hashable, Codable, CaseIterable {
    case admin = "ADMIN"
    case maintain = "MAINTAIN"
    case write = "WRITE"
    case triage = "TRIAGE"
    case read = "READ"

    /// Parses gh's value in any case. Unknown or empty values return nil (treat as no access).
    public init?(ghValue: String) {
        self.init(rawValue: ghValue.uppercased())
    }

    /// `repositories.has_admin`: ADMIN only.
    public var hasAdmin: Bool {
        self == .admin
    }

    /// `repositories.has_push`: ADMIN, MAINTAIN or WRITE.
    public var hasPush: Bool {
        switch self {
        case .admin, .maintain, .write: true
        case .triage, .read: false
        }
    }
}

/// The options FX Vault used to create a repository (`create_spec_json`, M4).
public struct RepoCreateSpecModel: Sendable, Hashable, Codable {
    /// `--add-readme`.
    public var autoInit: Bool
    /// `--gitignore=<template>`.
    public var gitignoreTemplate: String?
    /// `--license=<key>`.
    public var licenseTemplate: String?
    /// Clone into the default folder after creation.
    public var cloneAfter: Bool

    public init(
        autoInit: Bool,
        gitignoreTemplate: String? = nil,
        licenseTemplate: String? = nil,
        cloneAfter: Bool
    ) {
        self.autoInit = autoInit
        self.gitignoreTemplate = gitignoreTemplate
        self.licenseTemplate = licenseTemplate
        self.cloneAfter = cloneAfter
    }

    private enum CodingKeys: String, CodingKey {
        case autoInit = "auto_init"
        case gitignoreTemplate = "gitignore_template"
        case licenseTemplate = "license_template"
        case cloneAfter = "clone_after"
    }
}
