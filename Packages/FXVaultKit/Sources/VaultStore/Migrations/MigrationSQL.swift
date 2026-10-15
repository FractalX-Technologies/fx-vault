/// The frozen SQL of each migration, from tasks/todo.md §6.
///
/// One deliberate difference from the §6 text: the `key_wraps` table CHECK adds
/// `salt IS NOT NULL`. In SQL, `length(NULL) = 16` is NULL and a NULL CHECK passes, so §6 as
/// written accepted an Argon2id wrap with no salt (MigrationTests/ConstraintTests cover it).
/// A second addition (made before any build ran v6): `config_items.provenance` gets
/// `CHECK (provenance IN ('local','github','share'))`, so the database rejects unknown values
/// instead of relying on Swift decoding alone (ConstraintTests.provenanceIsAnEnum).
/// SQL comments from §6 are omitted; the column meanings are documented on the records.
///
/// FROZEN: once any build has run a migration, its text below must never change (not even
/// whitespace that alters `sqlite_master`). Schema changes go into a new migration appended to
/// ``VaultMigrator/Migration``.
enum MigrationSQL {
    // MARK: v1_vault (M1). FROZEN.

    static let v1Vault = """
        CREATE TABLE vaults (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          vault_id BLOB NOT NULL CHECK (length(vault_id) = 16),
          format_version INTEGER NOT NULL DEFAULT 1,
          dek_version INTEGER NOT NULL DEFAULT 1,
          kcv BLOB NOT NULL CHECK (length(kcv) = 16),
          biometry_state_hash BLOB,
          last_password_unlock_at TEXT, last_password_boot_session TEXT,
          created_at TEXT NOT NULL);
        CREATE TABLE key_wraps (
          method TEXT PRIMARY KEY CHECK (method IN ('password','recovery')),
          kdf_alg INTEGER NOT NULL CHECK (kdf_alg IN (1,2)),
          ops_limit INTEGER, mem_limit_bytes INTEGER, salt BLOB,
          wrapped_dek BLOB NOT NULL CHECK (length(wrapped_dek) = 62),
          dek_version INTEGER NOT NULL, updated_at TEXT NOT NULL,
          CHECK (kdf_alg = 2 OR (ops_limit IS NOT NULL AND mem_limit_bytes IS NOT NULL AND salt IS NOT NULL AND length(salt) = 16)));
        """

    // MARK: v2_accounts_repos (M2). FROZEN.

    static let v2AccountsRepos = """
        CREATE TABLE accounts (
          login TEXT PRIMARY KEY COLLATE NOCASE,
          host TEXT NOT NULL DEFAULT 'github.com' CHECK (host = 'github.com'),
          ssh_host_alias TEXT, ssh_verified_login TEXT, ssh_verified_at TEXT,
          is_present INTEGER NOT NULL DEFAULT 1,
          last_seen_at TEXT NOT NULL);
        CREATE TABLE repositories (
          id TEXT PRIMARY KEY,
          account_login TEXT NOT NULL REFERENCES accounts(login) ON UPDATE CASCADE,
          github_id TEXT UNIQUE,
          owner_login TEXT NOT NULL, owner_type TEXT NOT NULL CHECK (owner_type IN ('User','Organization')),
          name TEXT NOT NULL, description TEXT,
          is_private INTEGER NOT NULL, is_archived INTEGER NOT NULL DEFAULT 0, is_fork INTEGER NOT NULL DEFAULT 0,
          default_branch TEXT,
          has_admin INTEGER NOT NULL DEFAULT 0, has_push INTEGER NOT NULL DEFAULT 0,
          origin TEXT NOT NULL CHECK (origin IN ('imported','created')),
          is_env_plan_gated INTEGER NOT NULL DEFAULT 0,
          is_unavailable INTEGER NOT NULL DEFAULT 0,
          imported_at TEXT NOT NULL, last_refreshed_at TEXT, created_at_github TEXT);
        CREATE UNIQUE INDEX repositories_owner_name ON repositories(owner_login COLLATE NOCASE, name COLLATE NOCASE);
        """

    // MARK: v3_config (M2). FROZEN.

