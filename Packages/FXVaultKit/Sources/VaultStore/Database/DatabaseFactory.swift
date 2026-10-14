import Foundation
import GRDB

/// Opens and migrates the vault database (tasks/todo.md §6 Storage, D10).
///
/// - Live: `~/Library/Application Support/FX Vault/vault.sqlite`; Debug builds use
///   `FX Vault Dev/` so a development build never touches the real vault.
/// - The directory is created with mode 0700 (and forced back to 0700 if it exists), the files
///   are set to 0600.
/// - Every connection runs `PRAGMA secure_delete = ON` and has foreign keys enabled
///   (`prepareDatabase`); GRDB keeps statement arguments out of logs and errors.
/// - All migrations run before the database is returned (``VaultMigrator``).
public enum DatabaseFactory {
    /// The database file name inside the vault directory.
    public static let databaseFileName = "vault.sqlite"
    /// Directory name under Application Support for release builds.
    public static let releaseDirectoryName = "FX Vault"
    /// Directory name under Application Support for Debug builds.
    public static let debugDirectoryName = "FX Vault Dev"

    /// Which vault directory a build uses.
    public enum Flavor: Sendable, Hashable, CaseIterable {
        case release
        case debug

        /// The flavor of the code calling it: `.debug` when the package is compiled with
        /// `DEBUG` (SwiftPM and Xcode Debug configurations).
        public static var current: Flavor {
            #if DEBUG
            .debug
            #else
            .release
            #endif
        }

        /// The directory name under Application Support.
        public var directoryName: String {
            switch self {
            case .release: releaseDirectoryName
            case .debug: debugDirectoryName
            }
        }
    }

    /// `~/Library/Application Support/<FX Vault | FX Vault Dev>/`. Does not create it.
    public static func defaultDirectory(
        flavor: Flavor = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.insecureDirectory
        }
        return support.appendingPathComponent(flavor.directoryName, isDirectory: true)
    }

    /// Opens (creating if needed) and migrates the live vault database for `flavor`.
    public static func openLive(flavor: Flavor = .current) throws -> VaultDatabase {
        try openOnDisk(directory: defaultDirectory(flavor: flavor))
    }

    /// Opens (creating if needed) and migrates `vault.sqlite` in `directory` as a
    /// `DatabasePool`. Tests pass a temporary directory.
    public static func openOnDisk(directory: URL) throws -> VaultDatabase {
        try prepareDirectory(directory)
        let fileURL = directory.appendingPathComponent(databaseFileName, isDirectory: false)
        let pool = try VaultDatabase.translatingErrors {
            try DatabasePool(path: fileURL.path, configuration: makeConfiguration())
        }
        let database = VaultDatabase(writer: pool, fileURL: fileURL)
        try restrictFilePermissions(of: fileURL)
        try VaultMigrator.migrate(database)
        try restrictFilePermissions(of: fileURL)
        return database
    }

    /// A migrated in-memory database (`DatabaseQueue`) with the same connection settings, for
    /// tests and previews. Each call returns an independent, empty vault.
    public static func inMemory() throws -> VaultDatabase {
        let database = try unmigratedInMemory()
        try VaultMigrator.migrate(database)
        return database
    }

    // MARK: - Internal (also used by MigrationTests)

    /// An in-memory database with no migrations applied.
    static func unmigratedInMemory() throws -> VaultDatabase {
        let queue = try VaultDatabase.translatingErrors {
            try DatabaseQueue(configuration: makeConfiguration())
        }
        return VaultDatabase(writer: queue, fileURL: nil)
    }

    /// An on-disk pool with no migrations applied.
    static func unmigratedOnDisk(directory: URL) throws -> VaultDatabase {
        try prepareDirectory(directory)
        let fileURL = directory.appendingPathComponent(databaseFileName, isDirectory: false)
        let pool = try VaultDatabase.translatingErrors {
            try DatabasePool(path: fileURL.path, configuration: makeConfiguration())
        }
        return VaultDatabase(writer: pool, fileURL: fileURL)
    }

    /// Connection settings shared by every connection (writer and readers).
    static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.label = StoreConstants.databaseLabel
        configuration.foreignKeysEnabled = true
        configuration.publicStatementArguments = false
        configuration.busyMode = .timeout(StoreConstants.busyTimeoutSeconds)
        configuration.maximumReaderCount = StoreConstants.maximumReaderCount
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            let secureDelete = try Int.fetchOne(db, sql: "PRAGMA secure_delete")
            // SQLite ignores an unknown or refused pragma silently; refuse to open instead.
            guard secureDelete == StoreConstants.secureDeleteOn else {
                throw StoreError.database(code: ResultCode.SQLITE_MISUSE.rawValue)
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return configuration
    }

    /// Creates `directory` with mode 0700, or forces an existing one back to 0700. Refuses a
    /// symbolic link or a non-directory.
    static func prepareDirectory(_ directory: URL, fileManager: FileManager = .default) throws {
        let path = directory.path
        do {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            if let attributes {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw StoreError.insecureDirectory
                }
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: StoreConstants.directoryPermissions)]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: StoreConstants.directoryPermissions)],
                ofItemAtPath: path
            )
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.insecureDirectory
        }
        let mode = try? fileManager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        guard mode?.int16Value == StoreConstants.directoryPermissions else {
            throw StoreError.insecureDirectory
        }
    }

    /// Sets `vault.sqlite` and any existing `-wal`/`-shm` files to 0600.
    static func restrictFilePermissions(of fileURL: URL, fileManager: FileManager = .default) throws {
        let paths = [fileURL.path] + StoreConstants.companionFileSuffixes.map { fileURL.path + $0 }
        for path in paths where fileManager.fileExists(atPath: path) {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: StoreConstants.filePermissions)],
                    ofItemAtPath: path
                )
            } catch {
                throw StoreError.insecureDirectory
            }
        }
    }
}
