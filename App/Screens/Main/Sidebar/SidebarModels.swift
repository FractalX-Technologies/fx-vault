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
    /// The case-folded `owner/name`: one row per repository, whichever accounts list it.
    let repoKey: String
    /// The gh account its reads go through (the vault row's account once imported).
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

    var id: String {
        repoKey
    }

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

/// Why an owner needs attention: the subline under its node (board Main2-Expanded). Settings ›
/// Accounts keeps the details and the commands.
enum SidebarOwnerProblem: Hashable {
    /// gh no longer lists the account the owner goes through.
    case signedOut
    /// The account's token lacks `repo` or `read:org` (on the account's own node).
    case missingScopes([String])
    /// The token lacks `admin:org`, which the organization's secrets need.
    case needsAdminOrg
    /// The account is a member: only an org admin can manage the organization's secrets.
    case needsOrgAdmin
    /// SAML SSO; GitHub's authorization page when gh printed one.
    case ssoRequired(URL?)
    /// gh could not list the owner.
    case unavailable(GHError)
}

extension SidebarOwnerProblem {
    /// What Approve asks gh for in the app (1.0 B4b), from the fixed list only; nil when the
    /// problem has no in-app approval, or names a scope outside the list.
    var approvalScopes: [GHApprovalScope]? {
        switch self {
        case .missingScopes(let names):
            let scopes = names.compactMap { GHApprovalScope(rawValue: $0.lowercased()) }
            return scopes.isEmpty || scopes.count != names.count ? nil : scopes
        case .needsAdminOrg:
            return [.adminOrg]
        case .signedOut, .needsOrgAdmin, .ssoRequired, .unavailable:
            return nil
        }
    }
}

/// One owner node under GitHub: an organization or a person, once across every gh account.
struct SidebarOwnerModel: Identifiable, Hashable {
    /// The owner's fold key.
    let id: String
    let login: String
    /// The gh account the owner's reads go through: the one that imported it, else the first
    /// signed-in account that lists it.
    let accountLogin: String
    let ownerType: OwnerType
    /// A gh account's own repositories: the node has no place of its own.
    let isPersonal: Bool
    /// gh returned the listing maximum; the list may be cut.
    let isTruncated: Bool
    let repos: [SidebarRepoModel]
    /// The organization's own secrets and variables in the vault (1.0); nil until imported.
    let organization: OrganizationModel?
    let problem: SidebarOwnerProblem?

    /// An organization node: selecting it opens the organization's place.
    var isOrganization: Bool {
        !isPersonal && ownerType == .organization
    }
}

/// The repositories an owner node shows, and how many wait behind "Show N more".
struct SidebarRepoListModel: Hashable {
    let shown: [SidebarRepoModel]
    let hiddenCount: Int
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
    /// Each signed-in account's organizations with their access, by account fold key (it may
    /// arrive after the catalogs, or never offline).
    var organizationAccess: [String: [OrgAccessModel]] = [:]
}

/// Builds the GitHub tree and applies the search (§10 Column 1; boards Main2-Home,
/// Main2-Expanded). Pure, so it is tested without gh.
enum SidebarGrouping {
    /// One node per owner across every gh account. The vault row wins over a listing
    /// (refreshed flags). A non-empty `query` keeps repositories whose `owner/name` contains it
    /// (any case), an imported organization whose login contains it, and drops the other owners.
    static func owners(_ input: SidebarInputModel, query: String) -> [SidebarOwnerModel] {
        let accounts = accountOrder(input)
        var groups: [String: OwnerGroup] = [:]

        func group(_ login: String, _ type: OwnerType) -> String {
            let key = OwnerLoginValidator.foldKey(login)
            if groups[key] == nil {
                groups[key] = OwnerGroup(login: login, ownerType: type)
            }
            return key
        }

        // Each gh account has its own node, where its problems show before any listing.
        for account in accounts where account.summary != nil {
            _ = group(account.login, .user)
        }
        for account in accounts {
            for owner in input.catalogs[account.key]?.owners ?? [] {
                let key = group(owner.login, owner.ownerType)
                groups[key]?.listings.append(Listing(account: account, owner: owner))
            }
            for repo in input.addedByName[account.key] ?? [] {
                let key = group(repo.ref.owner, repo.ownerType)
                groups[key]?.addedByName.append((account, repo))
            }
        }
        for repo in input.vaultRepos {
            groups[group(repo.ownerLogin, repo.ownerType)]?.vaultRepos.append(repo)
        }
        for organization in input.vaultOrganizations {
            groups[group(organization.login, .organization)]?.organization = organization
        }

        let accountKeys = Set(accounts.map(\.key))
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Organizations first, then people (board Main2-Home), each by login.
        let owners = groups.compactMap { key, group in
            owner(key: key, group: group, isPersonal: accountKeys.contains(key), accounts: accounts, input: input)
        }
        .sorted { lhs, rhs in
            guard lhs.isOrganization == rhs.isOrganization else { return lhs.isOrganization }
            return lhs.login.localizedCaseInsensitiveCompare(rhs.login) == .orderedAscending
        }
        return filter(owners, query: trimmed)
    }

