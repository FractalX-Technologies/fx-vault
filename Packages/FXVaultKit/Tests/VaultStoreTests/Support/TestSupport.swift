import Foundation
import GRDB
import VaultCore
@testable import VaultStore

/// A unique directory under the system temporary directory, removed by ``remove()``.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxvault-vaultstore-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// The vault directory inside this temporary directory (not created yet).
    var vaultDirectory: URL {
        url.appendingPathComponent("FX Vault Test", isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum TestError: Error, Equatable {
    case rollback
}

/// Deterministic sample rows. Blobs are dummy bytes: VaultStore never interprets them.
enum Sample {
    static let start = ManualClock.defaultStart
    static let login = "fx-test-owner"
    static let ciphertextByte: UInt8 = 0xC7
    static let fingerprintByte: UInt8 = 0xF1
    static let otherFingerprintByte: UInt8 = 0xF2
    static let ciphertextLength = 40
    static let fingerprintLength = 32

    static func date(_ secondsAfterStart: TimeInterval) -> Date {
        start.addingTimeInterval(secondsAfterStart)
    }

    static func ciphertext(_ byte: UInt8 = ciphertextByte) -> Data {
        Data(repeating: byte, count: ciphertextLength)
    }

    static func fingerprint(_ byte: UInt8 = fingerprintByte) -> Data {
        Data(repeating: byte, count: fingerprintLength)
    }

    static func account(_ login: String = login) -> AccountModel {
        AccountModel(login: login, lastSeenAt: start)
    }

    static func repo(
        id: RepoID = RepoID(),
        account: String = login,
        owner: String = login,
        name: String = "fx-test-repo",
        githubID: String? = "R_kgDOTEST0001"
    ) -> RepoModel {
        RepoModel(
            id: id,
            accountLogin: account,
            githubID: githubID,
            ownerLogin: owner,
            ownerType: .user,
            name: name,
            visibility: .private,
            hasAdmin: true,
            hasPush: true,
            origin: .imported,
            importedAt: start
        )
    }

    static func environment(
        id: EnvironmentID = EnvironmentID(),
        repositoryID: RepoID,
        name: String = "production",
        policy: DeploymentBranchPolicyModel = .all
    ) -> EnvironmentModel {
        EnvironmentModel(
            id: id,
            repositoryID: repositoryID,
            name: name,
            branchPolicy: policy,
            createdAt: start,
            updatedAt: start
        )
    }

    static func item(
        id: ConfigItemID = ConfigItemID(),
        repositoryID: RepoID,
        scope: ConfigScope = .repository,
        kind: ConfigKind = .secret,
        name: String = "API_TOKEN",
        hasValue: Bool = true
    ) -> ConfigItemRecord {
        ConfigItemRecord(
            id: id,
            repositoryID: repositoryID,
            scope: scope,
            kind: kind,
            name: name,
            valueCiphertext: hasValue ? ciphertext() : nil,
            valueFingerprint: hasValue ? fingerprint() : nil,
            createdAt: start,
            updatedAt: start
        )
    }

    static func vault() -> VaultRecord {
        VaultRecord(
            vaultID: Data(repeating: 0x01, count: Limits.vaultIDBytes),
            kcv: Data(repeating: 0x02, count: Limits.kcvBytes),
            createdAt: start
        )
    }

    static func passwordWrap(dekVersion: Int = VaultRecord.initialVersion, byte: UInt8 = 0x03) -> KeyWrapRecord {
        KeyWrapRecord(
            method: .password,
            kdf: .argon2id13,
            opsLimit: Limits.passwordKDFOpsLimit,
            memLimitBytes: Limits.passwordKDFMemoryBytes,
            salt: Data(repeating: 0x04, count: Limits.kdfSaltBytes),
            wrappedDEK: Data(repeating: byte, count: Limits.wrappedDEKBytes),
            dekVersion: dekVersion,
            updatedAt: start
        )
    }

    static func recoveryWrap() -> KeyWrapRecord {
        KeyWrapRecord(
            method: .recovery,
            kdf: .hkdfSHA256,
            wrappedDEK: Data(repeating: 0x05, count: Limits.wrappedDEKBytes),
            dekVersion: VaultRecord.initialVersion,
            updatedAt: start
        )
    }

    static func journal(
        runID: SyncRunID,
        account: String = login,
        repositoryID: RepoID?,
        command: String = "secret.set",
        isWrite: Bool = true,
        itemName: String? = "API_TOKEN",
        startedAt: Date
    ) -> SyncJournalRecord {
        SyncJournalRecord(
            runID: runID,
            accountLogin: account,
            repositoryID: repositoryID,
            op: "setSecret",
            command: command,
            isWrite: isWrite,
            scopeLabel: "Repository",
            targetKey: "repo:\(itemName ?? "-")",
            itemName: itemName,
            startedAt: startedAt
        )
    }
}

/// A migrated in-memory database with one account and one repository.
struct SeededDatabase {
    let database: VaultDatabase
    let repo: RepoModel

    init() throws {
        database = try DatabaseFactory.inMemory()
        repo = Sample.repo()
        try AccountStore(database: database).save(Sample.account())
        try RepoStore(database: database).insert(repo)
    }

    var accounts: AccountStore { AccountStore(database: database) }
    var repos: RepoStore { RepoStore(database: database) }
    var config: ConfigStore { ConfigStore(database: database) }
    var journal: SyncJournalStore { SyncJournalStore(database: database) }
    var vault: VaultRecordStore { VaultRecordStore(database: database) }
    var shares: SharePackageStore { SharePackageStore(database: database) }

    /// Runs raw SQL in a write transaction (constraint tests).
    func execute(_ sql: String) throws {
        try database.write { tx in
            try tx.db.execute(sql: sql)
        }
    }

    /// Fetches one raw text value.
    func text(_ sql: String) throws -> String? {
        try database.read { tx in try String.fetchOne(tx.db, sql: sql) }
    }

    /// Fetches one raw integer value.
    func integer(_ sql: String) throws -> Int? {
        try database.read { tx in try Int.fetchOne(tx.db, sql: sql) }
    }
}
