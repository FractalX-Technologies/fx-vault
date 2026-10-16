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
- **The vault is the source of truth.** A secret value you fill in is pushed by the next Sync
  (unless you check "Already matches GitHub"), and Push on Next Sync re-sends any secret so
  GitHub matches FX Vault.
- **Environments.** Create, rename (guided recreate on GitHub), duplicate and delete
  environments, and edit their deployment branch and tag rules.
- **Review, then sync.** Edits stay local until you press Sync. The summary shows names and
  counts only, explains blocked changes with a fix, and asks before anything is deleted on
  GitHub.
- **Drift detection.** Changes a teammate made on GitHub since your last sync are listed per
  repository; keep yours or accept GitHub's.
- **New repositories.** Stage a repository with its environments, secrets and variables, create
  everything in one Sync, and clone it through your SSH alias.
- **Teammates nearby.** Pair once with a teammate's Mac (Settings › Teammates › Add Teammate…,
  compare a 6-digit code). From then on, while FX Vault is open, teammates who are nearby appear
  as bubbles next to Sync: click one to **Ping** (their Mac plays a sound) or **Chat** (no code
  needed between teammates). Only your teammates recognize your Mac: it shows up under a name that
  changes every 15 minutes. Choose Nobody, Teammates or Everyone nearby, and mute pings per
  teammate or all at once.
- **Shared scopes (experimental).** Share a repository level or an environment with paired
  teammates: every push becomes a signed version they get Mac to Mac (nearby, or at an address
  you allow, such as a Tailscale name), with its values, author and time. Before anyone pushes,
  FX Vault checks a small signed marker on GitHub and asks you to get your teammates' newer
  versions first, so nobody overwrites anyone. History shows every version and restores an older
  value. No server and no extra repository: GitHub holds only the marker.
- **Copy once, use everywhere.** Select secrets or variables, press ⌘C, open any other scope of
  any repository in the vault (any account) and press ⌘V, or choose **Copy To › Another
  Repository…**. Each copy stays **linked** to its item: a link chip with the number of places
  sits next to the name, and its popover lists every place with Same value or Differs. When you
  change a linked item's value, the editor offers to update the copies too, so a rotation is one
  edit and one Sync.
- **Paste many at once.** Copy a whole `.env` and press ⌘V on the secrets or variables table
  (or choose **Paste Multiple…** in the Add menu): a live preview lists every `KEY=value` as
  you edit, with line numbers for problem lines. Rows start as the tab's kind (Variables or
  Secrets), credential-looking variables get a "Make Secret" badge, and Mark All and Overwrite
  All handle the rest. The target is the repository or environment you have open. FX Vault
  reads the clipboard only when you paste.
- **`.env` import and export.** Import with key fixes and credential detection; export after
  Touch ID or your master password, with iCloud and git-exposure warnings.
- **Sharing.** Send any combination to a teammate as an encrypted `.fxvault` file protected
  by a 6-word passphrase: the repository level, one or more environments, or individual
  secrets and variables (tri-state checkboxes, with "Secrets: n · Variables: m" per scope). An
  environment's deployment branch policy travels only when the whole environment is checked.
- **Works offline.** A banner says when the Mac has no internet connection or GitHub isn't
  responding (with Retry). Your edits stay in the vault; Sync, Import, New Repository, Refresh
  and drift checks wait until you are back online, and drift is checked again when the
  connection returns.
