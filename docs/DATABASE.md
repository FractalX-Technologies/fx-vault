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
  force_push INTEGER NOT NULL DEFAULT 0,           -- "Keep local" drift resolution
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

## Tables at a glance

| Table | Record | Store | Notes |
|---|---|---|---|
| `vaults` | `VaultRecord` | `VaultRecordStore` | Single row (`id = 1`) |
| `key_wraps` | `KeyWrapRecord` | `VaultRecordStore` | One row per unlock method; map to VaultCrypto with `KeyWrapModel(storedMethod:…)` |
| `accounts` | `AccountRecord` | `AccountStore` | |
| `repositories` | `RepositoryRecord` | `RepoStore` | Deleting a repository cascades to environments, items and patterns and nulls journal rows |
| `environments` | `EnvironmentRecord` | `ConfigStore` | Patterns are attached when the policy is custom |
| `deployment_branch_patterns` | `BranchPatternRecord` | `ConfigStore` | |
| `config_items` | `ConfigItemRecord` (with ciphertext), `ConfigItemState` (read-only projection without ciphertext) | `ConfigStore` | Status is derived with `ConfigSyncStatus.derive(state.syncFacts)` |
| `sync_journal` | `SyncJournalRecord` | `SyncJournalStore` | Names and push fingerprints only, never values |
| `imported_share_packages` | `ImportedSharePackageRecord` | `SharePackageStore` | |

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
`ConfigStore.observeEnvironments/observeItems/observePendingInputs/observeAllPendingInputs` and
`SyncJournalStore.observeLatestRun` return `AsyncThrowingStream`s. Each emits the current value,
then a new value after every committed change; consecutive equal values are skipped; a failed
fetch ends the stream with a `StoreError`; observation stops when the consumer stops iterating.

## Not in the database

Non-secret preferences live in `UserDefaults` (`PreferencesManager`): `defaultCloneFolder`,
`autoLockMinutes`, `ghPathOverride`, `lastResolvedGHPath`, `nearbyDisplayName`,
`lastSelectedRepoId`. The Touch ID copy of the DEK lives in the keychain (plan §5.5).
