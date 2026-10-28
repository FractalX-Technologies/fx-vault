# FX Vault - Sharing formats and protocol

Implemented in `Packages/FXVaultKit/Sources/SharingKit`. This document records the wire formats
as built (plan §9 plus the decisions made during M6 implementation). Known-answer vectors are
pinned in `Tests/SharingKitTests/Fixtures/file_v1_kat.json` and `file_v2_kat.json`; the
independent generators (`Fixtures/kat/file_v1_kat.py` and `file_v2_kat.py`, Python
`cryptography`) produce byte-identical output.

1.0 shares by file only. Nearby sharing, Nearby Chat, teammates (pairing, presence) and shared
spaces (former §4, §7, §10, §11) were removed; the section numbers are kept.

## 1. Payload: `SharePackageModel` (schema 1 and 2; 3 for folders, §1.3; 4 for bundles, §1.4)

JSON, keys sorted, dates ISO-8601 UTC with `Z`. `value` and `githubUpdatedAt` are always present
(explicit `null` when absent). `deploymentBranchPolicy` is an object, or an explicit `null` for a
partial environment (schema 2 only, §1.1).

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 1 | 2,
  "packageId": "<uuid>", "createdAt": "2026-10-14T10:00:00Z",
  "producer": {"app": "FX Vault", "version": "1.0.0"},
  "sender": {"displayName": "<sanitized, ≤ 63 bytes>"},
  "scope": "secret | environment | repository",
  "repository": {
    "host": "github.com", "owner": "<owner>", "name": "<repo>", "githubRepoId": "<node id> | null",
    "secrets":   [{"id": "<uuid>", "name": "API_KEY", "value": "<utf-8> | null",
                   "valueState": "present | missing", "githubUpdatedAt": "<date> | null",
                   "syncState": "synced | pending"}],
    "variables": [ ... same shape ... ],
    "environments": [{"id": "<uuid>", "name": "production",
                      "deploymentBranchPolicy": {"type": "all | protected | custom",
                                                 "patterns": [{"name": "release/*", "type": "branch | tag"}]}
                                                | null,
                      "secrets": [ ... ], "variables": [ ... ]}] } }
```

- **Entry ids** (`ShareEntryID`, a UUID) are on every item and environment, in one id space,
  so the receiver's plan can name every row.
- **Manifest** = the same document with every `value` set to null (`valueState` kept). Value
  hashes are never included.
- **Scopes** describe the contents; the receiver merges every scope the same way (nothing that
  is missing from a package is ever deleted):
  - `secret`: exactly one item (secret or variable), at repository or environment level.
  - `environment`: exactly one whole environment (with its policy) and no repository-level items.
  - `repository`: any other combination, including a subset of the repository level, several
    environments, and partial environments. No new scope value was needed: the v1 validator
    already accepts any mix under `repository`.

### 1.1 Schema versions and compatibility (v0.2.0)

| `schemaVersion` | Written by | Meaning |
|---|---|---|
| 1 | 0.1.x, and 0.2.0 whenever possible | Every environment carries its `deploymentBranchPolicy` |
| 2 | 0.2.0 when needed | Adds **partial environments**: `deploymentBranchPolicy: null` plus at least one item |
| 3 | 0.7.0, for a folder | A folder instead of a repository (§1.3) |
| 4 | 0.9.0, every `.fxvault` export | A bundle: repositories with their destinations, folders, link tokens and `expiresAt` (§1.4) |

- **Since 0.9.0** every `.fxvault` file is a schema 4 bundle in format 2 (§2.1); the
  lowest-version rule below describes the files 0.2–0.8 wrote, which 1.0 still opens.

- **Lowest version rule.** A package is written with the lowest version that can hold it
  (`SharePackageModel.requiredSchemaVersion(for:)`): 2 only when at least one environment is
  partial. The whole repository, whole environments, the repository level (all or some of it)
  and single repository-level items are still written as v1.
- **0.1.x → 0.2.0.** Every v1 file written by 0.1.x imports unchanged
  (pinned by `SharingKitTests/Fixtures/item-v1-0.1.1.json` and
  `VaultDataTests/Fixtures/Sharing/repository-v1-0.1.1.fxvault`, both written by 0.1.1). A v1
  environment always carries its policy, so 0.1.x semantics are kept: a single
  environment-level item from 0.1.x still offers its environment's policy as a "Deployment
  branches differ" row (Keep mine by default).
- **0.2.0 → 0.1.x.** v1 packages import in 0.1.x. A v2 package (anything with a partial
  environment, including a single environment-level secret or variable) is rejected by 0.1.x:
  its decoder requires a policy object, so a `.fxvault` file shows "Wrong passphrase or damaged
  file". The workaround is to check the whole environment (v1) or
  to update the receiver.
- A v1 document with a `null` or missing policy is rejected (`branchPolicyRequired`); a v2
  document may also contain only whole environments. A repository package with a version other
  than 1 and 2 is `unsupportedSchemaVersion` (`SharePackageModel.repositorySchemaVersions`);
  version 3 is a folder (§1.3).

### 1.3 Folders: schema 3 (v0.7.0)

A copy of a folder is scope `folder`, `schemaVersion` 3, and carries a `folder` object instead of
`repository`:

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 3, "packageId": "<uuid>",
  "createdAt": "…", "producer": {…}, "sender": {…}, "scope": "folder",
  "folder": {"name": "Mobile App",
             "secrets":   [{"id": "<uuid>", "name": "FIREBASE_API_KEY", "value": "<utf-8> | null",
                           "valueState": "present", "githubUpdatedAt": null, "syncState": "pending"}],
             "variables": [ ... same shape ... ]} }
```

