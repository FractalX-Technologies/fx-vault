# Changelog

All notable changes to FX Vault are listed here. Versions follow `MAJOR.MINOR.PATCH`
(see [docs/RELEASING.md](docs/RELEASING.md)).

## 0.2.0

### Added

- **Share any combination.** The share scope tree (Share › File… and the nearby "what to send"
  picker) is multi-select with tri-state checkboxes: the repository level, one or more
  environments, the repository level plus environments, or individual secrets and variables.
  The sheet shows "Secrets: n · Variables: m" per scope. An environment's deployment branch
  policy is shared only when the whole environment is checked; a partly checked environment
  shares only its checked items and never changes the receiver's policy.
- **Connectivity banner.** "No internet connection" at the top of the main window when the Mac
  is offline, and a separate "GitHub isn't responding" state with Retry when gh calls time out
  or cannot reach GitHub. While offline, Sync, New Repository, Import, Add by name, Clone,
  Refresh and drift checks are disabled with an explanation; local editing, `.env` files and
  sharing keep working. When the connection returns, the repository lists reload and the open
  repository's drift check runs again.
- **Nearby without a shared network.** Nearby share and Nearby Chat also run over peer-to-peer
  Wi-Fi (AWDL, the link AirDrop uses): Wi-Fi and Bluetooth on, about 10 m apart, no router or
  internet needed.
- **Nearby Chat (experimental).** Share › Nearby Chat… opens a separate window for an
  end-to-end encrypted 1:1 chat with a teammate's Mac nearby. You are visible under your name
  (Settings › General › "Name for nearby Macs") only while the window lists people. Both people
  compare a 6-digit code before anything is sent. Messages live only in memory and are wiped
  when the chat ends, the window closes, the vault locks or the connection drops; nothing is
  written to disk. Copy a message from its context menu: like a copied value it stays on this
  Mac and is cleared after 30 s and on lock.
- **Attach a secret or variable in chat.** After Touch ID or your master password, pick one
  item to offer. The other person sees a card with its name, kind, repository and environment
  (never the value); "Save to my vault" fetches the value and opens the normal share import
  preview, "Dismiss" declines it.

### Changed

- Share packages use schema version 2 only when an environment is partly selected (including a
  single environment-level secret or variable). FX Vault 0.1.x cannot open those; everything
  else is still written as version 1 and opens in 0.1.x. Files and nearby shares from 0.1.x
  open unchanged.
- A 0.1.x Mac and a 0.2.0 Mac find each other for nearby sharing only on a shared network
  (0.1.x does not use peer-to-peer Wi-Fi).
- The Local Network permission text now mentions chat.
- Nearby share, receive and chat use the name from Settings › General when one is set.

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
