# FX Vault - Local database

The vault is one SQLite database managed by GRDB 7.11.1, inside the `VaultStore` module
(`Packages/FXVaultKit/Sources/VaultStore`). Only VaultStore imports GRDB (`scripts/lint.sh`
enforces it); every other module uses the opaque `VaultDatabase` and the stores.

The database holds **no plaintext values**. Secret and variable values are stored only as
AES-256-GCM blobs (`value_ct`, `synced_value_ct`) encrypted by VaultCrypto with the field AAD
(docs/ARCHITECTURE.md, "VaultCrypto"), next to HMAC-SHA256 fingerprints (`value_fp`,
`synced_fp`). Names, timestamps, GitHub ids and vault names are plaintext.

## Storage

| Item | Value |
|---|---|
| Release path | `~/Library/Application Support/FX Vault/vault.sqlite` (+ `-wal`, `-shm`) |
| Debug path | `~/Library/Application Support/FX Vault Dev/vault.sqlite` |
| Directory | Created with mode 0700; an existing directory is forced back to 0700; a symlink or plain file is refused (`StoreError.insecureDirectory`) |
| Files | Mode 0600 |
| Connection | `DatabasePool` (WAL) on disk; `DatabaseQueue` in memory (`DatabaseFactory.inMemory()`, tests and previews) |
| Every connection | `PRAGMA secure_delete = ON` (opening fails unless it reads back 1) and `PRAGMA foreign_keys = ON` |
| Checkpoint | `VaultDatabase.checkpointTruncate()` runs `wal_checkpoint(TRUNCATE)` after every key write (the `VaultRecordStore` convenience methods do it themselves) and on lock, so old wrapped keys do not linger in the WAL |

## Formats

- **Timestamps** are ISO-8601 UTC TEXT with millisecond precision, e.g. `2001-01-01T00:00:01.250Z`
  (`DatabaseTimestamp`). Every value has the same width, so text comparison orders them.
- **UUIDs** are lowercase TEXT (`Identifier.uuidString`); the AAD uses the raw 16 bytes.
- **Fold keys** (`environments.name_key`, `synced_name_key`) are
  `EnvironmentNameValidator.foldKey(name)`: NFC, then Swift `lowercased()`, then NFC. They are
  recomputed by `EnvironmentRecord` whenever the name changes and cannot be set directly. SQLite
  `NOCASE` is used only for ASCII GitHub logins and repository names.
- **Booleans** are INTEGER 0/1. **Enums** are TEXT with CHECK constraints whose values match
  the VaultCore raw values.

## Migrations

`VaultMigrator` runs GRDB's `DatabaseMigrator` with the ids below, in order. A migration is
**frozen** once any build has run it; schema changes always go into a new migration appended to
`VaultMigrator.Migration`. `eraseDatabaseOnSchemaChange` is never used. Opening a file written
by a newer build throws `StoreError.schemaNewerThanBuild`.