    /// The tree for ``SidebarRepoFilter/added``: only repositories in the vault (and the selected
    /// row, so a repository added by name stays open), owners left without one dropped unless
    /// they are an imported organization or an account with a problem to fix.
    static func owners(
        _ input: SidebarInputModel,
        query: String,
        filter repoFilter: SidebarRepoFilter,
        selectedRowID: SidebarRepoModel.ID?
    ) -> [SidebarOwnerModel] {
        let owners = owners(input, query: query)
        guard repoFilter == .added else { return owners }
        return owners.compactMap { owner in
            let repos = owner.repos.filter { $0.isImported || $0.id == selectedRowID }
            let keepsEmpty = owner.organization != nil || (owner.isPersonal && owner.problem != nil)
            guard !repos.isEmpty || keepsEmpty else { return nil }
            return owner.with(repos: repos)
        }
    }

    /// What an owner node shows: every repository in the vault and the selected one, and the rest
    /// only when `showsAll` (its "Show N more", or a search).
    static func repoList(of owner: SidebarOwnerModel, selectedRowID: SidebarRepoModel.ID?, showsAll: Bool) -> SidebarRepoListModel {
        guard !showsAll else { return SidebarRepoListModel(shown: owner.repos, hiddenCount: 0) }
        let shown = owner.repos.filter { $0.isImported || $0.id == selectedRowID }
        return SidebarRepoListModel(shown: shown, hiddenCount: owner.repos.count - shown.count)
    }

    /// The subline an owner node shows. A member's organization says "Org secrets need an org
    /// admin" only once imported or selected: nothing fixes it, and under every listed
    /// organization it would be noise.
    static func shownProblem(of owner: SidebarOwnerModel, isSelected: Bool) -> SidebarOwnerProblem? {
        guard owner.problem == .needsOrgAdmin else { return owner.problem }
        return owner.organization != nil || isSelected ? owner.problem : nil
    }

    // MARK: - Accounts

    private struct Account {
        let key: String
        let login: String
        let summary: GHAccountSummaryModel?

        var isLoggedIn: Bool {
            summary?.isLoggedIn ?? false
        }
    }

