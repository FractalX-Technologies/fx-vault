import Foundation
import GitHubKit
import VaultCore
import VaultCrypto
import VaultStore

/// One repository row of the sidebar (§10 Column 1): listed by gh, added by name, or only known
/// from the vault.
public struct CatalogRepoModel: Sendable, Hashable, Identifiable {
    /// How the row entered the catalog.
    public enum Source: Sendable, Hashable {
        /// `gh repo list <owner>` (B1).
        case listed
        /// **Add repository by name** (B2), for collaborator access gh cannot list (§2).
        case addedByName
        /// In the vault but not in this listing (added by name earlier, or no longer listed).
        case vaultOnly
    }

    public let ref: GHRepoRef
    public let ownerType: OwnerType
    public let visibility: RepoVisibility
    public let isArchived: Bool
    public let isFork: Bool
    public let hasAdmin: Bool
    public let hasPush: Bool
    /// The repository could not be read (SAML, removed). Only known for vault rows.
    public let isUnavailable: Bool
    /// The vault row, when the repository is imported (otherwise the row is dimmed and the
    /// detail column offers **Import**).
    public let importedRepoID: RepoID?
    public let source: Source

    public init(
        ref: GHRepoRef,
        ownerType: OwnerType,
        visibility: RepoVisibility,
        isArchived: Bool,
        isFork: Bool,
        hasAdmin: Bool,
        hasPush: Bool,
        isUnavailable: Bool,
        importedRepoID: RepoID?,
        source: Source
    ) {
        self.ref = ref
        self.ownerType = ownerType
        self.visibility = visibility
        self.isArchived = isArchived
        self.isFork = isFork
        self.hasAdmin = hasAdmin
        self.hasPush = hasPush
        self.isUnavailable = isUnavailable
        self.importedRepoID = importedRepoID
        self.source = source
    }

    /// The case-folded `owner/name`.
    public var id: String {
        ref.foldKey
    }

    public var isImported: Bool {
        importedRepoID != nil
    }

    /// What the viewer may change, from `viewerPermission` and `isArchived` (§2).
    public func capability(writePolicy: WriteCollaboratorPolicy = .default) -> RepoCapabilityModel {
        RepoCapabilityModel(
            hasAdmin: hasAdmin,
            hasPush: hasPush,
            isArchived: isArchived,
            isUnavailable: isUnavailable,
            writePolicy: writePolicy
        )
    }
}

/// One owner group of an account (§10: Personal, then each organization).
public struct OwnerCatalogModel: Sendable, Hashable, Identifiable {
    public let login: String
    public let ownerType: OwnerType
    public let repositories: [CatalogRepoModel]
    /// Why B1 failed for this owner (for example `.samlRequired`, shown as a banner); nil when
    /// it was listed.
    public let failure: GHError?
    /// gh returned exactly `Limits.repoListMax` repositories: the list may be cut ("List
    /// truncated").
    public let isTruncated: Bool

    public init(login: String, ownerType: OwnerType, repositories: [CatalogRepoModel], failure: GHError?, isTruncated: Bool) {
        self.login = login
        self.ownerType = ownerType
        self.repositories = repositories
        self.failure = failure
        self.isTruncated = isTruncated
    }

    public var id: String {
        OwnerLoginValidator.foldKey(login)
    }

    /// The owner could not be listed.
    public var isUnavailable: Bool {
        failure != nil
    }
}

/// The catalog of one account: its own repositories, then each organization's (§8 A5, B1).
public struct AccountCatalogModel: Sendable, Hashable {
    public let accountLogin: String
    public let owners: [OwnerCatalogModel]
    /// Why A5 failed (organizations then cannot be listed); nil on success. Without `read:org`
    /// the list can also be silently incomplete (§2).
    public let organizationsFailure: GHError?

    public init(accountLogin: String, owners: [OwnerCatalogModel], organizationsFailure: GHError?) {
        self.accountLogin = accountLogin
        self.owners = owners
        self.organizationsFailure = organizationsFailure
    }
}

/// A remote read that failed during an import; the rest of the repository was imported and the
/// affected scope shows as unreadable.
public struct ImportReadFailureModel: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// B3: the environment list.
        case environments
        /// B5: one custom environment's patterns.
        case branchPolicies(environment: String)
        /// B6/B7: secrets of the repository (nil) or one environment.
        case secrets(environment: String?)
        /// B8/B9: variables of the repository (nil) or one environment.
        case variables(environment: String?)
    }

    public let target: Target
    public let error: GHError

    public init(target: Target, error: GHError) {
        self.target = target
        self.error = error
    }
}

/// A remote name the vault cannot hold (D29: invalid environment, item or pattern name), skipped
/// during import.
public struct SkippedRemoteNameModel: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case environment
        case item(ConfigKind)
        case branchPattern
    }

    public let kind: Kind
    /// The environment the name belongs to (nil at repository level or for environments).
    public let environment: String?
    public let name: String

    public init(kind: Kind, environment: String?, name: String) {
        self.kind = kind
        self.environment = environment
        self.name = name
    }
}

/// What ``RepoCatalogRepository/importRepository(_:accountLogin:)`` stored.
public struct RepoImportResultModel: Sendable, Hashable {
    public let repository: RepoModel
    public let environmentCount: Int
    public let secretCount: Int
    public let variableCount: Int
    public let unreadable: [ImportReadFailureModel]
    public let skippedNames: [SkippedRemoteNameModel]

    public init(
        repository: RepoModel,
        environmentCount: Int,
        secretCount: Int,
        variableCount: Int,
        unreadable: [ImportReadFailureModel],
        skippedNames: [SkippedRemoteNameModel]
    ) {
        self.repository = repository
        self.environmentCount = environmentCount
        self.secretCount = secretCount
        self.variableCount = variableCount
        self.unreadable = unreadable
        self.skippedNames = skippedNames
    }
}

/// Why a ``RepoCatalogRepository`` operation failed. Carries no localized text.
public enum RepoCatalogError: Error, Sendable, Hashable {
    /// A gh command failed (including `.invalidInput` for a malformed `owner/name`).
    case github(GHError)
    case store(StoreError)
    /// Import needs an unlocked vault (variables are encrypted).
    case vault(VaultError)
    case encryptionFailed
    /// No vault row with that id.
    case repositoryNotFound
    /// The repository is already in the vault; use refresh or drift review instead.
    case alreadyImported(RepoID)
    /// An error of an unknown type (never expected).
    case unexpected

    static func wrap(_ error: any Error) -> RepoCatalogError {
        switch error {
        case let error as RepoCatalogError: error
        case let error as GHError: .github(error)
        case let error as StoreError: .store(error)
        case let error as VaultError: .vault(error)
        case is CryptoError: .encryptionFailed
        default: .unexpected
        }
    }
}