Migration ids are shared by every branch. "Newer" means the file lists any id this build does
not know (GRDB's `hasBeenSuperseded`), so a branch that lacks one of main's ids cannot open a
vault main has migrated, even if it adds its own migration with the same number. Merge main's
migrations into a branch before that branch adds a migration or builds a release. Debug builds
of every branch and worktree share the `FX Vault Dev` vault, so the first Debug run of a build
with a new migration locks older branches' Debug builds out of it.

`MigrationTests.stepByStepFrom` migrates up to each version, inserts rows valid at that version,
migrates the rest of the way, and checks that the schema equals a fresh database's and that the
rows still read back.

Two deliberate differences from plan §6, both made before any build ran the migration:
- `key_wraps` CHECK adds `salt IS NOT NULL`: `length(NULL) = 16` is NULL and a NULL CHECK
  passes, so the plan's text accepted an Argon2id wrap without a salt.
- `config_items.provenance` gets `CHECK (provenance IN ('local','github','share'))`.

### v1_vault (M1)

```sql
CREATE TABLE vaults (                         -- single row
  id INTEGER PRIMARY KEY CHECK (id = 1),
  vault_id BLOB NOT NULL CHECK (length(vault_id) = 16),
  format_version INTEGER NOT NULL DEFAULT 1,
  dek_version INTEGER NOT NULL DEFAULT 1,
  kcv BLOB NOT NULL CHECK (length(kcv) = 16),   -- key check value of the current DEK
  biometry_state_hash BLOB,                     -- LAContext domain state at Touch ID enrolment
  last_password_unlock_at TEXT, last_password_boot_session TEXT,
  created_at TEXT NOT NULL);
CREATE TABLE key_wraps (
  method TEXT PRIMARY KEY CHECK (method IN ('password','recovery')),
  kdf_alg INTEGER NOT NULL CHECK (kdf_alg IN (1,2)),   -- 1 argon2id13, 2 hkdf-sha256
  ops_limit INTEGER, mem_limit_bytes INTEGER, salt BLOB,
  wrapped_dek BLOB NOT NULL CHECK (length(wrapped_dek) = 62),
  dek_version INTEGER NOT NULL, updated_at TEXT NOT NULL,
  CHECK (kdf_alg = 2 OR (ops_limit IS NOT NULL AND mem_limit_bytes IS NOT NULL
                         AND salt IS NOT NULL AND length(salt) = 16)));
```

`wrapped_dek` layout (62 bytes): format (1) ‖ aead (1) ‖ nonce (12) ‖ ciphertext (32) ‖ tag (16).
Stored KDF parameters are checked against `KDFBounds` before Argon2id runs.

### v2_accounts_repos (M2)

```sql
CREATE TABLE accounts (
  login TEXT PRIMARY KEY COLLATE NOCASE,           -- GitHub logins are ASCII
  host TEXT NOT NULL DEFAULT 'github.com' CHECK (host = 'github.com'),
  ssh_host_alias TEXT, ssh_verified_login TEXT, ssh_verified_at TEXT,
  is_present INTEGER NOT NULL DEFAULT 1,           -- still listed by gh auth status
  last_seen_at TEXT NOT NULL);
CREATE TABLE repositories (
  id TEXT PRIMARY KEY,
  account_login TEXT NOT NULL REFERENCES accounts(login) ON UPDATE CASCADE,
  github_id TEXT UNIQUE,                           -- gh --json `id` (GraphQL node id); NULL until created
  owner_login TEXT NOT NULL, owner_type TEXT NOT NULL CHECK (owner_type IN ('User','Organization')),
  name TEXT NOT NULL, description TEXT,
  is_private INTEGER NOT NULL, is_archived INTEGER NOT NULL DEFAULT 0, is_fork INTEGER NOT NULL DEFAULT 0,
  default_branch TEXT,
  has_admin INTEGER NOT NULL DEFAULT 0, has_push INTEGER NOT NULL DEFAULT 0,
  origin TEXT NOT NULL CHECK (origin IN ('imported','created')),
  is_env_plan_gated INTEGER NOT NULL DEFAULT 0,
  is_unavailable INTEGER NOT NULL DEFAULT 0,       -- e.g. SAML not authorized, no longer listed
  imported_at TEXT NOT NULL, last_refreshed_at TEXT, created_at_github TEXT);
CREATE UNIQUE INDEX repositories_owner_name
  ON repositories(owner_login COLLATE NOCASE, name COLLATE NOCASE);
```

`RepoVisibility.internal` is stored as `is_private = 1` and reads back as `.private`. A
case-only change to an account login does not cascade, because the column is NOCASE; the child
row still matches its parent.

### v3_config (M2)

```sql
CREATE TABLE environments (
  id TEXT PRIMARY KEY,
  repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 255), name_key TEXT NOT NULL,
  synced_name TEXT, synced_name_key TEXT,          -- NULL = never synced
  is_deleted INTEGER NOT NULL DEFAULT 0,           -- tombstone, only with synced_name
  branch_policy TEXT NOT NULL DEFAULT 'all' CHECK (branch_policy IN ('all','protected','custom')),
  synced_branch_policy TEXT CHECK (synced_branch_policy IN ('all','protected','custom')),
  foreign_rules_json TEXT,                         -- reviewers, wait timer, ... (read-only)
  github_env_id INTEGER,
  remote_updated_at TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX environments_repo_name ON environments(repository_id, name_key);

CREATE TABLE config_items (
  id TEXT PRIMARY KEY,
  repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  environment_id TEXT REFERENCES environments(id) ON DELETE CASCADE,  -- NULL = repository level; immutable once synced
  kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),          -- immutable once synced
  name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
  value_ct BLOB, value_fp BLOB,                    -- value_ct NULL = secret value missing locally
  is_deleted INTEGER NOT NULL DEFAULT 0,
  synced_name TEXT,                                -- NULL = never pushed (pending add)
  synced_value_ct BLOB, synced_fp BLOB,
  force_push INTEGER NOT NULL DEFAULT 0,           -- re-send on next Sync (Push on Next Sync, a pushing fill, "Keep local")
  remote_updated_at TEXT,
  verify_state TEXT NOT NULL DEFAULT 'verified' CHECK (verify_state IN ('verified','pending')),
  pre_write_updated_at TEXT,                       -- verification baseline
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK (kind = 'secret' OR value_ct IS NOT NULL),
  CHECK ((value_ct IS NULL) = (value_fp IS NULL)));
CREATE UNIQUE INDEX config_items_scope_name
  ON config_items(repository_id, COALESCE(environment_id, ''), kind, name);
```

Beyond the schema, `ConfigStore` throws `StoreError.scopeMismatch` when an item or pattern
names another repository's environment, and `StoreError.immutableAfterSync` when a synced item
would change repository, environment or kind (D11).

### v4_sync_journal (M3)

```sql
CREATE TABLE sync_journal (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  account_login TEXT NOT NULL,
  repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
  op TEXT NOT NULL,                                -- change kind
  command TEXT NOT NULL,                           -- gh command id (secret.set, api.env.put, ...)
  is_write INTEGER NOT NULL,
  scope_label TEXT NOT NULL, target_key TEXT NOT NULL, item_name TEXT,   -- names only, never values
  state TEXT NOT NULL CHECK (state IN ('in_flight','succeeded','failed','skipped','indeterminate','reconciled')),
  exit_code INTEGER, error_code TEXT,              -- GHError.logCode
  started_at TEXT NOT NULL, pre_write_updated_at TEXT, finished_at TEXT);
CREATE INDEX sync_journal_account_time ON sync_journal(account_login, started_at);
```

- An `in_flight` row is appended before each gh write; its outcome and the item bookkeeping are
  committed together in one transaction afterwards (`SyncPersisting.commit`, implemented by
  VaultData's `VaultSyncPersistence`).
- Column values (SyncEngine owns them):

  | Column | Values |
  |---|---|
  | `op` | `ConfigChangeKind` raw value: `create_repository`, `upsert_environment`, `rename_environment`, `reconcile_branch_patterns`, `delete_environment`, `set_variable`, `set_secret`, `delete_variable`, `delete_secret` |
  | `command` | `SyncJournalCommand` raw value: `repo.create`, `repo.view`, `api.env.put`, `api.env.delete`, `api.policy.post`, `api.policy.delete`, `secret.set`, `secret.delete`, `variable.set`, `variable.delete` |
  | `scope_label` | `repository`, or the environment's remote name |
  | `target_key` | `ChangeTargetModel.journalKey`: `repo`, `env\|<foldkey>`, `item\|<kind>\|<NAME>\|repo`, `item\|<kind>\|<NAME>\|env\|<foldkey>` |
  | `error_code` | `GHError.logCode`, or `remoteChanged`, `createConflict`, `notConfirmed`, `renameTargetIsSource` (`SyncExecutionConstants`) |

- The preflight B2 lookup before creating a repository (`repo.view`) is journaled as a **read**
  row (`is_write = 0`): launch reconciliation adopts a timed-out create only when the journal
  shows that lookup ("name is free") followed by the create attempt.
- Drift review hides our own recent deletions: `fetchSucceeded(repositoryID:commands:since:)`
  with the deletion commands, whose `target_key`s feed `DriftSuppressionModel`.
- Pending-verification miss counts (`Limits.pendingVerifyChecks`) are **not** stored; they live
  in memory (`DriftRepository`) and restart after a relaunch.
- Retention (`pruneExpired(now:)`): rows older than `Timeouts.syncJournalRetention` (24 h) are
  deleted, **except** the latest run (highest row id, so wall-clock jumps cannot change it) and
  every `in_flight` row (launch reconciliation must still find them).
- Throttle seeding (`writeStartTimes(accountLogin:since:)`): rows with `is_write = 1`,
  login matched ignoring case, `skipped` rows excluded, `in_flight` rows counted.

### v5_create_policies (M4)

```sql
ALTER TABLE repositories ADD COLUMN create_spec_json TEXT;   -- {auto_init, gitignore_template, license_template, clone_after}
ALTER TABLE repositories ADD COLUMN clone_path TEXT;
CREATE TABLE deployment_branch_patterns (
  id TEXT PRIMARY KEY,
  environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  pattern TEXT NOT NULL CHECK (length(pattern) BETWEEN 1 AND 255),
  type TEXT NOT NULL CHECK (type IN ('branch','tag')),
  github_policy_id INTEGER,                        -- reset to NULL when the policy leaves 'custom'
  is_deleted INTEGER NOT NULL DEFAULT 0,
  UNIQUE (environment_id, pattern, type));
```

### v6_sharing (M6)

```sql
ALTER TABLE config_items ADD COLUMN provenance TEXT NOT NULL DEFAULT 'local'
  CHECK (provenance IN ('local','github','share'));
ALTER TABLE config_items ADD COLUMN provenance_detail TEXT;  -- JSON: share packageId + unverified sender name
CREATE TABLE imported_share_packages (
  package_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, imported_at TEXT NOT NULL, sender_name TEXT);
```

`imported_share_packages` drives replay detection (`ShareReplayWarning.alreadyImported`).

### v7_journal_fingerprints (v0.1.0)

```sql
ALTER TABLE sync_journal ADD COLUMN source_fp BLOB;   -- value_fp of the value the push read
ALTER TABLE sync_journal ADD COLUMN pushed_fp BLOB;   -- fingerprint of the bytes gh received (D32)
ALTER TABLE sync_journal ADD COLUMN did_normalize_value INTEGER CHECK (did_normalize_value IN (0, 1));
```

- Set on `secret.set` / `variable.set` rows only (`SyncJournalPushModel`); NULL for every other
  command and for rows written before v7. They are row-bound HMAC fingerprints (§5.4), never
  values.
- Launch reconciliation builds a confirmed secret push from these columns, not from the value as
  it is at reconcile time, so a value edited after an indeterminate push stays pending. A
  secret row without them is closed as `failed` (`notConfirmed`).
- A DEK rotation recomputes `config_items` fingerprints but not these. A row reconciled after a
  rotation therefore never matches `value_fp`, so the value stays pending and is pushed again
  (the safe direction).

### v8_force_push_requested_at (v0.1.2)

```sql
ALTER TABLE config_items ADD COLUMN force_push_requested_at TEXT;  -- when the user asked for the push
```

- Set with `force_push = 1` when the user asks for a secret's push: a fill without "Already
  matches GitHub" (`ConfigRepository.fillValue`) or Push on Next Sync
  (`ConfigRepository.requestPush`). The time is the injected clock's at the edit.
- NULL for pushes FX Vault schedules itself (drift "Keep local", an expired verification) and
  for share-import fills. Cleared wherever `force_push` is cleared: a push (`itemPushed`),
  Revert, Discard all, a deletion, and the drift resolutions that take GitHub's state.
- D27 and drift detection (`ConfigItemSnapshotModel.isSecretChangedOnGitHub`): while
  `force_push = 1`, a GitHub `updatedAt` earlier than this time's whole second minus
  `SyncEngineConstants.requestedPushClockMargin` (5 s) is covered by the request and does not
  block the push; any later one does. GitHub lists whole seconds and its clock can differ from
  the Mac's, so a change whose order is unclear blocks and goes to the drift review.
- An expired verification (`itemVerificationExpired`) of a secret sets
  `remote_updated_at := pre_write_updated_at`, the base the write was checked against, so the
  re-push is not blocked by a GitHub change the request already replaced.

### v9_item_links (v0.4.1)

```sql
ALTER TABLE config_items ADD COLUMN link_id TEXT CHECK (link_id IS NULL OR length(link_id) = 36);
CREATE INDEX config_items_link ON config_items(link_id) WHERE link_id IS NOT NULL;
```

- Linked copies (`ItemLinkID`, a lowercase UUID). `ConfigRepository.copyItems` gives the copy
  (an add or a replaced value) its source's `link_id`, and a new one to both when the source
  had none; a kept conflict is not linked. `ConfigStore.setLinkID(_:itemIDs:in:)` changes only
  this column, so values, AADs and sync state stay as they are.
- The link follows the item: `ItemMutationWriter` gives the row that takes over another row's
  item (Convert/Move, a rename or move into a tombstone) that row's `link_id`. Duplicate
  environment, imports, shares and drift do not link.
- Group lookups: `ConfigStore.fetchLinkedItemRecords(linkID:in:)` (live rows of every
  repository) and the counts `observeItems` attaches to each model (`ConfigItemModel.linkCount`,
  live rows only, so a deleted copy leaves the group's count). Unlinking the last-but-one item
  clears the last one too.

### v10_teammates (v0.5.0)

```sql
CREATE TABLE device_identity (id INTEGER PRIMARY KEY CHECK (id = 1),
  device_id TEXT NOT NULL CHECK (length(device_id) = 32 AND device_id = lower(device_id)),
  secret_ct BLOB NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE teammates (device_id TEXT PRIMARY KEY CHECK (...same...),
  signing_pk BLOB NOT NULL CHECK (length(signing_pk) = 32),
  agreement_pk BLOB NOT NULL CHECK (length(agreement_pk) = 32),
  announce_ct BLOB NOT NULL, login TEXT NOT NULL, display_name TEXT NOT NULL, mac_name TEXT NOT NULL,
  paired_at TEXT NOT NULL, last_seen_at TEXT,
  is_muted INTEGER NOT NULL DEFAULT 0 CHECK (is_muted IN (0, 1)),
  needs_card_update INTEGER NOT NULL DEFAULT 0 CHECK (needs_card_update IN (0, 1)));
```

- `secret_ct` and `announce_ct` were sealed as secret fields (`SecretFieldAAD`). Both tables are
  dropped by `v15_drop_teammates`.

### v11_spaces (v0.6.0)

```sql
CREATE TABLE spaces (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  environment_id TEXT REFERENCES environments(id) ON DELETE CASCADE,
  head_version INTEGER NOT NULL CHECK (head_version >= 1),
  head_hash BLOB NOT NULL CHECK (length(head_hash) = 32),
  epoch INTEGER NOT NULL CHECK (epoch >= 1),
  claimed_version INTEGER CHECK (claimed_version IS NULL OR claimed_version >= 1),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX spaces_scope ON spaces(repository_id, COALESCE(environment_id, ''));
CREATE TABLE space_keys (space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  epoch INTEGER NOT NULL CHECK (epoch >= 1), key_ct BLOB NOT NULL, PRIMARY KEY (space_id, epoch));
CREATE TABLE space_versions (space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  version INTEGER NOT NULL CHECK (version >= 1), kind INTEGER NOT NULL CHECK (kind IN (1, 2, 3)),
  author_device_id TEXT NOT NULL CHECK (length(author_device_id) = 32 AND author_device_id = lower(author_device_id)),
  created_at TEXT NOT NULL, hash BLOB NOT NULL CHECK (length(hash) = 32), data BLOB NOT NULL,
  PRIMARY KEY (space_id, version));
CREATE TABLE teammate_addresses (device_id TEXT PRIMARY KEY REFERENCES teammates(device_id) ON DELETE CASCADE,
  host TEXT CHECK (host IS NULL OR length(host) BETWEEN 1 AND 253),
  port INTEGER CHECK (port IS NULL OR port BETWEEN 1 AND 65535),
  allows_remote INTEGER NOT NULL DEFAULT 0 CHECK (allows_remote IN (0, 1)),
  last_connected_at TEXT, CHECK ((host IS NULL) = (port IS NULL)));
```

- Every table here is dropped by `v15_drop_teammates`.

### v12_folders (v0.7.0)

```sql
CREATE TABLE folders (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 64), name_key TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX folders_name_key ON folders(name_key);
CREATE TABLE folder_items (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
  name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
  value_ct BLOB NOT NULL, value_fp BLOB NOT NULL,
  link_id TEXT CHECK (link_id IS NULL OR length(link_id) = 36),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX folder_items_name ON folder_items(folder_id, kind, name);
CREATE INDEX folder_items_link ON folder_items(link_id) WHERE link_id IS NOT NULL;
```

- Folders hold secrets and variables that belong to no repository. They are separate tables on
  purpose: no sync path (`ChangeSetBuilder`, preflight, executor, drift) reads
  them, so a folder item can never reach GitHub by itself. Repositories get folder items only as
  copies written into `config_items`.
- `name_key` = `FolderNameValidator.foldKey(name)` (case-insensitive, NFC). `sort_order` is the
  sidebar order; `FolderRepository.reorderFolders` rewrites it.
- A folder item always has a value (nothing in a folder comes from GitHub), so `value_ct` and
  `value_fp` are NOT NULL. `value_ct` is sealed with `FolderFieldAAD` (row, folder, kind, name:
  the §5.4 field layout with table `folder_items`); a rename or kind change re-seals it.
  `value_fp` is the row-bound fingerprint, as for `config_items`. DEK rotation re-seals both.
- Folder item ids are `ConfigItemID`s and never collide with `config_items` ids, so copy and
  paste, linked copies and Reveal take either. A `link_id` group spans both tables:
  `LinkCountQuery` counts live members of both (`config_items` without tombstones), and
  `ConfigStore`/`FolderStore` each set `link_id` on their own rows.
- Deleting a folder cascades to its items; their copies in repositories keep their rows (a copy
  left alone in its group is no longer shown as linked).
- `FolderRepository` (VaultData) owns both tables; `ConfigRepository` reads and writes folder
  items only through `ItemCopySource` (copy, links, Reveal) and `FolderItemWriter`.

### v13_destinations (v0.8.0)

```sql
CREATE TABLE provider_connections (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  provider TEXT NOT NULL CHECK (provider IN ('supabase','vercel')),
  label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 64),
  token_ct BLOB NOT NULL,
  account_hint TEXT CHECK (account_hint IS NULL OR length(account_hint) BETWEEN 1 AND 255),
  last_validated_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE destinations (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('azure_keyvault','supabase','vercel')),
  target_key TEXT NOT NULL CHECK (length(target_key) BETWEEN 1 AND 255),
  settings_json TEXT NOT NULL,                     -- DestinationSettings: the provider's identifiers
  stage TEXT CHECK (stage IS NULL OR length(stage) BETWEEN 1 AND 255), stage_key TEXT,
  connection_id TEXT REFERENCES provider_connections(id) ON DELETE SET NULL,
  sort_order INTEGER NOT NULL DEFAULT 0, last_refreshed_at TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK ((stage IS NULL) = (stage_key IS NULL)));
CREATE UNIQUE INDEX destinations_repo_target ON destinations(repository_id, target_key);
CREATE TABLE destination_items (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  destination_id TEXT NOT NULL REFERENCES destinations(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
  name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
  value_ct BLOB, value_fp BLOB,                    -- value_ct NULL = the provider never returned it
  is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
  synced_name TEXT CHECK (synced_name IS NULL OR synced_name = upper(synced_name)),
  synced_kind TEXT CHECK (synced_kind IS NULL OR synced_kind IN ('secret','variable')),
  synced_fp BLOB,                                  -- NULL = the remote holds a value FX Vault never saw
  remote_ref TEXT, remote_version TEXT,
  force_push INTEGER NOT NULL DEFAULT 0 CHECK (force_push IN (0, 1)),
  verify_state TEXT NOT NULL DEFAULT 'verified' CHECK (verify_state IN ('verified','pending')),
  pre_write_version TEXT,
  is_public_allowed INTEGER NOT NULL DEFAULT 0 CHECK (is_public_allowed IN (0, 1)),
  link_id TEXT CHECK (link_id IS NULL OR length(link_id) = 36),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK (kind = 'secret' OR value_ct IS NOT NULL),
  CHECK ((value_ct IS NULL) = (value_fp IS NULL)),
  CHECK ((synced_name IS NULL) = (synced_kind IS NULL)),
  CHECK (is_deleted = 0 OR synced_name IS NOT NULL));
CREATE UNIQUE INDEX destination_items_name ON destination_items(destination_id, name);
CREATE INDEX destination_items_link ON destination_items(link_id) WHERE link_id IS NOT NULL;
CREATE TABLE destination_journal (id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  destination_id TEXT REFERENCES destinations(id) ON DELETE SET NULL,
  item_id TEXT,
  op TEXT NOT NULL CHECK (op IN ('set','delete','recover')),
  item_name TEXT NOT NULL,                         -- names only, never values
  state TEXT NOT NULL CHECK (state IN ('in_flight','succeeded','failed','indeterminate','reconciled')),
  error_code TEXT, pre_write_version TEXT, pushed_fp BLOB,
  started_at TEXT NOT NULL, finished_at TEXT);
CREATE INDEX destination_journal_time ON destination_journal(started_at);
```

- Runtime destinations of a repository: Azure Key Vaults (since v16 the only provider; the
  `supabase` and `vercel` values the CHECKs allow are no longer written). No GitHub sync path
  (`ChangeSetBuilder`, preflight, executor, drift) reads these tables; destination items reach
  their provider only through `DestinationSyncRepository`.
- `target_key` = `DestinationTargetModel.targetKey`, lowercase: `kv|<vault>`. A repository
  cannot add the same place twice.
- `settings_json` = `DestinationSettings`, a flat object with sorted keys: `version` (1),
  `vaultName` and `tenantID`. A row whose settings do not decode reads as
  `StoreError.invalidStoredValue`.
- `stage` names the stage the destination serves (the GitHub environment of the same fold key,
  as Share Project matches them); `stage_key` = `EnvironmentNameValidator.foldKey(stage)`, set with it.
- `connection_id` and `provider_connections` held the Supabase and Vercel tokens until v16,
  which nulls and empties them; nothing reads or writes them since. Key Vault uses the `az`
  sign-in.
- `destination_items.value_ct` is sealed with `DestinationFieldAAD` (row, destination, kind,
  name: the §5.4 field layout with table `destination_items` and an empty environment,
  `DestinationFieldCipher`); a rename or kind change re-seals it. `value_fp` is the row-bound
  fingerprint, as for `config_items`. There is no `synced_value_ct`: `synced_fp` alone records
  what the remote was last confirmed to hold.
- A secret without a value is legal (a disabled Key Vault secret, an item received without a
  value): it is value-missing until filled. Key Vault holds secrets only, so 1.0 writes no
  `variable` rows.
- Names are unique per destination whatever the kind. Key Vault rows keep FX Vault's name; the remote name (`DATABASE-URL`) is derived
  by `DestinationRules`, never stored.
- `remote_version` = Key Vault's `updated` change marker. `pre_write_version` is the marker
  listed right before FX Vault's last write (the verification baseline). `force_push`,
  `verify_state` and `is_deleted` behave as in `config_items`.
- `remote_ref` (the Vercel variable id) and `is_public_allowed` (Vercel's "Mark as Public") are
  unused since 1.0; the columns stay at their defaults.
- `link_id` joins the link groups of `config_items` and `folder_items`: `LinkCountQuery` counts
  live members of all three tables, and `DestinationStore.setLinkID` changes only this column.
- `destination_journal` is appended `in_flight` before every write and finished afterwards. The
  repository journals Key Vault recoveries inside their `set`; `recover` is reserved.
  `pushed_fp` is the fingerprint of the value sent, written with the `in_flight` row before the
  request (a delete has none). The next listing settles interrupted rows: a
  set whose item now lists another version than `pre_write_version` is `reconciled` (with
  `pushed_fp` as the synced fingerprint), a delete whose item is gone likewise; the rest are
  `failed`. Resolved rows older than `Timeouts.syncJournalRetention` are pruned; `in_flight`
  rows are kept. Recent deletions (`recentlyDeletedNames`) keep Refresh from reporting them as
  remote adds while the provider still lists them.
- Removing a repository removes its destinations and their items; removing a destination
  removes its items and nulls its journal rows. Nothing is deleted in the provider.
- DEK rotation re-seals every destination value with its fingerprint. A `synced_fp` is recomputed when it matched the value under the old key and cleared
  otherwise, so that item is pushed again (the safe direction).
- `DestinationRepository` owns `destinations`, `destination_items` and `retired_destinations`;
  `DestinationSyncRepository` writes the sync columns and `destination_journal`.

### v14_project_shares (v0.9.0)

```sql
CREATE TABLE sent_shares (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  package_id TEXT NOT NULL CHECK (length(package_id) = 36),
  created_at TEXT NOT NULL, expires_at TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('passphrase','teammates')),
  recipients TEXT NOT NULL,  -- JSON array of lowercase device ids; [] for a passphrase file
  summary TEXT NOT NULL,     -- JSON SentShareSummaryModel: stages and places, names only
  CHECK (expires_at > created_at));
CREATE INDEX sent_shares_time ON sent_shares(created_at);
ALTER TABLE config_items ADD COLUMN share_hold TEXT
  CHECK (share_hold IS NULL OR (length(share_hold) = 36 AND share_hold = lower(share_hold)));
CREATE INDEX config_items_share_hold ON config_items(share_hold) WHERE share_hold IS NOT NULL;
ALTER TABLE destination_items ADD COLUMN share_hold TEXT CHECK (...same...);
CREATE INDEX destination_items_share_hold ON destination_items(share_hold) WHERE share_hold IS NOT NULL;
ALTER TABLE imported_share_packages ADD COLUMN sender_device_id TEXT
  CHECK (sender_device_id IS NULL OR (length(sender_device_id) = 32 AND sender_device_id = lower(sender_device_id)));
-- teammates rebuilt (teammates_v14, every row copied, old table dropped, renamed):
--   announce_ct BLOB                (was NOT NULL)
--   paired_via TEXT NOT NULL DEFAULT 'nearby' CHECK (paired_via IN ('nearby','remote'))
--   CHECK (announce_ct IS NOT NULL OR paired_via = 'remote')
```

- `sent_shares` is the sent log of Settings › Sharing (P6): one row per exported file with its
  package id, expiry, protection mode and recipients, and a summary of the stages and places it
  carried with the names of their secrets and variables. Names are plaintext metadata, as
  repository and item names are; no value, fingerprint or passphrase is ever written here. The
  exporter writes the row before the file and deletes it again if the file write fails.
  `SentShareStore` inserts, lists newest first, observes and deletes. `expires_at > created_at`
  compares fixed-width timestamps as text. The JSON columns have no CHECK (no dependency on
  SQLite's JSON functions); the record types enforce their shape.
- `share_hold` = the package id of the share file a row was imported from, until Sync's From
  Files review includes that file (P8). A held row stays out of every sync plan, GitHub or
  destination. Including a file clears every hold of that package in both tables in one
  transaction before the run (`ShareHoldStore.clearShareHold(packageIDs:in:)`); Push on Next
  Sync on a held row clears that row only (`clearShareHold(itemIDs:in:)`). The user's own delete,
  GitHub-scope Revert or typed value clears the row's hold (`ItemMutationWriter`,
  `DestinationItemWriter`); a rename or move carries it to the row that holds the item
  afterwards. `ConfigStore` and `DestinationStore` each have `setShareHold(_:itemIDs:in:)`,
  `fetchHeldItemStates(packageID:)` and `clearShareHold(packageID:in:)`; these change only this
  column (values, AADs, fingerprints and sync state are untouched). `ConfigItemState` and
  `DestinationItemState` carry it as `shareHold`, so filters need no ciphertext; the models
  expose it as `heldBy`. DEK rotation keeps holds.
- `imported_share_packages.sender_device_id` is the verified sender of a 0.9 teammates file;
  NULL for a passphrase file, whose sender name is unverified, and for every file 1.0 imports.
  Sync's From Files review shows "verified" only when it is set.
- `teammates` was rebuilt so `announce_ct` could be NULL (remote pairing); v15 drops it.
- `sent_shares.mode = 'teammates'` and its `recipients` exist only in 0.9 rows; 1.0 writes
  `passphrase` and `[]`, and still lists the old rows.

### v15_drop_teammates (1.0)

```sql
DROP TABLE teammate_addresses;
DROP TABLE space_versions;
DROP TABLE space_keys;
DROP TABLE spaces;
DROP TABLE teammates;
DROP TABLE device_identity;
```

- 1.0 removes nearby sharing, Nearby Chat, teammates and shared spaces. Their rows (this Mac's
  device keys, paired teammates' keys and addresses, space keys and versions) are never read
  again; dropping them leaves no key material behind. Children are dropped before their parents.
- `secure_delete` zeroes the freed pages in `vault.sqlite`, but the WAL keeps copies until a
  checkpoint, so `VaultMigrator.migrate` runs `checkpointTruncate()` after any pending migration
  (`droppingTheTeammateTablesLeavesNoKeyBytesInTheWAL`).
- `MigrationTests` seeds every dropped table from v10 on and checks they are gone after
  migrating; `sent_shares` and the share holds read back unchanged.

### v16_drop_runtime_providers (1.0)

```sql
CREATE TABLE retired_destinations (id INTEGER PRIMARY KEY AUTOINCREMENT,
  label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 1024));
INSERT INTO retired_destinations (label) SELECT …;   -- one label per Supabase or Vercel destination
DELETE FROM destination_journal WHERE destination_id IN (… supabase, vercel …);
DELETE FROM destination_items WHERE destination_id IN (… supabase, vercel …);
DELETE FROM destinations WHERE provider IN ('supabase','vercel');
UPDATE destinations SET connection_id = NULL WHERE connection_id IS NOT NULL;
DELETE FROM provider_connections;
```

- 1.0 keeps Azure Key Vault only. The Supabase and Vercel destinations, their items, their
  journal rows and every sealed provider token are deleted from the vault; nothing is deleted
  in Supabase or Vercel.
- Migrations run with foreign keys off, so children are deleted explicitly. `provider_connections`
  stays (empty) because `destinations.connection_id` references it.
- `retired_destinations.label` = `owner/name · Supabase <projectRef>` or `owner/name · Vercel
  <projectName> (<environment>)`, in owner, name, `sort_order`, `created_at` order. The main
  window lists them once after unlock (`DestinationStore.fetchRetiredDestinationLabels`); OK
  deletes every row (`deleteRetiredDestinations`). Names only, never values or tokens.
- The checkpoint after migrating leaves no token bytes in the WAL
  (`droppingTheRuntimeProvidersLeavesNoTokenBytesOnDisk`).

### v17_organizations (1.0)

```sql
CREATE TABLE organizations (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  login TEXT NOT NULL CHECK (length(login) BETWEEN 1 AND 39),
  login_key TEXT NOT NULL UNIQUE CHECK (login_key = lower(login_key)),
  account_login TEXT NOT NULL CHECK (length(account_login) BETWEEN 1 AND 255),
  last_refreshed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE org_items (id TEXT PRIMARY KEY CHECK (length(id) = 36),
  organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),
  name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
  value_ct BLOB, value_fp BLOB,
  visibility TEXT NOT NULL CHECK (visibility IN ('all','private','selected')),
  selected_count INTEGER CHECK (selected_count IS NULL OR selected_count >= 0),
  synced_fp BLOB, remote_updated_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK (kind = 'secret' OR value_ct IS NOT NULL),
  CHECK ((value_ct IS NULL) = (value_fp IS NULL)));
CREATE UNIQUE INDEX org_items_name ON org_items(organization_id, kind, name);
```

- Additive: nothing existing changes. Organizations get their own tables (as folders and
  destinations do) rather than a generalized `config_items`, so no repository sync path reads them.
- `login_key` = `OwnerLoginValidator.foldKey(login)`; one row per organization, whatever the case.
- Secrets have no value (GitHub never returns one) and keep `remote_updated_at`; variables are
  sealed with `OrgFieldAAD` and `synced_fp` is the fingerprint of the value last read.
- `selected_count` is how many repositories a `selected` item reaches (nil for the others).
- DEK rotation re-seals `org_items.value_ct` and recomputes `value_fp` and `synced_fp` (a
  `synced_fp` that no longer matches is cleared).

### v18_standalone_key_vaults (1.0)

```sql
CREATE TABLE destinations_v18 (… as v13, but repository_id TEXT REFERENCES repositories(id) ON DELETE CASCADE,
  CHECK (repository_id IS NOT NULL OR provider = 'azure_keyvault'));
INSERT INTO destinations_v18 SELECT … FROM destinations;
DROP TABLE destinations;
ALTER TABLE destinations_v18 RENAME TO destinations;
CREATE UNIQUE INDEX destinations_repo_target ON destinations(repository_id, target_key);
CREATE UNIQUE INDEX destinations_standalone_target ON destinations(target_key) WHERE repository_id IS NULL;
```

- A Key Vault becomes a source of its own (1.0 brief): a `destinations` row with a NULL
  `repository_id`, listed beside GitHub. Only Key Vault rows may have no repository.
- The table is rebuilt because SQLite cannot drop a NOT NULL. Migrations run with foreign keys
  off, so `destination_items` and `destination_journal` keep their rows and ids.
- A vault of its own is unique by `target_key`; the same vault may also stay under a repository
  (a separate row with its own items).
- Removing a repository never touches the vaults of their own. Their pending changes count
  under the nil key of `DestinationStore.pendingCounts` (the Sync badge, B8c), and share imports
  only place destinations under repositories, so they hold no share rows.

### v19_org_item_changes (1.0)

```sql
ALTER TABLE org_items ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1));
ALTER TABLE org_items ADD COLUMN synced_visibility TEXT
  CHECK (synced_visibility IS NULL OR synced_visibility IN ('all','private','selected'));
ALTER TABLE org_items ADD COLUMN repositories_edited INTEGER NOT NULL DEFAULT 0 CHECK (repositories_edited IN (0, 1));
UPDATE org_items SET synced_visibility = visibility;
CREATE TABLE org_item_repositories (item_id TEXT NOT NULL REFERENCES org_items(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100), PRIMARY KEY (item_id, name)) WITHOUT ROWID;
```

- Additive. Organization items get local changes (B6b): a tombstone, the visibility GitHub has
  (NULL: never synced, an add; rows imported before v19 are synced), and an edited repository
  list.
- `org_item_repositories` holds the list to send while `repositories_edited` is set; otherwise
  GitHub's list as Import, Refresh or Sync last read it (B14/B15, 1.0 O1), or nothing when unknown.
  Sync still reads GitHub's list right before a write of an unedited item, so every write sends
  the complete list.
- Status (`OrgItemRecord.syncStatus`): deleted, added, modified (value fingerprint differs from
  `synced_fp`, visibility differs, or the list was edited), else synced. A secret with no value
  is synced. No synced value is kept, so a changed value cannot be reverted (as destinations).

### v20_key_vault_subscriptions (1.0)

```sql
ALTER TABLE destinations ADD COLUMN subscription_id TEXT
  CHECK (subscription_id IS NULL OR length(subscription_id) = 36);
ALTER TABLE destinations ADD COLUMN subscription_name TEXT
  CHECK (subscription_name IS NULL OR length(subscription_name) BETWEEN 1 AND 255);
```

- Additive. The Azure subscription of a Key Vault of its own (D6c6), so the sidebar shows Azure ›
  subscription › vault. Connect Azure saves it; vaults imported before v20 keep NULL (directly
  under Azure) until a Refresh looks it up with `az`. FX Vault always writes both columns together.

### v21_file_secrets (1.0)

```sql
ALTER TABLE config_items ADD COLUMN file_detail TEXT
  CHECK (file_detail IS NULL OR (json_valid(file_detail)
    AND json_type(file_detail, '$.fileName') IS 'text'
    AND length(json_extract(file_detail, '$.fileName')) BETWEEN 1 AND 255
    AND coalesce(json_extract(file_detail, '$.encoding'), '') IN ('text', 'base64')
    AND coalesce(json_type(file_detail, '$.lineCount'), 'null') IN ('null', 'integer')));
-- The same column and CHECK on folder_items and destination_items.
```

- Additive. The file a secret's value came from (F1, Add file secret): `FileSecretModel` as JSON
  (`fileName` without its folder, `lineCount` of a text file, `encoding` `text` or `base64`).
  NULL for a typed value and for every row saved before v21. Plaintext like the item's name
  (docs/SECURITY-MODEL.md); the file's content is the sealed value.
- The CHECK uses `IS` and `coalesce` because a CHECK that evaluates to NULL passes (a missing
  key would otherwise slip through, as with `key_wraps` above). It is spelled out per table: a
  frozen migration shares no text with later code.
- The label follows the value (`ConfigFieldCipher.setValue` and its folder and destination
  twins): a value with another fingerprint drops it, so a typed value, a pull or a drift
  replace leaves no stale file name; a rename, a move, a copy and a linked update carry it with
  the value, and a pushed Key Vault rename gives it to the new row. Revert restores a value but
  not a label an edit dropped; `.env` files and share files carry no label.

## Tables at a glance

| Table | Record | Store | Notes |
|---|---|---|---|
| `vaults` | `VaultRecord` | `VaultRecordStore` | Single row (`id = 1`) |
| `key_wraps` | `KeyWrapRecord` | `VaultRecordStore` | One row per unlock method; map to VaultCrypto with `KeyWrapModel(storedMethod:…)` |
| `accounts` | `AccountRecord` | `AccountStore` | |
| `repositories` | `RepositoryRecord` | `RepoStore` | Deleting a repository cascades to environments, items, patterns and destinations and nulls journal rows |
| `environments` | `EnvironmentRecord` | `ConfigStore` | Patterns are attached when the policy is custom |
| `deployment_branch_patterns` | `BranchPatternRecord` | `ConfigStore` | |
| `config_items` | `ConfigItemRecord` (with ciphertext), `ConfigItemState` (read-only projection without ciphertext) | `ConfigStore` | Status is derived with `ConfigSyncStatus.derive(state.syncFacts)`; `link_id` groups linked copies (v0.4.1); `share_hold` (v0.9.0); `file_detail` (v21) |
| `sync_journal` | `SyncJournalRecord` | `SyncJournalStore` | Names and push fingerprints only, never values |
| `imported_share_packages` | `ImportedSharePackageRecord` | `SharePackageStore` | `sender_device_id` for a 0.9 teammates file, v0.9.0 |
| `folders` | `FolderRecord` | `FolderStore` | Unique by `name_key`, sidebar order, v0.7.0 |
| `folder_items` | `FolderItemRecord` (with ciphertext; `FolderItemModel` without) | `FolderStore` | Always with a value; `link_id` groups span `config_items`, v0.7.0; `file_detail` (v21) |
| `provider_connections` | — | — | Empty and unused since v16 (Supabase and Vercel tokens, v0.8.0) |
| `destinations` | `DestinationRecord` (`DestinationSettings` in `settings_json`) | `DestinationStore` | Unique per repository by `target_key`, v0.8.0; a NULL `repository_id` is a Key Vault of its own, unique by `target_key` (v18, 1.0); its Azure subscription (v20) |
| `destination_items` | `DestinationItemRecord` (with ciphertext), `DestinationItemState` (without) | `DestinationStore` | Value optional for secrets; `link_id` groups span all three item tables, v0.8.0; `share_hold` (v0.9.0); `file_detail` (v21) |
| `destination_journal` | `DestinationJournalRecord` | `DestinationStore` | Destination writes, names and push fingerprints only, v0.8.0 |
| `retired_destinations` | — (labels as `String`) | `DestinationStore` | The one-time notice after v16, names only, 1.0 |
| `sent_shares` | `SentShareRecord` (`SentShareModel`) | `SentShareStore` | Names only, v0.9.0 |
| `organizations` | `OrganizationRecord` (`OrganizationModel` with counts) | `OrganizationStore` | Unique by `login_key`, 1.0 |
| `org_items` | `OrgItemRecord` (with ciphertext; `OrgItemModel` without) | `OrganizationStore` | Value optional for secrets; visibility and selected count, 1.0; pending state, v19 |
| `org_item_repositories` | — (raw SQL) | `OrganizationStore` | A `selected` item's repository list: the edited one, or GitHub's as last read, v19 |
| holds (`share_hold` on both item tables, the import records) | `HeldShareInputsModel` | `ShareHoldStore` | Read model of Sync's From Files review and bulk release, v0.9.0 |

## Transactions

- Writes are **synchronous only** (`VaultDatabase.write { tx in ... }`). There is no async write
  API, so a write can never be split across a suspension point.
- Inside a write body call only the `in tx:` forms of store methods. Calling a convenience
  method, `read`, `write` or `checkpointTruncate()` there traps (GRDB access is not reentrant).
- After a key write made through an `in:` variant (DEK rotation, password change), call
  `checkpointTruncate()` once the transaction has returned.
- **Ciphertext goes through `VaultSession`.** Repositories write `value_ct`, `value_fp` and the
  `synced_*` columns only inside `VaultSession.write { keys, tx in }`, whose keys are checked
  against the stored `vaults` row (so a concurrent DEK rotation can never mix keys), and decrypt
  only inside `VaultSession.read`. Plain bookkeeping without keys uses `VaultDatabase.write`.
- **Re-seal on identity change.** `value_ct` (and `synced_value_ct`) is re-encrypted whenever a
  row's name, scope or kind changes, because the field AAD binds them; fingerprints are
  recomputed for the target row id. Item edits go through `ItemMutationWriter`, which applies
  SyncEngine's `ConfigItemEditPlanner` mutations in one transaction.
- **Imports store values as listed.** An imported variable's value and synced value are the
  listed bytes, trailing CR/LF included (D32 normalizes at push time); imported secrets are
  value-missing with `remote_updated_at` = GitHub's `updatedAt`. Listed rows share one shape
  (`SyncRowWriter.insertListedItem`).
- **Sync outcomes** are one transaction of journal outcomes plus row effects. A push re-seals
  `synced_value_ct` (and, when the value was normalized, `value_ct`) only if the value did not
  change during the run; a rename's detached tombstone is re-sealed and re-fingerprinted for its
  own row id. Only pushes need the keys, so other bookkeeping is still recorded after a lock.
- **Destination writes** (v0.8.0) follow the GitHub rules: values and tokens are sealed only
  inside `VaultSession.write`, an item's identity change re-seals its value
  (`DestinationItemWriter`), and each provider write is journaled `in_flight` in its own
  transaction before the request starts, then finished with its row effects. A Sync never holds
  a transaction across a network call.
- **Share imports** re-plan, write the rows (re-encrypted with the receiver's keys under new row
  ids, `provenance = share`) and record `imported_share_packages` in the same transaction.
- **Bundle imports** (v0.9.0) apply everything in one transaction: the re-plan, every ✓
  repository through the share importer, destinations created or merged, folders, fresh
  `link_id`s, `share_hold` set after every value write, and one `imported_share_packages` row.
  Repositories still to be imported from GitHub are imported before it, outside any
  transaction.
- **Releasing holds** (v0.9.0): including files in a Sync clears their holds in both tables in
  one transaction before the run is planned; nothing else in the run changes `share_hold`.
- **Sent log** (v0.9.0): the `sent_shares` row is its own transaction, written before the file;
  a failed file write deletes it.
- Database errors become `StoreError` (`notFound`, `constraintViolation(StoreConstraint)`,
  `busy`, `corruptDatabase`, `database(code:)`, ...) with no SQL or SQLite message text. Errors
  thrown by the caller's own body pass through unchanged.

## Observation

`AccountStore.observeAll`, `RepoStore.observeAll/observe(id:)`,
`ConfigStore.observeEnvironments/observeItems/observePendingInputs/observeAllPendingInputs`,
`FolderStore.observeFolders/observeItems` (v0.7.0),
`DestinationStore.observeDestinations/observeItems/observePendingCounts`
(v0.8.0), `SentShareStore.observe` and `ShareHoldStore.observeInputs` (v0.9.0) and
`SyncJournalStore.observeLatestRun` return
`AsyncThrowingStream`s. Each emits the current value,
then a new value after every committed change; consecutive equal values are skipped; a failed
fetch ends the stream with a `StoreError`; observation stops when the consumer stops iterating.

## Not in the database

Non-secret preferences live in `UserDefaults` (`PreferencesManager`): `autoLockMinutes`,
`cloneFolderPath`, `ghPathOverride`, `trustedGHPath`, `trustedGHOwnerUID`,
`recoveryKeyConfirmationPending`, `touchIDOfferAnswered`. The Touch ID copy of the DEK lives in the keychain (plan §5.5).

Destinations (v0.8.0) keep these out of the database too:
- Azure Key Vault access tokens from `az account get-access-token` live in memory only
  (`ShellResolvingAzureTokens`) and are dropped when the vault locks.
- Remote values are never cached: a listed value is either stored sealed in `value_ct` (an
  import or Use Remote) or wiped after the comparison.
