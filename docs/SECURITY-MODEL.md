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
- **Teammates (v0.5.0):** `device_identity.secret_ct` and `teammates.announce_ct` are sealed
  under `K_field` with a secret-field AAD (§10.2); public keys and names are plaintext.
- **Shared spaces (v0.6.0):** each epoch key is sealed in `space_keys.key_ct` with a secret-field
  AAD binding the space id and the epoch (§10.3). `space_versions.data` is the signed wire form
  of each version: headers and member lists in plaintext, item names and values only inside the
  payload, encrypted under the epoch key. Teammates' addresses (`teammate_addresses`) are
  plaintext.
- **Plaintext on disk:** names (repositories, environments, items), GitHub ids, timestamps,
  branch patterns, the sync journal (names and row-bound push fingerprints, never values),
  `link_id` (which items are linked copies of each other, v0.4.1) and preferences. No group
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
is checkpointed. The sync, drift and nearby stages add: cancel the active sync run
(`SyncRunHandle.cancel()`), `DriftRepository.reset()`, cancel nearby sessions. Since v0.2.0 the
Nearby Chat window is a lock observer too: a lock (including sleep and screen lock, which always
lock) closes the chat (CLOSE to the peer), stops advertising and browsing, discards an open
import preview and wipes the transcript, the typed message and every received value.

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

Revealing an older value in a shared scope's history (v0.6.0) also asks for Touch ID or the
master password (`ReauthPurpose.spaceHistory`); the value is masked again after 30 seconds.

`.env` export, `.fxvault` export, nearby send and attaching a secret, a variable or (v0.4.0) a
whole repository in Nearby Chat (`ShareAuthorizationPurpose.nearbySend`, asked before the picker
opens), and saving a repository received in chat as a file (`.fileExport`, v0.4.0), require a
fresh Touch ID or master-password
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
- **Copying items (v0.4.0; any repository and linked since v0.4.1):** ⌘C on the detail table
  keeps the selected items in the app (by id in `ClipboardManager`, app-wide, dropped on lock and
  quit) and puts only their names on the pasteboard (this Mac only, Transient and source markers,
  not concealed: names are not values). ⌘V in another scope of any repository of the vault, or
  Copy To, copies them inside the vault: each value is decrypted and re-encrypted for its new
  row in one transaction and never reaches the pasteboard. The target must be editable by its
  own repository's account. FX Vault tells its own copy from other text by `changeCount` only,
  without reading the pasteboard. "Also update linked copies" in the item editor writes the
  new value to the checked copies the same way (one transaction across their repositories); a
  copy the account cannot change is never written.
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
- Shared scopes (v0.6.0): pull, verify, then push. The signed marker is checked in preflight,
  claimed and re-read before the first write, and published and re-read after (§10.3).
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
- A man in the middle on the local network or within peer-to-peer Wi-Fi range during nearby
  sharing and nearby chat (commit-reveal SAS; share and chat use domain-separated labels, so a
  session of one can never be completed as the other).
- An intercepted `.fxvault` file (Argon2id plus a 6-word, 77.5-bit passphrase).
- Malicious share packages (validator, merge defaults, replay warnings). A package that shares
  only some items of an environment carries no branch policy and can never change the
  receiver's policy (SHARING-PROTOCOL.md §1.2).
- Partial or indeterminate sync results (journal, reconciliation, verification).
- Leaked old credentials combined with new data (DEK rotation).

**Out of scope**
- Malware or root running as the user, including same-user write access to the vault or to
  `~/.zshrc`, `~/.ssh/config` and `PATH` while the vault is locked: such code can already
  replace gh or git. The field AAD still makes kind and scope tampering fail decryption.
- A compromised gh token or GitHub account.
- Keyloggers.
- A compromised build machine.

### 10.1 Nearby Chat (v0.2.0, experimental)

Protocol details: [SHARING-PROTOCOL.md](SHARING-PROTOCOL.md) §7.

**Assets.** Message text, an attached secret or variable value, an attached repository's
values (v0.4.0), and the user's display name.

**Adversaries.** Anyone within Wi-Fi range (on the same network or over peer-to-peer Wi-Fi, about
10 m): passive listeners, an active relay between the two Macs, a Mac that impersonates a
teammate's name, and a peer that sends hostile frames.