- **Experimental: nearby sharing.** Send directly to a teammate's Mac nearby after both people
  compare a 6-digit code. No shared Wi-Fi network is needed (see
  [Nearby without internet](#nearby-without-internet)). Marked experimental in the app.
- **Experimental: Nearby Chat.** Share › Nearby Chat… opens an end-to-end encrypted 1:1 chat
  with a teammate's Mac nearby, after the same 6-digit code check. Messages live only in memory
  and are wiped when the chat ends, the window closes or the vault locks. You can attach a
  secret or variable (after Touch ID or your master password); the other person sees its name,
  never the value, until they choose **Save to my vault**, which opens the normal import
  preview.

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

It prints a JSON report (version, signing, keychain access group, Touch ID availability, a
keychain probe that adds and deletes a throwaway item, and since 0.3.1 the GitHub CLI it finds;
see [Troubleshooting](#troubleshooting-fx-vault-doesnt-see-my-gh-login)) and exits without
opening a window. It never reads your vault or a keychain item and prints no secret.

### Nearby without internet

Nearby sharing and Nearby Chat work between two Macs with no router, no shared Wi-Fi network
and no internet, over peer-to-peer Wi-Fi (AWDL, the link AirDrop uses). They also work when
both Macs are on the same network.

- **Turn on Wi-Fi and Bluetooth** on both Macs. Wi-Fi does not need to be joined to a network.
- **Stay close:** about 10 m (30 ft), as for AirDrop.
- **Allow Local Network access** when macOS asks the first time (or later in **System Settings ›
  Privacy & Security › Local Network**). Without it FX Vault cannot find or reach the other
  Mac, and says so.
- **Firewall:** the receiving Mac (Receive Nearby, or the person listed in Nearby Chat)
  accepts one incoming connection. If the macOS firewall asks whether FX Vault may accept
  incoming connections, choose **Allow**. With "Block all incoming connections" turned on, that
  Mac cannot be reached: turn the option off while you share, or let the other person receive.
- **Both Macs need FX Vault 0.2.0** to meet without a shared network. A 0.1.x Mac uses the
  shared network only, and cannot open a share in which an environment is only partly checked.
- You are visible to nearby Macs only while **Receive Nearby** is open (under a random name) or
  while the **Nearby Chat** window lists people (under your name from **Settings › General ›
  Name for nearby Macs**, or your macOS name). Anyone nearby can see that name, and it proves
  nothing: always compare the 6-digit code.

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

## Troubleshooting: FX Vault doesn't see my gh login

Terminal says you are logged in, but FX Vault shows "Log in to GitHub", "Update the GitHub
CLI" or "The GitHub CLI is not trusted". FX Vault runs the same `gh` your shell runs, without
your Terminal's environment, and only uses the accounts gh **stores**. First update to FX Vault
0.3.1 or later, then work through these checks.

1. **Enterprise Managed User accounts (logins with an underscore).** EMU logins look like
   `mona-cat_acme` (your handle, an underscore, your enterprise's short code). FX Vault 0.3.0
   and earlier ignored them and asked you to log in although gh was logged in; 0.3.1 accepts
   them. If an account still cannot be used, the setup screen and **Settings › Accounts** name it
   with the reason.

2. **`GH_TOKEN` or `GITHUB_TOKEN` in your shell.** If `~/.zshrc` (or another start-up file)
   exports one of them, gh in Terminal uses that token and `gh auth login` refuses to save an
   account. FX Vault never passes these variables to gh, so it sees no account. Check where
   Terminal's token comes from:

   ```sh
   gh auth status          # "(GH_TOKEN)" or "(GITHUB_TOKEN)" after the login means the variable
   ```

   Store the account in gh without the variables, then choose **Check Again** in FX Vault (you
   can keep the variable in your shell):

   ```sh
   env -u GH_TOKEN -u GITHUB_TOKEN gh auth login
   ```

   `gh auth status` should then list the account with `(keyring)`.

3. **A different gh, or Homebrew owned by another user.** FX Vault uses the gh your shell finds
   (it starts your shell the way Terminal does, so `~/.zshrc` counts) and never falls back to
   another one behind it. Compare:

   ```sh
   which -a gh                     # every gh on your PATH, the first one is Terminal's
   ls -l /opt/homebrew/bin/gh      # who owns Homebrew's gh (/usr/local/bin/gh on Intel Macs)
   whoami                          # who you are
   ```

   If the owner is another user (another administrator installed Homebrew), FX Vault explains
   what that means and offers **Trust This gh**: anyone who can sign in as that user could
   replace gh and see the values FX Vault sends to it. Trust it only if you trust that user; you
   can revoke it in **Settings › Advanced**. A gh that other users can write to is never trusted.
   You can also point **Settings › Advanced › gh path override** at a gh you own.

**Diagnostics.** **Copy Diagnostics** on the GitHub CLI setup screen copies a plain-text report:
which gh FX Vault found and why, your shell and whether the probe ran interactively, the
**names** of `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME` and `GH_HOST` if your
shell sets them, and each account's login, state, token source and scopes. The same report is the
`gh` section of:

```sh
"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose
```

Neither contains a token, a secret, or the value of an environment variable.

## Security model

- Values are encrypted field by field with AES-256-GCM under a random data key, which is
  wrapped by a key derived from your master password with Argon2id (256 MiB) and by a one-time
  recovery key you keep offline.
- The vault locks on sleep, screen lock, inactivity and window close, and the clipboard is
  cleared 30 seconds after a copy.
- `.env` export and every share need a fresh Touch ID or master-password check.
- Every GitHub operation goes through `gh` with values passed on stdin, never as arguments.
- Nothing leaves your Mac except what Sync sends to GitHub and what you choose to share or send
  in Nearby Chat. Chat messages are never written to disk.
- Nearby sharing and chat are end-to-end encrypted after a 6-digit code that both people
  compare; a mismatch means someone is in the middle, and nothing is sent.

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
- [docs/SHARING-PROTOCOL.md](docs/SHARING-PROTOCOL.md): `.fxvault` files, nearby sharing and
  Nearby Chat
- [docs/RELEASING.md](docs/RELEASING.md): signing, notarization, the Homebrew cask and the
  manual release checklist

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
