# FX Vault

A native macOS app for managing GitHub Actions secrets and variables across repositories,
environments and accounts, with a local encrypted vault and the GitHub CLI, and, experimentally,
the secrets your code reads at runtime in Azure Key Vault.

**Status: Beta.** Under active development; expect breaking changes before 1.0.

## Features

- **One vault for every account.** Every `gh` account you are logged in to, its organizations
  and their repositories in one sidebar tree, one node per organization or person whichever
  accounts see it, with each repository's environments under it, search (⌘F), and what an
  owner needs under its name (Needs admin:org · Approve, Authorize SSO · Open); the Azure Key
  Vaults you connected are under **Azure** by subscription, and Lock and Settings at the bottom of the sidebar.
  The toolbar shows where you are; **⌘K** jumps to any organization, repository, environment,
  Key Vault or folder by typing part of its name, and finds secrets and variables by name (never
  by value), opening their place with the row selected. Settings ›
  Accounts shows, per organization, whether you can manage its secrets: **Ready**, **Needs
  admin:org** (with the `gh auth refresh -s admin:org` commands to copy, then Re-check), **Org
  secrets need an org admin**, or **Needs SSO authorization** (with GitHub's SSO page).
- **Organization secrets and variables.** Selecting an organization in the sidebar imports
  its own secrets (names only: GitHub never returns values) and variables with their visibility:
  all repositories, private and internal, or the selected ones. **New Secret** and **New
  Variable** (in the ⋯ menu) open an editor with the value and Access (All, Private, or Selected with the
  organization's repositories); the row menu edits, deletes, reverts and copies a value. Changes
  wait in the vault with their status and count on the Sync button; the toolbar Sync sends them
  after the repositories (deletions only after the deletion review). A repository's own Sync
  leaves them for later. **Refresh** (⋯ menu) reads the organization again and marks what
  changed on GitHub; Review keeps your version or takes GitHub's for each. Needs
  `admin:org` and the organization's admin role (see Settings › Accounts).
- **Secrets and variables, repository and environment level.** Add, edit, rename, convert
  between secret and variable, move between scopes, fill values GitHub does not return, revert
  and delete. Secrets stay masked until you reveal them and re-mask after 30 seconds.
- **The vault is the source of truth.** A secret value you fill in is pushed by the next Sync
  (unless you check "Already matches GitHub"), and Push on Next Sync re-sends any secret so
  GitHub matches FX Vault.
- **Environments.** Create, rename (guided recreate on GitHub), duplicate and delete
  environments, and edit their deployment branch and tag rules.
- **Review, then sync.** Edits stay local until you press Sync. The summary shows names only,
  one card per place (a repository, each environment, each Azure Key Vault, each organization),
  explains blocked changes with a fix in their place's card, and asks before anything is deleted
  on GitHub or in a vault.
- **Drift detection.** Changes a teammate made on GitHub since your last sync are listed per
  repository; keep yours or accept GitHub's.
- **New repositories.** Stage a repository with its environments, secrets and variables, create
  everything in one Sync, and clone it through your SSH alias.
- **Runtime destinations (experimental).** Next to a repository's GitHub scopes, add the places
  its code reads at runtime: an **Azure Key Vault**, reached through your `az login`. A
  destination works like a scope (table, paste, `.env`, ⌘C / ⌘V, linked copies), and Sync pushes
  its changes after GitHub's, in the same review. Changes made in the vault are never
  overwritten: Refresh lists them first. 1.0 removed the Supabase and Vercel destinations: the
  first unlock lists the ones it deleted from your vault (nothing is deleted remotely).
- **Folders.** Keep the secrets and variables you use in several repositories in folders of your
  own ("Mobile App", "Stripe test") under GitHub in the sidebar (New Folder…, ⇧⌘N). A folder never
  goes to GitHub by itself: copy its items into any repository with ⌘C / ⌘V or Copy To, and every
  copy stays linked, so changing a value in the folder offers to update the repositories that
  use it. Folders take Paste Multiple…, `.env` import and export too.
- **Send a folder to a teammate.** From the folder's menu, share it as an encrypted `.fxvault`
  file (after Touch ID or your master password). The teammate saves it as a folder of their own
  or imports it into one of their repositories. Each person keeps their own copy.
- **Copy once, use everywhere.** Select secrets or variables, press ⌘C, open any other scope of
  any repository in the vault (any account) and press ⌘V, or choose **Copy To › Another
  Repository…**. Each copy stays **linked** to its item: a link chip with the number of places
  sits next to the name, and its popover lists every place with Same value or Differs. When you
  change a linked item's value, the editor offers to update the copies too, so a rotation is one
  edit and one Sync.
- **Paste many at once.** Copy a whole `.env` and press ⌘V on the secrets or variables table
  (or choose **Paste Multiple…** in the place's ⋯ menu): a live preview lists every `KEY=value` as
  you edit, with line numbers for problem lines. Rows start as the tab's kind (Variables or
  Secrets), credential-looking variables get a "Make Secret" badge, and Mark All and Overwrite
  All handle the rest. The target is the repository or environment you have open. FX Vault
  reads the clipboard only when you paste.
- **`.env` import and export.** Import with key fixes and credential detection; export after
  Touch ID or your master password, with iCloud and git-exposure warnings.
- **Copy All.** A place's Copy All (its header or its ⋯ menu) copies every value as `.env` text,
  secrets then variables, after Touch ID or your master password; the clipboard clears after 30
  seconds.
- **Share a project as one file.** File › Share Project… (⌥⌘S) puts several repositories into
  one encrypted `.fxvault` file you send with **Send with AirDrop** to a Mac nearby, or by
  WhatsApp or Mail: pick the stages, and
  each repository brings its GitHub environments and its runtime destinations with their values,
  then adjust the tree down to single secrets. The file opens with a **6-word passphrase** you
  send another way. **Production is unchecked by default**: checking it asks for Touch ID (or
  your master password), and the file is refused without that confirmation. The file expires after 1, 7 or 30 days, and Settings ›
  Sharing lists what you sent, names only, so you know what to rotate if a file leaks. Azure
  sessions never travel: the receiver uses their own `az login`.
- **Open a project file.** Double-click it: FX Vault lists each repository as already in your
  vault, to import from GitHub with your account, or skipped (no access), previews the merge
  (nothing of yours is deleted), and **Import as Held** opens the first repository at the
  environment of the file's first stage. Nothing from the file reaches
  GitHub or Azure until you include it in Sync's **From Files** review; until then its rows
  show **Held**.
- **Works offline.** A banner says when the Mac has no internet connection or GitHub isn't
  responding (with Retry). Your edits stay in the vault; Sync, Import, New Repository, Refresh
  and drift checks wait until you are back online, and drift is checked again when the
  connection returns.
## Requirements

- macOS 26 Tahoe or later (FX Vault 0.9 is the last version for macOS 14 and 15)
- [GitHub CLI](https://cli.github.com) (`gh`) 2.97.0 or later, logged in (`gh auth login`)
- Only for Azure Key Vault destinations: the [Azure CLI](https://learn.microsoft.com/cli/azure/)
  (`az`), signed in (`az login`)
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
   Check **I saved it offline**, then type the two groups FX Vault asks for.
3. **Optional: turn on Touch ID** (see [Touch ID](#touch-id)).
4. **Connect gh.** FX Vault looks for `gh` and its logged-in accounts. When gh is missing or
   too old and Homebrew is installed, **Run** next to `brew install gh` or `brew upgrade gh` runs
   it here and checks again (FX Vault runs only these fixed commands). Run `gh auth login` in
   Terminal, then choose **Check Again**.
5. **Choose what to import from GitHub.** Each account lists its organizations (checked when
   the account can read their secrets) and its personal repositories. **Continue** goes on to
   Azure; **Not Now** imports nothing.
6. **Choose Azure Key Vaults.** FX Vault reads your subscriptions and their vaults through the
   Azure CLI (`az`), every vault checked. Without `az`, **Run** next to `brew install azure-cli`
   installs it; sign in with `az login` in Terminal (reading a vault needs the Key Vault Secrets
   User role), then **Check Again**. **Continue** imports GitHub's checked sources (secret
   names, variable values) and each checked vault with its secret values, and shows what was
   found; **Skip** imports GitHub only. Nothing is written to GitHub or Azure.

### Unlocking

A locked FX Vault has no window. When you switch to it, a small black island grows out of the
notch (on a screen without one, it floats under the menu bar): **Touch ID to unlock**, or **Use
Password** for the master password. The island never shows names or values. After the unlock it
says **Unlocked** and the main window opens; locking (⌃⌘L, sleep, idle) closes the window again.
**Recovery Key…** in the island opens the recovery window.

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

The island says which of these applies. Ad-hoc builds cannot use Touch ID (it needs the
signed release's keychain entitlement).

To check Touch ID support on an installed copy, run:

```sh
"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose
```

It prints a JSON report (version, signing, keychain access group, Touch ID availability, a
keychain probe that adds and deletes a throwaway item, and since 0.3.1 the GitHub CLI it finds;
see [Troubleshooting](#troubleshooting-fx-vault-doesnt-see-my-gh-login)) and exits without
opening a window. It never reads your vault or a keychain item and prints no secret.

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
- `.env` export, Copy All and every share need a fresh Touch ID or master-password check.
- Every GitHub operation goes through `gh` with values passed on stdin, never as arguments.
- Runtime destinations are reached over HTTPS only at `<vault>.vault.azure.net`, with no
  cookies, cache or redirects; the Azure token stays in memory until the vault locks.
- Nothing leaves your Mac except what Sync sends to GitHub and your destinations, and the files
  you choose to share.
- A share file uses Argon2id and six words that should travel another way, and never contains a
  production stage. FX Vault refuses a file after its expiry date (the app enforces it, not the
  cryptography). Imported rows are held until you include them in a Sync.

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

### UI tests

```sh
xcodebuild -project FXVault.xcodeproj -scheme FXVaultUITests -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- test                           # XCUITest suite
```

- The scheme builds the **UITesting** configuration, a separate app ("FX Vault UI Test",
  `io.fractalx.fxvault.uitesthost`), so a test launch never quits a running FX Vault or FX Vault Dev.
- That app always starts on a new throwaway vault under the temporary directory (`fxvault-uitests`),
  with a scripted gh (one account, `owner-a`, read commands only), fake Touch ID, in-memory settings
  and a private pasteboard. It never opens your vault, the keychain, a real account or the network.
- Debug and Release builds don't contain this code; `scripts/ci-local.sh` checks it.
- macOS may ask once to allow UI automation (your password). To run `scripts/ci-local.sh` without
  the UI tests, set `FXVAULT_SKIP_UI_TESTS=1`.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): modules, layers, public APIs and the UI
- [docs/STRUCTURE.md](docs/STRUCTURE.md): repository layout
- [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md): keys, lock, Touch ID, threat model
- [docs/DATABASE.md](docs/DATABASE.md): the local encrypted vault schema
- [docs/API.md](docs/API.md): every gh, git, ssh and az command the app runs, and the HTTPS
  endpoints of runtime destinations
- [docs/SHARING-PROTOCOL.md](docs/SHARING-PROTOCOL.md): `.fxvault` files (formats 1 and 2) and
  project bundles
- [docs/RELEASING.md](docs/RELEASING.md): signing, notarization, the Homebrew cask and the
  manual release checklist

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
