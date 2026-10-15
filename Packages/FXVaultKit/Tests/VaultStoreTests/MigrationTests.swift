import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

/// §6 Migrations: applied fresh and step by step from every earlier version, on a temp-dir
/// `DatabasePool`, with the storage settings (secure_delete, foreign keys, 0700/0600).
@Suite("Migrations and storage")
struct MigrationTests {
    typealias Migration = VaultMigrator.Migration

    static let expectedTables: Set<String> = [
        "vaults", "key_wraps", "accounts", "repositories", "environments", "config_items",
        "sync_journal", "deployment_branch_patterns", "imported_share_packages",
    ]

    @Test func migrationIdentifiersAreFrozenAndOrdered() {
        #expect(Migration.allCases.map(\.rawValue) == [
            "v1_vault", "v2_accounts_repos", "v3_config", "v4_sync_journal", "v5_create_policies", "v6_sharing",
            "v7_journal_fingerprints", "v8_force_push_requested_at",
        ])
        #expect(Migration.latest == .v8ForcePushRequestedAt)
        #expect(Migration.v1Vault < Migration.v7JournalFingerprints)
        #expect(VaultMigrator.makeMigrator().migrations == Migration.allCases.map(\.rawValue))
    }

    @Test func fixturesAreBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }

    @Test func freshOnDiskPoolAppliesEveryMigration() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let database = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }

        #expect(try VaultMigrator.appliedMigrations(database) == Migration.allCases)
        #expect(try VaultMigrator.isUpToDate(database))
        #expect(try Self.tableNames(database).isSuperset(of: Self.expectedTables))
        #expect(database.fileURL?.lastPathComponent == DatabaseFactory.databaseFileName)
        #expect(database.isInMemory == false)
        let journalMode = try database.read { tx in try String.fetchOne(tx.db, sql: "PRAGMA journal_mode") }
        #expect(journalMode == "wal")
    }

    @Test(arguments: Migration.allCases)
    func stepByStepFrom(_ start: Migration) throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }

        let stepped = try DatabaseFactory.unmigratedOnDisk(directory: temp.vaultDirectory)
        defer { try? stepped.close() }
        try VaultMigrator.migrate(stepped, upTo: start)
        #expect(try VaultMigrator.appliedMigrations(stepped) == Migration.allCases.filter { $0 <= start })
        try Self.seed(stepped, upTo: start)

        try VaultMigrator.migrate(stepped)
        #expect(try VaultMigrator.isUpToDate(stepped))

        let fresh = try DatabaseFactory.inMemory()
        #expect(try Self.schema(stepped) == Self.schema(fresh))
        try Self.verifySeed(stepped, upTo: start)
    }

    @Test func migratingTwiceIsANoOp() throws {
        let database = try DatabaseFactory.inMemory()
        let before = try Self.schema(database)
        try VaultMigrator.migrate(database)
        #expect(try Self.schema(database) == before)
    }

    @Test func reopeningKeepsData() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        do {
            let database = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
            try AccountStore(database: database).save(Sample.account())
            try database.close()
        }
        let reopened = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? reopened.close() }
        #expect(try AccountStore(database: reopened).fetchAll().map(\.login) == [Sample.login])
    }

    @Test func databaseFromANewerBuildIsRefused() throws {
        let database = try DatabaseFactory.inMemory()
        try database.write { tx in
            try tx.db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99_future')")
        }
        #expect(throws: StoreError.schemaNewerThanBuild) {
            try VaultMigrator.migrate(database)
        }
    }

    // MARK: - Storage settings

    @Test func secureDeleteAndForeignKeysOnEveryConnection() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let pool = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? pool.close() }
        let memory = try DatabaseFactory.inMemory()

        for database in [pool, memory] {
            let writer = try database.write { tx in
                try (Int.fetchOne(tx.db, sql: "PRAGMA secure_delete"), Int.fetchOne(tx.db, sql: "PRAGMA foreign_keys"))
            }
            let reader = try database.read { tx in
                try (Int.fetchOne(tx.db, sql: "PRAGMA secure_delete"), Int.fetchOne(tx.db, sql: "PRAGMA foreign_keys"))
            }
            #expect(writer.0 == 1)
            #expect(writer.1 == 1)
            #expect(reader.0 == 1)
            #expect(reader.1 == 1)
        }
    }

    @Test func directoryIs0700AndFilesAre0600() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let database = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }
        try AccountStore(database: database).save(Sample.account())

        #expect(try Self.mode(of: temp.vaultDirectory.path) == 0o700)
        let fileURL = try #require(database.fileURL)
        #expect(try Self.mode(of: fileURL.path) == 0o600)
        for suffix in StoreConstants.companionFileSuffixes where FileManager.default.fileExists(atPath: fileURL.path + suffix) {
            #expect(try Self.mode(of: fileURL.path + suffix) == 0o600)
        }
    }

    @Test func existingDirectoryIsForcedBackTo0700() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let lax: Int16 = 0o755
        try FileManager.default.createDirectory(
            at: temp.vaultDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: lax)]
        )
        #expect(try Self.mode(of: temp.vaultDirectory.path) == lax)
        let database = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }
        #expect(try Self.mode(of: temp.vaultDirectory.path) == 0o700)
    }

    @Test func symbolicLinkOrFileAsDirectoryIsRefused() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let target = temp.url.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: temp.vaultDirectory, withDestinationURL: target)
        #expect(throws: StoreError.insecureDirectory) {
            try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        }

        let file = temp.url.appendingPathComponent("plain-file", isDirectory: false)
        try Data().write(to: file)
        #expect(throws: StoreError.insecureDirectory) {
            try DatabaseFactory.openOnDisk(directory: file)
        }
    }

    @Test func defaultDirectoriesSeparateDebugFromRelease() throws {
        let release = try DatabaseFactory.defaultDirectory(flavor: .release)
        let debug = try DatabaseFactory.defaultDirectory(flavor: .debug)
        #expect(release.lastPathComponent == "FX Vault")
        #expect(debug.lastPathComponent == "FX Vault Dev")
        #expect(release.deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(DatabaseFactory.Flavor.current == .debug)
    }

    @Test func checkpointTruncateEmptiesTheWAL() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let database = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }
        let walPath = try #require(database.fileURL).path + "-wal"

        try database.write { tx in try Sample.vault().insert(tx.db) }
        #expect(try Self.size(of: walPath) > 0)
        try database.checkpointTruncate()
        #expect(try Self.size(of: walPath) == 0)

        // Key writes through the convenience API checkpoint on their own (D10).
        try VaultRecordStore(database: database).saveKeyWrap(Sample.passwordWrap())
        #expect(try Self.size(of: walPath) == 0)

        try DatabaseFactory.inMemory().checkpointTruncate()
    }

    @Test func deletedBlobsDoNotSurviveOnDisk() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let database = try DatabaseFactory.openOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }
        let marker = Data("FXV_FIXTURE_DELETED_WRAP_MARKER_0123456789_ABCDEFGHIJKLMNOPQRS".utf8.prefix(Limits.wrappedDEKBytes))
        var wrap = Sample.recoveryWrap()
        wrap.wrappedDEK = marker

        try VaultRecordStore(database: database).saveKeyWrap(wrap)
        #expect(try Self.bytesOnDisk(database).range(of: marker) != nil)
        try VaultRecordStore(database: database).deleteKeyWrap(.recovery)
        #expect(try Self.bytesOnDisk(database).range(of: marker) == nil)
    }

    @Test func timestampsAndIdentifiersUseTheDocumentedTextForms() throws {
        let seeded = try SeededDatabase()
        let createdAt = Sample.date(1.25)
        let item = ConfigItemRecord(
            repositoryID: seeded.repo.id,
            scope: .repository,
            kind: .variable,
            name: "API_URL",
            valueCiphertext: Sample.ciphertext(),
            valueFingerprint: Sample.fingerprint(),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try seeded.config.insertItem(item)

        let row = try seeded.database.read { tx in
            try Row.fetchOne(tx.db, sql: "SELECT id, repository_id, created_at, typeof(created_at) AS t FROM config_items")
        }
        let fetched = try #require(row)
        #expect(fetched["created_at"] as String == "2001-01-01T00:00:01.250Z")
        #expect(fetched["t"] as String == "text")
        #expect(fetched["id"] as String == item.id.uuidString)
        #expect(fetched["repository_id"] as String == seeded.repo.id.uuidString)
        let id: String = fetched["id"]
        #expect(id == id.lowercased())
        #expect(DatabaseTimestamp.date(from: "2001-01-01T00:00:01Z") == Sample.date(1))
        #expect(DatabaseTimestamp.date(from: "yesterday") == nil)
        #expect(DatabaseTimestamp.roundTripped(createdAt) == createdAt)
        #expect(try seeded.config.fetchItemRecord(id: item.id)?.createdAt == createdAt)
    }

    // MARK: - Helpers

    static func tableNames(_ database: VaultDatabase) throws -> Set<String> {
        try database.read { tx in
            try Set(String.fetchAll(tx.db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    /// Every schema object (except GRDB's and SQLite's own) with its SQL, plus each table's
    /// columns, so a stepped database can be compared with a fresh one.
    static func schema(_ database: VaultDatabase) throws -> [String] {
        try database.read { tx in
            let objects = try Row.fetchAll(tx.db, sql: """
                SELECT type, name, tbl_name, sql FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY type, name
                """)
            var lines = objects.map { "\($0["type"] as String) \($0["name"] as String) \($0["sql"] as String? ?? "")" }
            for table in expectedTables.sorted() {
                let columns = try Row.fetchAll(tx.db, sql: "PRAGMA table_info(\(table))")
                lines += columns.map { "\(table).\($0["name"] as String) \($0["type"] as String) \($0["notnull"] as Int) \($0["dflt_value"] as String? ?? "NULL")" }
            }
            return lines
        }
    }

    static func mode(of path: String) throws -> Int16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? -1
    }

    /// `vault.sqlite` plus any `-wal`/`-shm` bytes.
    static func bytesOnDisk(_ database: VaultDatabase) throws -> Data {
        let path = try #require(database.fileURL).path
        var bytes = Data()
        for file in [path] + StoreConstants.companionFileSuffixes.map({ path + $0 })
        where FileManager.default.fileExists(atPath: file) {
            bytes.append(try Data(contentsOf: URL(fileURLWithPath: file)))
        }
        return bytes
    }

    static func size(of path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    // MARK: - Seed data valid at each version (raw SQL: later columns do not exist yet)

    static let seedRepoID = "11111111-1111-4111-8111-111111111111"
    static let seedEnvironmentID = "22222222-2222-4222-8222-222222222222"
    static let seedItemID = "33333333-3333-4333-8333-333333333333"
    static let seedRunID = "44444444-4444-4444-8444-444444444444"
    static let seedPatternID = "55555555-5555-4555-8555-555555555555"
    static let seedPackageID = "66666666-6666-4666-8666-666666666666"
    static let seedTime = "2001-01-01T00:00:00.000Z"
    static let seedSourceFingerprint = Data(repeating: 9, count: 32)
    static let seedPushedFingerprint = Data(repeating: 10, count: 32)

    static func seed(_ database: VaultDatabase, upTo version: Migration) throws {
        try database.write { tx in
            let db = tx.db
            try db.execute(
                sql: "INSERT INTO vaults (id, vault_id, kcv, created_at) VALUES (1, ?, ?, ?)",
                arguments: [Data(repeating: 1, count: 16), Data(repeating: 2, count: 16), seedTime]
            )
            try db.execute(
                sql: "INSERT INTO key_wraps (method, kdf_alg, wrapped_dek, dek_version, updated_at) VALUES ('recovery', 2, ?, 1, ?)",
                arguments: [Data(repeating: 3, count: 62), seedTime]
            )
            guard version >= .v2AccountsRepos else { return }
            try db.execute(
                sql: "INSERT INTO accounts (login, last_seen_at) VALUES (?, ?)",
                arguments: [Sample.login, seedTime]
            )
            try db.execute(sql: """
                INSERT INTO repositories (id, account_login, github_id, owner_login, owner_type, name, is_private, origin, imported_at)
                VALUES (?, ?, 'R_seed', ?, 'User', 'seed-repo', 1, 'imported', ?)
                """, arguments: [seedRepoID, Sample.login, Sample.login, seedTime])
            guard version >= .v3Config else { return }
            try db.execute(sql: """
                INSERT INTO environments (id, repository_id, name, name_key, branch_policy, created_at, updated_at)
                VALUES (?, ?, 'Staging', 'staging', 'custom', ?, ?)
                """, arguments: [seedEnvironmentID, seedRepoID, seedTime, seedTime])
            try db.execute(sql: """
                INSERT INTO config_items (id, repository_id, environment_id, kind, name, value_ct, value_fp, created_at, updated_at)
                VALUES (?, ?, ?, 'variable', 'API_URL', ?, ?, ?, ?)
                """, arguments: [
                    seedItemID, seedRepoID, seedEnvironmentID,
                    Data(repeating: 7, count: 40), Data(repeating: 8, count: 32), seedTime, seedTime,
                ])
            guard version >= .v4SyncJournal else { return }
            try db.execute(sql: """
                INSERT INTO sync_journal (run_id, account_login, repository_id, op, command, is_write, scope_label, target_key, state, started_at)
                VALUES (?, ?, ?, 'setVariable', 'variable.set', 1, 'Staging', 'k', 'succeeded', ?)
                """, arguments: [seedRunID, Sample.login, seedRepoID, seedTime])
            guard version >= .v5CreatePolicies else { return }
            try db.execute(
                sql: "UPDATE repositories SET create_spec_json = ?, clone_path = '/tmp/seed' WHERE id = ?",
                arguments: [#"{"auto_init":true,"clone_after":false}"#, seedRepoID]
            )
            try db.execute(
                sql: "INSERT INTO deployment_branch_patterns (id, environment_id, pattern, type) VALUES (?, ?, 'release/*', 'branch')",
                arguments: [seedPatternID, seedEnvironmentID]
            )
            guard version >= .v6Sharing else { return }
            try db.execute(
                sql: "INSERT INTO imported_share_packages (package_id, created_at, imported_at) VALUES (?, ?, ?)",
                arguments: [seedPackageID, seedTime, seedTime]
            )
            guard version >= .v7JournalFingerprints else { return }
            try db.execute(
                sql: "UPDATE sync_journal SET source_fp = ?, pushed_fp = ?, did_normalize_value = 1",
                arguments: [seedSourceFingerprint, seedPushedFingerprint]
            )
            guard version >= .v8ForcePushRequestedAt else { return }
            try db.execute(
                sql: "UPDATE config_items SET force_push = 1, force_push_requested_at = ? WHERE id = ?",
                arguments: [seedTime, seedItemID]
            )
        }
    }

    /// After the remaining migrations, the seed reads back through the stores with the new
    /// columns at their defaults.
    static func verifySeed(_ database: VaultDatabase, upTo version: Migration) throws {
        let vault = try VaultRecordStore(database: database).fetchVault()
        #expect(vault?.formatVersion == VaultRecord.initialVersion)
        #expect(try VaultRecordStore(database: database).fetchKeyWrap(.recovery)?.kdf == .hkdfSHA256)
        guard version >= .v2AccountsRepos else { return }
        let repoID = try #require(RepoID(uuidString: seedRepoID))
        let repo = try #require(try RepoStore(database: database).fetch(id: repoID))
        #expect(repo.name == "seed-repo")
        #expect(repo.visibility == .private)
        guard version >= .v3Config else { return }
        let environment = try #require(try ConfigStore(database: database).fetchEnvironments(repositoryID: repoID).first)
        #expect(environment.nameKey == "staging")
        let items = try ConfigStore(database: database).fetchItems(repositoryID: repoID)
        #expect(items.map(\.name) == ["API_URL"])
        #expect(items.first?.provenance == .local)
        #expect(items.first?.syncStatus == .added)
        guard version >= .v4SyncJournal else { return }
        #expect(try SyncJournalStore(database: database).fetchLatestRun().map(\.command) == ["variable.set"])
        guard version >= .v5CreatePolicies else { return }
        #expect(repo.createSpec == RepoCreateSpecModel(autoInit: true, cloneAfter: false))
        #expect(environment.branchPolicy.patterns.map(\.pattern) == ["release/*"])
        guard version >= .v6Sharing else { return }
        let packageID = try #require(SharePackageID(uuidString: seedPackageID))
        #expect(try SharePackageStore(database: database).hasImported(packageID))
        let journal = try #require(try SyncJournalStore(database: database).fetchLatestRun().first)
        guard version >= .v7JournalFingerprints else {
            // Rows journaled before v7 read back without push fingerprints.
            #expect(journal.sourceFingerprint == nil && journal.pushedFingerprint == nil && journal.didNormalizeValue == nil)
            return
        }
        #expect(journal.sourceFingerprint == seedSourceFingerprint)
        #expect(journal.pushedFingerprint == seedPushedFingerprint)
        #expect(journal.didNormalizeValue == true)
        let record = try #require(try database.read { tx in
            try ConfigItemRecord.fetchOne(tx.db, key: seedItemID)
        })
        guard version >= .v8ForcePushRequestedAt else {
            // Rows from before v8 have no requested push.
            #expect(!record.forcePush && record.forcePushRequestedAt == nil)
            return
        }
        #expect(record.forcePush)
        #expect(record.forcePushRequestedAt == DatabaseTimestamp.date(from: seedTime))
    }
}
