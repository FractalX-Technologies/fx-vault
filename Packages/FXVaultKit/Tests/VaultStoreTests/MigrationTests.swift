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
        "sync_journal", "deployment_branch_patterns", "imported_share_packages", "folders", "folder_items",
        "provider_connections", "destinations", "destination_items", "destination_journal", "sent_shares",
        "retired_destinations", "organizations", "org_items",
    ]

    // v15 drops these, with the teammate and space key material in them.
    static let droppedTables: Set<String> = [
        "device_identity", "teammates", "spaces", "space_keys", "space_versions", "teammate_addresses",
    ]

    @Test func migrationIdentifiersAreFrozenAndOrdered() {
        #expect(Migration.allCases.map(\.rawValue) == [
            "v1_vault", "v2_accounts_repos", "v3_config", "v4_sync_journal", "v5_create_policies", "v6_sharing",
            "v7_journal_fingerprints", "v8_force_push_requested_at", "v9_item_links", "v10_teammates",
            "v11_spaces", "v12_folders", "v13_destinations", "v14_project_shares",
            "v15_drop_teammates", "v16_drop_runtime_providers", "v17_organizations", "v18_standalone_key_vaults",
        ])
        #expect(Migration.latest == .v18StandaloneKeyVaults)
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
        #expect(try Self.tableNames(database).isDisjoint(with: Self.droppedTables))
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

    /// v15 drops tables that held this Mac's teammate and space keys: the migration checkpoints,
    /// so no copy of their pages stays in `vault.sqlite-wal` (secure_delete zeroes only the main file).
    @Test func droppingTheTeammateTablesLeavesNoKeyBytesInTheWAL() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let database = try DatabaseFactory.unmigratedOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }
        try VaultMigrator.migrate(database, upTo: .v14ProjectShares)
        try Self.seed(database, upTo: .v14ProjectShares)
        try database.checkpointTruncate()
        let walPath = try #require(database.fileURL).path + "-wal"

        try VaultMigrator.migrate(database)

        #expect(try Self.size(of: walPath) == 0)
        #expect(try Self.bytesOnDisk(database).range(of: Self.seedAnnounceCiphertext) == nil)
    }

    /// v16 deletes the provider tokens and the Supabase and Vercel rows: the token bytes stay
    /// neither in `vault.sqlite` nor in its WAL.
    @Test func droppingTheRuntimeProvidersLeavesNoTokenBytesOnDisk() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let database = try DatabaseFactory.unmigratedOnDisk(directory: temp.vaultDirectory)
        defer { try? database.close() }
        try VaultMigrator.migrate(database, upTo: .v15DropTeammates)
        try Self.seed(database, upTo: .v15DropTeammates)
        try database.checkpointTruncate()
        #expect(try Self.bytesOnDisk(database).range(of: Self.seedConnectionToken) != nil)
        let walPath = try #require(database.fileURL).path + "-wal"

        try VaultMigrator.migrate(database)

        #expect(try Self.size(of: walPath) == 0)
        #expect(try Self.bytesOnDisk(database).range(of: Self.seedConnectionToken) == nil)
        #expect(try Self.bytesOnDisk(database).range(of: Self.seedRetiredValueCiphertext) == nil)
    }

    @Test func retiredDestinationsShowOnceThenClear() throws {
        let database = try DatabaseFactory.unmigratedInMemory()
        try VaultMigrator.migrate(database, upTo: .v15DropTeammates)
        try Self.seed(database, upTo: .v15DropTeammates)
        try VaultMigrator.migrate(database)
        let store = DestinationStore(database: database)
        #expect(try store.fetchRetiredDestinationLabels() == Self.seedRetiredLabels)

        try store.deleteRetiredDestinations()

        #expect(try store.fetchRetiredDestinationLabels().isEmpty)
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
    static let seedLinkID = "44444444-4444-4444-8444-444444444444"
    static let seedFolderID = "77777777-7777-4777-8777-777777777777"
    static let seedFolderItemID = "88888888-8888-4888-8888-888888888888"
    static let seedConnectionID = "99999999-9999-4999-8999-999999999999"
    static let seedDestinationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let seedDestinationItemID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    static let seedTeammateID = "0123456789abcdef0123456789abcdef"
    static let seedRemoteTeammateID = "fedcba9876543210fedcba9876543210"
    static let seedSentShareID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    static let seedSigningKey = Data(repeating: 0x21, count: 32)
    static let seedAgreementKey = Data(repeating: 0x22, count: 32)
    static let seedAnnounceCiphertext = Data((0..<60).map { UInt8($0) })
    static let seedConnectionToken = Data((100..<148).map { UInt8($0) })
    static let seedVercelDestinationID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    static let seedSupabaseDestinationID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    static let seedRetiredItemID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    static let seedRetiredValueCiphertext = Data((150..<190).map { UInt8($0) })
    static let seedRetiredLabels = [
        "\(Sample.login)/seed-repo · Vercel web (production)",
        "\(Sample.login)/seed-repo · Supabase abcdefghijklmnopqrst",
    ]

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
            guard version >= .v9ItemLinks else { return }
            try db.execute(sql: "UPDATE config_items SET link_id = ? WHERE id = ?", arguments: [seedLinkID, seedItemID])
            guard version >= .v10Teammates else { return }
            // The teammate tables exist from v10 to v14 only (v15 drops them).
            let hasTeammates = version < .v15DropTeammates
            if hasTeammates { try db.execute(sql: """
                INSERT INTO teammates (device_id, signing_pk, agreement_pk, announce_ct, login, display_name, mac_name,
                  paired_at, last_seen_at, is_muted, needs_card_update)
                VALUES (?, ?, ?, ?, 'user-a', 'User A', 'User A Mac', ?, ?, 1, 1)
                """, arguments: [seedTeammateID, seedSigningKey, seedAgreementKey, seedAnnounceCiphertext, seedTime, seedTime]) }
            guard version >= .v11Spaces else { return }
            if hasTeammates {
                try db.execute(
                    sql: "INSERT INTO teammate_addresses (device_id, host, port, allows_remote) VALUES (?, 'mac-a.example.ts.net', 7443, 1)",
                    arguments: [seedTeammateID]
                )
            }
            guard version >= .v12Folders else { return }
            try db.execute(
                sql: "INSERT INTO folders (id, name, name_key, sort_order, created_at, updated_at) VALUES (?, 'Mobile App', 'mobile app', 0, ?, ?)",
                arguments: [seedFolderID, seedTime, seedTime]
            )
            try db.execute(sql: """
                INSERT INTO folder_items (id, folder_id, kind, name, value_ct, value_fp, link_id, created_at, updated_at)
                VALUES (?, ?, 'variable', 'API_URL', ?, ?, ?, ?, ?)
                """, arguments: [
                    seedFolderItemID, seedFolderID, Data(repeating: 7, count: 40), Data(repeating: 8, count: 32),
                    seedLinkID, seedTime, seedTime,
                ])
            guard version >= .v13Destinations else { return }
            try db.execute(sql: """
                INSERT INTO destinations (id, repository_id, provider, target_key, settings_json, stage, stage_key,
                  connection_id, sort_order, created_at, updated_at)
                VALUES (?, ?, 'azure_keyvault', 'kv|kv-sample-prod', ?, 'Production', 'production', NULL, 0, ?, ?)
                """, arguments: [seedDestinationID, seedRepoID, #"{"vaultName":"kv-sample-prod","version":1}"#, seedTime, seedTime])
            try db.execute(sql: """
                INSERT INTO destination_items (id, destination_id, kind, name, value_ct, value_fp, link_id, created_at, updated_at)
                VALUES (?, ?, 'secret', 'API_URL', ?, ?, ?, ?, ?)
                """, arguments: [
                    seedDestinationItemID, seedDestinationID, Data(repeating: 7, count: 40), Data(repeating: 8, count: 32),
                    seedLinkID, seedTime, seedTime,
                ])
            // Supabase and Vercel exist from v13 to v15 only (v16 deletes them).
            if version < .v16DropRuntimeProviders {
                try seedRuntimeProviders(db)
            }
            guard version >= .v14ProjectShares else { return }
            // A file held under 0.9 from a verified teammate: Sync keeps showing it as verified.
            try db.execute(
                sql: "UPDATE imported_share_packages SET sender_device_id = ? WHERE package_id = ?",
                arguments: [seedTeammateID, seedPackageID]
            )
            try db.execute(sql: """
                INSERT INTO sent_shares (id, package_id, created_at, expires_at, mode, recipients, summary)
                VALUES (?, ?, ?, '2001-01-08T00:00:00.000Z', 'teammates', ?, ?)
                """, arguments: [
                    seedSentShareID, seedPackageID, seedTime, #"["\#(seedTeammateID)"]"#,
                    #"{"places":[{"kind":"environment","name":"staging","repository":"user-a/seed-repo","secretNames":[],"variableNames":["API_URL"]}],"stages":["staging"]}"#,
                ])
            try db.execute(sql: "UPDATE config_items SET share_hold = ? WHERE id = ?", arguments: [seedPackageID, seedItemID])
            try db.execute(
                sql: "UPDATE destination_items SET share_hold = ? WHERE id = ?",
                arguments: [seedPackageID, seedDestinationItemID]
            )
            guard hasTeammates else { return }
            try db.execute(sql: """
                INSERT INTO teammates (device_id, signing_pk, agreement_pk, announce_ct, login, display_name, mac_name,
                  paired_at, paired_via)
                VALUES (?, ?, ?, NULL, 'user-b', 'User B', 'User B Mac', ?, 'remote')
                """, arguments: [seedRemoteTeammateID, seedSigningKey, seedAgreementKey, seedTime])
        }
    }

    /// A Vercel destination (with its connection, an item and a journal row) and a Supabase one.
    static func seedRuntimeProviders(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO provider_connections (id, provider, label, token_ct, created_at, updated_at)
            VALUES (?, 'vercel', 'Sample Vercel', ?, ?, ?)
            """, arguments: [seedConnectionID, seedConnectionToken, seedTime, seedTime])
        try db.execute(sql: """
            INSERT INTO destinations (id, repository_id, provider, target_key, settings_json, connection_id, sort_order,
              created_at, updated_at)
            VALUES (?, ?, 'vercel', 'vc|prj_web|production', ?, ?, 1, ?, ?),
                   (?, ?, 'supabase', 'sb|abcdefghijklmnopqrst', ?, NULL, 2, ?, ?)
            """, arguments: [
                seedVercelDestinationID, seedRepoID,
                #"{"environment":"production","projectID":"prj_web","projectName":"web","version":1}"#,
                seedConnectionID, seedTime, seedTime,
                seedSupabaseDestinationID, seedRepoID, #"{"projectRef":"abcdefghijklmnopqrst","version":1}"#,
                seedTime, seedTime,
            ])
        try db.execute(sql: """
            INSERT INTO destination_items (id, destination_id, kind, name, value_ct, value_fp, created_at, updated_at)
            VALUES (?, ?, 'variable', 'NEXT_PUBLIC_URL', ?, ?, ?, ?)
            """, arguments: [
                seedRetiredItemID, seedVercelDestinationID, seedRetiredValueCiphertext, Data(repeating: 8, count: 32),
                seedTime, seedTime,
            ])
        try db.execute(sql: """
            INSERT INTO destination_journal (run_id, destination_id, item_id, op, item_name, state, started_at)
            VALUES (?, ?, ?, 'set', 'NEXT_PUBLIC_URL', 'succeeded', ?)
            """, arguments: [seedRunID, seedVercelDestinationID, seedRetiredItemID, seedTime])
    }

    static func rowCount(_ database: VaultDatabase, _ table: String) throws -> Int {
        try database.read { tx in try Int.fetchOne(tx.db, sql: "SELECT count(*) FROM \(table)") ?? -1 }
    }

    /// After the remaining migrations, the seed reads back through the stores with the new
    /// columns at their defaults.
    static func verifySeed(_ database: VaultDatabase, upTo version: Migration) throws {
        try verifyProjectShareSeed(database, upTo: version)
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
        guard version >= .v9ItemLinks else {
            // Rows from before v9 are not linked.
            #expect(record.linkID == nil)
            return
        }
        #expect(record.linkID == ItemLinkID(uuidString: seedLinkID))
        let folders = try FolderStore(database: database).fetchFolders()
        let link = try #require(ItemLinkID(uuidString: seedLinkID))
        let linkCount = try database.read { tx in try LinkCountQuery.counts(of: [link], db: tx.db)[link] }
        guard version >= .v12Folders else {
            #expect(folders.isEmpty)
            #expect(linkCount == 1)
            return
        }
        #expect(folders.map(\.name) == ["Mobile App"])
        #expect(folders.first?.variableCount == 1)
        let folderID = try #require(FolderID(uuidString: seedFolderID))
        let destinations = try DestinationStore(database: database).fetchDestinations(repositoryID: repoID)
        guard version >= .v13Destinations else {
            #expect(destinations.isEmpty)
            #expect(try FolderStore(database: database).fetchItems(folderID: folderID).map(\.linkCount) == [2])
            #expect(linkCount == 2)
            return
        }
        #expect(destinations.map(\.target) == [.azureKeyVault(vaultName: "kv-sample-prod", tenantID: nil)])
        #expect(destinations.first?.stageKey == "production")
        #expect(destinations.first?.secretCount == 1)
        #expect(destinations.first?.pendingCount == 1)
        // v16 deleted the Vercel and Supabase rows and the token; their labels wait for the notice.
        #expect(try rowCount(database, "provider_connections") == 0)
        #expect(try rowCount(database, "destination_items") == 1)
        #expect(try rowCount(database, "destination_journal") == 0)
        #expect(try DestinationStore(database: database).fetchRetiredDestinationLabels()
            == (version < .v16DropRuntimeProviders ? seedRetiredLabels : []))
        #expect(try FolderStore(database: database).fetchItems(folderID: folderID).map(\.linkCount) == [3])
        #expect(linkCount == 3)
    }

    /// v15: the teammate and space tables are gone whatever they held (the seed puts teammates,
    /// addresses and a remote teammate in them); the v14 seed (a sent file, held rows) reads back.
    static func verifyProjectShareSeed(_ database: VaultDatabase, upTo version: Migration) throws {
        #expect(try tableNames(database).isDisjoint(with: droppedTables))
        let packageID = try #require(SharePackageID(uuidString: seedPackageID))
        let configHeld = try ConfigStore(database: database).fetchHeldItemStates()
        let destinationHeld = try DestinationStore(database: database).fetchHeldItemStates()
        let sent = try SentShareStore(database: database).fetchAll()
        guard version >= .v14ProjectShares else {
            #expect(configHeld.isEmpty && destinationHeld.isEmpty && sent.isEmpty)
            return
        }
        #expect(configHeld.map(\.id.uuidString) == [seedItemID])
        #expect(configHeld.first?.shareHold == packageID)
        #expect(destinationHeld.map(\.id.uuidString) == [seedDestinationItemID])
        #expect(destinationHeld.first?.shareHold == packageID)
        let share = try #require(sent.first)
        #expect(sent.count == 1)
        #expect(share.id.uuidString == seedSentShareID && share.packageID == packageID)
        // A 0.9 teammates row still reads back (the Sent list shows it), recipients unresolved.
        #expect(share.mode == .teammates && share.recipientIDs == [seedTeammateID])
        #expect(share.summary.stages == ["staging"])
        #expect(share.summary.places.first?.variableNames == ["API_URL"])
        let imported = try #require(try SharePackageStore(database: database).fetch(packageID))
        #expect(imported.senderDeviceID == seedTeammateID)
    }
}