    static let v3Config = """
        CREATE TABLE environments (
          id TEXT PRIMARY KEY,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
          name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 255), name_key TEXT NOT NULL,
          synced_name TEXT, synced_name_key TEXT,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          branch_policy TEXT NOT NULL DEFAULT 'all' CHECK (branch_policy IN ('all','protected','custom')),
          synced_branch_policy TEXT CHECK (synced_branch_policy IN ('all','protected','custom')),
          foreign_rules_json TEXT,
          github_env_id INTEGER,
          remote_updated_at TEXT,
          sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE UNIQUE INDEX environments_repo_name ON environments(repository_id, name_key);

        CREATE TABLE config_items (
          id TEXT PRIMARY KEY,
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
          environment_id TEXT REFERENCES environments(id) ON DELETE CASCADE,
          kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
          name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
          value_ct BLOB, value_fp BLOB,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          synced_name TEXT,
          synced_value_ct BLOB, synced_fp BLOB,
          force_push INTEGER NOT NULL DEFAULT 0,
          remote_updated_at TEXT,
          verify_state TEXT NOT NULL DEFAULT 'verified' CHECK (verify_state IN ('verified','pending')),
          pre_write_updated_at TEXT,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          CHECK (kind = 'secret' OR value_ct IS NOT NULL),
          CHECK ((value_ct IS NULL) = (value_fp IS NULL)));
        CREATE UNIQUE INDEX config_items_scope_name ON config_items(repository_id, COALESCE(environment_id, ''), kind, name);
        """

    // MARK: v4_sync_journal (M3). FROZEN.

    static let v4SyncJournal = """
        CREATE TABLE sync_journal (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          run_id TEXT NOT NULL,
          account_login TEXT NOT NULL,
          repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
          op TEXT NOT NULL,
          command TEXT NOT NULL,
          is_write INTEGER NOT NULL,
          scope_label TEXT NOT NULL, target_key TEXT NOT NULL, item_name TEXT,
          state TEXT NOT NULL CHECK (state IN ('in_flight','succeeded','failed','skipped','indeterminate','reconciled')),
          exit_code INTEGER, error_code TEXT,
          started_at TEXT NOT NULL, pre_write_updated_at TEXT, finished_at TEXT);
        CREATE INDEX sync_journal_account_time ON sync_journal(account_login, started_at);
        """

    // MARK: v5_create_policies (M4). FROZEN.

    static let v5CreatePolicies = """
        ALTER TABLE repositories ADD COLUMN create_spec_json TEXT;
        ALTER TABLE repositories ADD COLUMN clone_path TEXT;
        CREATE TABLE deployment_branch_patterns (
          id TEXT PRIMARY KEY,
          environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
          pattern TEXT NOT NULL CHECK (length(pattern) BETWEEN 1 AND 255),
          type TEXT NOT NULL CHECK (type IN ('branch','tag')),
          github_policy_id INTEGER,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          UNIQUE (environment_id, pattern, type));
        """

    // MARK: v6_sharing (M6). FROZEN.

    static let v6Sharing = """
        ALTER TABLE config_items ADD COLUMN provenance TEXT NOT NULL DEFAULT 'local'
          CHECK (provenance IN ('local','github','share'));
        ALTER TABLE config_items ADD COLUMN provenance_detail TEXT;
        CREATE TABLE imported_share_packages (
          package_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, imported_at TEXT NOT NULL, sender_name TEXT);
        """

    // MARK: v7_journal_fingerprints (v0.1.0). FROZEN.

    /// The row-bound fingerprints of a set row's push (never values), so launch reconciliation
    /// records what was actually sent instead of the value as it is now.
    static let v7JournalFingerprints = """
        ALTER TABLE sync_journal ADD COLUMN source_fp BLOB;
        ALTER TABLE sync_journal ADD COLUMN pushed_fp BLOB;
        ALTER TABLE sync_journal ADD COLUMN did_normalize_value INTEGER CHECK (did_normalize_value IN (0, 1));
        """

    // MARK: v8_force_push_requested_at (v0.1.2). FROZEN.

    /// When the user asked for a secret's push (Fill without "Already matches GitHub", or Push
    /// on Next Sync). D27 lets that push replace a GitHub change made up to this instant.
    static let v8ForcePushRequestedAt = """
        ALTER TABLE config_items ADD COLUMN force_push_requested_at TEXT;
        """
}
