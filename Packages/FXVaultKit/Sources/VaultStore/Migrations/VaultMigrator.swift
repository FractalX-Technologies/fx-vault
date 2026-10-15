import GRDB

/// The vault schema migrations (tasks/todo.md §6 Migrations).
///
/// **A migration is frozen once any build has run it.** Never edit the SQL of a registered
/// migration: every change goes into a new migration appended to ``Migration``.
/// `eraseDatabaseOnSchemaChange` is never used.
public enum VaultMigrator {
    /// Every migration, in the order it runs. Raw values are GRDB's migration identifiers and
    /// must never change.
    public enum Migration: String, Sendable, Hashable, CaseIterable, Comparable {
        case v1Vault = "v1_vault"
        case v2AccountsRepos = "v2_accounts_repos"
        case v3Config = "v3_config"
        case v4SyncJournal = "v4_sync_journal"
        case v5CreatePolicies = "v5_create_policies"
        case v6Sharing = "v6_sharing"
        case v7JournalFingerprints = "v7_journal_fingerprints"
        case v8ForcePushRequestedAt = "v8_force_push_requested_at"

        /// The newest migration this build knows.
        public static var latest: Migration {
            allCases[allCases.index(before: allCases.endIndex)]
        }

        public static func < (lhs: Migration, rhs: Migration) -> Bool {
            order(of: lhs) < order(of: rhs)
        }

        private static func order(of migration: Migration) -> Int {
            allCases.firstIndex(of: migration) ?? allCases.endIndex
        }

        /// The frozen SQL of this migration.
        var sql: String {
            switch self {
            case .v1Vault: MigrationSQL.v1Vault
            case .v2AccountsRepos: MigrationSQL.v2AccountsRepos
            case .v3Config: MigrationSQL.v3Config
            case .v4SyncJournal: MigrationSQL.v4SyncJournal
            case .v5CreatePolicies: MigrationSQL.v5CreatePolicies
            case .v6Sharing: MigrationSQL.v6Sharing
            case .v7JournalFingerprints: MigrationSQL.v7JournalFingerprints
            case .v8ForcePushRequestedAt: MigrationSQL.v8ForcePushRequestedAt
            }
        }
    }

    /// Applies every pending migration, or only those up to and including `target`.
    ///
    /// Throws ``StoreError/schemaNewerThanBuild`` without changing anything when the database was
    /// migrated by a newer build (it holds a migration this build does not know).
    public static func migrate(_ database: VaultDatabase, upTo target: Migration = .latest) throws {
        let migrator = makeMigrator()
        try VaultDatabase.translatingErrors {
            let isSuperseded = try database.writer.read { db in
                try migrator.hasBeenSuperseded(db)
            }
            guard !isSuperseded else {
                throw StoreError.schemaNewerThanBuild
            }
            try migrator.migrate(database.writer, upTo: target.rawValue)
        }
    }

    /// The migrations already applied to `database`, in order.
    public static func appliedMigrations(_ database: VaultDatabase) throws -> [Migration] {
        let migrator = makeMigrator()
        let identifiers = try database.read { tx in
            try migrator.appliedIdentifiers(tx.db)
        }
        return Migration.allCases.filter { identifiers.contains($0.rawValue) }
    }

    /// True when every migration this build knows has been applied.
    public static func isUpToDate(_ database: VaultDatabase) throws -> Bool {
        try appliedMigrations(database) == Migration.allCases
    }

    /// GRDB's migrator with every migration registered in order.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for migration in Migration.allCases {
            let sql = migration.sql
            migrator.registerMigration(migration.rawValue) { db in
                try db.execute(sql: sql)
            }
        }
        return migrator
    }
}
