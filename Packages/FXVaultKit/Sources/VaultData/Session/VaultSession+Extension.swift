import Foundation
import VaultStore

/// Factories for the composition root, so the app opens the vault through VaultData and never
/// imports VaultStore (§4.2; `scripts/lint.sh` enforces it).
extension VaultSession {
    /// A locked session over the live vault database under `~/Library/Application Support`
    /// (`FX Vault`, or `FX Vault Dev` in debug builds), created and migrated if needed.
    ///
    /// - Throws: `StoreError` when the folder or the database cannot be opened or migrated.
    public static func openLive() throws -> VaultSession {
        try VaultSession(database: DatabaseFactory.openLive())
    }

    /// A locked session over `vault.sqlite` in `directory`, created and migrated if needed (the
    /// UI-testing host's throwaway vault).
    ///
    /// - Throws: `StoreError` when the folder or the database cannot be opened or migrated.
    public static func openOnDisk(directory: URL) throws -> VaultSession {
        try VaultSession(database: DatabaseFactory.openOnDisk(directory: directory))
    }

    /// A locked session over a new, empty, migrated in-memory database (previews and tests).
    ///
    /// - Throws: `StoreError` when the database cannot be created.
    public static func inMemory() throws -> VaultSession {
        try VaultSession(database: DatabaseFactory.inMemory())
    }

    /// The folder holding `vault.sqlite`, or nil for an in-memory vault (Preferences › Advanced ›
    /// Reveal vault folder).
    public var databaseDirectory: URL? {
        database.fileURL?.deletingLastPathComponent()
    }
}
