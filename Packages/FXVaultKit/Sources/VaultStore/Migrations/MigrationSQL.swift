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

    // MARK: v9_item_links (v0.4.1). FROZEN.

    /// Linked copies: every row pasted from another place shares its source's `link_id`
    /// (a lowercase UUID). NULL = not linked. The partial index serves the group lookups.
    static let v9ItemLinks = """
        ALTER TABLE config_items ADD COLUMN link_id TEXT CHECK (link_id IS NULL OR length(link_id) = 36);
        CREATE INDEX config_items_link ON config_items(link_id) WHERE link_id IS NOT NULL;
        """

    // MARK: v10_teammates (v0.5.0). FROZEN.

    /// This device's teammate keys (one row, sealed: signing seed, agreement key, announce key)
    /// and the paired devices: public keys in plaintext, each teammate's announce key sealed (it
    /// recognizes that teammate's pseudonyms), names as the teammate's Mac sent them.
    static let v10Teammates = """
        CREATE TABLE device_identity (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          device_id TEXT NOT NULL CHECK (length(device_id) = 32 AND device_id = lower(device_id)),
          secret_ct BLOB NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL);
        CREATE TABLE teammates (
          device_id TEXT PRIMARY KEY CHECK (length(device_id) = 32 AND device_id = lower(device_id)),
          signing_pk BLOB NOT NULL CHECK (length(signing_pk) = 32),
          agreement_pk BLOB NOT NULL CHECK (length(agreement_pk) = 32),
          announce_ct BLOB NOT NULL,
          login TEXT NOT NULL,
          display_name TEXT NOT NULL,
          mac_name TEXT NOT NULL,
          paired_at TEXT NOT NULL,
          last_seen_at TEXT,
          is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
          needs_card_update INTEGER NOT NULL DEFAULT 0 CHECK (needs_card_update IN (0, 1)));
        """

    // MARK: v11_spaces (v0.6.0). FROZEN.

    /// Shared spaces: one per scope, its verified log (each version's wire form: header,
    /// keyring, payload ciphertext under the space key, signature), the space keys per epoch
    /// (sealed), and remote addresses of teammates (Q4: off unless allowed).
    static let v11Spaces = """
        CREATE TABLE spaces (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
          environment_id TEXT REFERENCES environments(id) ON DELETE CASCADE,
          head_version INTEGER NOT NULL CHECK (head_version >= 1),
          head_hash BLOB NOT NULL CHECK (length(head_hash) = 32),
          epoch INTEGER NOT NULL CHECK (epoch >= 1),
          claimed_version INTEGER CHECK (claimed_version IS NULL OR claimed_version >= 1),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL);
        CREATE UNIQUE INDEX spaces_scope ON spaces(repository_id, COALESCE(environment_id, ''));
        CREATE TABLE space_keys (
          space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
          epoch INTEGER NOT NULL CHECK (epoch >= 1),
          key_ct BLOB NOT NULL,
          PRIMARY KEY (space_id, epoch));
        CREATE TABLE space_versions (
          space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
          version INTEGER NOT NULL CHECK (version >= 1),
          kind INTEGER NOT NULL CHECK (kind IN (1, 2, 3)),
          author_device_id TEXT NOT NULL CHECK (length(author_device_id) = 32 AND author_device_id = lower(author_device_id)),
          created_at TEXT NOT NULL,
          hash BLOB NOT NULL CHECK (length(hash) = 32),
          data BLOB NOT NULL,
          PRIMARY KEY (space_id, version));
        CREATE TABLE teammate_addresses (
          device_id TEXT PRIMARY KEY REFERENCES teammates(device_id) ON DELETE CASCADE,
          host TEXT CHECK (host IS NULL OR length(host) BETWEEN 1 AND 253),
          port INTEGER CHECK (port IS NULL OR port BETWEEN 1 AND 65535),
          allows_remote INTEGER NOT NULL DEFAULT 0 CHECK (allows_remote IN (0, 1)),
          last_connected_at TEXT,
          CHECK ((host IS NULL) = (port IS NULL)));
        """

    // MARK: v12_folders (v0.7.0). FROZEN.

    /// Folders of secrets and variables that belong to no repository: the folders (unique by
    /// fold key, in the user's order) and their items. A folder item always has a value
    /// (sealed with its own AAD) and may share a `link_id` group with repository items.
    static let v12Folders = """
        CREATE TABLE folders (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
          name_key TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL);
        CREATE UNIQUE INDEX folders_name_key ON folders(name_key);
        CREATE TABLE folder_items (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
          kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
          name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
          value_ct BLOB NOT NULL,
          value_fp BLOB NOT NULL,
          link_id TEXT CHECK (link_id IS NULL OR length(link_id) = 36),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL);
        CREATE UNIQUE INDEX folder_items_name ON folder_items(folder_id, kind, name);
        CREATE INDEX folder_items_link ON folder_items(link_id) WHERE link_id IS NOT NULL;
        """

    // MARK: v13_destinations (v0.8.0). FROZEN.

    /// Runtime destinations of repositories (tasks/todo.md R1–R5): the Supabase and Vercel tokens
    /// FX Vault keeps (sealed), the destinations (one remote place each, unique per repository),
    /// their items (values sealed with their own AAD; a write-only remote value is NULL) and the
    /// journal of destination writes. No GitHub sync path reads these tables.
    static let v13Destinations = """
        CREATE TABLE provider_connections (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          provider TEXT NOT NULL CHECK (provider IN ('supabase','vercel')),
          label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 64),
          token_ct BLOB NOT NULL,
          account_hint TEXT CHECK (account_hint IS NULL OR length(account_hint) BETWEEN 1 AND 255),
          last_validated_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL);
        CREATE TABLE destinations (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
          provider TEXT NOT NULL CHECK (provider IN ('azure_keyvault','supabase','vercel')),
          target_key TEXT NOT NULL CHECK (length(target_key) BETWEEN 1 AND 255),
          settings_json TEXT NOT NULL,
          stage TEXT CHECK (stage IS NULL OR length(stage) BETWEEN 1 AND 255),
          stage_key TEXT,
          connection_id TEXT REFERENCES provider_connections(id) ON DELETE SET NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          last_refreshed_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK ((stage IS NULL) = (stage_key IS NULL)));
        CREATE UNIQUE INDEX destinations_repo_target ON destinations(repository_id, target_key);
        CREATE TABLE destination_items (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          destination_id TEXT NOT NULL REFERENCES destinations(id) ON DELETE CASCADE,
          kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
          name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
          value_ct BLOB,
          value_fp BLOB,
          is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
          synced_name TEXT CHECK (synced_name IS NULL OR synced_name = upper(synced_name)),
          synced_kind TEXT CHECK (synced_kind IS NULL OR synced_kind IN ('secret','variable')),
          synced_fp BLOB,
          remote_ref TEXT,
          remote_version TEXT,
          force_push INTEGER NOT NULL DEFAULT 0 CHECK (force_push IN (0, 1)),
          verify_state TEXT NOT NULL DEFAULT 'verified' CHECK (verify_state IN ('verified','pending')),
          pre_write_version TEXT,
          is_public_allowed INTEGER NOT NULL DEFAULT 0 CHECK (is_public_allowed IN (0, 1)),
          link_id TEXT CHECK (link_id IS NULL OR length(link_id) = 36),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK (kind = 'secret' OR value_ct IS NOT NULL),
          CHECK ((value_ct IS NULL) = (value_fp IS NULL)),
          CHECK ((synced_name IS NULL) = (synced_kind IS NULL)),
          CHECK (is_deleted = 0 OR synced_name IS NOT NULL));
        CREATE UNIQUE INDEX destination_items_name ON destination_items(destination_id, name);
        CREATE INDEX destination_items_link ON destination_items(link_id) WHERE link_id IS NOT NULL;
        CREATE TABLE destination_journal (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          run_id TEXT NOT NULL,
          destination_id TEXT REFERENCES destinations(id) ON DELETE SET NULL,
          item_id TEXT,
          op TEXT NOT NULL CHECK (op IN ('set','delete','recover')),
          item_name TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('in_flight','succeeded','failed','indeterminate','reconciled')),
          error_code TEXT,
          pre_write_version TEXT,
          pushed_fp BLOB,
          started_at TEXT NOT NULL,
          finished_at TEXT);
        CREATE INDEX destination_journal_time ON destination_journal(started_at);
        """

    // MARK: v14_project_shares (v0.9.0). FROZEN.

    /// Project share files (tasks/todo.md P3–P8): the files this Mac wrote (names only, never
    /// values), the package id an imported row is held under until Sync's From Files review
    /// releases it, the teammate who sealed an imported file (`sender_device_id`, NULL for a
    /// passphrase file: its sender is unverified), and remote pairing. `teammates` is rebuilt so `announce_ct` may be NULL: a
    /// teammate paired remotely as the inviter is stored before its announce key arrives. The
    /// rebuild runs with foreign keys off (GRDB's deferred checks), so `teammate_addresses` rows
    /// survive the drop; every row of the old table is copied unchanged and is `nearby`.
    static let v14ProjectShares = """
        CREATE TABLE sent_shares (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          package_id TEXT NOT NULL CHECK (length(package_id) = 36),
          created_at TEXT NOT NULL,
          expires_at TEXT NOT NULL,
          mode TEXT NOT NULL CHECK (mode IN ('passphrase','teammates')),
          recipients TEXT NOT NULL,
          summary TEXT NOT NULL,
          CHECK (expires_at > created_at));
        CREATE INDEX sent_shares_time ON sent_shares(created_at);
        ALTER TABLE config_items ADD COLUMN share_hold TEXT
          CHECK (share_hold IS NULL OR (length(share_hold) = 36 AND share_hold = lower(share_hold)));
        CREATE INDEX config_items_share_hold ON config_items(share_hold) WHERE share_hold IS NOT NULL;
        ALTER TABLE destination_items ADD COLUMN share_hold TEXT
          CHECK (share_hold IS NULL OR (length(share_hold) = 36 AND share_hold = lower(share_hold)));
        CREATE INDEX destination_items_share_hold ON destination_items(share_hold) WHERE share_hold IS NOT NULL;
        ALTER TABLE imported_share_packages ADD COLUMN sender_device_id TEXT
          CHECK (sender_device_id IS NULL OR (length(sender_device_id) = 32 AND sender_device_id = lower(sender_device_id)));
        CREATE TABLE teammates_v14 (
          device_id TEXT PRIMARY KEY CHECK (length(device_id) = 32 AND device_id = lower(device_id)),
          signing_pk BLOB NOT NULL CHECK (length(signing_pk) = 32),
          agreement_pk BLOB NOT NULL CHECK (length(agreement_pk) = 32),
          announce_ct BLOB,
          login TEXT NOT NULL,
          display_name TEXT NOT NULL,
          mac_name TEXT NOT NULL,
          paired_at TEXT NOT NULL,
          last_seen_at TEXT,
          is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
          needs_card_update INTEGER NOT NULL DEFAULT 0 CHECK (needs_card_update IN (0, 1)),
          paired_via TEXT NOT NULL DEFAULT 'nearby' CHECK (paired_via IN ('nearby','remote')),
          CHECK (announce_ct IS NOT NULL OR paired_via = 'remote'));
        INSERT INTO teammates_v14 (device_id, signing_pk, agreement_pk, announce_ct, login, display_name,
            mac_name, paired_at, last_seen_at, is_muted, needs_card_update)
          SELECT device_id, signing_pk, agreement_pk, announce_ct, login, display_name,
            mac_name, paired_at, last_seen_at, is_muted, needs_card_update
          FROM teammates;
        DROP TABLE teammates;
        ALTER TABLE teammates_v14 RENAME TO teammates;
        """

    /// v15 (1.0): drops the teammate and shared-space tables. 1.0 removes nearby pairing,
    /// presence and spaces, so these rows (this Mac's teammate keys, paired devices, space keys
    /// and versions) are never read again; keeping them would leave key material behind.
    static let v15DropTeammates = """
        DROP TABLE teammate_addresses;
        DROP TABLE space_versions;
        DROP TABLE space_keys;
        DROP TABLE spaces;
        DROP TABLE teammates;
        DROP TABLE device_identity;
        """

    /// v16 (1.0): deletes the Supabase and Vercel destinations, their items and journal, and every
    /// provider connection token. 1.0 keeps Key Vault only; nothing is deleted remotely. Their
    /// labels stay in `retired_destinations` for one notice after unlock. Items and journal are
    /// deleted explicitly: migrations run with foreign keys off, so no cascade fires. The emptied
    /// `provider_connections` table stays because `destinations.connection_id` references it.
    static let v16DropRuntimeProviders = """
        CREATE TABLE retired_destinations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 1024));
        INSERT INTO retired_destinations (label)
          SELECT r.owner_login || '/' || r.name || ' · ' || CASE d.provider
              WHEN 'supabase' THEN 'Supabase ' || coalesce(json_extract(d.settings_json, '$.projectRef'), '?')
              ELSE 'Vercel ' || coalesce(json_extract(d.settings_json, '$.projectName'), '?')
                || ' (' || coalesce(json_extract(d.settings_json, '$.environment'), '?') || ')'
            END
          FROM destinations d JOIN repositories r ON r.id = d.repository_id
          WHERE d.provider IN ('supabase','vercel')
          ORDER BY r.owner_login, r.name, d.sort_order, d.created_at;
        DELETE FROM destination_journal
          WHERE destination_id IN (SELECT id FROM destinations WHERE provider IN ('supabase','vercel'));
        DELETE FROM destination_items
          WHERE destination_id IN (SELECT id FROM destinations WHERE provider IN ('supabase','vercel'));
        DELETE FROM destinations WHERE provider IN ('supabase','vercel');
        UPDATE destinations SET connection_id = NULL WHERE connection_id IS NOT NULL;
        DELETE FROM provider_connections;
        """

    // MARK: v17_organizations (1.0, tasks/todo.md B5). Additive: nothing existing changes.

    /// Organizations and their secrets and variables. `org_items` mirrors `config_items` for one
    /// organization: secrets may have no value (GitHub never returns it), variables always do;
    /// `synced_fp` is the fingerprint of the value last read from GitHub.
    static let v17Organizations = """
        CREATE TABLE organizations (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          login TEXT NOT NULL CHECK (length(login) BETWEEN 1 AND 39),
          login_key TEXT NOT NULL UNIQUE CHECK (login_key = lower(login_key)),
          account_login TEXT NOT NULL CHECK (length(account_login) BETWEEN 1 AND 255),
          last_refreshed_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL);
        CREATE TABLE org_items (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
          kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
          name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
          value_ct BLOB,
          value_fp BLOB,
          visibility TEXT NOT NULL CHECK (visibility IN ('all','private','selected')),
          selected_count INTEGER CHECK (selected_count IS NULL OR selected_count >= 0),
          synced_fp BLOB,
          remote_updated_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK (kind = 'secret' OR value_ct IS NOT NULL),
          CHECK ((value_ct IS NULL) = (value_fp IS NULL)));
        CREATE UNIQUE INDEX org_items_name ON org_items(organization_id, kind, name);
        """

    // MARK: v19_org_item_changes (1.0, tasks/todo.md B6b). Additive.

    /// Local changes to organization items, sent by Sync: a tombstone (`is_deleted`), the
    /// visibility last synced (NULL: never synced, an add; imported rows get theirs), and the
    /// repository list to send when the user edited it (`repositories_edited`; otherwise Sync
    /// reads GitHub's list before a write, so it always sends the complete list).
    static let v19OrgItemChanges = """
        ALTER TABLE org_items ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1));
        ALTER TABLE org_items ADD COLUMN synced_visibility TEXT
          CHECK (synced_visibility IS NULL OR synced_visibility IN ('all','private','selected'));
        ALTER TABLE org_items ADD COLUMN repositories_edited INTEGER NOT NULL DEFAULT 0 CHECK (repositories_edited IN (0, 1));
        UPDATE org_items SET synced_visibility = visibility;
        CREATE TABLE org_item_repositories (
          item_id TEXT NOT NULL REFERENCES org_items(id) ON DELETE CASCADE,
          name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
          PRIMARY KEY (item_id, name)) WITHOUT ROWID;
        """

    // MARK: v18_standalone_key_vaults (1.0, tasks/todo.md B8b)

    /// A Key Vault is a source of its own (1.0 brief): `destinations.repository_id` becomes
    /// optional, and a vault without a repository is unique by `target_key`. SQLite cannot drop a
    /// NOT NULL, so the table is rebuilt; migrations run with foreign keys off, so the items and
    /// journal rows keep pointing at the same ids and nothing cascades.
    static let v18StandaloneKeyVaults = """
        CREATE TABLE destinations_v18 (
          id TEXT PRIMARY KEY CHECK (length(id) = 36),
          repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE,
          provider TEXT NOT NULL CHECK (provider IN ('azure_keyvault','supabase','vercel')),
          target_key TEXT NOT NULL CHECK (length(target_key) BETWEEN 1 AND 255),
          settings_json TEXT NOT NULL,
          stage TEXT CHECK (stage IS NULL OR length(stage) BETWEEN 1 AND 255),
          stage_key TEXT,
          connection_id TEXT REFERENCES provider_connections(id) ON DELETE SET NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          last_refreshed_at TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK ((stage IS NULL) = (stage_key IS NULL)),
          CHECK (repository_id IS NOT NULL OR provider = 'azure_keyvault'));
        INSERT INTO destinations_v18 SELECT id, repository_id, provider, target_key, settings_json, stage, stage_key,
          connection_id, sort_order, last_refreshed_at, created_at, updated_at FROM destinations;
        DROP TABLE destinations;
        ALTER TABLE destinations_v18 RENAME TO destinations;
        CREATE UNIQUE INDEX destinations_repo_target ON destinations(repository_id, target_key);
        CREATE UNIQUE INDEX destinations_standalone_target ON destinations(target_key) WHERE repository_id IS NULL;
        """

    // MARK: v20_key_vault_subscriptions (1.0, tasks/todo.md D6c6). Additive.

    /// The Azure subscription of a Key Vault of its own, saved when Connect Azure imports it or
    /// a Refresh finds it, so the sidebar groups Azure › subscription › vault without an `az`
    /// call at launch. NULL until then: the vault shows directly under Azure.
    static let v20KeyVaultSubscriptions = """
        ALTER TABLE destinations ADD COLUMN subscription_id TEXT
          CHECK (subscription_id IS NULL OR length(subscription_id) = 36);
        ALTER TABLE destinations ADD COLUMN subscription_name TEXT
          CHECK (subscription_name IS NULL OR length(subscription_name) BETWEEN 1 AND 255);
        """
}
