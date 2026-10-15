# FX Vault

A native macOS app for managing GitHub Actions secrets and variables across repositories,
environments and accounts, with a local encrypted vault and the GitHub CLI.

**Status: Beta.** Under active development; expect breaking changes before 1.0.

## Features

- **One vault for every account.** Every `gh` account you are logged in to, its organizations
  and their repositories in one sidebar, with search, badges and scope warnings.
- **Secrets and variables, repository and environment level.** Add, edit, rename, convert
  between secret and variable, move between scopes, fill values GitHub does not return, revert
  and delete. Secrets stay masked until you reveal them and re-mask after 30 seconds.
- **Environments.** Create, rename (guided recreate on GitHub), duplicate and delete
  environments, and edit their deployment branch and tag rules.
- **Review, then sync.** Edits stay local until you press Sync. The summary shows names and
  counts only, explains blocked changes with a fix, and asks before anything is deleted on
  GitHub.
- **Drift detection.** Changes a teammate made on GitHub since your last sync are listed per
  repository; keep yours or accept GitHub's.
- **New repositories.** Stage a repository with its environments, secrets and variables, create
  everything in one Sync, and clone it through your SSH alias.
- **Paste many at once.** Copy a whole `.env` and press ⌘V on the secrets or variables table
  (or choose **Paste Multiple…** in the Add menu): a live preview lists every `KEY=value` as
  you edit, with line numbers for problem lines. Rows start as the tab's kind (Variables or
  Secrets), credential-looking variables get a "Make Secret" badge, and Mark All and Overwrite
  All handle the rest. The target is the repository or environment you have open. FX Vault
  reads the clipboard only when you paste.
- **`.env` import and export.** Import with key fixes and credential detection; export after
  Touch ID or your master password, with iCloud and git-exposure warnings.
- **Sharing.** Send a scope to a teammate as an encrypted `.fxvault` file protected by a
  6-word passphrase.
- **Experimental: nearby sharing.** Send directly to a Mac on the same network after both
  people compare a 6-digit code. Marked experimental in the app.

## Requirements

- macOS 14 Sonoma or later
- [GitHub CLI](https://cli.github.com) (`gh`) 2.97.0 or later, logged in (`gh auth login`)
- `git`, and an SSH key or host alias for GitHub, to clone repositories and for **New
  Repository** with cloning (the Xcode Command Line Tools provide `git`)

FX Vault turns off gh's telemetry and update notifier for the gh commands it runs itself
(`GH_TELEMETRY=false`, `DO_NOT_TRACK=1`, `GH_NO_UPDATE_NOTIFIER=1`).

## Install

With Homebrew (installs `gh` if it is missing):

```sh
brew install --cask fractalx-technologies/tap/fx-vault
```

Homebrew does not upgrade a `gh` you already have. If yours is older than 2.97.0, run
`brew upgrade gh` (FX Vault shows a setup screen until it is).

Or download `FXVault-<version>.dmg` from the GitHub Releases page, open it and drag
**FX Vault** to Applications.

After installing, run `gh auth login` once if you have not used the GitHub CLI before, and
`brew upgrade gh` if FX Vault reports that gh is too old.

### First launch

1. **Choose a master password.** It encrypts the vault on this Mac. FX Vault cannot recover it.
2. **Save the recovery key offline** (on paper or in a password manager). It is shown once and
   is the only way back in if you forget the password. Losing both means losing the vault.
3. **Connect gh.** FX Vault looks for `gh` and its logged-in accounts. If it asks, run
   `gh auth login`, or `brew upgrade gh`, then choose **Check Again**.
4. **Optional: turn on Touch ID** (see [Touch ID](#touch-id)).

### Touch ID

The signed release can unlock the vault with Touch ID. After a password unlock, FX Vault offers
once to turn it on (**Turn On Touch ID** / **Not Now**); you can change it any time in
**Settings › Security**.

Touch ID is a convenience, not a replacement for the master password. FX Vault still asks for
the password:

- after every restart of the Mac,
- at least every 14 days (a Touch ID unlock does not reset the timer),
- after fingerprints are added or removed (Touch ID turns itself off; FX Vault offers to turn
  it on again after the password unlock).

The lock screen says which of these applies. Ad-hoc builds cannot use Touch ID (it needs the
signed release's keychain entitlement).

To check Touch ID support on an installed copy, run:

```sh
"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose
```

It prints a JSON report (version, signing, keychain access group, Touch ID availability and a
keychain probe that adds and deletes a throwaway item) and exits without opening a window. It
never reads your vault or a keychain item and prints no secret.

### Verify a download

Each release ships `FXVault-<version>.dmg.sha256` next to the DMG. Releases are signed with a
Developer ID certificate and notarized by Apple:

```sh
shasum -a 256 -c FXVault-<version>.dmg.sha256
spctl -a -vvv -t install FXVault-<version>.dmg     # expect: accepted, source=Notarized Developer ID
xcrun stapler validate FXVault-<version>.dmg
```

`gh attestation verify` works only for releases built by the CI release workflow; releases
published from a maintainer's Mac carry no build attestation.

### Opening an ad-hoc build

Builds from source, forks and the CI verification DMG are ad-hoc signed, not notarized, so
Gatekeeper blocks the first launch. Either open **System Settings › Privacy & Security** and
click **Open Anyway** next to the FX Vault message, or remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine "/Applications/FX Vault.app"   # or wherever you put the app
```

Ad-hoc builds cannot use Touch ID (it needs the signed release's keychain entitlement); they
use the master password instead.

## Security model

- Values are encrypted field by field with AES-256-GCM under a random data key, which is
  wrapped by a key derived from your master password with Argon2id (256 MiB) and by a one-time
  recovery key you keep offline.
- The vault locks on sleep, screen lock, inactivity and window close, and the clipboard is
  cleared 30 seconds after a copy.
- `.env` export and every share need a fresh Touch ID or master-password check.
- Every GitHub operation goes through `gh` with values passed on stdin, never as arguments.
- Nothing leaves your Mac except what Sync sends to GitHub and what you choose to share.

The full model, threat model and residual risks are in
[docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md).

## Building from source

```sh
git clone <this repository> && cd FXVault
swift test --package-path Packages/FXVaultKit          # package tests
xcodebuild -project FXVault.xcodeproj -scheme FXVault -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- build test                     # app build and tests, ad-hoc signed
```

Requires Xcode 26.6 or later. See [CONTRIBUTING.md](CONTRIBUTING.md) for XcodeGen, linting and
the local CI script, and [docs/RELEASING.md](docs/RELEASING.md) for signed builds.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): modules, layers, public APIs and the UI
- [docs/STRUCTURE.md](docs/STRUCTURE.md): repository layout
- [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md): keys, lock, Touch ID, threat model
- [docs/DATABASE.md](docs/DATABASE.md): the local encrypted vault schema
- [docs/API.md](docs/API.md): every gh, git and ssh command the app runs
- [docs/SHARING-PROTOCOL.md](docs/SHARING-PROTOCOL.md): `.fxvault` files and nearby sharing
- [docs/RELEASING.md](docs/RELEASING.md): signing, notarization, the Homebrew cask and the
  manual release checklist

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
