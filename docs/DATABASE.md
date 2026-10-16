# FX Vault - Local database

The vault is one SQLite database managed by GRDB 7.11.1, inside the `VaultStore` module
(`Packages/FXVaultKit/Sources/VaultStore`). Only VaultStore imports GRDB (`scripts/lint.sh`
enforces it); every other module uses the opaque `VaultDatabase` and the stores.

The database holds **no plaintext values**. Secret and variable values are stored only as
AES-256-GCM blobs (`value_ct`, `synced_value_ct`) encrypted by VaultCrypto with the field AAD
(docs/ARCHITECTURE.md, "VaultCrypto"), next to HMAC-SHA256 fingerprints (`value_fp`,
`synced_fp`). Names, timestamps and GitHub ids are plaintext.

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

- `secret_ct` = this device's `signingSeed ‖ agreementKey ‖ announceKey` (96 bytes) sealed as a
  secret field (`SecretFieldAAD`: table, column, device id bytes); `announce_ct` = a teammate's
  announce key, sealed the same way. Both are re-sealed by DEK rotation (`DEKRotator`).
- `TeamRepository` (VaultData) owns both tables: keys are created on first use; removing a
  teammate renews this device's announce key and sets `needs_card_update` on every remaining
  teammate; `last_seen_at` is written at most once a minute.

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

- One space per scope. `head_version`/`head_hash` are the verified head; every read re-verifies
  the whole `space_versions` log from genesis and refuses a stored head that does not match it.
  `claimed_version` is set by a claim and cleared only when the `published` marker is confirmed
  on GitHub (or the claim is lost); launch reconciliation finishes it.
- `space_versions` is append-only: `data` is the version's signed wire form (SHARING-PROTOCOL.md
  §11.1), whose payload (names and values) is encrypted under the epoch key. Removing a
  repository or environment removes its space, versions and keys.
- `key_ct` = one epoch key sealed as a secret field (`SecretFieldAAD`: table, column,
  `spaceID ‖ u32be(epoch)`); re-sealed by DEK rotation.
- `teammate_addresses`: remote space sync per teammate (Q4). A row with `allows_remote = 1` and no
  address only accepts that teammate's connections. Removing the teammate removes the row.
- `SpaceRepository` (VaultData) owns `spaces`, `space_keys` and `space_versions`;
  `TeamRepository` owns `teammate_addresses`.

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
  purpose: no sync path (`ChangeSetBuilder`, preflight, executor, drift, scope spaces) reads
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

## Tables at a glance

| Table | Record | Store | Notes |
|---|---|---|---|
| `vaults` | `VaultRecord` | `VaultRecordStore` | Single row (`id = 1`) |
| `key_wraps` | `KeyWrapRecord` | `VaultRecordStore` | One row per unlock method; map to VaultCrypto with `KeyWrapModel(storedMethod:…)` |
| `accounts` | `AccountRecord` | `AccountStore` | |
| `repositories` | `RepositoryRecord` | `RepoStore` | Deleting a repository cascades to environments, items, patterns and spaces and nulls journal rows |
| `environments` | `EnvironmentRecord` | `ConfigStore` | Patterns are attached when the policy is custom |
| `deployment_branch_patterns` | `BranchPatternRecord` | `ConfigStore` | |
| `config_items` | `ConfigItemRecord` (with ciphertext), `ConfigItemState` (read-only projection without ciphertext) | `ConfigStore` | Status is derived with `ConfigSyncStatus.derive(state.syncFacts)`; `link_id` groups linked copies (v0.4.1) |
| `sync_journal` | `SyncJournalRecord` | `SyncJournalStore` | Names and push fingerprints only, never values |
| `imported_share_packages` | `ImportedSharePackageRecord` | `SharePackageStore` | |
| `device_identity` | `DeviceIdentityRecord` | `TeamStore` | Single row (`id = 1`), v0.5.0 |
| `teammates` | `TeammateRecord` (`TeammateModel` without keys) | `TeamStore` | v0.5.0 |
| `spaces` | `SpaceRecord` | `SpaceStore` | One per shared scope, v0.6.0 |
| `space_keys` | `SpaceKeyRecord` | `SpaceStore` | Epoch keys, sealed, v0.6.0 |
| `space_versions` | `SpaceVersionRecord` | `SpaceStore` | Append-only signed versions, v0.6.0 |
| `teammate_addresses` | `TeammateAddressRecord` | `SpaceStore` | Remote space sync per teammate (Q4), v0.6.0 |
| `folders` | `FolderRecord` | `FolderStore` | Unique by `name_key`, sidebar order, v0.7.0 |
| `folder_items` | `FolderItemRecord` (with ciphertext; `FolderItemModel` without) | `FolderStore` | Always with a value; `link_id` groups span `config_items`, v0.7.0 |

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
- **Share imports** re-plan, write the rows (re-encrypted with the receiver's keys under new row
  ids, `provenance = share`) and record `imported_share_packages` in the same transaction.
- Database errors become `StoreError` (`notFound`, `constraintViolation(StoreConstraint)`,
  `busy`, `corruptDatabase`, `database(code:)`, ...) with no SQL or SQLite message text. Errors
  thrown by the caller's own body pass through unchanged.

## Observation

`AccountStore.observeAll`, `RepoStore.observeAll/observe(id:)`,
`ConfigStore.observeEnvironments/observeItems/observePendingInputs/observeAllPendingInputs`,
`FolderStore.observeFolders/observeItems` (v0.7.0) and `SyncJournalStore.observeLatestRun` return
`AsyncThrowingStream`s. Each emits the current value,
then a new value after every committed change; consecutive equal values are skipped; a failed
fetch ends the stream with a `StoreError`; observation stops when the consumer stops iterating.

## Not in the database

Non-secret preferences live in `UserDefaults` (`PreferencesManager`): `defaultCloneFolder`,
`autoLockMinutes`, `ghPathOverride`, `lastResolvedGHPath`, `nearbyDisplayName`,
`lastSelectedRepoId`. The Touch ID copy of the DEK lives in the keychain (plan §5.5).
