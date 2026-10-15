# FX Vault - Security model

How FX Vault protects GitHub Actions secrets and variables on a Mac, what it defends against,
and what it does not. The design is `tasks/todo.md` §5; this document describes the
implementation (VaultCrypto, VaultStore, VaultData and the app shell). Related:
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
- **Plaintext on disk:** names (repositories, environments, items), GitHub ids, timestamps,
  branch patterns, the sync journal (names and row-bound push fingerprints, never values) and preferences.
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
is checkpointed. The sync, drift and nearby stages add: cancel the active sync run
(`SyncRunHandle.cancel()`), `DriftRepository.reset()`, cancel nearby sessions.

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
  Debug build never touches the release vault's item), account `touchid-v1-<vault_id hex>`, `WhenPasscodeSetThisDeviceOnly` with
  `.biometryCurrentSet`, not synchronizable. Enabling it requires the master password and first
  deletes items of other vaults (orphans).
- Each unlock uses a fresh `LAContext` with no reuse window; the prompt strings come from the
  app. The returned key must pass the kcv check, otherwise the item is deleted.
- **The master password is still required** after a restart (boot session differs, or cannot be
  read: fail closed), when the last password unlock is older than 14 days (a clock moved
  backwards also requires it), and after a fingerprint enrollment change (the item is deleted and
  `biometry_state_hash` cleared). A Touch ID unlock never refreshes the 14-day timer; password
  unlocks, password re-authentication, password change, recovery reset and enabling or disabling
  Touch ID do.
- Errors: missing or invalidated item → Touch ID turned off (offer to re-enable after a password
  unlock); cancel → nothing shown; the prompt's fallback button →
  `VaultError.passwordFallbackRequested` (focus the password field); lockout is checked first and
  never deletes the item.
- Disabling Touch ID, changing the password, rotating the key, a new recovery key and resetting
  the vault accept **only** the master password (`ReauthGate.authorizeWithPassword`).

## 6. Re-authentication (D30)

`.env` export, `.fxvault` export and nearby send require a fresh Touch ID or master-password
check through `ReauthGate` (never `.deviceOwnerAuthentication`, which would accept the macOS
login password). The result is a single-use authorization (`EnvExportAuthorizationModel`,
`ShareAuthorizationModel`) bound to the session and its key generation: a lock, unlock or
rotation in between invalidates it, and an authorization for one purpose cannot be used for
another.

## 7. Values in use

- `SecretBytes` holds values in memory: lock-protected, wiped on `wipe()` and `deinit`,
  redacted in every textual representation, constant-time comparison.
- Values are decrypted only to reveal, copy, edit, push, export or share. A push goes from
  decryption to gh's stdin pipe, which is closed, and the buffer is wiped.
- **Clipboard:** current host only, Concealed / Transient / source markers, cleared after 30 s,
  on lock and on quit, but only if FX Vault still owns it; the pasteboard is never read.
- **Entry:** `SecretValueEditor` turns off substitutions, spelling, completion, undo and Writing
  Tools, enables secure event input while focused, and strips trailing CR/LF with a notice (D32).
- **Display:** revealed cells re-mask after 30 s, when the app resigns active, on a scope change
  and on lock; windows are not restorable; recovery-key and passphrase views, the item editors
  and the `.env` import sheet are excluded from screen capture. Sheets that hold typed or
  decrypted values (`LockObserving`) wipe them on lock and on close.
- **Files:** `.env` and `.fxvault` exports are written 0600 from creation (exclusive create, no
  symlinks, `F_FULLFSYNC`, atomic rename), with iCloud-sync and git-exposure warnings and a
  `.gitignore` offer.
- **Share staging:** a `.fxvault` export is first written (ciphertext only) to
  `$TMPDIR/io.fractalx.fxvault.shares/<uuid>/` (folder 0700, file 0600), then copied by Save…
  (written again 0600) or handed to AirDrop. The staging folder is removed when the sheet closes
  or when a running AirDrop hand-off ends.

## 8. Child processes

gh, git and ssh run with absolute executables, an argv array (no shell), an exact environment
allowlist, an empty working directory and closed descriptors. Values and JSON bodies go only
through stdin; forbidden flags are rejected by the builders. gh binaries are accepted only from
non-writable locations owned by root or the user. Details: [API.md](API.md).

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

## 10. Threat model

**In scope**
- A stolen or copied disk while the vault is locked.
- Other local users: no values in argv, files 0600, folder 0700.
- Shoulder surfing and screen sharing of revealed values.
- Clipboard leaks.
- Accidental `.env` commits and iCloud upload of exports.
- A person at an unlocked Mac using the recovery-key, export or share paths (ReauthGate).
- A man in the middle on the local network during nearby sharing (commit-reveal SAS).
- An intercepted `.fxvault` file (Argon2id plus a 6-word, 77.5-bit passphrase).
- Malicious share packages (validator, merge defaults, replay warnings).
- Partial or indeterminate sync results (journal, reconciliation, verification).
- Leaked old credentials combined with new data (DEK rotation).

**Out of scope**
- Malware or root running as the user, including same-user write access to the vault or to
  `~/.zshrc`, `~/.ssh/config` and `PATH` while the vault is locked: such code can already
  replace gh or git. The field AAD still makes kind and scope tampering fail decryption.
- A compromised gh token or GitHub account.
- Keyloggers.
- A compromised build machine.

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
- Nearby HELLO metadata (display name, versions) is cleartext on the LAN.
- The Keychain status codes for the Touch ID fallback button, lockout and an enrollment-
  invalidated item follow Apple's documentation and still need confirmation on a signed build
  (RELEASING.md manual checklist).