- The validator requires a valid folder name (`FolderNameValidator`, NFC), at most
  `Limits.maxFolderItems` (1,000) items, every item `valueState: present` (a folder item always
  has a value), unique names per kind, and GitHub item names. A document with both `folder` and
  `repository`, or a `folder` with any other scope, does not decode.
- In memory (`SharePackageModel`) the items sit at repository level of a `repository` block with
  an empty owner and name and no environments, so manifests, summaries and wiping work
  unchanged; `folder` holds the name.
- **Import Into a repository**: `SharePackageModel.intoRepository(owner:name:githubRepoID:environmentName:)`
  turns the folder into an ordinary package for the chosen repository, its items at repository
  level or in a partial environment (schema 2) of the chosen environment, with the same package
  id. Only that converted package is planned: `ShareImportPlanner` refuses a folder package.
- **Save as Folder**: `FolderRepository.save(_:as:conflicts:)` writes the items into a new folder
  (by default named as the sender's) or merges them into an existing folder (names it has are
  kept unless Replace is chosen), normalizes values (D32) and records the package id in
  `imported_share_packages` like an import.
- 0.6 and older reject version 3 (`unsupportedSchemaVersion`): a `.fxvault` folder file shows
  "Wrong passphrase or damaged file" there.
- A folder's subfolders (v22) and files (v23) are never in a share: the payload carries the
  folder's secrets and variables only, and the format is unchanged.

### 1.4 Bundles: schema 4 (v0.9.0)

A project share (tasks/todo.md P1). Every `.fxvault` export from 0.9 on is a bundle, even for one
repository or one folder, sealed in format 2 (§2.1). Schemas 1–3 stay readable:
`ShareDocumentCoder` reads `schemaVersion` first, sends 4 to `ShareBundleCoder` and
`ShareBundleValidator`, and everything else to `SharePackageCoder` and `SharePackageValidator`.

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 4, "scope": "bundle",
  "packageId": "<uuid>", "createdAt": "<date>", "expiresAt": "<date>",
  "producer": {"app": "FX Vault", "version": "0.9.0"}, "sender": {"displayName": "…"},
  "stages": ["staging"],
  "repositories": [ { "host": "github.com", "owner": "owner-a", "name": "example-web", "githubRepoId": "<node id> | null",
      "secrets": [ITEM], "variables": [ITEM], "environments": [ENV (schema 2: policy or null)],
      "destinations": [ { "id": "<uuid>", "stage": "staging | null",
          "target": {"provider": "azureKeyVault", "vaultName": "kv-example-staging", "tenantId": "… | null"},
          "secrets": [ITEM], "variables": [ITEM] } ] } ],
  "folders": [ { "id": "<uuid>", "name": "Mobile App", "secrets": [ITEM], "variables": [ITEM] } ] }
