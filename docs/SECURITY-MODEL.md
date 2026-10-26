# FX Vault - Security model

How FX Vault protects GitHub Actions secrets and variables on a Mac (and, since v0.8.0, the
runtime secrets it sends to Azure Key Vault), what it defends against, and
what it does not. The design is `tasks/todo.md` §5 (destinations: R1–R12; project share files:
P1–P11); this document
describes the implementation (VaultCrypto, VaultStore, VaultData, DestinationKit and the app
shell). Related:
[ARCHITECTURE.md](ARCHITECTURE.md), [DATABASE.md](DATABASE.md), [API.md](API.md),
[SHARING-PROTOCOL.md](SHARING-PROTOCOL.md).

## 1. Key hierarchy

```
vault_id   16 random bytes (vaults row)
DEK        32 random bytes, dek_version starts at 1
K_field    HKDF-SHA256(DEK, salt: vault_id, info: "fxvault/v1/field-enc")      AES-256-GCM field key
K_fp       HKDF-SHA256(DEK, salt: vault_id, info: "fxvault/v1/fingerprint")    HMAC-SHA256 fingerprint key
kcv        HMAC-SHA256(DEK, "fxvault/v1/kcv")[0..<16]                          vaults.kcv, constant-time compare
K_pw       Argon2id13(NFC(password), salt 16 B, ops 3, 256 MiB)               wraps the DEK (password)
K_rec      HKDF-SHA256(recovery key 32 B, salt: vault_id, info: "fxvault/v1/kek/recovery")
Touch ID   the DEK in a data-protection keychain item (signed builds only, §5)
```

- The DEK is wrapped twice (`key_wraps`, 62 bytes: format, AEAD, nonce, ciphertext, tag). The
  wrap AAD binds the method, vault id, DEK version and KDF parameters.
- KDF parameters are checked **before** Argon2id runs (ops 2–10, 64 MiB–1 GiB, 16-byte salt);
  anything else is `VaultError.corrupted`, so a tampered row cannot make the app run an
  unbounded KDF. A GCM failure on the password wrap is `.wrongPassword`; a kcv mismatch after a
  successful unwrap is `.corrupted(.keyCheckMismatch)`.
- Only `UnlockedKeys` touches key material (no public `SymmetricKey`); `VaultKeyring` holds it
  and `lock()` drops it synchronously. Argon2id runs off the main actor (`@concurrent`).
- A new or changed master password must pass `PasswordStrength` (at least 12 characters and an
  estimated 60 bits). The package enforces it too (`PasswordPolicyError.tooWeak`), so no caller
  can skip the UI check.
- The recovery key is 56 Crockford Base32 characters (32 key bytes plus a 3-byte checksum),
  shown once in 14 groups of 4, confirmed by typing 2 random groups, and never stored.

## 2. Data at rest

- `vault.sqlite` lives in `~/Library/Application Support/FX Vault/` (0700; files 0600) with
  `secure_delete` on. The WAL is checkpointed (`TRUNCATE`) after every key write and on lock, so
  old wrapped keys do not linger.
- **Values** (`value_ct`, `synced_value_ct`) are AES-256-GCM blobs under K_field. The field AAD
  binds the table, column, row id, repository id, environment id, kind, the column's name and
  the DEK version, so moving a blob to another row, scope, kind or name fails decryption.
  Renames, moves and conversions re-seal the value; duplicates, imports and shares re-encrypt
  under new row ids.
- **Fingerprints** (`value_fp`, `synced_fp`) are `HMAC-SHA256(K_fp, row id ‖ value)`: change
  detection without decrypting, and no cross-row comparison.
- **Folders (v0.7.0):** `folder_items.value_ct` is AES-256-GCM under K_field with
  `FolderFieldAAD`: the field layout above with table `folder_items`, the folder id in the
  repository's place and no environment, so a folder blob never opens as a repository item (or
  in another folder, row, kind or name). `value_fp` is the row-bound fingerprint. Renames and
  kind changes re-seal; DEK rotation re-seals every folder value. Folder items live in their own
  tables, which no sync path reads: they reach GitHub only after the user copies them into a
  repository scope and syncs. Folder names are plaintext, like repository names.
- **Destinations (v0.8.0):** `destination_items.value_ct` is AES-256-GCM under K_field with
  `DestinationFieldAAD`: the field layout above with table `destination_items`, the destination
  id in the repository's place and no environment, so a destination blob never opens as a
  repository or folder item (or in another destination, row, kind or name). `value_fp` and
  `synced_fp` are row-bound fingerprints. A secret can have no value (`value_ct` NULL) until it
  is filled. DEK rotation re-seals every destination value and recomputes the fingerprints (a
  `synced_fp` that cannot be recomputed is cleared, so the item is pushed again). Key Vault
  access tokens are never stored (§10.4). Migration `v16_drop_runtime_providers` (1.0) deleted
  the Supabase and Vercel destinations and every sealed personal access token
  (`provider_connections`), then checkpointed the WAL; `retired_destinations` keeps their names
  only, until the user dismisses the notice.
