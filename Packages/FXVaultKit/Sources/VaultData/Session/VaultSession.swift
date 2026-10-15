import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// The shared, `Sendable` handle every repository uses to reach the vault database and the
/// unlocked keys (§4.3).
///
/// One session exists per open vault. ``VaultManager`` owns the key lifecycle (unlock, lock,
/// rotation); repositories only **use** the keys, through one of three entry points:
///
/// | Entry point | Use it for |
/// |---|---|
/// | ``write(_:)`` | Anything that encrypts or fingerprints a value and stores the result. |
/// | ``read(_:)`` | Decrypting stored values (reveal, copy, push, export). |
/// | ``withKeys(_:)`` | Key work with no database access (fingerprinting a listed remote value). |
///
/// ``write(_:)`` and ``read(_:)`` pair the keys with a database snapshot whose `vaults` row
/// matches them, so a concurrent DEK rotation can never make a repository write a blob under the
/// old key or decrypt a new blob with the old key. Plain database work without keys goes through
/// ``database`` and the VaultStore stores as usual.
///
/// Every body is synchronous and must not keep the keys (they are `borrowing`). Long jobs call an
/// entry point once per item, so a lock takes effect between items.
public final class VaultSession: Sendable {
    /// The migrated vault database. Use the VaultStore stores on it for work that needs no keys.
    public let database: VaultDatabase

    /// The unlocked keys. Internal: only ``VaultManager`` installs and drops them.
    let keyring: VaultKeyring

    private let records: VaultRecordStore

    /// Creates a locked session over `database`.
    public init(database: VaultDatabase) {
        self.database = database
        keyring = VaultKeyring()
        records = VaultRecordStore(database: database)
    }

    // MARK: - State

    /// True when no keys are installed (no vault, or the vault is locked).
    public var isLocked: Bool {
        keyring.isLocked
    }

    /// The keyring generation. It changes on every unlock, lock and DEK rotation; capture it
    /// before slow work and pass it to ``ensureCurrent(_:)`` before committing the result.
    public var generation: UInt64 {
        keyring.generation
    }

    /// The `vaults` row values of the installed keys (vault id, DEK version, key-check value), or
    /// nil while locked. Not secret.
    public var context: VaultKeyContext? {
        try? keyring.withKeys { $0.context }
    }

    /// Throws `VaultError.locked` unless `generation` is still current: no lock, unlock or
    /// rotation happened since it was read.
    public func ensureCurrent(_ generation: UInt64) throws(VaultError) {
        try keyring.ensureCurrent(generation)
    }

    // MARK: - Keys

    /// Runs `body` with a snapshot of the keys, outside any lock (``VaultKeyring/withKeys(_:)``).
    ///
    /// The keys are not tied to a database snapshot here: prefer ``read(_:)`` and ``write(_:)``
    /// whenever the work also touches stored rows.
    ///
    /// - Throws: `VaultError.locked` when the vault is locked, or whatever `body` throws.
    public func withKeys<Result>(_ body: (borrowing UnlockedKeys) throws -> Result) throws -> Result {
        try keyring.withKeys(body)
    }

    /// Runs `body` in one write transaction with the keys that match the stored `vaults` row, and
    /// commits only if the keys are still current when `body` returns.
    ///
    /// Use it for every write that stores ciphertext or fingerprints (value edits, imports,
    /// duplication, share import). Writes are serialized with DEK rotation, so the blobs written
    /// here are always under the current DEK version.
    ///
    /// - Throws: `VaultError.locked` when the vault is locked or was locked while `body` ran (the
    ///   transaction is rolled back), `VaultError.notInitialized` without a vault row,
    ///   ``StoreError`` for database failures, or whatever `body` throws.
    public func write<Result>(_ body: (borrowing UnlockedKeys, StoreTransaction) throws -> Result) throws -> Result {
        try database.write { tx in
            try keyring.withKeys { keys in
                guard try storedVaultMatches(keys, in: tx) else { throw VaultError.locked }
                let result = try body(keys, tx)
                try keyring.ensureCurrent(keys.generation)
                return result
            }
        }
    }

    /// Runs `body` with a read snapshot whose `vaults` row matches the keys.
    ///
    /// The fast path is a concurrent read. If a DEK rotation is committing at that moment (keys and
    /// snapshot disagree), `body` runs once inside a write transaction instead, which waits for the
    /// rotation and sees its result. `body` runs exactly once either way and must only read.
    ///
    /// - Throws: `VaultError.locked` when the vault is locked, `VaultError.notInitialized`
    ///   without a vault row, ``StoreError`` for database failures, or whatever `body` throws.
    public func read<Result>(_ body: (borrowing UnlockedKeys, StoreTransaction) throws -> Result) throws -> Result {
        let attempt: SessionReadAttempt<Result> = try database.read { tx in
            try keyring.withKeys { keys in
                guard try storedVaultMatches(keys, in: tx) else { return .staleSnapshot }
                return .completed(try body(keys, tx))
            }
        }
        switch attempt {
        case .completed(let result):
            return result
        case .staleSnapshot:
            return try database.write { tx in
                try keyring.withKeys { keys in
                    guard try storedVaultMatches(keys, in: tx) else { throw VaultError.locked }
                    return try body(keys, tx)
                }
            }
        }
    }

    // MARK: - VaultManager

    /// Installs freshly unlocked or rotated keys and returns the new generation.
    @discardableResult
    func install(_ keys: UnlockedKeys) -> UInt64 {
        keyring.install(keys)
    }

    /// Drops the keys synchronously (lock procedure Phase A, §5.8).
    func lock() {
        keyring.lock()
    }

    // MARK: - Private

    /// True when the `vaults` row in `tx` belongs to `keys` (same vault id and DEK version).
    private func storedVaultMatches(_ keys: borrowing UnlockedKeys, in tx: StoreTransaction) throws -> Bool {
        guard let vault = try records.fetchVault(in: tx) else { throw VaultError.notInitialized }
        return vault.vaultID == keys.vaultID && UInt32(exactly: vault.dekVersion) == keys.dekVersion
    }
}

/// The outcome of the concurrent fast path of ``VaultSession/read(_:)``.
private enum SessionReadAttempt<Value> {
    case completed(Value)
    /// A rotation is committing: the snapshot's `vaults` row and the keys disagree.
    case staleSnapshot
}
