import Foundation

/// File-system and SQLite settings for the vault database (§6 Storage, D10).
///
/// Kept here rather than in VaultCore `Limits`/`Timeouts` because nothing outside VaultStore
/// uses them.
enum StoreConstants {
    /// Mode of the vault directory: owner read, write and search only (D10).
    static let directoryPermissions: Int16 = 0o700
    /// Mode of `vault.sqlite` and its `-wal`/`-shm` companions: owner read and write only.
    static let filePermissions: Int16 = 0o600
    /// How long a connection waits on a lock before failing with `SQLITE_BUSY`, in seconds.
    /// Covers a `wal_checkpoint(TRUNCATE)` waiting for a short pool read to finish.
    static let busyTimeoutSeconds: TimeInterval = 5
    /// Upper bound of concurrent reader connections in the on-disk `DatabasePool`.
    static let maximumReaderCount = 4
    /// GRDB connection label, visible in Instruments and crash logs. Not a secret.
    static let databaseLabel = "io.fractalx.fxvault.vault"
    /// `PRAGMA secure_delete` value meaning ON (deleted content is overwritten with zeros).
    static let secureDeleteOn = 1
    /// Suffixes of SQLite's WAL-mode companion files.
    static let companionFileSuffixes = ["-wal", "-shm"]
}
