import Foundation
import GitHubKit
import os
import VaultCore
import VaultCrypto
import VaultStore

/// The repositories each account can reach, and moving them into and out of the vault
/// (§2, §8 A5/B1–B9, §10 sidebar; M2).
///
/// - **Catalog** (``catalog(accountLogin:)``): A5 for the account's organizations, then B1 for
///   the account and each organization, grouped account → owner. One owner failing (SAML, for
///   example) marks only that owner unavailable. Imported repositories are matched by
///   `owner/name`; their metadata (permission, archived, visibility, default branch) is
///   refreshed from the listing.
/// - **Add repository by name** (``lookUpRepository(fullName:accountLogin:)``): B2 for
///   collaborator access gh cannot list; the repository joins the catalog until relaunch, and
///   for good once imported.
/// - **Import** (``importRepository(_:accountLogin:)``): B2, B3, B5, B6–B9, stored in one
///   transaction. Secrets are value-missing with `remote_updated_at`; variables are encrypted
///   with the synced snapshot equal to the value, stored exactly as listed (D32: values from
///   GitHub may end in CR/LF; `SyncPlanner` normalizes at push time). Everything imported has
///   `provenance = github`. The capability comes from `viewerPermission`.
/// - **Refresh** and **Remove from vault**.
public actor RepoCatalogRepository {
    private let session: VaultSession
    private let schedulers: any GHSchedulerProviding
    private let clock: any VaultClock
    /// Repositories added by name this session, per account fold key, by `owner/name` fold key.
    private var addedByName: [String: [String: CatalogRepoModel]] = [:]
    /// The organizations of each account (fold key) at its last catalog listing.
    private var organizationsByAccount: [String: [String]] = [:]

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "catalog")

    public init(session: VaultSession, schedulers: any GHSchedulerProviding, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.schedulers = schedulers
        self.clock = clock
    }

    private var repoStore: RepoStore {
        RepoStore(database: session.database)
    }

    // MARK: - Catalog

    /// Lists the account's repositories grouped by owner: the account first, then its
    /// organizations in gh's order, then any other owner reached by name or in the vault.
    ///
    /// - Throws: only when nothing can be listed at all (no gh, token, network); per-owner
    ///   failures are reported in ``OwnerCatalogModel/failure``.
    public func catalog(accountLogin: String) async throws(RepoCatalogError) -> AccountCatalogModel {
        let scheduler = try await scheduler(for: accountLogin)
        var organizations: [String] = []
        var organizationsFailure: GHError?
        do {
            organizations = try await scheduler.listOrganizations()
        } catch {
            if Self.isFatal(error) { throw .github(error) }
            organizationsFailure = error
        }

        let accountKey = OwnerLoginValidator.foldKey(accountLogin)
        if organizationsFailure == nil {
            organizationsByAccount[accountKey] = organizations
        }
        var owners: [(login: String, type: OwnerType)] = [(accountLogin, .user)]
        owners += organizations.filter { OwnerLoginValidator.foldKey($0) != accountKey }.map { ($0, .organization) }

        var listings: [String: Result<[GHRepoDTO], GHError>] = [:]
        for owner in owners {
            do {
                let listed = try await scheduler.listRepositories(owner: owner.login)
                listings[OwnerLoginValidator.foldKey(owner.login)] = .success(listed)
            } catch {
                if Self.isFatal(error) { throw .github(error) }
                listings[OwnerLoginValidator.foldKey(owner.login)] = .failure(error)
            }
        }

        let stored = try refreshStoredRepositories(accountLogin: accountLogin, listings: listings)
        return buildCatalog(
            accountLogin: accountLogin,
            owners: owners,
            listings: listings,
            stored: stored,
            organizationsFailure: organizationsFailure
        )
    }

    /// **Add repository by name**: checks `owner/name` with B2 and adds it to the account's
    /// catalog. Import it to keep it.
    ///
    /// - Throws: `.github(.invalidInput)` for a malformed name, `.github(.notFound)` when the
    ///   account cannot see it.
    public func lookUpRepository(fullName: String, accountLogin: String) async throws(RepoCatalogError) -> CatalogRepoModel {
        let ref: GHRepoRef
        do {
            ref = try GHRepoRef(fullName: fullName.trimmingCharacters(in: .whitespaces))
        } catch {
            throw .github(error)
        }
        let scheduler = try await scheduler(for: accountLogin)
        let listing: GHRepoDTO
        do {
            listing = try await scheduler.viewRepository(ref)
        } catch {
            throw .github(error)
        }
        let stored = try perform { try repoStore.fetch(ownerLogin: ref.owner, name: ref.name) }
        guard let model = Self.catalogModel(
            listing,
            ownerType: ownerType(of: ref.owner, accountLogin: accountLogin),
            stored: stored,
            source: .addedByName
        ) else { throw .github(.malformedOutput) }
        addedByName[OwnerLoginValidator.foldKey(accountLogin), default: [:]][model.id] = model
        return model
    }

    // MARK: - Import

    /// Imports `repo` into the vault through `accountLogin` (M2). Needs an unlocked vault.
    ///
    /// - Throws: `.alreadyImported` when the repository is in the vault; `.github` for B2 and
    ///   for reads that are not scope-level; `.vault(.locked)`.
    @discardableResult
    public func importRepository(
        _ repo: GHRepoRef,
        accountLogin: String
    ) async throws(RepoCatalogError) -> RepoImportResultModel {
        if let existing = try perform({ try repoStore.fetch(ownerLogin: repo.owner, name: repo.name) }) {
            throw .alreadyImported(existing.id)
        }
        let scheduler = try await scheduler(for: accountLogin)
        let remote: RemoteRepoConfigModel
        let listing: GHRepoDTO
        do {
            listing = try await scheduler.viewRepository(repo)
            remote = try await RemoteConfigReader(scheduler: scheduler, repo: repo).read()
        } catch {
            throw .github(error)
        }
        defer { remote.wipe() }

        let now = clock.now
        guard let model = listing.makeRepoModel(
            accountLogin: accountLogin,
            ownerType: ownerType(of: listing.owner.login, accountLogin: accountLogin),
            importedAt: now
        ) else { throw .github(.malformedOutput) }

        let writer = RepoImportWriter(database: session.database, now: now)
        try perform {
            try session.write { keys, tx in
                try writer.store(model, remote: remote, keys: keys, in: tx)
            }
        }
        let result = RepoImportResultModel(
            repository: model,
            environmentCount: remote.environments.count,
            secretCount: remote.secrets.count + remote.environments.reduce(0) { $0 + $1.secrets.count },
            variableCount: remote.variables.count + remote.environments.reduce(0) { $0 + $1.variables.count },
            unreadable: remote.failures,
            skippedNames: remote.skipped
        )
        Self.log.info(
            """
            Imported a repository: \(result.environmentCount, privacy: .public) environments, \
            \(result.secretCount, privacy: .public) secrets, \(result.variableCount, privacy: .public) variables, \
            \(result.unreadable.count, privacy: .public) unreadable reads
            """
        )
        return result
    }

    // MARK: - Refresh and remove

    /// Re-reads the repository's metadata with B2 (permission, archived, visibility, default
    /// branch). SAML or "not found" marks it unavailable instead of failing.
    @discardableResult
    public func refreshRepository(_ id: RepoID) async throws(RepoCatalogError) -> RepoModel {
        guard var repo = try perform({ try repoStore.fetch(id: id) }) else { throw .repositoryNotFound }
        let ref: GHRepoRef
        do {
            ref = try GHRepoRef(owner: repo.ownerLogin, name: repo.name)
        } catch {
            throw .github(error)
        }
        let scheduler = try await scheduler(for: repo.accountLogin)
        do {
            let listing = try await scheduler.viewRepository(ref)
            Self.applyListing(listing, to: &repo)
        } catch {
            guard Self.marksUnavailable(error) else { throw .github(error) }
            repo.isUnavailable = true
        }
        repo.lastRefreshedAt = clock.now
        let refreshed = repo
        try perform { try repoStore.update(refreshed) }
        return refreshed
    }

    /// **Remove from vault**: deletes the repository with its environments, items and patterns.
    /// Nothing changes on GitHub.
    public func removeFromVault(_ id: RepoID) throws(RepoCatalogError) {
        guard try perform({ try repoStore.delete(id: id) }) else { throw .repositoryNotFound }
        Self.log.info("Removed a repository from the vault")
    }

    /// Every repository in the vault (sidebar), now and after each change.
    public nonisolated func observeRepositories() -> AsyncThrowingStream<[RepoModel], any Error> {
        RepoStore(database: session.database).observeAll()
    }

    // MARK: - Private

    private func scheduler(for accountLogin: String) async throws(RepoCatalogError) -> GHCommandScheduler {
        do {
            return try await schedulers.scheduler(for: accountLogin)
        } catch {
            throw .github(error)
        }
    }

    private func perform<Result>(_ body: () throws -> Result) throws(RepoCatalogError) -> Result {
        do {
            return try body()
        } catch {
            throw RepoCatalogError.wrap(error)
        }
    }

    /// Failures that mean nothing else can be listed either.
    private static func isFatal(_ error: GHError) -> Bool {
        switch error {
        case .tokenRevoked, .notAuthenticated, .network, .timeout, .rateLimited, .cancelled, .notInstalled,
             .launchFailed, .untrustedBinary, .versionTooOld:
            true
        default:
            false
        }
    }

    /// B1/B2 failures that make a repository unavailable rather than failing the call.
    private static func marksUnavailable(_ error: GHError) -> Bool {
        switch error {
        case .samlRequired, .notFound: true
        default: false
        }
    }

    /// The owner's type: the account itself is a user, a listed organization of the account is an
    /// organization. gh reports no type for other owners (collaborator access); they are stored
    /// as users, which only affects grouping.
    private func ownerType(of owner: String, accountLogin: String) -> OwnerType {
        let key = OwnerLoginValidator.foldKey(owner)
        let accountKey = OwnerLoginValidator.foldKey(accountLogin)
        if key == accountKey { return .user }
        let organizations = organizationsByAccount[accountKey] ?? []
        return organizations.contains { OwnerLoginValidator.foldKey($0) == key } ? .organization : .user
    }

    /// Refreshes the vault rows of this account from the listings and marks the rows of an
    /// owner that failed with SAML or "not found" unavailable. Returns the account's rows.
    private func refreshStoredRepositories(
        accountLogin: String,
        listings: [String: Result<[GHRepoDTO], GHError>]
    ) throws(RepoCatalogError) -> [RepoModel] {
        let now = clock.now
        return try perform {
            try session.database.write { tx in
                var result: [RepoModel] = []
                let accountKey = OwnerLoginValidator.foldKey(accountLogin)
                let rows = try repoStore.fetchAll(in: tx).filter { OwnerLoginValidator.foldKey($0.accountLogin) == accountKey }
                for var repo in rows {
                    let original = repo
                    switch listings[OwnerLoginValidator.foldKey(repo.ownerLogin)] {
                    case .success(let listed):
                        let key = Self.repoKey(repo)
                        if let listing = listed.first(where: { $0.repoRef?.foldKey == key }), listing.id == repo.githubID {
                            Self.applyListing(listing, to: &repo)
                            repo.lastRefreshedAt = now
                        }
                    case .failure(let error) where Self.marksUnavailable(error):
                        repo.isUnavailable = true
                    default:
                        break
                    }
                    if repo != original {
                        try repoStore.update(repo, in: tx)
                    }
                    result.append(repo)
                }
                return result
            }
        }
    }

    private func buildCatalog(
        accountLogin: String,
        owners: [(login: String, type: OwnerType)],
        listings: [String: Result<[GHRepoDTO], GHError>],
        stored: [RepoModel],
        organizationsFailure: GHError?
    ) -> AccountCatalogModel {
        let storedByKey = Dictionary(stored.map { (Self.repoKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var placed: Set<String> = []
        var groups: [OwnerCatalogModel] = []
        var extraOwners: [(login: String, type: OwnerType)] = []
        let added = Array((addedByName[OwnerLoginValidator.foldKey(accountLogin)] ?? [:]).values).sorted { $0.id < $1.id }

        for owner in owners {
            let ownerKey = OwnerLoginValidator.foldKey(owner.login)
            var repositories: [CatalogRepoModel] = []
            var failure: GHError?
            var isTruncated = false
            switch listings[ownerKey] {
            case .success(let listed):
                isTruncated = listed.count >= Limits.repoListMax
                for listing in listed {
                    let storedRow = listing.repoRef.flatMap { storedByKey[$0.foldKey] }
                    guard let model = Self.catalogModel(listing, ownerType: owner.type, stored: storedRow, source: .listed),
                          placed.insert(model.id).inserted
                    else { continue }
                    repositories.append(model)
                }
            case .failure(let error):
                failure = error
            case nil:
                break
            }
            repositories += Self.unplaced(
                added: added,
                stored: stored,
                ownerKey: ownerKey,
                storedByKey: storedByKey,
                placed: &placed
            )
            groups.append(OwnerCatalogModel(
                login: owner.login,
                ownerType: owner.type,
                repositories: repositories,
                failure: failure,
                isTruncated: isTruncated
            ))
        }

        let placedOwners = Set(owners.map { OwnerLoginValidator.foldKey($0.login) })
        for model in added where !placedOwners.contains(OwnerLoginValidator.foldKey(model.ref.owner)) {
            extraOwners.append((model.ref.owner, model.ownerType))
        }
        for repo in stored where !placedOwners.contains(OwnerLoginValidator.foldKey(repo.ownerLogin)) {
            extraOwners.append((repo.ownerLogin, repo.ownerType))
        }
        var seenOwners: Set<String> = []
        let sortedOwners = extraOwners
            .filter { seenOwners.insert(OwnerLoginValidator.foldKey($0.login)).inserted }
            .sorted { OwnerLoginValidator.foldKey($0.login) < OwnerLoginValidator.foldKey($1.login) }
        for owner in sortedOwners {
            let repositories = Self.unplaced(
                added: added,
                stored: stored,
                ownerKey: OwnerLoginValidator.foldKey(owner.login),
                storedByKey: storedByKey,
                placed: &placed
            )
            guard !repositories.isEmpty else { continue }
            groups.append(OwnerCatalogModel(
                login: owner.login,
                ownerType: owner.type,
                repositories: repositories,
                failure: nil,
                isTruncated: false
            ))
        }
        return AccountCatalogModel(accountLogin: accountLogin, owners: groups, organizationsFailure: organizationsFailure)
    }

    /// Added-by-name and vault-only repositories of `ownerKey` not placed yet.
    private static func unplaced(
        added: [CatalogRepoModel],
        stored: [RepoModel],
        ownerKey: String,
        storedByKey: [String: RepoModel],
        placed: inout Set<String>
    ) -> [CatalogRepoModel] {
        var result: [CatalogRepoModel] = []
        for model in added where OwnerLoginValidator.foldKey(model.ref.owner) == ownerKey && placed.insert(model.id).inserted {
            let storedRow = storedByKey[model.id]
            result.append(CatalogRepoModel(
                ref: model.ref,
                ownerType: model.ownerType,
                visibility: model.visibility,
                isArchived: model.isArchived,
                isFork: model.isFork,
                hasAdmin: model.hasAdmin,
                hasPush: model.hasPush,
                isUnavailable: storedRow?.isUnavailable ?? false,
                importedRepoID: storedRow?.id,
                source: .addedByName
            ))
        }
        for repo in stored where OwnerLoginValidator.foldKey(repo.ownerLogin) == ownerKey {
            guard let ref = try? GHRepoRef(owner: repo.ownerLogin, name: repo.name),
                  placed.insert(ref.foldKey).inserted
            else { continue }
            result.append(CatalogRepoModel(
                ref: ref,
                ownerType: repo.ownerType,
                visibility: repo.visibility,
                isArchived: repo.isArchived,
                isFork: repo.isFork,
                hasAdmin: repo.hasAdmin,
                hasPush: repo.hasPush,
                isUnavailable: repo.isUnavailable,
                importedRepoID: repo.id,
                source: .vaultOnly
            ))
        }
        return result
    }

    static func catalogModel(
        _ listing: GHRepoDTO,
        ownerType: OwnerType,
        stored: RepoModel?,
        source: CatalogRepoModel.Source
    ) -> CatalogRepoModel? {
        guard let ref = listing.repoRef else { return nil }
        let permission = listing.permission
        return CatalogRepoModel(
            ref: ref,
            ownerType: stored?.ownerType ?? ownerType,
            visibility: listing.repoVisibility,
            isArchived: listing.isArchived,
            isFork: listing.isFork,
            hasAdmin: permission?.hasAdmin ?? false,
            hasPush: permission?.hasPush ?? false,
            isUnavailable: false,
            importedRepoID: stored?.id,
            source: source
        )
    }

    /// The case-folded `owner/name` of a vault row (the form of `GHRepoRef.foldKey`).
    static func repoKey(_ repo: RepoModel) -> String {
        "\(OwnerLoginValidator.foldKey(repo.ownerLogin))/\(RepoNameValidator.foldKey(repo.name))"
    }

    /// Copies the listing's metadata onto a vault row and marks it available.
    static func applyListing(_ listing: GHRepoDTO, to repo: inout RepoModel) {
        let permission = listing.permission
        repo.visibility = listing.repoVisibility
        repo.isArchived = listing.isArchived
        repo.isFork = listing.isFork
        repo.defaultBranch = listing.defaultBranch
        repo.hasAdmin = permission?.hasAdmin ?? false
        repo.hasPush = permission?.hasPush ?? false
        repo.isUnavailable = false
    }
}
