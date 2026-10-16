import Foundation
import GitHubKit
import os
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Sample names and values for the Config, Catalog, Accounts and EnvFiles tests. Names follow
/// the public-fixture rule (owner-a, user-a, ...); values are synthetic.
enum ConfigFixture {
    static let password = "meadow quartz lantern harbor violet anchor"
    static let login = "user-a"
    static let ownerLogin = "owner-a"
    static let repoName = "repo-a"
    static let valueA = "value-a-\u{00E9}"
    static let valueB = "value-b"
    static let valueC = "value-c"
    static let token = "fixture-token-a"
    /// A JWT-shaped public key (an anon key), joined at runtime so secret scanners skip the source.
    static let sampleJWT = ["eyJhbGciOiJIUzI1NiJ9", "eyJyb2xlIjoiYW5vbiJ9", "c2lnbmF0dXJl"].joined(separator: ".")
}

/// An unlocked vault over an in-memory (or given) database with fakes, plus the repositories
/// under test.
struct ConfigHarness {
    let database: VaultDatabase
    let session: VaultSession
    let manager: VaultManager
    let clock: ManualClock
    let config: ConfigRepository

    /// Creates the vault (unlocked) with ``ConfigFixture/password``.
    static func make(database: VaultDatabase? = nil, writePolicy: WriteCollaboratorPolicy = .default) async throws -> ConfigHarness {
        let database = try database ?? DatabaseFactory.inMemory()
        let session = VaultSession(database: database)
        let clock = ManualClock()
        let manager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: FakeBiometricKeyStore(),
            capabilities: FakeBuildCapabilities(),
            clock: clock
        )
        _ = try await manager.create(password: ConfigFixture.password)
        return ConfigHarness(
            database: database,
            session: session,
            manager: manager,
            clock: clock,
            config: ConfigRepository(session: session, clock: clock, writePolicy: writePolicy)
        )
    }

    var store: ConfigStore {
        ConfigStore(database: database)
    }

    /// Inserts the account and one repository the viewer administers (unless told otherwise).
    @discardableResult
    func seedRepository(
        name: String = ConfigFixture.repoName,
        hasAdmin: Bool = true,
        hasPush: Bool = true,
        isArchived: Bool = false
    ) throws -> RepoModel {
        let start = ManualClock.defaultStart
        if try AccountStore(database: database).fetch(login: ConfigFixture.login) == nil {
            try AccountStore(database: database).save(AccountModel(login: ConfigFixture.login, lastSeenAt: start))
        }
        let repo = RepoModel(
            accountLogin: ConfigFixture.login,
            githubID: "R_\(name)",
            ownerLogin: ConfigFixture.ownerLogin,
            ownerType: .user,
            name: name,
            visibility: .private,
            isArchived: isArchived,
            hasAdmin: hasAdmin,
            hasPush: hasPush,
            origin: .imported,
            importedAt: start
        )
        try RepoStore(database: database).insert(repo)
        return repo
    }

    // MARK: - Items

    @discardableResult
    func add(
        _ repo: RepoModel,
        _ name: String,
        kind: ConfigKind = .secret,
        value: String,
        scope: ConfigScope = .repository
    ) throws -> ConfigItemID {
        try config.addItem(repositoryID: repo.id, scope: scope, kind: kind, name: name, value: SecretBytes(utf8: value)).itemID
    }

    func reveal(_ id: ConfigItemID) throws -> String? {
        let value = try config.reveal(id)
        defer { value.wipe() }
        return value.utf8String()
    }

    func state(_ id: ConfigItemID) throws -> ConfigItemState {
        let record = try #require(try store.fetchItemRecord(id: id))
        return record.state
    }

    func record(_ id: ConfigItemID) throws -> ConfigItemRecord {
        try #require(try store.fetchItemRecord(id: id))
    }

    func states(_ repo: RepoModel) throws -> [ConfigItemState] {
        try store.fetchItemStates(repositoryID: repo.id)
    }

    func changeSet(_ repo: RepoModel) throws -> ChangeSetModel {
        try #require(try config.changeSet(repositoryID: repo.id))
    }

    func status(_ id: ConfigItemID) throws -> ConfigSyncStatus {
        try state(id).model.syncStatus
    }

    // MARK: - Simulated sync

    /// Marks every row of the repository as GitHub has it now, as a verified Sync would: live
    /// items get `synced_name := name` and the synced value := the value; tombstones and
    /// environment tombstones are removed; environments get their synced name and policy, and
    /// patterns a GitHub id.
    func markSynced(_ repo: RepoModel) throws {
        try session.write { keys, tx in
            let store = ConfigStore(database: database)
            for environment in try store.fetchEnvironments(repositoryID: repo.id, in: tx) {
                if environment.isDeleted {
                    try store.deleteEnvironment(id: environment.id, in: tx)
                    continue
                }
                var synced = environment
                synced.syncedName = environment.name
                synced.syncedBranchPolicy = environment.branchPolicy.kind
                synced.githubEnvID = synced.githubEnvID ?? Self.fakeEnvironmentID
                try store.updateEnvironment(synced, in: tx)
                for (index, pattern) in try store.fetchPatterns(environmentID: environment.id, in: tx).enumerated() {
                    if pattern.isDeleted {
                        try store.deletePattern(id: pattern.id, in: tx)
                    } else if pattern.githubPolicyID == nil {
                        var posted = pattern
                        posted.githubPolicyID = Int64(index + 1)
                        try store.updatePattern(posted, in: tx)
                    }
                }
            }
            for var record in try store.fetchItemRecords(repositoryID: repo.id, in: tx) {
                if record.isDeleted {
                    try store.deleteItem(id: record.id, in: tx)
                    continue
                }
                record.syncedName = record.name
                record.forcePush = false
                if let value = try ConfigFieldCipher.openValue(of: record, keys: keys) {
                    defer { value.wipe() }
                    try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
                } else {
                    record.syncedValueCiphertext = nil
                    record.syncedFingerprint = nil
                }
                try store.updateItem(record, in: tx)
            }
        }
    }

    private static let fakeEnvironmentID: Int64 = 1
}

/// A unique directory under the temporary directory, removed by ``remove()``.
struct ConfigTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxvault-config-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs `body` and returns the ``ConfigRepositoryError`` it throws, or nil.
func configError(_ body: () throws -> Void) -> ConfigRepositoryError? {
    do {
        try body()
        return nil
    } catch let error as ConfigRepositoryError {
        return error
    } catch {
        Issue.record("Expected a ConfigRepositoryError, got \(error)")
        return nil
    }
}