| Threat | Defense |
|---|---|
| Eavesdropping | Every TEXT, attachment, PING and CLOSE frame is AES-GCM under per-direction keys from X25519, with strict sequence numbers bound into the AAD. Nothing but HELLO (display name, versions) and the Bonjour advertisement is cleartext. |
| Man in the middle | Commit-reveal X25519 with a 6-digit code (SAS) both people compare. A relay gets different codes on each leg; one attempt per session (the commitment stops it from searching for a matching code). Nothing is sent before both press "Codes match"; "Don't match" ends the chat with an interception warning. |
| Impersonation by name | Display names are unverified and shown as such: the code comparison (in person or over a trusted channel) is what authenticates the peer, and the UI says so. |
| Share and chat confusion | Separate Bonjour types and label prefixes (`fxvault/chat/v1`): a share session can never complete as a chat or the reverse, and each rejects the other's frame types. |
| Replay, reorder, truncation, reflection, oversize | Abort the chat (`NearbyChatMachine`): exact sequence numbers per direction, 64 KiB frames, 4 KiB messages, 512 KiB single-item attachments and 16 MiB repository attachments (v0.4.0), at most 8 open offers and 32 offers per chat. Text and display names are sanitized on both sides before display: controls, bidi, zero-width and every other invisible character (format characters such as tag characters, soft hyphens and invisible operators, Hangul fillers); a message keeps at most one blank line in a row and four combining marks per character. |
| Flooding by a verified peer | More than 100 TEXT, offer, request, decline or PING frames within 10 s abort the chat; the window keeps at most 1,000 messages. Decrypted attachment chunks are zeroed once copied into the payload buffer, which is reserved at its final size. |
| Leaving traces | Ephemeral: messages live only in memory (the session keeps no history; the window's transcript is dropped), no message is logged or written to disk, and closing the window, End Chat, a lock (also on sleep and screen lock), a disconnect, the idle timeout (10 min) or a missed keepalive end the chat and wipe keys, offers, typed text and received values. Message text cannot be selected; Copy goes through `ClipboardManager` (concealed, this Mac only, cleared after 30 s and on lock). One exception: saving an attachment is a share import, so like any import it records the package id, its dates and the sender's (unverified) display name in `imported_share_packages` (replay detection) and logs "Imported a share package" with the count of changed items; never a value or a message. |
| An attached value | Sending needs Touch ID or the master password first (ReauthGate, `.nearbySend`). The offer is a manifest without the value; the value is decrypted only when the peer asks, re-read and checked against the offered name, kind and scope and against the stored value fingerprint taken when the user authorized the offer (a value changed since then is never sent: the offer is withdrawn), then wiped. The receiver's UI shows name, kind and scope only; "Save to my vault" moves the value into the normal share import preview (re-encrypted under the receiver's DEK), and Dismiss or the end of the chat wipes it. |
| An attached repository (v0.4.0) | Only between two Macs on 0.4 or later (chat version 2, negotiated in the transcript); with an older peer nothing is offered and no authorization is used. Sending needs Touch ID or the master password first (`.nearbySend`). The offer carries names and counts only; the values are read only when the peer asks, and sent only if every item's stored value fingerprint and the repository's shape (names, kinds, scopes, branch policies, value states) still equal what the user authorized, otherwise the offer is withdrawn and the values read are wiped. The session wipes them once sent. The receiver chooses where it goes: Import Into… lists their repositories, and those the account cannot change (archived; admin required for environments) are shown with the reason and cannot be chosen; the import is the normal share preview, re-encrypted under the receiver's DEK, and every change waits for their next Sync (deletion and push review included). Save as File… needs the receiver's Touch ID or master password (`.fileExport`) and writes an encrypted `.fxvault` under a fresh six-word passphrase shown once; there is no plaintext export from chat. The received package stays in memory (`SecretBytes`) until an import preview takes it (applied, or wiped on Cancel) or the chat ends. |
| Unwanted visibility | The Mac is advertised only while the chat window lists people (and, since v0.5.0, while Everyone nearby is chosen in Settings › Teammates, §10.2), and only on the link-local Bonjour domain (`local.`, never a wide-area DNS-SD domain); connecting or being connected stops advertising and browsing. The listener accepts one connection. |
| Disruption by strangers | Anyone nearby can connect to an advertising Mac. A connection that drops, stays silent or sends garbage before its HELLO, or that leaves before the code is shown, returns the window to the people list and advertises again: no "Conversation ended" screen, no failed-handshake count (interception warning), and it never counts toward the listener-failure limit (3 in a row), so a stranger cannot make the Mac invisible. The chip shows "Not visible" while such a connection is held. A Mac that advertises the user's own name stays listed (the own entry is filtered by the name Bonjour actually registered). |

