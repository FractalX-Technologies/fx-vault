# Changelog

All notable changes to FX Vault are listed here. Versions follow `MAJOR.MINOR.PATCH`
(see [docs/RELEASING.md](docs/RELEASING.md)).

## 0.1.2

### Fixed

- **Debug builds no longer look like the real app.** A development build is now a separate
  app, **FX Vault Dev** (`io.fractalx.fxvault.dev`), with a DEV badge in the toolbar. Before,
  it registered as "FX Vault" with the release bundle identifier, so Spotlight or the Dock could
  open it instead of the installed app. A development build keeps its vault in the separate
  `FX Vault Dev` folder, so an account created in such a copy never reached the installed app's
  vault, and the installed app correctly showed no vault after an upgrade. Upgrading does not
  delete a vault. A vault created by a development build is intact in
  `~/Library/Application Support/FX Vault Dev/vault.sqlite`; it opens only in a development build
  (now "FX Vault Dev") and is not merged into the installed app's vault. The installed app is
  unchanged (`io.fractalx.fxvault`, "FX Vault"), and `.fxvault` files open in it, not in a
  development build.
- **Filled secrets now sync.** GitHub never returns secret values, so after importing a
  repository you fill them in. A filled value used to be recorded as already on GitHub, so Sync
  stayed disabled. It is now pushed by the next Sync, so GitHub matches your vault; check
  "Already matches GitHub (don't push)" when you are sure it is the same value. After a drift
  review's "Accept GitHub" the box starts checked.

### Added

- **Push on Next Sync.** Right-click a secret (or open it in the editor) to send its value to
  GitHub on the next Sync even when it did not change. The row shows "Will push", the Sync
  button counts it, and Revert cancels it. Variables do not need it: FX Vault compares their
  values with GitHub's.
- A push you asked for (Push on Next Sync, or a fill that pushes) is not blocked by a change
  made on GitHub before you asked; a change made after it, or within a few seconds of it, still
  stops the push and is listed in the drift review.

### Changed

- The vault database gains one column (migration `v8_force_push_requested_at`). Older versions
  of FX Vault refuse to open a vault that 0.1.2 has opened.

## 0.1.1

### Added

- **Paste Multiple with live preview.** The Add button in the secrets and variables table is a
  split button with Paste Multiple… and Import .env File…, and ⌘V on the table opens the import
  preview filled with what you pasted (a whole `.env` or a single `KEY=value` line). The text is
  parsed as you type, without a Review step; problem lines show their line numbers, and your
  changes to a row survive further edits. The clipboard is read only when you paste.
- **Kind follows the tab.** From the Variables tab every pasted or imported row starts as a
  Variable, from the Secrets tab as a Secret. A variable that looks like a credential gets a
  "Make Secret" badge. The toolbar Import .env keeps the automatic credential detection.
- **Bulk marking.** Mark All as Variable / Mark All as Secret (also for rows added by later
  edits) and Overwrite All for conflicts. The target scope starts at the repository or
  environment you have open.
- **Touch ID offer after a password unlock.** On the signed build, when Touch ID can be used and
  is off, FX Vault offers once to turn it on with the password you just typed (Turn On Touch ID
  / Not Now, remembered). It comes back once after a fingerprint change turned Touch ID off,
  also when the lock screen showed the restart or 14-day reason, or the change was noticed by a
  Touch ID check while the vault was open.
- **Lock-screen reason.** When Touch ID is on but the password is needed, the lock screen says
  why: after a restart, every 14 days, or fingerprints changed. When Touch ID can unlock, the
  lock card says so and "Unlock with Touch ID" is a bordered button.
- **`--diagnose`.** `"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose` prints a
  JSON report (version, signing and keychain access group, Touch ID availability, and an add and
  delete of a probe keychain item with the Touch ID attributes), then exits without a window. It
  never reads a keychain item or prints a secret.

### Fixed

- A finger Touch ID did not recognize (`errSecAuthFailed`) was treated as an invalidated item,
  which deleted the Touch ID item and turned Touch ID off. It now only moves focus to the
  password field.
- After a fingerprint change, Touch ID stayed on in Settings and every unlock asked for the
  password. The next password unlock now turns Touch ID off cleanly and offers to turn it on
  again.
- The Touch ID presence check asks the keychain for attributes only (it used to request the
  item's data).
- An unquoted multi-line key or certificate in a `.env` (`KEY=-----BEGIN ...` over several
  lines) is skipped with one error asking for quotes. Its lines used to become rows named after
  pieces of the key. Rows whose key needed characters replaced are no longer pre-selected, and a
  line without `=` is listed without its text.

## 0.1.0 - Beta

First beta, for the FractalX team.

- Local encrypted vault: master password (Argon2id), one-time recovery key, field-level
  AES-GCM encryption, auto-lock, and Touch ID in the signed release.
- Every `gh` account, its organizations and their repositories in one sidebar.
- Repository and environment secrets and variables: add, edit, rename, convert, move, fill,
  revert and delete, then review and sync through `gh`.
- Environments: create, guided rename, duplicate, delete and edit deployment branch and tag
  rules. A policy change is blocked while GitHub lists reviewers, wait timers or app rules on
  that environment.
- Drift detection, interrupted-sync reconciliation at unlock, and write verification by
  re-listing GitHub.
- New repositories with environments, secrets and variables, cloned through an SSH alias.
- `.env` import and export, encrypted `.fxvault` sharing, and experimental nearby sharing.
