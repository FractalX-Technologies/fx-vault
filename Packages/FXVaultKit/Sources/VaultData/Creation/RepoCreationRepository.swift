import Foundation
import GitHubKit
import os
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// New repositories and cloning (§8 B2, B10, C1, D3; D18; M4).
///
/// - **Staging** (``stage(_:)``): the repository row is written with `github_id = NULL`,
///   `origin = created` and its `create_spec_json` (README, templates, clone after), together
///   with its environments and items, in **one** transaction. Nothing touches GitHub: the next
///   Sync creates the repository first (C1, then B2), then the environments, patterns and items,
///   so a single Sync creates everything (§7.3 step 1). Until then the repository is a pending
///   change like any other and can be edited with `ConfigRepository`.
/// - **Name check** (``checkAvailability(owner:name:accountLogin:)``): B2; the UI debounces it.
/// - **Pickers**: owners (the account and its organizations, A5) and the .gitignore and
///   license templates (B10, cached per account for the session).
/// - **Clone** (``clone(_:into:)``): `git clone` through the account's mapped SSH alias into a
///   temporary sibling directory that is renamed into place (D18, `GitService`); the path is
///   recorded in `clone_path`. Also the "clone after" step of a Sync (``RepoCloning``).
public actor RepoCreationRepository: RepoCloning {
    private let session: VaultSession
    private let schedulers: any GHSchedulerProviding
    private let git: GitService?
    private let clock: any VaultClock
    private let writePolicy: WriteCollaboratorPolicy
    private var gitignoreTemplatesByAccount: [String: [String]] = [:]
    private var licenseTemplatesByAccount: [String: [GHLicenseTemplateModel]] = [:]

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "creation")

    /// - Parameter git: hardened git (`GitService`) with the probed shell environment; nil until
    ///   gh and the shell environment are detected (cloning then throws `.gitUnavailable`).
    public init(
        session: VaultSession,
        schedulers: any GHSchedulerProviding,
        git: GitService?,
        clock: any VaultClock = SystemClock(),
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        self.session = session
        self.schedulers = schedulers
        self.git = git
        self.clock = clock
        self.writePolicy = writePolicy
    }

    // MARK: - Staging

    /// Stages a new repository with its environments and items (§7.3 step 1).
    ///
    /// The viewer is recorded as admin (the creator administers the repository); the next Sync
    /// confirms it with B2. Values are normalized on entry (D32).
    ///
    /// - Throws: `.validation` (owner, name, environment or item names, empty or oversized
    ///   values, duplicates), `.repositoryExists`, `.config` (patterns, capacity),
    ///   `.vault(.locked)`.
    @discardableResult
    public func stage(_ draft: RepoCreationDraftModel) throws(RepoCreationError) -> RepoStagingResultModel {
        let owner = try performCreation { try OwnerLoginValidator.validate(draft.ownerLogin) }
        let name = try performCreation { try RepoNameValidator.validate(draft.name) }
        let accountLogin = try performCreation { try OwnerLoginValidator.validate(draft.accountLogin) }
        var stripped: [String] = []
        let repositoryItems = try Self.normalized(draft.items, label: nil, stripped: &stripped)
        defer { repositoryItems.forEach { $0.value.wipe() } }
        var environments: [(draft: RepoCreationEnvironmentDraftModel, items: [NormalizedItem])] = []
        defer { environments.forEach { $0.items.forEach { $0.value.wipe() } } }
        for environment in draft.environments {
            environments.append((environment, try Self.normalized(environment.items, label: environment.name, stripped: &stripped)))
        }

        let now = clock.now
        let repository = RepoModel(
            accountLogin: accountLogin,
            githubID: nil,
            ownerLogin: owner,
            ownerType: draft.ownerType,
            name: name,
            description: draft.description,
            visibility: draft.visibility,
            hasAdmin: true,
            hasPush: true,
            origin: .created,
            importedAt: now,
            createSpec: draft.spec
        )
        let database = session.database
        let writePolicy = writePolicy
        try performCreation {
            try session.write { keys, tx in
                let repositories = RepoStore(database: database)
                if let existing = try repositories.fetch(ownerLogin: owner, name: name, in: tx) {
                    throw RepoCreationError.repositoryExists(existing.id)
                }
                let accounts = AccountStore(database: database)
                if try accounts.fetch(login: accountLogin, in: tx) == nil {
                    try accounts.save(AccountModel(login: accountLogin, lastSeenAt: now), in: tx)
                }
                try repositories.insert(repository, in: tx)
                let store = ConfigStore(database: database)
                let editor = EnvironmentEditor(store: store, tx: tx, now: now, writePolicy: writePolicy)
                var scopes: [(ConfigScope, [NormalizedItem])] = [(.repository, repositoryItems)]
                for environment in environments {
                    let id = try editor.create(in: repository.id, name: environment.draft.name, policy: environment.draft.policy)
                    scopes.append((.environment(id), environment.items))
                }
                var batch = try ItemEditBatch(
                    repositoryID: repository.id,
                    keys: keys,
                    tx: tx,
                    store: store,
                    now: now,
                    writePolicy: writePolicy
                )
                for (scope, items) in scopes {
                    for item in items {
                        try batch.add(scope: scope, kind: item.kind, name: item.name, value: item.value)
                    }
                }
            }
        }
        Self.log.info(
            "Staged a new repository with \(environments.count, privacy: .public) environments and \(repositoryItems.count + environments.reduce(0) { $0 + $1.items.count }, privacy: .public) items"
        )
        return RepoStagingResultModel(repositoryID: repository.id, strippedTrailingNewlines: stripped)
    }

    /// Removes a staged repository (never created on GitHub) with everything staged in it.
    ///
    /// - Throws: `.alreadyOnGitHub` once a Sync created it (use "Remove from vault" instead),
    ///   `.repositoryNotFound`.
    public func discardStaged(_ repositoryID: RepoID) throws(RepoCreationError) {
        let repositories = RepoStore(database: session.database)
        try performCreation {
            try session.database.write { tx in
                guard let repository = try repositories.fetch(id: repositoryID, in: tx) else {
                    throw RepoCreationError.repositoryNotFound
                }
                guard !repository.existsOnGitHub else { throw RepoCreationError.alreadyOnGitHub }
                try repositories.delete(id: repositoryID, in: tx)
            }
        }
    }

    // MARK: - Name check and pickers

    /// B2 for `owner/name` (§8 B2). Never throws.
    public func checkAvailability(owner: String, name: String, accountLogin: String) async -> RepoNameAvailabilityModel {
        let ref: GHRepoRef
        do {
            _ = try OwnerLoginValidator.validate(owner)
            _ = try RepoNameValidator.validate(name)
            ref = try GHRepoRef(owner: owner, name: name)
        } catch let error as ValidationError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidName(.invalidCharacter))
        }
        do {
            let scheduler = try await schedulers.scheduler(for: accountLogin)
            _ = try await scheduler.viewRepository(ref)
            return .taken
        } catch .notFound {
            return .probablyAvailable
        } catch {
            return .unknown(error)
        }
    }

    /// The owners a new repository can belong to: the account, then its organizations (A5).
    public func owners(accountLogin: String) async throws(RepoCreationError) -> [RepoOwnerChoiceModel] {
        let organizations: [String]
        do {
            organizations = try await schedulers.scheduler(for: accountLogin).listOrganizations()
        } catch {
            throw .github(error)
        }
        let accountKey = OwnerLoginValidator.foldKey(accountLogin)
        return [RepoOwnerChoiceModel(login: accountLogin, ownerType: .user)]
            + organizations
            .filter { OwnerLoginValidator.foldKey($0) != accountKey }
            .map { RepoOwnerChoiceModel(login: $0, ownerType: .organization) }
    }

    /// `gh repo gitignore list` (B10), cached per account for the session.
    public func gitignoreTemplates(accountLogin: String) async throws(RepoCreationError) -> [String] {
        let key = OwnerLoginValidator.foldKey(accountLogin)
        if let cached = gitignoreTemplatesByAccount[key] { return cached }
        do {
            let templates = try await schedulers.scheduler(for: accountLogin).gitignoreTemplates()
            gitignoreTemplatesByAccount[key] = templates
            return templates
        } catch {
            throw .github(error)
        }
    }

    /// `gh repo license list` (B10), cached per account for the session.
    public func licenseTemplates(accountLogin: String) async throws(RepoCreationError) -> [GHLicenseTemplateModel] {
        let key = OwnerLoginValidator.foldKey(accountLogin)
        if let cached = licenseTemplatesByAccount[key] { return cached }
        do {
            let templates = try await schedulers.scheduler(for: accountLogin).licenseTemplates()
            licenseTemplatesByAccount[key] = templates
            return templates
        } catch {
            throw .github(error)
        }
    }

    // MARK: - Clone (§8 D3, D18)

    /// Clones the repository through its account's mapped SSH alias into `<folder>/<name>`
    /// and records `clone_path`. The **Clone** button and "clone after" both use it.
    ///
    /// - Throws: `.repositoryNotFound`, `.notOnGitHub`, `.sshAliasNotMapped`, `.gitUnavailable`,
    ///   `.git` (`.destinationExists`, `.authenticationFailed`, `.hostKeyVerificationFailed`,
    ///   `.folderAccessDenied`, ...).
    public func clone(_ repositoryID: RepoID, into folder: URL) async throws(RepoCreationError) -> URL {
        guard let git else { throw .gitUnavailable }
        let database = session.database
        let (repository, alias) = try performCreation { () throws -> (RepoModel, String?) in
            guard let repository = try RepoStore(database: database).fetch(id: repositoryID) else {
                throw RepoCreationError.repositoryNotFound
            }
            let account = try AccountStore(database: database).fetch(login: repository.accountLogin)
            return (repository, account?.sshHostAlias)
        }
        guard repository.existsOnGitHub else { throw .notOnGitHub }
        guard let alias else { throw .sshAliasNotMapped }
        let ref: GHRepoRef
        do {
            ref = try GHRepoRef(owner: repository.ownerLogin, name: repository.name)
        } catch {
            throw .github(error)
        }
        let destination: URL
        do {
            destination = try await git.clone(repo: ref, alias: alias, into: folder)
        } catch {
            Self.log.error("Clone failed: \(error.logCode, privacy: .public)")
            throw .git(error)
        }
        try performCreation {
            try database.write { tx in
                let repositories = RepoStore(database: database)
                guard var stored = try repositories.fetch(id: repositoryID, in: tx) else { return }
                stored.clonePath = destination.path
                try repositories.update(stored, in: tx)
            }
        }
        Self.log.info("Cloned a repository")
        return destination
    }

    // MARK: - Private

    /// A staged item with its value normalized (D32).
    private struct NormalizedItem {
        let kind: ConfigKind
        let name: String
        let value: SecretBytes
    }

    /// Normalizes every value; names of stripped values are added to `stripped`.
    private static func normalized(
        _ items: [RepoCreationItemDraftModel],
        label: String?,
        stripped: inout [String]
    ) throws(RepoCreationError) -> [NormalizedItem] {
        var result: [NormalizedItem] = []
        do {
            for item in items {
                let normalized = try ValueNormalizer.normalize(item.value)
                if normalized.didStripTrailingNewlines {
                    stripped.append(label.map { "\($0)/\(item.name)" } ?? item.name)
                }
                result.append(NormalizedItem(kind: item.kind, name: item.name, value: normalized.value))
            }
        } catch {
            result.forEach { $0.value.wipe() }
            throw .validation(error)
        }
        return result
    }
}