**Cleartext metadata.** While the chat window lists people, the Bonjour instance name (the
sanitized display name, at most 63 bytes) and the TXT record `v=1` are visible to every Mac in
range, and HELLO carries the display name and protocol versions in cleartext (since v0.4.0 the
chat version, 2, also tells a listener that FX Vault 0.4 or later is running). Anyone nearby
learns that someone with that name has FX Vault's chat window open. Users who do not want that
can set a different name in Settings › General or keep the window closed.

**Not covered.** A peer who passes the code check is trusted with what the user chooses to send
it; FX Vault cannot stop them from copying a message or a saved value. The receiver of a
repository decides where it goes (any repository they can change, or a file); the sender cannot
restrict it. A user who skips the
code comparison gets no protection against a relay. Denial of service by radio jamming or by
flooding Bonjour is out of scope. There is no accept/decline step before the code comparison:
a stranger who connects and lets the code screen appear, then cancels, ends that conversation
attempt on the other Mac like any cancelled chat (pending a product decision).

### 10.2 Teammates nearby (v0.5.0)

Protocol details: [SHARING-PROTOCOL.md](SHARING-PROTOCOL.md) §10.

**Assets.** This device's teammate keys (Ed25519 signing, X25519 agreement, the announce key),
the teammates' announce keys (they recognize a teammate's pseudonyms), who is nearby, pings.

**Keys at rest.** The device keys are created on first use and stored only in
`device_identity.secret_ct`, sealed under `K_field` with a secret-field AAD
(`fxvault/v1/secret-field`, table, column, device id, DEK version); a teammate's announce key is
sealed the same way (`teammates.announce_ct`). Public keys, logins and names are plaintext. A
DEK rotation re-seals both. Nothing is in the keychain, so ad-hoc builds work, and nothing is
readable while the vault is locked: presence stops on lock.

| Threat | Defense |
|---|---|
| Tracking by strangers | In the default visibility (Teammates) the Mac advertises a pseudonym: 16 bytes of HMAC-SHA256(announce key, window) as hex, renewed every 15 minutes. Without the announce key the names look random and cannot be linked across windows. Nobody advertises nothing; Everyone nearby also advertises the display name (as the chat window does), which the setting explains. |
| A removed teammate tracking the Mac | Removing a teammate gives this device a new announce key; the remaining teammates get the new card through an authenticated CARD_UPDATE the next time they are nearby. Until then they do not recognize the Mac. |
| Impersonating a teammate | Pairing is the nearby commit-reveal handshake with its own labels (`fxvault/pair/v1`) and the 6-digit code both people compare; each card is signed with the device key over the transcript hash and the role, so it cannot be replayed or reflected. After pairing, every session is the paired handshake: X25519 ephemerals, and each side signs the transcript hash (both ephemerals and nonces) with its device key, naming both device ids. A relay that runs its own handshakes on both sides cannot reuse a signature; an AUTH that names another teammate fails. |
| Probing who a Mac is | The responder reveals its identity (AUTH_R) only after the initiator proved it is one of its teammates and meant this device; anything else is closed. The initiator reveals its device id (encrypted) to whoever answers at the pseudonym it chose. |
| Spam and floods | Only an authenticated teammate can ping; at most 5 pings per teammate per minute are accepted, the sender waits 10 s between pings to the same teammate, and Mute (per teammate or all) silences them. The presence listener accepts at most 20 connections a minute; a connection without a valid preamble within 30 s is closed; every session must finish within 30 s. |
| Chat without the code | Only at chat version 3, and only when the chat was opened from a teammate's bubble: the initiator signs the chat transcript hash with its device key (TEAMMATE_IDENT); the responder accepts it only from a teammate, answers with its own, and only then confirms the code for its user. An unknown device is ignored (the people compare the code); a known device with a bad signature aborts. The initiator accepts only the teammate whose bubble it used. |
| Energy and Wi-Fi | Browsing runs only while the main window is visible and FX Vault is active; advertising and listening run while the vault is unlocked. |

**Residual risks.** A pseudonym is stable for 15 minutes, so a listener nearby can tell that the
same (unknown) device is still there within a window. The initiator of a teammate session
reveals its device id to an impostor that advertises a copied pseudonym (no keys are exposed and
the session then fails). Names in cards are what the other Mac sent.

### 10.3 Shared spaces (v0.6.0, experimental)

Protocol details: [SHARING-PROTOCOL.md](SHARING-PROTOCOL.md) §11.

