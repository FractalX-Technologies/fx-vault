import Foundation
import GitHubKit
import VaultCore
import VaultData

/// A badge on a sidebar repository row (§10 Column 1).
enum SidebarRepoBadge: Hashable, CaseIterable {
    case `private`
    case archived
    case fork
    case unavailable
    /// Created in FX Vault and not on GitHub until the next Sync.
    case notOnGitHub
}

/// One repository row: listed by gh, added by name, or only in the vault.
struct SidebarRepoModel: Identifiable, Hashable {
    /// `<account fold key>|<owner/name fold key>`: unique even when two accounts list the same
    /// repository.
    let id: String
    /// The case-folded `owner/name`.
    let repoKey: String
    let accountLogin: String
    let ownerLogin: String
    let name: String
    let visibility: RepoVisibility
    let isArchived: Bool
    let isFork: Bool
    let isUnavailable: Bool
    /// The vault row; nil until imported (the row is dimmed and the detail column offers Import).
    let importedRepoID: RepoID?
    /// False for a repository FX Vault created that the next Sync will create on GitHub.
    let existsOnGitHub: Bool

    var fullName: String {
        "\(ownerLogin)/\(name)"
    }

    var isImported: Bool {
        importedRepoID != nil
    }

    var badges: [SidebarRepoBadge] {
        var badges: [SidebarRepoBadge] = []
        if !existsOnGitHub { badges.append(.notOnGitHub) }
        if visibility.isPrivate { badges.append(.private) }
        if isArchived { badges.append(.archived) }
        if isFork { badges.append(.fork) }
        if isUnavailable { badges.append(.unavailable) }
        return badges
    }

    /// The `GHRepoRef` for gh calls (import, look-up).
    func ref() throws(GHError) -> GHRepoRef {
        try GHRepoRef(owner: ownerLogin, name: name)
    }

    static func foldKey(owner: String, name: String) -> String {
        "\(OwnerLoginValidator.foldKey(owner))/\(RepoNameValidator.foldKey(name))"
    }
}

/// An owner group under an account: the account itself ("Personal") or an organization.
struct SidebarOwnerModel: Identifiable, Hashable {
    /// `<account fold key>/<owner fold key>`.
    let id: String
    let login: String
    /// The gh account the group is listed under (organization reads go through it).
    let accountLogin: String
    let ownerType: OwnerType
    /// True for the account's own repositories (shown as "Personal").
    let isAccount: Bool
    /// Why gh could not list this owner (SAML banner, not found); nil when listed.
    let failure: GHError?
    /// gh returned the listing maximum; the list may be cut.
    let isTruncated: Bool
    let repos: [SidebarRepoModel]
    /// The organization's own secrets and variables in the vault (1.0); nil until imported.
    let organization: OrganizationModel?

    /// An organization group (not the account's own repositories): it has the organization row.
    var isOrganization: Bool {
        !isAccount && ownerType == .organization
    }

    /// The SAML authorization link gh printed, when the owner needs SAML SSO.
    var samlAuthorizationURL: URL? {
        if case .samlRequired(let url) = failure { return url }
        return nil
    }

    var requiresSAML: Bool {
        if case .samlRequired = failure { return true }
        return false
    }
}

/// One gh account with its owner groups.
struct SidebarAccountModel: Identifiable, Hashable {
    /// The lowercase login.
    let id: String
    let login: String
    /// gh lists the account (false: only its vault repositories remain).
    let isLoggedIn: Bool
    /// The scopes the account's token lacks (`repo`, `read:org`); empty when OK or unknown.
    let missingScopes: [String]
    /// Why the organizations could not be listed (A5); nil on success.
    let organizationsFailure: GHError?
    let owners: [SidebarOwnerModel]

    var hasScopeWarning: Bool {
        !missingScopes.isEmpty
    }
}

/// Everything the sidebar is built from.
struct SidebarInputModel {
    var accounts: [GHAccountSummaryModel] = []
    /// Catalogs by account fold key.
    var catalogs: [String: AccountCatalogModel] = [:]
    /// Repositories added by name this session, by account fold key.
    var addedByName: [String: [CatalogRepoModel]] = [:]
    /// Every repository in the vault.
    var vaultRepos: [RepoModel] = []
    /// Every organization in the vault (1.0).
    var vaultOrganizations: [OrganizationModel] = []
}