    /// gh's accounts in its order, then the accounts only the vault or a catalog still refers to,
    /// by login.
    private static func accountOrder(_ input: SidebarInputModel) -> [Account] {
        var accounts = input.accounts.map { Account(key: $0.id, login: $0.account.login, summary: $0) }
        let known = Set(accounts.map(\.key))
        let others = input.vaultRepos.map { (OwnerLoginValidator.foldKey($0.accountLogin), $0.accountLogin) }
            + input.vaultOrganizations.map { (OwnerLoginValidator.foldKey($0.accountLogin), $0.accountLogin) }
            + input.catalogs.values.map { (OwnerLoginValidator.foldKey($0.accountLogin), $0.accountLogin) }
            + input.addedByName.keys.map { ($0, $0) }
        accounts += Dictionary(others, uniquingKeysWith: { first, _ in first })
            .filter { !known.contains($0.key) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map { Account(key: $0.key, login: $0.value, summary: nil) }
        return accounts
    }

    // MARK: - Owners

    private struct Listing {
        let account: Account
        let owner: OwnerCatalogModel
    }

    private struct OwnerGroup {
        var login: String
        var ownerType: OwnerType
        var listings: [Listing] = []
        var addedByName: [(Account, CatalogRepoModel)] = []
        var vaultRepos: [RepoModel] = []
        var organization: OrganizationModel?
    }

    private static func owner(
        key: String,
        group: OwnerGroup,
        isPersonal: Bool,
        accounts: [Account],
        input: SidebarInputModel
    ) -> SidebarOwnerModel? {
        guard let account = account(of: key, group: group, isPersonal: isPersonal, accounts: accounts) else { return nil }
        let listing = group.listings.first { $0.account.key == account.key } ?? group.listings.first
        // The chosen account's listing first, so a repository two accounts list goes through it.
        let listings = group.listings.filter { $0.account.key == account.key }
            + group.listings.filter { $0.account.key != account.key }

        var rows: [String: SidebarRepoModel] = [:]
        for listing in listings {
            for repo in listing.owner.repositories where rows[repo.id] == nil {
                rows[repo.id] = row(repo, accountLogin: listing.account.login)
            }
        }
        for (account, repo) in group.addedByName where rows[repo.id] == nil {
            rows[repo.id] = row(repo, accountLogin: account.login)
        }
        for repo in group.vaultRepos {
            let row = row(repo)
            rows[row.repoKey] = row
        }

        let problem = problem(
            of: group,
            key: key,
            listing: listing?.owner,
            account: account,
            isPersonal: isPersonal,
            input: input
        )
        // An empty node stays when it is a place (an organization gh lists, an imported one), the
        // account's own listing, or where a problem shows.
        let keepsEmpty = group.organization != nil || problem != nil
            || (isPersonal ? input.catalogs[account.key] != nil : !group.listings.isEmpty)
        guard !rows.isEmpty || keepsEmpty else { return nil }
        return SidebarOwnerModel(
            id: key,
            login: listing?.owner.login ?? group.login,
            accountLogin: account.login,
            ownerType: listing?.owner.ownerType ?? group.ownerType,
            isPersonal: isPersonal,
            isTruncated: listing?.owner.isTruncated ?? false,
            repos: rows.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            organization: group.organization,
            problem: problem
        )
    }

    /// The account an owner goes through: the account itself for its own repositories; the one
    /// that imported the organization or a repository of it; else the first signed-in account
    /// that lists it, then any account that does.
    private static func account(of key: String, group: OwnerGroup, isPersonal: Bool, accounts: [Account]) -> Account? {
        func named(_ login: String) -> Account? {
            let fold = OwnerLoginValidator.foldKey(login)
            return accounts.first { $0.key == fold }
        }
        if isPersonal { return accounts.first { $0.key == key } }
        if let organization = group.organization, let account = named(organization.accountLogin) { return account }
        if let repo = group.vaultRepos.first, let account = named(repo.accountLogin) { return account }
        let listing = group.listings.map(\.account) + group.addedByName.map { $0.0 }
        return listing.first(where: \.isLoggedIn) ?? listing.first
    }

    private static func problem(
        of group: OwnerGroup,
        key: String,
        listing: OwnerCatalogModel?,
        account: Account,
        isPersonal: Bool,
        input: SidebarInputModel
    ) -> SidebarOwnerProblem? {
        if case .samlRequired(let url) = listing?.failure { return .ssoRequired(url) }
        if let failure = listing?.failure { return .unavailable(failure) }
        guard account.isLoggedIn else { return .signedOut }
        if isPersonal, case .missing(let scopes) = account.summary?.status?.scopes { return .missingScopes(scopes) }
        let access = input.organizationAccess[account.key]?.first { $0.id == key }
        switch access?.status {
        case .needsAdminOrgScope: return .needsAdminOrg
        case .needsOrgAdmin: return .needsOrgAdmin
        case .ssoRequired(let url): return .ssoRequired(url)
        case .ready, .unknown, nil: return nil
        }
    }

    // MARK: - Rows

    /// A catalog row, overlaid with the vault row when the repository is imported.
    private static func row(_ repo: CatalogRepoModel, accountLogin: String) -> SidebarRepoModel {
        SidebarRepoModel(
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

    private static func row(_ repo: RepoModel) -> SidebarRepoModel {
        SidebarRepoModel(
            repoKey: SidebarRepoModel.foldKey(owner: repo.ownerLogin, name: repo.name),
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

    private static func filter(_ owners: [SidebarOwnerModel], query: String) -> [SidebarOwnerModel] {
        guard !query.isEmpty else { return owners }
        return owners.compactMap { owner in
            let repos = owner.repos.filter { $0.fullName.localizedCaseInsensitiveContains(query) }
            // An imported organization stays findable by its login, for its own place.
            let keepsOrganization = owner.organization != nil && owner.login.localizedCaseInsensitiveContains(query)
            guard !repos.isEmpty || keepsOrganization else { return nil }
            return owner.with(repos: repos)
        }
    }
}

private extension SidebarOwnerModel {
    func with(repos: [SidebarRepoModel]) -> SidebarOwnerModel {
        SidebarOwnerModel(
            id: id,
            login: login,
            accountLogin: accountLogin,
            ownerType: ownerType,
            isPersonal: isPersonal,
            isTruncated: isTruncated,
            repos: repos,
            organization: organization,
            problem: problem
        )
    }
}

/// The Azure section's rows (1.0 D6c6). Pure, so the grouping is tested without the window.
struct SidebarAzureModel: Equatable {
    /// Vaults without a saved subscription, directly under Azure, in the observed order.
    let ungrouped: [DestinationModel]
    /// One group per subscription, by name; each keeps its vaults in the observed order.
    let subscriptions: [SidebarSubscriptionModel]

    init(vaults: [DestinationModel]) {
        ungrouped = vaults.filter { $0.subscription == nil }
        var groups: [UUID: SidebarSubscriptionModel] = [:]
        for vault in vaults {
            guard let subscription = vault.subscription else { continue }
            // Two vaults may have saved one subscription under different names: the last one wins.
            let vaults = (groups[subscription.id]?.vaults ?? []) + [vault]
            groups[subscription.id] = SidebarSubscriptionModel(subscription: subscription, vaults: vaults)
        }
        subscriptions = groups.values.sorted { lhs, rhs in
            let byName = lhs.subscription.name.localizedStandardCompare(rhs.subscription.name)
            return byName == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : byName == .orderedAscending
        }
    }

    var isEmpty: Bool {
        ungrouped.isEmpty && subscriptions.isEmpty
    }
}

/// One Azure subscription and its vaults in the sidebar.
struct SidebarSubscriptionModel: Identifiable, Equatable {
    let subscription: KeyVaultSubscriptionModel
    let vaults: [DestinationModel]

    var id: UUID {
        subscription.id
    }
}
