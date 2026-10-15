import Foundation
import os
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Sample credentials and rows. Passwords are synthetic passphrases that pass D8.
enum VaultFixture {
    static let password = "orbit velvet canyon mosaic lantern quartz"
    static let otherPassword = "harbor tundra pixel saffron glacier whistle"
    static let thirdPassword = "copper meadow falcon riddle summit nectar"
    static let weakPassword = "password1234"
    static let prompt = BiometricPrompt(reason: "test-reason", fallbackTitle: "test-fallback")
    static let login = "user-a"
    static let ownerLogin = "owner-a"
    static let secretValue = "s3cr3t-value-\u{00E9}"
    static let variableValue = "plain-variable-value"
    static let syncedSecretValue = "previous-pushed-value"
    static let fourteenDays: Duration = Timeouts.passwordMaxAge
    static let oneSecond: Duration = .seconds(1)
}

/// Counts calls of the `onLock` hook.
final class LockHookCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// A manager over an in-memory (or given) database with fakes for Touch ID, capabilities and
/// time.
struct VaultHarness {
    let database: VaultDatabase
    let session: VaultSession
    let manager: VaultManager
    let biometrics: FakeBiometricKeyStore
    let capabilities: FakeBuildCapabilities
    let clock: ManualClock
    let lockHook: LockHookCounter

    init(database: VaultDatabase? = nil, clock: ManualClock = ManualClock()) throws {
        let database = try database ?? DatabaseFactory.inMemory()
        self.database = database
        session = VaultSession(database: database)
        biometrics = FakeBiometricKeyStore()
        capabilities = FakeBuildCapabilities()
        self.clock = clock
        let lockHook = LockHookCounter()
        self.lockHook = lockHook
        manager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: biometrics,
            capabilities: capabilities,
            clock: clock,
            onLock: { lockHook.increment() }
        )
    }

    /// A harness whose vault is created (and unlocked) with ``VaultFixture/password``.
    static func created() async throws -> (VaultHarness, RecoveryKey) {
        let harness = try VaultHarness()
        let recoveryKey = try await harness.manager.create(password: VaultFixture.password)
        return (harness, recoveryKey)
    }

    var records: VaultRecordStore {
        VaultRecordStore(database: database)
    }

    func vaultRecord() throws -> VaultRecord {
        try #require(try records.fetchVault())
    }

    var account: String {
        get throws {
            try BiometricKeyAccount.name(vaultID: vaultRecord().vaultID)
        }
    }

    // MARK: - Rows

    /// Inserts the account and one repository.
    func seedRepository(name: String = "repo-a") throws -> RepoModel {
        let start = ManualClock.defaultStart
        try AccountStore(database: database).save(AccountModel(login: VaultFixture.login, lastSeenAt: start))
        let repo = RepoModel(
            accountLogin: VaultFixture.login,
            githubID: nil,
            ownerLogin: VaultFixture.ownerLogin,
            ownerType: .user,
            name: name,
            visibility: .private,
            hasAdmin: true,
            hasPush: true,
            origin: .imported,
            importedAt: start
        )
        try RepoStore(database: database).insert(repo)
        return repo
    }

    /// Encrypts and inserts one item through the session (`synced` also stores a synced value).
    @discardableResult
    func insertItem(
        repo: RepoModel,
        name: String,
        kind: ConfigKind = .secret,
        value: String,
        syncedValue: String? = nil
    ) throws -> ConfigItemID {
        let id = ConfigItemID()
        try session.write { keys, tx in
            let start = ManualClock.defaultStart
            var record = ConfigItemRecord(
                id: id,
                repositoryID: repo.id,
                scope: .repository,
                kind: kind,
                name: name,
                valueCiphertext: nil,
                valueFingerprint: nil,
                createdAt: start,
                updatedAt: start
            )
            let plaintext = SecretBytes(utf8: value)
            defer { plaintext.wipe() }
            record.valueCiphertext = try keys.seal(plaintext, for: Self.valueAAD(record))
            record.valueFingerprint = keys.fingerprint(plaintext, rowID: id)
            if let syncedValue {
                record.syncedName = name
                let synced = SecretBytes(utf8: syncedValue)
                defer { synced.wipe() }
                record.syncedValueCiphertext = try keys.seal(synced, for: Self.syncedAAD(record))
                record.syncedFingerprint = keys.fingerprint(synced, rowID: id)
            }
            try ConfigStore(database: database).insertItem(record, in: tx)
        }
        return id
    }

    func itemRecord(_ id: ConfigItemID) throws -> ConfigItemRecord {
        try #require(try ConfigStore(database: database).fetchItemRecord(id: id))
    }

    /// Decrypts `value_ct` through the session.
    func value(of id: ConfigItemID) throws -> String? {
        try session.read { keys, tx in
            guard
                let record = try ConfigStore(database: database).fetchItemRecord(id: id, in: tx),
                let ciphertext = record.valueCiphertext
            else { return nil }
            let plaintext = try keys.open(ciphertext, for: Self.valueAAD(record))
            defer { plaintext.wipe() }
            return plaintext.utf8String()
        }
    }

    /// Decrypts `synced_value_ct` through the session.
    func syncedValue(of id: ConfigItemID) throws -> String? {
        try session.read { keys, tx in
            guard
                let record = try ConfigStore(database: database).fetchItemRecord(id: id, in: tx),
                let ciphertext = record.syncedValueCiphertext
            else { return nil }
            let plaintext = try keys.open(ciphertext, for: Self.syncedAAD(record))
            defer { plaintext.wipe() }
            return plaintext.utf8String()
        }
    }

    /// True when `fingerprint` is the fingerprint of `value` in row `id` under the current keys.
    func fingerprintMatches(_ fingerprint: Data?, value: String, id: ConfigItemID) throws -> Bool {
        guard let fingerprint else { return false }
        return try session.withKeys { keys in
            let plaintext = SecretBytes(utf8: value)
            defer { plaintext.wipe() }
            return keys.fingerprintMatches(fingerprint, value: plaintext, rowID: id)
        }
    }

    static func valueAAD(_ record: ConfigItemRecord) -> FieldAAD {
        FieldAAD(
            location: .configItemValue,
            rowID: record.id,
            repositoryID: record.repositoryID,
            environmentID: record.environmentID,
            kind: record.kind,
            name: record.name
        )
    }

    static func syncedAAD(_ record: ConfigItemRecord) -> FieldAAD {
        FieldAAD(
            location: .configItemSyncedValue,
            rowID: record.id,
            repositoryID: record.repositoryID,
            environmentID: record.environmentID,
            kind: record.kind,
            name: record.syncedName ?? record.name
        )
    }
}

/// A unique directory under the system temporary directory, removed by ``remove()``.
struct VaultTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxvault-vaultdata-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func directory(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs `body` and returns the `VaultError` it throws, or nil.
func vaultError(_ body: () async throws -> Void) async -> VaultError? {
    do {
        try await body()
        return nil
    } catch let error as VaultError {
        return error
    } catch {
        Issue.record("Expected a VaultError, got \(error)")
        return nil
    }
}