```

- **Items.** ITEM is the schema 2 item (§1) plus an optional `"link": "<lowercase uuid>"`. The
  key exists only in bundles: schemas 1–3 never write it and their validator rejects it
  (`linkNotAllowed`), so older documents stay byte for byte the same.
- **Link tokens** (P9) are random per export, never the sender's `link_id`. A token is written
  only when at least two items of the file belong to the same linked-copy group.
- **0.9 files** (1.0 reads them): a destination whose provider is `supabase` or `vercel` is
  dropped on decode and its label (`Supabase <projectRef>`, `Vercel <projectName> (<environment>)`)
  is kept in `ShareBundleRepositoryModel.retiredDestinations` (never encoded); the open sheet
  shows "Left out: …" for the repository. A `link` token left with a single item by the drop is
  removed. `publicNames` is ignored. 1.0 writes Key Vault destinations only.
- **`stages`** are the stages the sender chose; after the import FX Vault opens the first repository at the environment of the first one.
- **Never in a bundle:** `az` sessions, GitHub accounts, SSH aliases, value hashes.
- **Encoding** follows schemas 1–3: sorted keys, whole-second ISO-8601 UTC dates (fractional
  seconds accepted), explicit `null` for absent values and optionals. A `scope` other than
  `bundle`, or any decoding failure, is `invalidFile`.

**Validator** (`ShareBundleValidator`, `.manifest` and `.payload` modes):

- **Header.** Schema `io.fractalx.fxvault.share` at version 4; producer and sender as in schema
  1; `createdAt < expiresAt ≤ createdAt + 30 days + 10 minutes` (`Timeouts.shareMaxExpiry` plus
  `shareClockSkew`; `invalidExpiry`); `stages` are environment names (strict NFC), unique by fold
  key (`invalidStage`, `duplicateStage`).
- **Contents.** 1–50 repositories (`Limits.maxShareRepositories`), or none and at least one
  folder (`emptyBundle`, `tooManyRepositories`); repositories unique by owner and name fold keys
  (`duplicateRepository`).
- **Each repository.** The schema 2 rules (host, owner, name, `githubRepoId`, environments,
  policies, items, partial environments); at most 32 destinations
  (`Limits.maxDestinationsPerRepository`, `tooManyDestinations`), unique by target key
  (`duplicateDestination`).
- **Each destination.** The target passes `DestinationRules.validate` and is already trimmed;
  the stage follows the environment name rules (`invalidDestinationTarget`). At most 1,000 items
  (`tooManyDestinationItems`). Item names follow GitHub's rules plus the provider's
  (`invalidDestinationItem`): Key Vault holds secrets only; values are at most 25 KiB; a name is
  unique across kinds (`duplicateDestinationItem`).
- **Folders.** Strict folder names (`invalidFolderName`), unique by fold key
  (`duplicateFolder`), at most 1,000 items, every one with a value (`valueStateMismatch`).
- **Entry ids** (environments, destinations, folders, items) are unique across the bundle
  (`duplicateEntryID`); **link tokens** are lowercase UUIDs carried by at least two items
  (`invalidLinkToken`).

**Freshness** (`ShareBundleModel.checkFreshness(now:)`, run when a bundle is opened and again by
the planner):

| Condition | Result |
|---|---|
| `createdAt > now + 10 min` | `invalidPackage(createdInFuture)` |
| `now > expiresAt + 10 min` | `ShareError.expired` ("This file expired") |

FX Vault enforces the expiry; the cryptography does not (SECURITY-MODEL.md §10.5).

### 1.2 Branch policy rule

An environment's deployment branch policy travels **only when the environment itself is
selected**: in the scope tree its checkbox is fully checked (checked directly, or every one of
its items is checked), or the selection is `.environment` / `.repository` / a subset's
`environmentIDs`. An environment reached only through some of its items is a partial environment:
it carries the selected items and no policy. Consequences on the receiver (§5):

- an existing environment keeps its policy (no "Deployment branches differ" row);
- a missing environment is created with GitHub's policy and patterns when GitHub lists it
  (created as synced, nothing pending), otherwise with all branches (GitHub's default for a new
  environment, pending create);
- a missing partial environment whose items the receiver all skips is not created
  (`ShareEnvironmentPlanModel.createsEnvironment`).

An environment without items and without a policy says nothing and is invalid
(`branchPolicyRequired`). One scope-tree exception: a
tree opened for one item ("Share this secret…") shares that item alone (`.item`, no policy)
even when it is its environment's only item, until the user changes the checks.

`SharePackageValidator` (modes `.manifest` and `.payload`) rejects, among others: a schema or
version other than the above (§1.1); a missing policy in a v1 document, in an `environment`-scope
document or on an environment without items (`branchPolicyRequired`); producer or sender fields that are not already sanitized; a host
other than `github.com`; invalid owner or repository names (owners: `OwnerLoginValidator`, ASCII
letters, digits, `-` and, since v0.3.1, `_` for Enterprise Managed User owners such as
`mona-cat_acme`, never first, at most 39 characters; repositories: `.`, `..`, `*.git`); a `githubRepoId`
over 128 characters; environment names that fail `EnvironmentNameValidator` (NFC, no C0/C1,
bidi, zero-width or edge whitespace, no `/`, no dot segments); item names that are not already
uppercase GitHub names; duplicate environments, items (per kind and level) or entry ids; more
than 100/500/100/100 secrets/variables at repository/environment level; values in a manifest;
empty, non-UTF-8 or over-48,000-byte values (measured after trailing CR/LF is stripped);
`valueState` not matching the value; patterns that are invalid, duplicated, more than 50, or
present without a custom policy; and content that does not match the declared scope. A secret
and a variable may share a name within a scope, as on GitHub.

## 2. File: `.fxvault` v1

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `46 58 56 41 55 4C 54 1A` |
| 8 | 2 | formatVersion u16 BE = 1 |
| 10 | 2 | headerLength u16 BE = 64 (must be exactly 64) |
| 12 | 1 | kdfId = 1 (Argon2id v1.3) |
| 13 | 1 | aeadId = 1 (AES-256-GCM) |
| 14 | 4 | opsLimit u32 BE (3) |
| 18 | 4 | memLimitKiB u32 BE (65536) |
| 22 | 1 | parallelism = 1 |
| 23 | 1 | flags = 0 |
| 24 | 16 | salt |
| 40 | 12 | nonce |
| 52 | 12 | reserved, zero |
| 64 | n | ciphertext ‖ tag (16); AAD = header bytes 0..<64 |

- Key: Argon2id(normalized passphrase, salt, t, m KiB, p = 1) → 32 bytes, through the injected
  `KeyDeriving` (VaultData adapts VaultCrypto's Argon2id; memory KiB × 1024 = bytes).
- Reader order: size ≤ 16 MiB + 80 → magic → version → headerLength → kdf/aead ids → bounds
  (1 ≤ t ≤ 10, 8192 ≤ m ≤ 1048576 KiB, p = 1, flags and reserved zero) → **only then** the
  passphrase (`FxVaultFileCodec.inspect` never calls the KDF) → Argon2id → GCM open → JSON
  (≤ 16 MiB) → validate (payload mode) → replay check → preview.
- Every read failure up to JSON decoding is `ShareError.invalidFile`, shown as "Wrong
  passphrase or damaged file". Validation failures are `invalidPackage(...)`.
- Writer: fresh salt and nonce every time; `ReauthGate(.share)` first; written with
  `SecureFileWriter` (0600).
- KAT: key `0x42 × 32`, t = 3, m = 65536, salt `80..8f`, nonce `90..9b`, payload
  `{"schema":"fxvault.share/1"}` → 108-byte file, header
  `46585641554c541a0001004001010000000300010000010080…8f 90…9b 00×12`.

### 2.1 File: `.fxvault` format 2 (v0.9.0)

Implemented in `SharingKit/File` (`FxVaultFileV2Codec`, `FxVaultHeaderV2Model`). Every export from
0.9 writes format 2; `FxVaultFileV2Codec.inspect` and `openWithPassphrase` still read v1 files (§2)
through `FxVaultFileCodec`. FX Vault 0.8 and earlier show format 2 as "Wrong passphrase or damaged
file" (their reader requires formatVersion 1).

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `46 58 56 41 55 4C 54 1A` (as v1) |
| 8 | 2 | formatVersion u16 BE = 2 |
| 10 | 2 | headerLength u16 BE = 64 (must be exactly 64) |
| 12 | 1 | kdfId = 1 (Argon2id v1.3) |
| 13 | 1 | aeadId = 1 (AES-256-GCM) |
| 14 | 4 | opsLimit u32 BE: 1…10 (writes 3) |
| 18 | 4 | memLimitKiB u32 BE: 8192…1048576 (writes 65536) |
| 22 | 1 | parallelism = 1 |
| 23 | 1 | flags = 0 |
| 24 | 16 | salt, fresh per export |
| 40 | 12 | nonce, fresh per export |
| 52 | 1 | mode = 1 (passphrase) |
| 53 | 1 | recipientCount = 0 |
| 54 | 10 | reserved, zero |

`header(64) ‖ ciphertext ‖ tag(16)`. Key = Argon2id(normalized passphrase, salt, t, m, p = 1) →
32 bytes, exactly as v1 (§2, §3); AES-256-GCM, nonce = header nonce, AAD = the 64 header bytes;
plaintext = the payload JSON (≤ 16 MiB). The sender's name in the payload is unverified. Largest
file: `Limits.maxShareFileBytes` = 16 MiB + 64 + 16, the v1 bound.

- **0.9 teammates mode** (mode 2: kdfId 0, recipient slots, HPKE-wrapped key, Ed25519 signature)
  is no longer written or opened: the header parser rejects mode 2, so such a file is
  `invalidFile` before any key is derived.

**Reader order:**

1. Size ≤ `Limits.maxShareFileBytes`, magic, formatVersion: 1 → the v1 reader (§2); 2 →
   continue; any other → `invalidFile`.
2. headerLength 64, aeadId 1, flags 0, reserved zero, mode 1, kdfId 1, the v1 cost bounds,
   parallelism 1, recipientCount 0, size ≥ 64 + 16.
3. **Only then** key material (`inspect` touches none): Argon2id → GCM open.
4. Payload ≤ 16 MiB → JSON decoding and validation (§1, §1.4).

Every structural or cryptographic failure is `ShareError.invalidFile` ("Wrong passphrase or
damaged file").

**Known answers**: `Tests/SharingKitTests/Fixtures/file_v2_kat.json`, generated by
`Fixtures/kat/file_v2_kat.py --write file_v2_kat.json` (a venv with `cryptography`).

- Passphrase mode: key `0x42 × 32`, t = 3, m = 65536, salt `80..8f`, nonce `90..9b`, payload
  `{"schema":"io.fractalx.fxvault.share","schemaVersion":4}`. Swift reproduces the header and the
  whole 136-byte file byte for byte (`FxVaultFileV2KATTests`).
- The fixture also keeps the 441-byte 0.9 teammates file, which 1.0 must refuse before deriving a
  key (`aTeammatesFileFromZeroNineIsRefusedBeforeAnyKeyIsDerived`).

## 3. Passphrase

Six words from the EFF large wordlist minus the four hyphenated words (`drop-down felt-tip
t-shirt yo-yo`): 7,772 words, about 77.5 bits, drawn with `SystemRandomNumberGenerator`, joined
with `-`. The bundled list is verified by SHA-256 (`addd3553…996b903e`) before use. Input is
lowercased, split on non-letters, and must be exactly six listed words; errors report the word
count or the position of an unknown word, never the typed text.

## 5. Receiver merge (`ShareImportPlanner`)

Pure planner; VaultData's `ShareImporter` applies the plan in one transaction (re-encrypting
with the receiver's DEK under new row ids, setting `provenance = share` with the package id and
unverified sender name, and recording the package in `imported_share_packages`).

- **Blocked** when the repository is not imported, when its name does not match, or when the
  package has a `githubRepoId` that differs from the local `github_id` (including a local nil:
  a repository created locally and not yet pushed).
- **Replay warnings** (need confirmation): already imported, `createdAt` older than 7 days,
  `createdAt` older than local changes.
- **Item chips:** new, fillsMissingValue, valueNotIncluded, existsLocally (manifest preview),
  same / differs (payload only), otherKindExists (skip + warning), deletedLocally (forced skip).
- **Defaults:** add; fill; skip when the fingerprint is identical; **keep mine** when different
  (overwrite and overwrite-all are available); an item that only exists under the other kind is
  skipped with a warning.
- **Partial environments (v2):** no policy row; an existing environment keeps its policy and
  only the incoming items are planned. A missing one is created with GitHub's policy and
  patterns when GitHub lists it (synced, nothing pending; `ShareImporter`), otherwise with all
  branches (pending create). Only whole environments count for the `olderThanLocalChanges`
  replay warning.
- **Environments:** missing ones are created (pending unless GitHub already lists them). A
  different branch policy is its own row, defaulting to keep mine. Widening (anything → all,
  custom → protected, or a new pattern containing `*`, `?` or `[`) needs a second confirmation.

### 5.1 Receiver merge for bundles (`ShareBundlePlanner`, v0.9.0)

Pure, like the single-repository planner. The local state (`ShareBundleLocalStateModel`) has one
entry per incoming repository, keyed by owner and name fold keys: the local `RepoModel` (or nil),
its environments, items and GitHub listing, its destinations with items and keyed fingerprints,
and, for a repository missing from the vault, its `access` (importable with an account, not
visible, unreachable, unknown). It also lists the vault's folders with their item names, the
imported package ids and `now`. Destination values are compared with a separate
`ShareDestinationFingerprinter` bound to the local destination row.

| Repository | Status | Planned |
|---|---|---|
| In the vault, same name and `githubRepoId` | ✓ `inVault` | GitHub scopes by `ShareImportPlanner`, exactly as the schema 2 package `githubPackage(for:)` (same package id, link tokens dropped); destinations merged or created |
| Not in the vault, an account can import it | ⇣ `willImportFromGitHub(accountLogin)` | Destinations all created; VaultData imports the repository, then plans again |
| Not in the vault: not visible, unreachable or not checked | ✕ `noAccess(reason)` | Nothing; opening the same file again later imports it |
| In the vault but another repository (name or id) | ✕ `blocked(reason)` | Nothing (§5 block reasons) |

**Destinations.** A local destination of that repository with the same target key (`kv|<vault>`,
lowercase) is merged (`useExisting`); its stage stays as it is. Otherwise the destination is
created; Sync reaches it with the receiver's own `az login`. Items are matched by name, whatever their kind
(one name per destination):

| Incoming vs local | Chip | Default | Allowed |
|---|---|---|---|
| No local item | new | add | add, skip |
| No local item, no incoming value | valueNotIncluded | add without value (a variable is then skipped) | add without value, skip |
| Local tombstone | deletedLocally | skip | skip |
| Same name, other kind | otherKindExists | skip | skip |
| Incoming value missing | valueNotIncluded | skip | skip |
| Local value missing | fillsMissingValue | fill | fill, skip |
| Same fingerprint | same | skip | skip |
| Different | differs | keep mine | keep mine, overwrite |

Every destination write is pending; VaultData holds the rows the remote does not have (§6.1). A
local row updated after `createdAt` raises the bundle's `olderThanLocalChanges` warning.

**Folders.** A local folder with the same name (folder fold key) is merged, keeping its items
(`mergeInto(id, keepMine)`); otherwise a new folder with the sender's name is created. The
receiver can choose another new name, a replacing merge or skip.

**Links** (P9). `linkGroups` lists, for each token, the entries whose chosen action writes a row
(a GitHub item, a destination item, or a folder item a merge does not keep). A group is kept only
when at least two of its entries are written; VaultData gives each kept group one fresh `link_id`.
Rows the receiver keeps keep their own links.

**Replay.** The bundle has one package id. Already imported and older than 7 days are checked for
the whole bundle, even when every repository is skipped; local changes newer than the package are
checked per repository and destination. Any warning needs a confirmation.

**Apply** re-plans inside the write transaction and refuses with `.planOutdated` unless
`isSamePreview(as:)` holds (the comparison ignores the user's choices: item actions, policy
decisions and folder actions).

## 6. VaultData integration (`SharingRepository`)

SharingKit stays pure; VaultData's `SharingRepository` connects it to the vault.

- **Authorization.** `.fxvault` export needs `ReauthGate.authorizeShare(.fileExport, …)`. Each
  authorization is single-use and invalidated by any
  lock, unlock or key rotation (SECURITY-MODEL.md §6).
- **Export** (through 0.8; since 0.9.0 every file export is a bundle, §6.1). The selection
  (`ShareSelectionModel` item, environment, repository, or
  `subset(ShareSubsetModel)`: whole environments plus individual items, any combination) is built
  into a `SharePackageModel` with values decrypted inside `VaultSession.read`, sealed with a
  fresh 6-word passphrase by `FxVaultFileCodec(deriver: Argon2idSharingDeriver())` and written
  0600 by `SecureFileWriter`. The passphrase is returned once (`SecretBytes`) and never stored.
  Value-missing secrets travel by name only.
- **Import.** `readFile(at:)` checks the header before any passphrase is asked for;
  `openFile(_:passphrase:checkGitHub:)` normalizes the typed passphrase, decrypts, validates and
  plans against local state (keyed fingerprints, optional GitHub listing) into a
  `ShareImportDraftModel` that owns a copy of the values and wipes it on apply, discard or
  deinit. Every read failure is the single `.invalidFile` error.
- **Apply.** `apply(_:plan:confirmReplay:)` re-plans inside the write transaction and refuses
  with `.planOutdated` if the result differs from what the user saw. Rows are re-encrypted with
  the receiver's keys under new row ids, carry `provenance = share` (package id plus the
  unverified sender name) and the package id is recorded in `imported_share_packages`, all in
  one transaction. Replays need `confirmReplay`.
- **Implementation choices:** an incoming variable without a value is skipped and reported (a
  variable row must hold a value); an environment GitHub already lists is created as synced; an
  add GitHub already has is imported as synced.

### 6.1 Project shares in VaultData (v0.9.0)

`SharingRepository+ProjectShare.swift` connects the bundle (§1.4) and format 2 (§2.1) to the vault:
`ProjectShareExportBuilder` builds bundles, `ProjectSharePlanning` collects the planner's local
state, `ProjectShareImporter` applies a plan.

- **Selection.** `ShareBundleSelectionModel` holds, per repository, the repository level on or
  off, whole environments and single items, whole destinations and single destination items; plus
  folder ids, the chosen stages and a `ShareExpiryChoice` (1, 7 or 30 days, 7 by default).
  `stageOptions(repositoryIDs:)` lists every live environment name and destination stage,
  de-duplicated by fold key and flagged with `StageRisk.isProduction` (a word of the name, split on
  non-letters, is `prod`, `production`, `prd` or `live`). `selection(repositoryIDs:stages:…)`
  expands stages by fold key: the environment whose fold key equals the stage plus
  the destinations with that stage.
- **Production places** (Q13): an environment or a destination stage `StageRisk` flags.
  `previewBundle(_:)` lists them; an export that includes them needs the
  `.productionFileExport` authorization (1.0, B3b), else it throws `.productionNotAuthorized`
  before the authorization is consumed, and again on the bundle actually sealed.
- **Export** (`exportBundle(_:to:senderName:appVersion:authorization:existingFile:)`), in this
  order:
  1. the production rule;
  2. the single-use `ReauthGate` `.fileExport` authorization is consumed;
  3. values are decrypted inside one `VaultSession.read`; linked rows get one fresh lowercase UUID
     `link` per group with at least two selected members;
  4. sealing: `sealWithPassphrase` with a fresh 6-word passphrase (returned once, never stored);
  5. a `sent_shares` row (names only, DATABASE.md v14), then the file (0600, `SecureFileWriter`);
     a failed file write deletes that row again.

  The suggested name is `FX Vault share <yyyy-MM-dd>.fxvault` (`defaultFileName`): no repository
  or stage, because chats and mail show it. `sentShares()`, `observeSentShares()` and
  `deleteSentShare(_:)` serve Settings › Sharing.
- **Opening.** `inspectFile(at:)` accepts format 1 and 2 and never touches a passphrase or key
  (`ShareInspectedFileModel`: the bytes and `FxVaultFileInfo`).
  `openShareFile(_:passphrase:checkGitHub:)` opens the file with `openWithPassphrase`; the sender
  is the unverified name in the payload. `ShareDocumentCoder.open` dispatches: schemas 1–2 are
  planned exactly as before (`ShareImportDraftModel`), schema 3 becomes a `ShareFolderDraftModel`,
  schema 4 is checked for freshness and becomes a `ShareBundleDraftModel`.
- **Bundle planning.** GitHub's listing is read for each repository in the vault (with
  `checkGitHub`); every listing shares one map of variable row ids, so one keyed fingerprinter
  serves the whole bundle. A repository missing from the vault is checked with
  `ShareRepositoryAccessChecking.access(owner:name:)` (the app passes `CatalogShareRepositoryAccess`,
  through every logged-in gh account). Destination values are compared with each row's `value_fp`,
  after normalizing the incoming value. `importMissingRepositories(of:)` imports every ⇣
  repository outside any transaction and plans again, listing the imports that failed.
- **Apply** (`applyBundle(_:plan:confirmReplay:)`), one write transaction:
  1. re-plan, `.planOutdated` if the preview changed;
  2. per ✓ repository, the existing `ShareImporter` on `githubPackage(for:)`, without recording
     the package each time;
  3. destinations merged by target key or created; items through `DestinationItemWriter` (a
     secret without a value is inserted value-missing);
  4. folders created or merged (kind plus fold-key name, keep mine or replace) with
     `FolderItemWriter` in the same transaction;
  5. one fresh `link_id` per plan link group with at least two written rows, across the three
     item tables;
  6. `share_hold` = the package id, set after every value write, on the GitHub rows that would
     push (a pending add, a pending fill, an overwrite) and on every destination row written;
  7. one `imported_share_packages` row (`sender_device_id` stays NULL; 0.9 wrote it for a
     teammates file).

  Folder rows never sync and are never held. ⇣, ✕ and blocked repositories are skipped. The result
  names the first imported repository and the first stage, which the app opens (the environment
  of that stage, or the repository level).
- **Holds** (P8, `VaultData/Sync`). A held row is never in a Sync plan (GitHub or destination).
  Sync's review lists each held file (`SyncReviewModel.heldShares`, `HeldShareModel`): sender
  (verified only for a 0.9 teammates file), import date, places and names. Including a file
  (`startRun(…, includeHeld:)`, `DestinationSyncRepository.run(…, includeHeld:)`) releases every
  hold of that package in both tables in one transaction before planning; a file left out stays
  held and is offered again at the next Sync. Push on Next Sync on a held row
  (`ShareHoldRepository.releaseHold(itemIDs:)`) releases that row only. The user's own changes are
  never held: a delete, a GitHub-scope Revert or a typed value clears the row's hold; a rename or
  move keeps it, and so does a destination Revert, which cannot bring back the previous value. A
  new environment waits while all its live items are held; a renamed environment waits while any of
  its live items is held. Holds do not touch values, AADs or fingerprints.
- **Not held (residual).** Two GitHub changes from a file reach the next Sync's normal review
  without a hold, because `share_hold` exists only on items: an environment the file creates when
  not every live item in it is held (a whole environment whose items the receiver all skipped, or
  one the receiver added an item of their own to), and a branch policy the user chose to take from
  the file in the preview.

## 8. Compatibility between versions

| Feature | 1.0 opening it | Older versions opening a 1.0 file |
|---|---|---|
| `.fxvault` format 1, schemas 1–3 (0.1–0.8) | Opens as before | n/a |
| `.fxvault` format 2 passphrase, schema 4 (0.9, 1.0) | Opens | 0.9 opens it; 0.8 and older: "Wrong passphrase or damaged file" |
| `.fxvault` format 2 teammates (0.9) | Refused: "Wrong passphrase or damaged file" | n/a (1.0 never writes it) |
| `.fxvcard` teammate card (0.9) | Not a known file type | n/a |

- A folder file (schema 3) is rejected by 0.6 and older; a partial environment (schema 2) by
  0.1.x (§1.1).
- `schemaVersion` changes follow the lowest-version rule in §1.1.