**Assets.** The values of a shared scope and their history, the epoch keys, who changed what and
when, and the order of pushes between teammates.

**Keys.** Each epoch has a random 32-byte key. It is wrapped for every member device with HPKE
(X25519, the device's agreement key from pairing) inside the signed version that introduces it,
and stored locally only sealed under `K_field` (secret-field AAD: table, column, space id, epoch,
DEK version). A DEK rotation re-seals every epoch key. Nothing is readable while the vault is
locked: space sync stops on lock.

| Threat | Defense |
|---|---|
| A forged or altered version | Every version is signed by its author's Ed25519 device key over its hash (header, keyring and payload ciphertext); its author must be a member before it; numbers and parent hashes chain from genesis. Every read re-verifies the stored log from genesis, so a tampered row is refused too. The payload is AES-GCM with the header and keyring as AAD. |
| A relay or a non-member reading values | Payloads are encrypted under the epoch key; only member devices hold a wrap for it. A relay (any member) forwards ciphertext it may not be able to open. A Mac sends versions only to devices that are members at its head. |
| Pushing over a teammate's change | Before any write in a shared scope, Sync compares GitHub's signed marker with the local head: behind, another member's live push, forked or an invalid marker block every change of the scope (Q1, strict). The claim is written and re-read before the first write. |
| Two members pushing at once | `gh variable set` has no compare-and-swap. The claim's re-read and the publish's re-read find the race (the scope shows Forked) instead of silently interleaving versions. |
| A stuck push blocking everyone | A `publishing` claim older than 15 minutes may be taken over after an explicit confirmation, recorded in the next version's note (Q3). A Mac's own unfinished claim is finished at its next unlock. |
| A removed member | Removing anyone starts a new epoch whose key only the remaining members get; versions after it cannot be opened with the old keys. What the removed device already received stays with it: the app lists every secret it ever received so they can be rotated on GitHub. |
| A teammate's change looking like drift | A drift finding in a scope whose marker is ahead is shown as the teammate's change; Keep Local and Accept GitHub are not offered (S9), so an old value is not pushed over a rotation. |
| A member pushing a bad value | It is signed, in the history with its author and time, and revertible with Restore This Value (its push is a new version). |
| Remote sync (Q4) | Off by default, turned on per teammate on both Macs, spaces service only (no ping, no chat). The listener is never advertised, routes only the spaces preamble, answers only the paired handshake of a teammate turned on for it, and closes for 10 minutes after 5 failed sessions in 10 minutes. The outgoing side connects only to the address typed for that teammate and aborts unless the peer proves that teammate's key. A private network (Tailscale, a VPN) is expected; the port should not be open to the internet. |

**Residual risks.** Removed members keep what they saw (rotation is the user's step). A Mac that
never meets another member stays behind and cannot push that scope (by design). A repository
admin can still change a secret in GitHub's web UI: it shows as changed outside FX Vault. The
marker reveals to anyone who can read the repository's variables that the scope is shared, its
version number, the last author's login and a time. Spaces store every version's full snapshot,
so the database grows with every push to a shared scope. Logins and names in member lists are
what each Mac sent when pairing.

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
- Nearby HELLO metadata (display name, versions) is cleartext on the LAN and, since v0.2.0,
  to anyone within peer-to-peer Wi-Fi (AWDL) range.
- While the nearby chat window lists people, the user's display name (Preferences › General
  › "Name for nearby Macs", or the macOS full name) is advertised as the Bonjour instance name
  to every Mac in range; connecting to someone, or being connected to, stops it. Chat message
  text arrives and is shown as Swift `String`s, which cannot be wiped; the chat keeps no
  history and writes nothing to disk, and the window drops its transcript when the chat ends
  (close, lock, sleep, disconnect, timeout). An attached value is decrypted only when the peer
  asks for it (re-read and checked against the offered name, kind and scope) and reaches the
  receiver's vault only through the share import preview; the chat UI never holds a value. A
  received repository (v0.4.0) waits in memory for Import Into… or Save as File… until the chat
  ends; a file saved from it is as safe as its passphrase, like any `.fxvault` file.
- The Keychain status codes for the Touch ID fallback button, lockout and an enrollment-
  invalidated item follow Apple's documentation and still need confirmation on a signed build
  (RELEASING.md manual checklist). Since v0.1.1 an unexpected `errSecAuthFailed` can no longer
  delete the item (it only focuses the password field), and an enrollment change is also caught
  from the biometry state hash, so a wrong guess costs a password entry, not Touch ID.