- **Organizations (1.0):** `org_items.value_ct` is AES-256-GCM under K_field with
  `OrgFieldAAD`: the field layout above with table `org_items`, the organization id in the
  repository's place and no environment, so an organization blob never opens as a repository,
  folder or destination item. Secrets have no value (GitHub never returns one); variables are
  stored as read, with row-bound `value_fp` and `synced_fp`. DEK rotation re-seals every
  organization value and recomputes the fingerprints, clearing a `synced_fp` that no longer
  matches.
- **Project share files (v0.9.0):** `sent_shares` holds one row per exported file: package id,
  times, protection mode and a names-only summary (stages, places, item
  names), never a value, fingerprint or passphrase. `share_hold` on `config_items` and
  `destination_items` is the package id an imported row is held under (§10.5);
  `imported_share_packages.sender_device_id` names the verified sender of a 0.9 teammates file
  (1.0 leaves it NULL). All plaintext metadata. Migration `v15_drop_teammates` (1.0) dropped the
  0.9 device identity, teammates and shared-space tables, with their sealed keys.
- **Plaintext on disk:** names (repositories, environments, items, folders, destinations),
  GitHub ids, timestamps, branch patterns, the sync journal (names and row-bound push
  fingerprints, never values), `link_id` (which items are linked copies of each other, v0.4.1;
  groups may include folder items since v0.7.0 and destination items since v0.8.0) and
  preferences. Since v0.8.0 also each destination's target (`settings_json`: vault name and
  tenant) and stage, Key Vault's change markers (`remote_version`, `pre_write_version`) and the
  destination journal (names, change markers, row-bound fingerprints). Since 1.0 also a file
  secret's label (`file_detail`, v21), next to the item's name: the file name it came from, its
  line count and its encoding. It stays plaintext because the place's tables and notes read
  their rows from key-less observation streams, and because a sealed label would have to be
  re-sealed on every rename and move, which today touch only names. No group
  fingerprint is stored: whether linked copies hold the same value is computed when it is shown
  (decrypted in memory, compared in constant time, wiped).
- Repositories write ciphertext only through `VaultSession.write`, whose keys are checked
  against the stored `vaults` row, and decrypt only through `VaultSession.read`; a write commits
  only if no lock or rotation happened while it ran.

## 3. Rotation and recovery