/// Groups accounts, owners and repositories for the sidebar and applies the search (§10
/// Column 1). Pure, so it is tested without gh.
enum SidebarGrouping {
    /// Accounts in gh's order (then vault-only accounts by name); in each, the account's own
    /// repositories, then its organizations in gh's order, then other owners by name; repositories
    /// by name. The vault row wins over the listing for imported repositories (refreshed flags).
    /// A non-empty `query` keeps repositories whose `owner/name` contains it (any case) and drops
    /// empty groups.
    static func sections(_ input: SidebarInputModel, query: String) -> [SidebarAccountModel] {
        let vaultByKey = Dictionary(
            input.vaultRepos.map { (SidebarRepoModel.foldKey(owner: $0.ownerLogin, name: $0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var accountLogins: [(key: String, login: String)] = input.accounts.map { ($0.id, $0.account.login) }
        let known = Set(accountLogins.map(\.key))
        // Accounts gh does not list (any more) but the vault, a catalog or an added repository
        // still refers to.
        let otherAccounts = input.vaultRepos.map { (OwnerLoginValidator.foldKey($0.accountLogin), $0.accountLogin) }
            + input.vaultOrganizations.map { (OwnerLoginValidator.foldKey($0.accountLogin), $0.accountLogin) }
            + input.catalogs.values.map { (OwnerLoginValidator.foldKey($0.accountLogin), $0.accountLogin) }
            + input.addedByName.keys.map { ($0, $0) }
        let vaultOnlyAccounts = Dictionary(otherAccounts, uniquingKeysWith: { first, _ in first })
            .filter { !known.contains($0.key) }
        .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        accountLogins += vaultOnlyAccounts.map { ($0.key, $0.value) }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return accountLogins.compactMap { account in
            let summary = input.accounts.first { $0.id == account.key }
            let owners = owners(
                accountKey: account.key,
                accountLogin: account.login,
                catalog: input.catalogs[account.key],
                addedByName: input.addedByName[account.key] ?? [],
                vaultRepos: input.vaultRepos.filter { OwnerLoginValidator.foldKey($0.accountLogin) == account.key },
                vaultOrganizations: input.vaultOrganizations.filter { OwnerLoginValidator.foldKey($0.accountLogin) == account.key },
                vaultByKey: vaultByKey
            )
            let filtered = filter(owners, query: trimmed)
            if !trimmed.isEmpty, filtered.isEmpty { return nil }
            return SidebarAccountModel(
                id: account.key,
                login: account.login,
                isLoggedIn: summary?.isLoggedIn ?? false,
                missingScopes: missingScopes(summary),
                organizationsFailure: input.catalogs[account.key]?.organizationsFailure,
                owners: filtered
            )
        }
    }

    private static func missingScopes(_ summary: GHAccountSummaryModel?) -> [String] {
        if case .missing(let scopes) = summary?.status?.scopes { return scopes }
        return []
    }

    private struct OwnerGroup {
        var login: String
        var ownerType: OwnerType
        var failure: GHError?
        var isTruncated: Bool
        var repos: [String: SidebarRepoModel] = [:]
    }

    private static func owners(
        accountKey: String,
        accountLogin: String,
        catalog: AccountCatalogModel?,
        addedByName: [CatalogRepoModel],
        vaultRepos: [RepoModel],
        vaultOrganizations: [OrganizationModel],
        vaultByKey: [String: RepoModel]
    ) -> [SidebarOwnerModel] {
        var order: [String] = []
        var groups: [String: OwnerGroup] = [:]

        func group(_ login: String, _ type: OwnerType) -> String {
            let key = OwnerLoginValidator.foldKey(login)
            if groups[key] == nil {
                groups[key] = OwnerGroup(login: login, ownerType: type, failure: nil, isTruncated: false)
                order.append(key)
            }
            return key
        }

        let accountOwnerKey = group(accountLogin, .user)
        for owner in catalog?.owners ?? [] {
            let key = group(owner.login, owner.ownerType)
            groups[key]?.failure = owner.failure
            groups[key]?.isTruncated = owner.isTruncated
            for repo in owner.repositories {
                insert(row(repo, accountKey: accountKey, accountLogin: accountLogin, vaultByKey: vaultByKey), into: &groups[key])
            }
        }
        for repo in addedByName {
            let key = group(repo.ref.owner, repo.ownerType)
            insert(row(repo, accountKey: accountKey, accountLogin: accountLogin, vaultByKey: vaultByKey), into: &groups[key])
        }
        for repo in vaultRepos {
            let key = group(repo.ownerLogin, repo.ownerType)
            let repoKey = SidebarRepoModel.foldKey(owner: repo.ownerLogin, name: repo.name)
            if groups[key]?.repos[repoKey] == nil {
                insert(row(repo, accountKey: accountKey), into: &groups[key])
            }
        }
        var organizations: [String: OrganizationModel] = [:]
        for organization in vaultOrganizations {
            organizations[group(organization.login, .organization)] = organization
        }

        // The account first, then gh's organization order, then other owners by name.
        let listedKeys = order.filter { key in
            key == accountOwnerKey || catalog?.owners.contains { OwnerLoginValidator.foldKey($0.login) == key } == true
        }
        let otherKeys = order.filter { !listedKeys.contains($0) }.sorted {
            (groups[$0]?.login ?? $0).localizedCaseInsensitiveCompare(groups[$1]?.login ?? $1) == .orderedAscending
        }
        return (listedKeys + otherKeys).compactMap { key in
            guard let group = groups[key] else { return nil }
            // Without a listing, an empty "Personal" group says nothing: leave it out.
            if catalog == nil, group.repos.isEmpty, group.failure == nil, organizations[key] == nil { return nil }
            let repos = group.repos.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return SidebarOwnerModel(
                id: "\(accountKey)/\(key)",
                login: group.login,
                accountLogin: accountLogin,
                ownerType: group.ownerType,
                isAccount: key == accountOwnerKey,
                failure: group.failure,
                isTruncated: group.isTruncated,
                repos: repos,
                organization: organizations[key]
            )
        }
    }

    private static func insert(_ row: SidebarRepoModel, into group: inout OwnerGroup?) {
        group?.repos[row.repoKey] = row
    }

    /// A catalog row, overlaid with the vault row when the repository is imported.
    private static func row(
        _ repo: CatalogRepoModel,
        accountKey: String,
        accountLogin: String,
        vaultByKey: [String: RepoModel]
    ) -> SidebarRepoModel {
        if let stored = vaultByKey[repo.id] {
            return row(stored, accountKey: accountKey)
        }
        return SidebarRepoModel(
            id: rowID(accountKey: accountKey, repoKey: repo.id),
            repoKey: repo.id,
            accountLogin: accountLogin,
            ownerLogin: repo.ref.owner,
            name: repo.ref.name,
            visibility: repo.visibility,
            isArchived: repo.isArchived,
            isFork: repo.isFork,
            isUnavailable: repo.isUnavailable,
            importedRepoID: nil,
            existsOnGitHub: true
        )
    }

    private static func row(_ repo: RepoModel, accountKey: String) -> SidebarRepoModel {
        let repoKey = SidebarRepoModel.foldKey(owner: repo.ownerLogin, name: repo.name)
        return SidebarRepoModel(
            id: rowID(accountKey: accountKey, repoKey: repoKey),
            repoKey: repoKey,
            accountLogin: repo.accountLogin,
            ownerLogin: repo.ownerLogin,
            name: repo.name,
            visibility: repo.visibility,
            isArchived: repo.isArchived,
            isFork: repo.isFork,
            isUnavailable: repo.isUnavailable,
            importedRepoID: repo.id,
            existsOnGitHub: repo.existsOnGitHub
        )
    }

    static func rowID(accountKey: String, repoKey: String) -> String {
        "\(accountKey)|\(repoKey)"
    }

    private static func filter(_ owners: [SidebarOwnerModel], query: String) -> [SidebarOwnerModel] {
        guard !query.isEmpty else { return owners }
        return owners.compactMap { owner in
            let repos = owner.repos.filter { $0.fullName.localizedCaseInsensitiveContains(query) }
            // An imported organization stays findable by its login, for its own row.
            let keepsOrganization = owner.organization != nil && owner.login.localizedCaseInsensitiveContains(query)
            guard !repos.isEmpty || keepsOrganization else { return nil }
            return SidebarOwnerModel(
                id: owner.id,
                login: owner.login,
                accountLogin: owner.accountLogin,
                ownerType: owner.ownerType,
                isAccount: owner.isAccount,
                failure: owner.failure,
                isTruncated: owner.isTruncated,
                repos: repos,
                organization: owner.organization
            )
        }
    }
}
