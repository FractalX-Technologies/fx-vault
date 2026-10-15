import Foundation
import FXVaultTestSupport
import GitHubKit
import os
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Synthetic names and values for the Sync, Creation, Drift and Sharing tests (owner-a,
/// user-a, FXV_* items; tasks/lessons.md).
enum SyncFixture {
    static let password = "violet harbor quartz lantern meadow anchor"
    static let login = "user-a"
    static let owner = "owner-a"
    static let repoName = "api"
    static let alias = "github-personal"
}

/// One `GHCommandScheduler` per account over a `CommandRunning` (the GitHub simulator), like
/// `GitHubEnvironmentRepository` in the app. No real gh, no real tokens.
final class SimulatorSchedulerProvider: GHSchedulerProviding {
    let runner: any CommandRunning
    let clock: any VaultClock
    let tokenCache = GHTokenCache()
    private let schedulers = OSAllocatedUnfairLock<[String: GHCommandScheduler]>(initialState: [:])

    init(runner: any CommandRunning, clock: any VaultClock) {
        self.runner = runner
        self.clock = clock
    }

    func scheduler(for accountLogin: String) async throws(GHError) -> GHCommandScheduler {
        let key = OwnerLoginValidator.foldKey(accountLogin)
        let runner = runner
        let clock = clock
        let tokenCache = tokenCache
        return schedulers.withLock { cache in
            if let existing = cache[key] { return existing }
            let service = GHCommandService(
                executableURL: GHFixtures.ghURL,
                identity: GHFixtures.identity,
                shell: .empty,
                workingDirectory: GHFixtures.workingDirectory,
                runner: runner
            )
            let scheduler = GHCommandScheduler(
                accountLogin: accountLogin,
                service: service,
                auth: GHAuthService(service: service, tokenCache: tokenCache),
                clock: clock
            )
            cache[key] = scheduler
            return scheduler
        }
    }
}

/// An unlocked vault (in-memory database, `KDFPolicy.testing`, fake Touch ID) wired to a
/// simulated GitHub, with every repository the sync side uses.
struct SyncHarness {
    let database: VaultDatabase
    let session: VaultSession
    let manager: VaultManager
    let clock: SteppingClock
    let github: GitHubSimulator
    let schedulers: SimulatorSchedulerProvider
    let config: ConfigRepository
    let catalog: RepoCatalogRepository
    let sync: SyncRepository
    let drift: DriftRepository

    static func make(github: GitHubSimulator = GitHubSimulator(), cloner: (any RepoCloning)? = nil) async throws -> SyncHarness {
        let database = try DatabaseFactory.inMemory()
        let session = VaultSession(database: database)
        let manager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: FakeBiometricKeyStore(),
            capabilities: FakeBuildCapabilities(),
            clock: ManualClock()
        )
        _ = try await manager.create(password: SyncFixture.password)
        let clock = SteppingClock()
        let schedulers = SimulatorSchedulerProvider(runner: github, clock: clock)
        return SyncHarness(
            database: database,
            session: session,
            manager: manager,
            clock: clock,
            github: github,
            schedulers: schedulers,
            config: ConfigRepository(session: session, clock: clock),
            catalog: RepoCatalogRepository(session: session, schedulers: schedulers, clock: clock),
            sync: SyncRepository(session: session, schedulers: schedulers, cloner: cloner, clock: clock),
            drift: DriftRepository(session: session, schedulers: schedulers, clock: clock)
        )
    }

    var store: ConfigStore {
        ConfigStore(database: database)
    }

    /// Imports `owner-a/api` from the simulated GitHub (M2 import), so the vault starts synced.
    @discardableResult
    func importRepository() async throws -> RepoModel {
        let ref = try GHRepoRef(owner: SyncFixture.owner, name: SyncFixture.repoName)
        return try await catalog.importRepository(ref, accountLogin: SyncFixture.login).repository
    }

    /// Preflight, run (deletions confirmed by default) and wait for the outcome.
    func runSync(includeDeletions: Bool = true, cloneFolder: URL? = nil) async throws -> SyncRunOutcomeModel {
        let review = try await sync.preflight()
        let handle = try await sync.startRun(review, includeDeletions: includeDeletions, cloneFolder: cloneFolder)
        return await handle.outcome()
    }

    // MARK: - Rows

    func pendingCount() throws -> Int {
        try sync.pendingSummary().pendingCount
    }

    func repository() throws -> RepoModel {
        try #require(try RepoStore(database: database).fetch(ownerLogin: SyncFixture.owner, name: SyncFixture.repoName))
    }

    func environment(_ name: String) throws -> EnvironmentModel? {
        try store.fetchEnvironments(repositoryID: repository().id).first {
            $0.nameKey == EnvironmentNameValidator.foldKey(name)
        }
    }

    /// The live row `name` (any case) of `kind` in `scope`.
    func item(_ name: String, kind: ConfigKind, scope: ConfigScope = .repository) throws -> ConfigItemState? {
        try store.fetchItemStates(repositoryID: repository().id, scope: scope).first {
            !$0.isDeleted && $0.kind == kind && GitHubNameValidator.foldKey($0.name) == GitHubNameValidator.foldKey(name)
        }
    }

    func states() throws -> [ConfigItemState] {
        try store.fetchItemStates(repositoryID: repository().id)
    }

    @discardableResult
    func add(
        _ name: String,
        kind: ConfigKind,
        value: String,
        scope: ConfigScope = .repository
    ) throws -> ConfigItemID {
        try config.addItem(
            repositoryID: repository().id,
            scope: scope,
            kind: kind,
            name: name,
            value: SecretBytes(utf8: value)
        ).itemID
    }

    /// The decrypted local value, or nil when it is missing.
    func value(_ id: ConfigItemID) throws -> String? {
        do {
            let value = try config.reveal(id)
            defer { value.wipe() }
            return value.utf8String()
        } catch .valueMissing {
            return nil
        }
    }

    /// The decrypted synced value, or nil.
    func syncedValue(_ id: ConfigItemID) throws -> String? {
        try session.read { keys, tx in
            guard let record = try ConfigStore(database: database).fetchItemRecord(id: id, in: tx),
                  let value = try ConfigFieldCipher.openSyncedValue(of: record, keys: keys)
            else { return nil }
            defer { value.wipe() }
            return value.utf8String()
        }
    }

    func record(_ id: ConfigItemID) throws -> ConfigItemRecord {
        try #require(try store.fetchItemRecord(id: id))
    }

    /// The row's fingerprint of `value` under the current keys.
    func fingerprint(_ value: String, rowID: ConfigItemID) throws -> Data {
        try session.withKeys { keys in
            let bytes = SecretBytes(utf8: value)
            defer { bytes.wipe() }
            return keys.fingerprint(bytes, rowID: rowID)
        }
    }

    /// Writes a row directly (values sealed under its identity), for states the editor cannot
    /// produce, such as a value imported from GitHub with a trailing newline (D32).
    @discardableResult
    func insertRow(
        _ name: String,
        kind: ConfigKind,
        value: String?,
        syncedValue: String? = nil,
        syncedName: String? = nil,
        scope: ConfigScope = .repository,
        provenance: ConfigProvenance = .local
    ) throws -> ConfigItemID {
        let repositoryID = try repository().id
        let now = clock.now
        return try session.write { keys, tx in
            var record = ConfigItemRecord(
                repositoryID: repositoryID,
                scope: scope,
                kind: kind,
                name: name,
                valueCiphertext: nil,
                valueFingerprint: nil,
                syncedName: syncedName,
                provenance: provenance,
                createdAt: now,
                updatedAt: now
            )
            if let value {
                let bytes = SecretBytes(utf8: value)
                defer { bytes.wipe() }
                try ConfigFieldCipher.setValue(bytes, on: &record, keys: keys)
            }
            if let syncedValue {
                let bytes = SecretBytes(utf8: syncedValue)
                defer { bytes.wipe() }
                try ConfigFieldCipher.setSyncedValue(bytes, on: &record, keys: keys)
            }
            try ConfigStore(database: database).insertItem(record, in: tx)
            return record.id
        }
    }
}

extension SyncChangeOutcomeModel {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