`VaultManager.rotateDEK` (also run by "Change password" with the default "rotate the vault
key" option, and always by a recovery reset) is one transaction:

1. Generate DEK′ (`dek_version + 1`).
2. Re-encrypt every `value_ct` and `synced_value_ct` under the new AAD and recompute every
   fingerprint. A row that does not decrypt aborts the rotation with nothing changed.
3. Re-wrap for the password and for a **new** recovery key; store the new kcv.
4. Install the new keys as the last step inside the transaction, so no repository write can
   slip in under the old key.
5. After the commit: WAL checkpoint, then replace the Touch ID item (a failed replacement
   turns Touch ID off rather than leaving a stale key).

Notes:
- A row with a synced fingerprint but no synced ciphertext keeps a fingerprint recomputed from
  the current value when the two matched before; otherwise the fingerprint is cleared and the
  item is pushed again on the next Sync.
- **Backups made before a rotation** can still be opened with the password and recovery key that
  were valid then. Rotation protects new data from leaked old credentials, not old copies.
- A recovery reset works while locked, always rotates and shows the new recovery key; the app
  keeps the lock screen until the user confirms they saved it. If the vault locks before a new
  recovery key is confirmed, the key is wiped from the screen and a reminder asks for a new one.

## 4. Lock

**Phase A** (synchronous, before any suspension point; `AppViewModel.lock(trigger:)`):
`VaultKeyring.lock()`, the token purge hook (`GHTokenCache`), `LAContext.invalidate()`, then
`phase = .locked`, which tears down every screen that showed values. Any unlock, rotation or
repository write that was in flight fails with `.locked` and installs or commits nothing.

**Phase B** (after Phase A): lock observers dismiss sheets and wipe on-screen key material, the
clipboard is cleared if FX Vault still owns it, a running modal panel is aborted, the database
is checkpointed. The sync and drift stages add: cancel the active sync run
(`SyncRunHandle.cancel()`) and `DriftRepository.reset()`. Since v0.8.0 it also drops the cached
Key Vault tokens (`ShellResolvingAzureTokens.reset()`; each copy is zeroed when its last
reference goes).

**Triggers:** system sleep, display sleep, session resign-active, protected data becoming
unavailable, screen lock, screensaver start, main-window close, manual lock (⌃⌘L), and
inactivity (default 5 minutes, checked every 15 s on a timer that ignores run-loop modes,
measured on a monotonic clock). A `SyncActivityAssertion` suspends only the inactivity rule
during a sync run, never the other triggers.

## 5. Touch ID (signed builds only)

Touch ID needs the keychain access group entitlement, which only the Developer ID-signed release
with its provisioning profile has (D14). Ad-hoc builds disable the toggle ("Touch ID requires
the official signed release.") and every keychain call refuses with `.unsignedBuild`.

- The DEK is stored in a data-protection keychain item: service `io.fractalx.fxvault.dek`
  (`io.fractalx.fxvault.dek.dev` in Debug builds, whose vault is `FX Vault Dev`, so a signed
  Debug build never touches the release vault's item; since v0.1.2 Debug builds are the
  separate app `io.fractalx.fxvault.dev` and stay ad-hoc unless given their own profile), account `touchid-v1-<vault_id hex>`, `WhenPasscodeSetThisDeviceOnly` with
  `.biometryCurrentSet`, not synchronizable. Enabling it requires the master password and first
  deletes items of other vaults (orphans).
- Each unlock uses a fresh `LAContext` with no reuse window; the prompt strings come from the
  app. The returned key must pass the kcv check, otherwise the item is deleted.
- **The master password is still required** after a restart (boot session differs, or cannot be
  read: fail closed), when the last password unlock is older than 14 days (a clock moved
  backwards also requires it), and after a fingerprint enrollment change (the item is deleted and
  `biometry_state_hash` cleared, at the latest by the next password unlock). A Touch ID unlock
  never refreshes the 14-day timer; password unlocks, password re-authentication, password
  change, recovery reset and enabling or disabling Touch ID do. The lock screen names the reason
  under the password field ("Password required: After a restart", "Every 14 days",
  "Fingerprints changed").
- Errors: missing or invalidated item (`errSecItemNotFound`) → Touch ID turned off (offered again
  after the password unlock); cancel → nothing shown; the prompt's fallback button and a finger
  Touch ID did not recognize (`errSecAuthFailed` without lockout) →
  `VaultError.passwordFallbackRequested` (focus the password field; the item stays); lockout is
  checked first and never deletes the item.
- **Discoverability (v0.1.1).** After a password unlock on a signed build where Touch ID can run
  and is off, a one-time sheet offers "Unlock FX Vault with Touch ID". Enable runs the normal
  enable flow with the password just typed, which the offer holds only until it is answered or
  the vault locks; Not Now (and any change in Settings › Security) is remembered in UserDefaults
  (`preferences.touchIDOfferAnswered`). Unsigned builds never show it.
- **Keychain queries** (`KeychainManager`, checked against Apple's data-protection keychain rules
  in v0.1.1): every query sets `kSecUseDataProtectionKeychain` and the full entitled access group
  (`<team id>.io.fractalx.fxvault`); the protection class lives only in the `SecAccessControl`
  (never `kSecAttrAccessible` next to it); the read passes a fresh `LAContext` through
  `kSecUseAuthenticationContext` with the prompt as `localizedReason`; presence checks and
  listings ask for attributes only, through a context with `interactionNotAllowed`.
- **`--diagnose`.** `"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose` prints JSON
  (version, build, signed with an access group, the group, biometry availability or reason) and
  adds then deletes a probe item with the exact Touch ID attributes under the service
  `io.fractalx.fxvault.diagnose` (random account, 16 random bytes), after deleting any probe item
  an earlier run left in the group. It runs before any window,
  vault or database opens, never reads the item (no prompt) and prints no secret; unsigned builds
  skip the probe. Since v0.3.1 it also prints a `gh` section (§8): it runs the shell probe,
  `gh --version` of each trusted candidate and `gh auth status --json hosts` (no token is fetched
  or printed) and reports paths, versions, owner names, the **names** of the token and config
  variables the shell sets, and account logins, states, token sources and scopes. The setup
  screen's **Copy Diagnostics** copies the same report as plain text.
- Disabling Touch ID, changing the password, rotating the key, a new recovery key and resetting
  the vault accept **only** the master password (`ReauthGate.authorizeWithPassword`).

## 6. Re-authentication (D30)

`.env` export (also of a folder, v0.7.0, or a destination, v0.8.0), Copy All (1.0: a place's
values as `.env` text on the clipboard, concealed and cleared after 30 s) and `.fxvault` export
(`.fileExport`; since v0.9.0 a project bundle, with a passphrase) require a fresh Touch ID or
master-password check through `ReauthGate` (never `.deviceOwnerAuthentication`, which would accept the macOS
login password). The result is a single-use authorization (`EnvExportAuthorizationModel`,
`ShareAuthorizationModel`) bound to the session and its key generation: a lock, unlock or
rotation in between invalidates it, and an authorization for one purpose cannot be used for
another.

Reveal in a place's notes (1.0 B9, `ReauthPurpose.reveal`) asks the same check for one secret.
Its `NotesRevealAuthorization` carries no session binding (`isUsable` is always true): the model
takes it and decrypts in the same main-actor turn the check returns in, and only for the request
still waiting for that check (a Cancel, another scope, a lock or a newer request drops it);
decrypting fails while the vault is locked. The revealed value is not selectable, so ⌘C,
Copy and Services can't put it on the clipboard around `ClipboardManager`.

## 7. Values in use

- `SecretBytes` holds values in memory: lock-protected, wiped on `wipe()` and `deinit`,
  redacted in every textual representation, constant-time comparison.
- Values are decrypted only to reveal, copy, edit, push, export or share. A push goes from
  decryption to gh's stdin pipe, which is closed, and the buffer is wiped.
- **Copying items (v0.4.0; any repository and linked since v0.4.1):** ⌘C on the detail table
  keeps the selected items in the app (by id in `ClipboardManager`, app-wide, dropped on lock and
  quit) and puts only their names on the pasteboard (this Mac only, Transient and source markers,
  not concealed: names are not values). ⌘V in another scope of any repository of the vault, or
  Copy To, copies them inside the vault: each value is decrypted and re-encrypted for its new
  row in one transaction and never reaches the pasteboard. The target must be editable by its
  own repository's account. FX Vault tells its own copy from other text by `changeCount` only,
  without reading the pasteboard. "Also update linked copies" in the item editor writes the
  new value to the checked copies the same way (one transaction across their repositories); a
  copy the account cannot change is never written. Folders (v0.7.0) take part the same way: a
  copy into a folder is saved at once, a copy from a folder into a scope is a pending change for
  the next Sync, and a received copy of a folder never changes a repository by itself.
  Destinations (v0.8.0) too: a copy into a destination is a pending change for its next Sync.
- **Destinations (v0.8.0):** a push goes from decryption into a JSON body written straight into
  `SecretBytes` (`JSONBodyWriter`: the value never becomes a Swift `String`), handed to
  URLSession as a private copy that is zeroed when Foundation releases it, and wiped after the
  last attempt. Answers are read into a `SecretByteBuffer` (at most 16 MiB) and parsed by the
  secret JSON scanner (`SecretJSONDocument`), which unescapes a value into new `SecretBytes`
  and never runs `JSONDecoder` over a provider answer; bodies are wiped once read. A value read
  from a provider (Use Remote, the import after Add Destination) is encrypted for its row in the
  write that records it and wiped. Values are decrypted for a destination only to be sent or to
  check a public name (§10.4).
- **Clipboard:** current host only, Concealed / Transient / source markers, cleared after 30 s,
  on lock and on quit, but only if FX Vault still owns it. The pasteboard is never read in the
  background: only a user paste (⌘V in the detail column, ⌘V or the Paste button in the import
  editor) hands text to the `.env` import sheet. The pasted text travels as `SecretBytes` in an
  `EnvPasteBuffer` (identity-hashed, redacted description), stays in the import editor while the
  user edits it, and is cleared after the import, on close and on lock; it is never logged.
  Lines of an unquoted multi-line PEM value are skipped with one error (never turned into
  names, which are plaintext on GitHub), parse issues never echo a line without `=`, and rows
  whose key had characters replaced are not pre-selected.
- **Entry:** `SecretValueEditor` turns off substitutions, spelling, completion, undo and Writing
  Tools, enables secure event input while focused, and strips trailing CR/LF with a notice (D32).
- **Display:** revealed cells re-mask after 30 s, when the app resigns active, on a scope change
  and on lock; windows are not restorable; recovery-key and passphrase views, the item editors
  and the `.env` import sheet are excluded from screen capture. A Reveal in a place's notes
  (1.0) asks Touch ID or the master password first, and the main window is excluded from screen
  capture while any value shows. Sheets that hold typed or
  decrypted values (`LockObserving`) wipe them on lock and on close.
- **File secrets (1.0):** Choose… or a drop on a place reads one regular file (no folder, pipe
  or device; at most twice the 48,000-byte limit) with `open`/`read` straight into
  `SecretBytes`, never through `Data` or `String`; Base64 is written into a new buffer the same
  way. The sheet wipes the bytes after Add, on close and on lock. The file itself is left where
  it is: FX Vault never deletes or changes it. Logs carry counts only, never the file name, the
  same as item names.
- **Files:** `.env` and `.fxvault` exports are written 0600 from creation (exclusive create, no
  symlinks, `F_FULLFSYNC`, atomic rename), with iCloud-sync and git-exposure warnings and a
  `.gitignore` offer.
- **Share staging:** a `.fxvault` export is first written (ciphertext only) to
  `$TMPDIR/io.fractalx.fxvault.shares/<uuid>/` (folder 0700, file 0600), then copied by Save…
  (written again 0600) or handed to AirDrop (Send with AirDrop or Share…). The staging folder is removed when the sheet closes
  or when a running AirDrop hand-off ends.

## 8. Child processes

gh, git and ssh run with absolute executables, an argv array (no shell), an exact environment
allowlist, an empty working directory and closed descriptors. Values and JSON bodies go only
through stdin; forbidden flags are rejected by the builders. gh binaries are accepted only from
non-writable locations owned by root or the user, or by one other user the user explicitly
trusted for that path (below). Details: [API.md](API.md).

- **Shell probe (A2).** The only shell FX Vault runs is the user's own login shell, with a
  constant script, an identity-only environment and empty stdin, for 5 s per attempt. Since
  v0.3.1 it starts as an interactive login shell first (it reads `~/.zshrc` like Terminal), then
  as a login shell. It reports the gh its PATH finds and whether `GH_TOKEN`, `GITHUB_TOKEN`,
  `GH_CONFIG_DIR`, `XDG_CONFIG_HOME` and `GH_HOST` are set: sh's `[ -n ]` builtin tests the
  values, which never reach stdout, an argv, a log or a file; the parser keeps only names. FX Vault
  still never passes `GH_TOKEN` or `GITHUB_TOKEN` to gh (its own `GH_TOKEN` is the account token
  it fetched, for write commands only).
- **Which gh.** The gh the shell finds comes first, then fixed folders; the first gh that exists
  decides, and FX Vault never runs another one when that one is rejected, so it cannot silently
  run a different (older or planted) gh than Terminal. A rejected gh is never executed, not even
  for `--version`.
- **Consented trust (v0.3.1).** When the only problem is that one other non-root user owns the
  gh file or its folders (typically another administrator installed Homebrew), the setup screen
  names that user and explains that anyone who can sign in as them could replace gh and see the
  values FX Vault sends to it. **Trust This gh** stores `{path, owner uid}` in UserDefaults; the
  locator then accepts exactly that path while every foreign owner is still that uid and nothing
  is writable by others (world, or a group other than `wheel` / `admin`). Writable binaries and
  binaries owned by several other users are never offered. A changed owner asks again;
  Settings › Advanced lists the trust with Revoke.
- **`az` (v0.8.0).** The Azure CLI is run for three read-only commands only (`AzureCLIRunner`):
  `az account get-access-token` for Key Vault, and since 1.0 `az account list` and
  `az keyvault list` for discovery ([API.md](API.md) §G.1), through the same runner rules. `AzureCLILocator`
  searches the login shell's PATH, then `/opt/homebrew/bin` and `/usr/local/bin`; the first `az`
  that exists decides and must pass gh's trust check (`GHLocator.evaluate`), re-run before every
  `az` run. There is no consented trust: an `az` owned by another user is refused
  (`azUntrusted`). Its environment is its own exact allowlist (HOME, the shell's PATH, LANG,
  TMPDIR, telemetry, color and progress output off), stdin is empty, and no value ever reaches
  it. The token is read from stdout with the secret JSON scanner and stdout is wiped; stderr is
  classified only after JWTs and GitHub token patterns are redacted, and never logged.

## 9. Sync integrity

- Every gh write is journaled `in_flight` before it starts; its outcome and the row bookkeeping
  commit together. Timeouts, server errors and crashes are reconciled by re-listing GitHub
  (never by the local clock); a repository create is never retried blindly. A reconciled secret
  push records the fingerprints journaled with it, never the value as it is later, and a guided
  rename's interrupted copies only close their journal rows (the rename runs again).
- A branch-policy change is not sent to an environment that GitHub lists with other protection
  rules (reviewers, wait timer, app rules): C2 sends only the policy, and whether GitHub keeps
  the omitted rules is unverified (Q6). Sync blocks it; the user changes the policy on GitHub.
- Optimistic concurrency (D27): each scope is re-listed right before our writes, and a change
  whose base moved on GitHub is blocked as "changed on GitHub" for Drift review.
- A write is confirmed by re-listing: a secret by a changed `updatedAt`, a variable by its value
  fingerprint. Unconfirmed writes stay pending and are retried; after 3 failed checks a secret is
  force-pushed on the next Sync.
- Destinations (v0.8.0), after GitHub's writes: each write is journaled `in_flight` in
  `destination_journal` (with the item's change marker before the write and the fingerprint of
  the value being sent) before it is sent; a write that got no answer ends `indeterminate`. The
  next review settles unfinished rows by listing the destination: a set whose item now has
  another marker counts as done with the journaled fingerprint as synced (a value edited since
  stays a change to push), a delete
  whose item is gone as done, the rest as failed. Each destination is listed right before its
  writes; an update or delete whose item changed remotely since the last sync (Key Vault
  `attributes.updated`) and an add whose name the destination already has are blocked for
  Refresh. A write is confirmed by one re-list (a new change marker); an unconfirmed write is
  pushed again on the next Sync.
  Deletions are sent only after the user confirms them in the Sync sheet.

## 10. Threat model

**In scope**
- A stolen or copied disk while the vault is locked.
- Other local users: no values in argv, files 0600, folder 0700.
- Shoulder surfing and screen sharing of revealed values.
- Clipboard leaks.
- Accidental `.env` commits and iCloud upload of exports.
- A person at an unlocked Mac using the recovery-key, export or share paths (ReauthGate).
- An intercepted `.fxvault` file (Argon2id plus a 6-word, 77.5-bit passphrase), including one sent
  through AirDrop, a chat or mail on purpose (§10.5).
- Malicious share packages (validator, merge defaults, replay warnings; since v0.9.0 held
  imports, §10.5). A package that shares only some items of an environment carries no branch
  policy and can never change the receiver's policy (SHARING-PROTOCOL.md §1.2).
- Partial or indeterminate sync results (journal, reconciliation, verification).
- Leaked old credentials combined with new data (DEK rotation).

**Out of scope**
- Malware or root running as the user, including same-user write access to the vault or to
  `~/.zshrc`, `~/.ssh/config` and `PATH` while the vault is locked: such code can already
  replace gh or git. The field AAD still makes kind and scope tampering fail decryption.
- A compromised gh token or GitHub account.
- A compromised Azure account or `az` login, or Azure itself (§10.4).
- Keyloggers.
- A compromised build machine.

§10.1–§10.3 (Nearby Chat, teammates nearby, shared spaces) were removed in 1.0 with the
features; the later numbers are kept because other documents cite them.

### 10.4 Runtime destinations (v0.8.0, experimental)

Endpoints and commands: [API.md](API.md) §G.

**Assets.** The values FX Vault sends to and reads from Azure Key Vault, and the Key Vault access
tokens `az` issues. (1.0 removed the Supabase and Vercel destinations and their tokens.)

**Network.** v0.8.0 is the first FX Vault code that makes HTTP requests itself: one
`URLSessionTransport`. Its session is ephemeral with no URL cache, no cookie storage (cookies are
neither sent nor accepted), no credential storage and no extra headers;
`Timeouts.destinationRequest` (30 s) applies to each request and to the whole transfer; TLS 1.2
or later with the system's certificate validation. Every request goes to an allowlisted host
(`DestinationHostPolicy`): `https` only, no user or password in the URL, port 443, and the host
exactly `<vault>.vault.azure.net` with a valid vault name
(no other subdomain, trailing dot or IP address). The response URL is checked again, redirects
are never followed (a 3xx is `disallowedHost`), and a Key Vault `nextLink` must stay on the
vault's host. URLs are built from validated, percent-encoded segments (`ProviderURL`, the D29
rules), so a name or id cannot change a request's shape. Values travel only in bodies and tokens
only in `Authorization`; neither ever goes into a URL or another header, and header values with
line breaks are refused. An answer larger than 16 MiB, or a listing longer than 400 pages, stops
with `responseTooLarge`. Logs carry the provider, the method, the status and a value-free error
code, never a URL, header, body, name or token; provider error messages are never kept, only a
short identifier code.

**Tokens.** Key Vault uses the user's `az login` (§8): `az account get-access-token --resource https://vault.azure.net
[--tenant <id>]` gives a short-lived token that lives only in memory, per tenant, until 5 minutes
before it expires; it is fetched again once after a 401 and dropped on lock (§4). FX Vault never
sees the Azure refresh token or the user's Azure credentials.

| Threat | Defense |
|---|---|
| A value or token sent to another host | The host allowlist before sending and on the response URL, no redirects, `nextLink` on the same vault only, validated and percent-encoded URL segments, a validated target (vault name, tenant) before any request exists. |
| Eavesdropping on the network | TLS 1.2 or later with the system's certificate validation. Nothing is cached or stored by URLSession (ephemeral session, no cookies, no credential storage). |
| Overwriting a change made in the provider | Each destination is listed right before its writes; an item whose change marker moved since the last sync, or a new name the provider already has, is blocked until Refresh resolves it (Keep Mine or Use Remote, which lists again and refuses a finding that changed). |
| Losing data in the provider | Deletions are sent only after the user confirms them in the Sync sheet. Key Vault deletes are soft deletes and FX Vault never purges; a soft-deleted name is recovered before it is written again. Removing a destination deletes nothing remotely, and neither did the 1.0 migration that removed the Supabase and Vercel destinations. Items FX Vault cannot manage (Key Vault managed or disabled secrets; names that are not valid FX Vault names) are listed with the reason and never written. |
| An interrupted Sync | `destination_journal` and reconciliation by listing (§9). |
| A planted `az` | gh's trust rules without consented trust, checked again before each run (§8). |
| Values left in memory | Bodies and answers stay in `SecretBytes`; the secret JSON scanner never turns a value into a `String` (§7). |

**Residual risks:** §11 (destinations).

### 10.5 Project share files (v0.9.0)

Formats: [SHARING-PROTOCOL.md](SHARING-PROTOCOL.md) §1.4 (bundle), §2.1 (`.fxvault` format 2),
§6.1 (VaultData).

**Assets.** The values of the repositories, environments, destinations and folders a file
carries; who sent it and to whom; the receiver's GitHub scopes and runtime providers, which an
import must not change by itself.

**What a file reveals.** A `.fxvault` file is made to be sent through chats and mail, so it is
assumed public. Without the key it shows only the header (format 2, the protection mode, the KDF
cost, the salt and nonce) and its size. Repository, stage, item and
sender names, the expiry and every value are inside the ciphertext. The default file name is
`FX Vault share <date>.fxvault`, without repository or stage names. `az` sessions, GitHub
accounts, SSH aliases and value hashes never enter a bundle. A 0.9 file's Supabase and Vercel
destinations are dropped on opening; the preview names them.

**Protections.**
- **Passphrase only.** Argon2id (t = 3, 64 MiB) over a fresh 6-word EFF passphrase (about 77.5
  bits), shown once and never stored, to be sent another way than the file. The sender's name is
  unverified. A 0.9 teammates file (mode 2) is refused as "Wrong passphrase or damaged file".
- **Production needs its own confirmation** (1.0, B3b): production stages are listed unchecked.
  A selection with a production environment or destination stage (`StageRisk`) needs the
  `.productionFileExport` authorization, else it is refused (`productionNotAuthorized`) before
  the re-authentication is used, and the bundle sealed is checked again. Checking production
  asks for Touch ID; without it, Create asks for the master password with a production message.
- **Re-authentication.** Exporting uses a single-use `.fileExport` or `.productionFileExport`
  authorization (§6), consumed after the production check and before any value is decrypted.
- **Expiry.** The sender picks 1, 7 (default) or 30 days. `expiresAt` is inside the ciphertext
  and FX Vault refuses an expired file (10-minute skew). This is
  enforced by the app, not by the cryptography: anyone with the passphrase and their own software
  could still decrypt a passphrase file after its expiry. The copy says so.
- **Opening never changes a remote.** Every imported row the remote does not have is held
  (`share_hold` = the package id): it is in no Sync plan, GitHub or destination, until the user
  includes that file in Sync's From Files review (one file at a time, the sender shown) or releases the row with Push on Next Sync. A file left out is offered again at
  every Sync. A new environment waits while all its live items are held; a renamed environment
  waits while any is held, because a rename copies every item. Destinations the file creates are
  reached with the receiver's own `az login`. The user's own delete, GitHub-scope
  Revert or typed value releases a row (they are not the file's changes); a rename or move keeps it.
- **Sent log.** Each export writes a `sent_shares` row: time, expiry, mode and the names it
  carried, never a value, fingerprint or passphrase. Settings › Sharing lists
  them with what to rotate if a file leaks.

| Threat | Defense |
|---|---|
| A file found in a chat, mailbox, AirDrop folder or backup | Argon2id plus 77.5 bits, with the words sent another way. Names, values and the sender are encrypted. |
| A file kept and opened long after | `expiresAt`, enforced by FX Vault (above); rotation for anything that leaked; the sent log lists what each file carried. |
| A forged or altered file | AES-GCM over everything after the header with the header as AAD. Every failure reads "Wrong passphrase or damaged file". Anyone with the passphrase can re-seal a file under any sender name: the name is a label, not an identity. |
| A malicious bundle | `ShareBundleValidator` (names, provider rules, limits, link tokens, expiry), the merge defaults (keep mine on differences, nothing deleted), replay warnings, and holds: nothing reaches GitHub or a provider without the receiver including the file. |
| Production values handed to a third party | Production is unchecked by default and needs its own Touch ID or password confirmation (`productionNotAuthorized` otherwise), checked before the authorization is used and again on the sealed bundle. |
| A leaked file exposing provider accounts | `az` sessions are never read by the exporter; the receiver reaches a created destination with their own `az login`. |
**Residual risks:** §11 (project share files).


## 11. Residual risks

- `GH_TOKEN` is visible to same-user processes while gh runs.
- Repository, environment and item **names** appear in gh's argv while it runs, visible to every
  local user; names and metadata are plaintext on disk.
- Swift `String` copies cannot be wiped reliably (JSON decoding of `gh variable list`, the cell
  being revealed or edited, Foundation coders in sharing).
- Screen-lock detection is best effort.
- Ad-hoc builds have no Touch ID and unstable privacy (TCC) grants.
- We trust the gh and git binaries we resolve. gh receives secret **and** variable plaintext on
  stdin and seals secrets itself, so a replaced gh binary could read values.
- **Accepted, user-consented: a gh owned by another user** (v0.3.1). After **Trust This gh**,
  the owner of that gh (and anyone who can act as that account, for example with its password or
  an administrator who can become it) could replace the binary between two checks and read every
  value FX Vault pushes, and every token FX Vault passes to it. FX Vault accepts this only after
  the user's explicit consent for that exact path and owner, re-checks ownership and write
  permissions before each detection, and keeps the consent visible and revocable in
  Settings › Advanced. The safer fix is a gh the user owns (reinstall, or the gh path override).
- The shell probe runs the user's interactive start-up files (`~/.zshrc`), as Terminal does.
  Code there already runs as the user (out of scope, §10); a start-up file that waits for input
  or never finishes costs at most the 5 s timeout per attempt before the login-shell fallback.
- Secret verification accepts a write as ours when `updatedAt` changed from the pre-write value.
  A write by someone else between a scope's pre-write re-list and its verification re-list is
  either silently overwritten (before our write; `gh secret set` is unconditional) or accepted
  as ours (after it). Throttling and verification retries can stretch this window to minutes;
  re-listing right before the writes and verifying right after keep it as short as possible.
- Pattern reconciliation deletes every GitHub branch pattern that is not wanted locally,
  including one a teammate just added.
- Values lose trailing CR/LF (D32); the user is told on entry.
- Pending-verification miss counts live in memory, so a relaunch restarts the count before a
  secret is force-pushed.
- **Destinations (v0.8.0, experimental).** The `az` token path ran live on 2026-10-16; the Key
  Vault data plane is tested only against fixtures and fakes so far. The opt-in suite
  `Tests/VaultDataTests/Live/LiveDestinationTests.swift` covers it against a throwaway vault.
- What Key Vault keeps is outside FX Vault's control: every version of a secret and soft-deleted
  secrets for the vault's retention period. Deleting a value in FX Vault or in the vault does not
  revoke it: rotate it. Supabase and Vercel tokens a 0.8 or 0.9 vault held are deleted from the
  vault by v16 but stay valid at the provider until the user revokes them.
- `az` keeps its own token cache and refresh tokens (`~/.azure`), outside FX Vault's protection;
  any process that can run `az` as the user gets the same Key Vault access. Only the `az` file
  is checked (§8): Homebrew's `az` is a script that starts Homebrew's Python and its packages,
  which are trusted as installed.
- The bearer token becomes a Swift `String` in the `URLRequest`'s `Authorization` header, and
  URLSession and the network stack keep their own copies of bodies and answers; none of these
  can be wiped.
- No certificate pinning: a root certificate the user or a configuration profile trusts can
  intercept destination traffic, as for any app that uses the system trust store.
- **Project share files (v0.9.0).**
  - A file cannot be revoked once sent. Expiry is enforced by FX Vault, not the cryptography: a
    passphrase file stays readable to anyone with the words and their own software. Rotate what a
    leaked file carried (Settings › Sharing lists it).
  - The header shows the protection mode; the file size hints at how much it carries.
  - Whoever received a file keeps its values; nothing takes them back. Rotate what must stop
    working for them.
  - Two GitHub changes from a file are not held, because holds exist only on items: an environment
    the file creates when not every live item in it is held, and a branch policy the receiver chose
    to take from the file in the preview. Both appear in Sync's normal review.
  - A destination Revert keeps a held row held: it cannot bring back the previous value, so the row
    still carries the file's value until it is included or released.
  - Pending counts in the toolbar and sidebar (`pendingSummary`, a destination's `pendingCount`)
    include held rows: they show what there is to review, not what the next run sends.
  - The sent log (names, dates) and the import records (sender name, sender device id)
    are plaintext metadata at rest, like repository and item names.
  - The production check reads environment and destination stages only: a folder that holds
    copies of production values (linked or not) is shared like any folder. Folders have no stage.
  - Sealing and opening decode the payload with Foundation coders, so values pass through Swift
    `String`s that cannot be wiped (as for every share).
- The Keychain status codes for the Touch ID fallback button, lockout and an enrollment-
  invalidated item follow Apple's documentation and still need confirmation on a signed build
  (RELEASING.md manual checklist). Since v0.1.1 an unexpected `errSecAuthFailed` can no longer
  delete the item (it only focuses the password field), and an enrollment change is also caught
  from the biometry state hash, so a wrong guess costs a password entry, not Touch ID.
