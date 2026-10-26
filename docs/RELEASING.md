# Releasing FX Vault

Official FX Vault releases are universal (arm64 and x86_64) DMGs. Each one is signed with
Developer ID (team `QYKC498D5D`), notarized and stapled: the app and the DMG are each
notarized and stapled separately. Releases are published on
[FractalX-Technologies/fx-vault](https://github.com/FractalX-Technologies/fx-vault/releases),
and the cask is in [FractalX-Technologies/homebrew-tap](https://github.com/FractalX-Technologies/homebrew-tap):

```sh
brew install --cask fractalx-technologies/tap/fx-vault
```

**Signing and notarization run only on the maintainer's Mac** (tasks/todo.md D25, Q1). No
certificate, provisioning profile or App Store Connect key is stored on GitHub. The
`Release` workflow builds an **ad-hoc** DMG from every tag, but that DMG is only for
verification. The workflow's signed job is optional and is skipped unless the
`release` environment has secrets (see [CI](#ci-releaseyml)).

| File | Role |
|------|------|
| `scripts/release-local.sh` | Preflight, archive, export, gates, notarize, staple, DMG, sha256, optional `gh release` upload |
| `scripts/make-dmg.sh` | Builds the DMG: the app plus an `Applications` link, ULFO format, checked with `hdiutil verify` and a test mount |
| `scripts/bump-cask.sh` | Writes `version` and `sha256` into the cask in a tap checkout. It never pushes |
| `ci/ExportOptions-DeveloperID.plist` | `developer-id`, manual signing, team `QYKC498D5D`, profile `FX Vault Developer ID` |
| `Casks/fx-vault.rb` | Cask template. The tap holds the canonical copy |
| `.github/workflows/release.yml` | On `v*` tags: tests and the ad-hoc DMG artifact, plus the optional signed path |

## One-time setup (release Mac)

1. **Tools.** You need:
   - Xcode 26.6 or later.
   - XcodeGen at the version on line 1 of `.xcodegen-version`.
   - `gh` 2.97.0 or later, logged in with push access to both repos (`gh auth status`).
2. **Certificate.** Install a *Developer ID Application: … (QYKC498D5D)* identity in the login
   keychain. To check, run `security find-identity -v -p codesigning`. If several match,
   the script uses the newest identity whose certificate is in the profile. Pass
   `--identity <SHA-1>` to pick one yourself.
3. **Provisioning profile.** Install the profile *FX Vault Developer ID* (Developer ID type,
   explicit App ID `io.fractalx.fxvault` with Keychain Sharing):
   - Download it from developer.apple.com (Certificates, IDs & Profiles > Profiles) and
     double-click it.
   - The script finds installed profiles by name or UUID in
     `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.
   - Alternatively, pass `--profile /path/to/file.provisionprofile` and the script
     installs it.

   Touch ID needs this profile: without the embedded profile, the
   `keychain-access-groups` entitlement kills the app at launch (D14).
4. **Signed settings.** Run `cp Config/Local.xcconfig.example Config/Local.xcconfig`. The copy
   is gitignored. To pin a specific profile, add `PROVISIONING_PROFILE_SPECIFIER = <UUID>`
   after the include line.
5. **Notary credentials.** Store an App Store Connect Team API key (Developer role) once, as
   the keychain profile `fxvault-notary`:

   ```sh
   xcrun notarytool store-credentials fxvault-notary \
     --key /path/to/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID> \
     --keychain ~/Library/Keychains/login.keychain-db
   ```

   Pass `--keychain` explicitly: without it notarytool may store the profile where a later
   `--keychain-profile` lookup cannot find it. `release-local.sh` reads the profile from the
   login keychain by default.

   The key ID, issuer and `.p8` never go into the repo. Delete the `.p8` file afterwards,
   or keep it outside the project.
6. **Tap checkout.** Either `brew tap fractalx-technologies/tap`, which gives
   `$(brew --repository)/Library/Taps/fractalx-technologies/homebrew-tap`, or a plain clone.
   With the tapped path, `bump-cask.sh` can also run `brew style`.

## Cutting a release

> **Never run an unreleased Release build on a Mac that uses FX Vault.** A Release build is
> `io.fractalx.fxvault` and opens the real vault (`~/Library/Application Support/FX Vault`).
> If its schema is newer (0.1.2 adds `v8_force_push_requested_at`), it migrates that vault and
> the installed older version refuses to open it until the new version ships. Run, test and
> profile with Debug ("FX Vault Dev", its own vault); the scheme's Profile action uses Debug.
> `release-local.sh` builds and checks the release app without launching it, and
> `FX Vault --diagnose` exits before the vault opens.

Versions are `MAJOR.MINOR.PATCH`, with an optional `-suffix` such as `0.1.0-beta.1`.
`CFBundleShortVersionString` is the numeric part, and `CFBundleVersion` is the commit
count of `HEAD`. A version with a suffix is published as a **pre-release**. Homebrew's
`livecheck` ignores pre-releases, but `brew install` still installs the version the cask
names.

1. **Check that `main` is green.** CI must pass on `main` (the `macos-26` job is the blocking
   gate), and `CHANGELOG.md` must have an entry for the version. Private vulnerability
   reporting must be on, because SECURITY.md sends reporters there:
   `gh api repos/FractalX-Technologies/fx-vault/private-vulnerability-reporting --jq .enabled`
   must print `true`. Before the first release with environment writes, run the LiveE2E write
   suite on a throwaway repository and record the results in docs/API.md (Q6).
2. **Tag and push.**

   ```sh
   git switch main && git pull --ff-only
   git tag -a v0.1.0 -m "FX Vault 0.1.0"
   git push origin v0.1.0
   ```

   The push starts `Release`, which builds and uploads the ad-hoc verification DMG.
3. **Optional rehearsal.** This runs the signed build without notarizing:

   ```sh
   scripts/release-local.sh --skip-tests --skip-notarize 0.1.0
   ```

   It runs every gate up to the signed DMG and writes nothing to `dist/`.
4. **Build, notarize and publish:**

   ```sh
   scripts/release-local.sh --publish 0.1.0
   ```

   - Before building, the script checks the tree, the tag and the signing assets. It then
     runs `scripts/ci-local.sh` (skip it with `--skip-tests`) and builds.
   - Notarization usually takes a few minutes per submission. There are two submissions,
     the app and then the DMG.
   - Outputs are `dist/FXVault-0.1.0.dmg` and `dist/FXVault-0.1.0.dmg.sha256`. With
     `--publish`, both are uploaded to the release `v0.1.0`; the release is created if
     it does not exist yet.
   - Logs are in `.build-release/0.1.0/logs/`. Notary logs are there too, in
     `notary-*-log.json`.
5. **Verify the published files:**

   ```sh
   cd dist
   shasum -a 256 -c FXVault-0.1.0.dmg.sha256
   spctl -a -vvv -t install FXVault-0.1.0.dmg   # accepted, source=Notarized Developer ID
   xcrun stapler validate FXVault-0.1.0.dmg
   gh release view v0.1.0 --repo FractalX-Technologies/fx-vault
   ```

6. **Bump the cask.** The script only writes the file; you review, commit and push:

   ```sh
   TAP="$(brew --repository)/Library/Taps/fractalx-technologies/homebrew-tap"
   git -C "$TAP" pull --ff-only
   scripts/bump-cask.sh --check-release --tap "$TAP" 0.1.0 dist/FXVault-0.1.0.dmg
   git -C "$TAP" diff
   git -C "$TAP" add Casks/fx-vault.rb && git -C "$TAP" commit -m "fx-vault 0.1.0" && git -C "$TAP" push
   ```

   `--check-release` downloads the published DMG and requires its sha256 to match.
7. **Install from the tap and audit:**

   ```sh
   brew update
   brew install --cask fractalx-technologies/tap/fx-vault
   brew audit --cask --online fractalx-technologies/tap/fx-vault
   ```

8. **Run the diagnostic on the installed app** (no window opens, nothing is read from the vault):

   ```sh
   "/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose
   ```

   The JSON must show `"version"` as the new version, `"isSignedWithAccessGroup": true`,
   `"keychainAccessGroup": "QYKC498D5D.io.fractalx.fxvault"` and a probe with `"add": 0`, <!-- gitleaks:allow (public team-prefixed access group, not a key) -->
   `"delete": 0` and `"passed": true`. Any other probe status means Touch ID items cannot be
   stored by this build: stop and check the profile and entitlements before announcing the
   release (manual check 29). Its `gh` section must show `"result": "ready"`, the gh Terminal
   runs as `chosenPath`, and your accounts (manual check 40).

   Then work through the [manual checklist](#manual-checklist-125).

Published releases are immutable. If something is wrong after publishing, fix it, then
release a new patch version. Never replace the assets of an existing release.

### What the script enforces

| Stage | Gate |
|-------|------|
| Preflight | The pinned XcodeGen version, `Config/Local.xcconfig` includes `Signed.xcconfig`, and the effective build settings (team, Developer ID identity, signed entitlements, bundle ID, profile specifier) |
| Profile | Installed and not expired. Team is `QYKC498D5D` and the app ID is `QYKC498D5D.io.fractalx.fxvault`. It is a macOS Developer ID profile (all devices), and its keychain groups allow the app's group |
| Identity | A valid Developer ID Application identity of the team whose certificate is in the profile. The app and the DMG are signed with the same SHA-1 |
| Notary | `notarytool history` works with the keychain profile (checked before the build) |
| App | `codesign --verify --deep --strict`. Universal `arm64 x86_64`. Bundle ID and versions. `CFBundleName` and `CFBundleDisplayName` are "FX Vault" in `Info.plist` and in any localized `InfoPlist.strings`. Hardened runtime. `Authority=Developer ID Application … (QYKC498D5D)` with a secure timestamp. Entitlements contain `keychain-access-groups` `QYKC498D5D.io.fractalx.fxvault` and no `get-task-allow`. The embedded profile's team and UUID match |
| After notarization | `stapler validate`, `spctl -t exec` reports `source=Notarized Developer ID`, `syspolicy_check distribution` passes |
| DMG | `hdiutil verify`, a test mount that shows `FX Vault.app` and the `Applications` link, the Developer ID signature, notarization, staple, `stapler validate`, and `spctl -a -vvv -t install` reports `source=Notarized Developer ID` |
| Publish | The tree is clean, tag `v<version>` exists locally and on GitHub with the same SHA and points at `HEAD`, and the release does not already have the DMG |

### Troubleshooting

| Message | Fix |
|---------|-----|
| `Config/Local.xcconfig is missing` | `cp Config/Local.xcconfig.example Config/Local.xcconfig` |
| `no valid provisioning profile 'FX Vault Developer ID' is installed` | Download it again and double-click it, or pass `--profile <file>` |
| `none of the Developer ID identities in the keychain is in profile …` | The profile was made with another certificate. Regenerate it on developer.apple.com and include the installed certificate |
| `notarytool keychain profile 'fxvault-notary' works` fails | Run `store-credentials` again (setup step 5). Check that the key is not revoked |
| `notarization of app ended with status 'Invalid'` | The issues are printed, and the full log is in `.build-release/<v>/logs/notary-app-log.json` |
| `tag v… is not on FractalX-Technologies/fx-vault yet` | `git push origin v…` |
| `… already exists: remove it, or bump the version` | `dist/` already holds that version. Delete it only if it was never published |

## Manual checklist (§12.5)

Run this checklist on the **notarized DMG installed through the tap**. Each item needs a
screenshot as evidence, saved with the release notes or in the Review section of
`tasks/todo.md`.

1.0 removed rows 12, 24, 35–39, 45 and 46 (nearby, chat, teammates) and 44 (Overview and
`fxvault.yml`); the other numbers stay
as release notes cite them.

| # | Area | Steps | Expected |
|---|------|-------|----------|
| 1 | Touch ID: enable | Settings > Security > enable Touch ID (asks for the master password) | The toggle is on, and the next unlock offers Touch ID |
| 2 | Touch ID: unlock | Lock the vault, then unlock with a finger | Unlocks; no password asked |
| 3 | Touch ID: cancel and fallback | Lock, then cancel the Touch ID sheet. Lock again and choose "Use Master Password" | Cancel: no error, the vault stays locked. Fallback: the password field is focused. Touch ID stays enabled in both cases |
| 4 | Touch ID: re-enrollment | Add or remove a fingerprint in System Settings, then unlock | The master password is required, and Touch ID offers to re-enable |
| 5 | Touch ID: restart | Restart the Mac, then open FX Vault | The master password is required once after the restart |
| 6 | Lock on sleep | `pmset sleepnow` (or Apple menu > Sleep), then wake the Mac | The vault is locked |
| 7 | Lock on screen lock | ⌃⌘Q, then log back in | The vault is locked |
| 8 | Lock when idle | Set auto-lock to 1 minute, then leave the Mac untouched | Locks within about 1 minute 15 s (checked every 15 s) |
| 9 | Lock on window close | Close the main window, then reopen it | The vault is locked |
| 10 | Clipboard clearing | Copy a secret value, then wait 30 s. Also: copy, then lock or quit | The clipboard is cleared, unless something else was copied since |
| 11 | Layout | macOS 26 and 27, narrowest and widest window, light and dark: Onboarding (every step), Lock, Recovery reset, Preferences (each tab, locked and unlocked), the main window | Nothing clipped or overlapping; one screenshot per screen and OS |
| 13 | Gatekeeper | Download the DMG in Safari and open it | Only the standard "downloaded from the Internet" dialog; `spctl -a -vvv -t install` reports Notarized Developer ID |
| 14 | Tahoe smoke | macOS 26 VM: install with Homebrew, then onboarding, gh detection, import, sync on the spike repo; on a macOS 15 Mac, `brew install` | Everything works on 26; on 15, `depends_on macos: :tahoe` refuses the install |
| 15 | Spike repos | Import, edit, sync and drift review on the spike repos | Matches the M3/M5 verify notes |
| 16 | Touch ID: status codes | On the signed build, trigger a lockout (5 failed fingers) and an enrollment change while Touch ID is on | Lockout asks for the password and keeps the item; the enrollment change turns Touch ID off and asks to re-enable (confirms the Keychain status mapping in SECURITY-MODEL.md §5) |
| 17 | Re-authentication | Export .env and File › Share Project… with Touch ID on; cancel once, choose "Use Master Password" once; repeat on an ad-hoc build | Each prompt names its purpose; cancel shows no error; the fallback focuses the password field; the ad-hoc build offers only the password |
| 18 | gh setup | Launch with gh missing, with gh older than 2.97, and logged out; then Check Again and Not Now | `GHSetupScreen` shows the matching kind with copyable commands; Check Again does not flicker; Not Now works offline until gh is ready; Sync and New Repository stay disabled without gh |
| 19 | Main window | With nothing selected, the "Choose a place" home with the pending count and the ⌘K hint. Sidebar with several accounts and organizations: open an owner with its chevron and click Show N more; Edit › Find (⌘F), also with the sidebar hidden; Approve under an owner that needs `admin:org`; Import, Clone, Remove from vault, Add repository by name; ⌘K (and Edit › Jump Anywhere, the toolbar's search button): type part of a name, ↑↓, ↩, esc, then part of a secret's and of a variable's name; ⌘N, ⇧⌘I, ⌃⌘L, ⇧⌘S and the Share menu with and without a selection | Owners start collapsed and list only the repositories in the vault until Show N more; ⌘F brings the sidebar back, focuses the search and opens the owners of the matches; ⌘K lists every place, filters as you type, ↩ selects the place in the sidebar; "Secrets by name" lists the secrets and variables by name only, with where each is, and ↩ on one opens its place with that row selected (Secrets or Variables); and the palette closes on esc, a click outside, a sheet or the lock; Approve opens Settings › Accounts; groups and badges as in §10; menu items enable and disable with the selection and the lock; the Dock badge and Sync label show the pending count |
| 20 | Reveal and re-mask | Reveal a secret, then wait 30 s; reveal, switch to another app; reveal, change scope; reveal, lock | The value is masked again in each case; variables show in plain text |
| 21 | Sheet keyboard rules | Return and Esc in: Sync deletions review, drift review, share import preview, .env export iCloud warning, item editor (value field) | Return does nothing in the deletions review, never imports a share, picks "Choose Another Location" on the iCloud warning; Esc cancels |
| 22 | `.fxvault` open | With the vault locked, double-click two `.fxvault` files in Finder (and receive one by AirDrop) | The window comes back, unlock comes first, then one import sheet per file, one at a time |
| 23 | Share as file | File › Share Project… (or Share Securely… on a place), Create File, copy the passphrase, Save File… and Share… › AirDrop; import the file on a second Mac | The passphrase copy clears after 30 s; the saved file is 0600; the staging folder under `$TMPDIR/io.fractalx.fxvault.shares/` is gone after the sheet closes or AirDrop ends; the import preview matches |
| 25 | .env files | Import: open panel shows `.env`, edit a key and kind in the table, pick an environment. Export: save into an iCloud Drive folder, then into a git repository that does not ignore `.env` | Hidden files are listed; table edits stick; the iCloud warning comes before any write; the `.gitignore` offer adds the line; the file is 0600 |
| 26 | New Repository and clone | Stage Repository with two environments (chips; click one to edit its rules, × removes it), a repository secret and an environment variable (Add Variable… asks for the scope), Clone on with and without an SSH alias mapped; Sync Now; then Clone from the Sync result without a clone folder set; then New Environment… on a repository: a free name, a taken one, Selected branches and tags with a branch and a tag rule | The forms match boards NewRepo and NewEnvironment in light and dark (pop-ups open menus with a check, the alias box shows the account's alias or "No SSH alias" with the warning); nothing reaches GitHub before Sync; the new repository is selected in the sidebar; Sync creates and clones it; Clone asks for a folder when none is set; New Environment says "Not used in <repository> yet" or why not, rules show as `main · branch ×` chips and Stage Environment adds it to the sidebar |
| 27 | Screen capture | Start a screen recording while the item editor, the New Repository item editor, the .env import sheet, a share passphrase or the recovery key is on screen | Those windows are blank in the recording (a value revealed in the main table is not protected) |
| 28 | Live write E2E | With approval for each repository: `FXV_LIVE_E2E=1 FXV_LIVE_E2E_WRITE=1 FXV_LIVE_E2E_FREE_ORG=<org> FXV_LIVE_E2E_REPORT=<file> swift test --package-path Packages/FXVaultKit --filter LiveE2E` | Passes; the report fills the open Q6 facts in API.md; delete the two `fx-vault-e2e*` repositories by hand afterwards |
| 29 | Touch ID: `--diagnose` | In Terminal: `"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose` | JSON only, no window or prompt: `isSignedWithAccessGroup` true, `keychainAccessGroup` `QYKC498D5D.io.fractalx.fxvault`, `biometryAvailable` true, `probe.add` 0 and `probe.delete` 0 (`passed` true). On an ad-hoc build: `probe.skipped` true, `skippedReason` `unsignedBuild` |
| 30 | Touch ID: unlock offer | With Touch ID off and the offer never answered (`defaults delete io.fractalx.fxvault preferences.touchIDOfferAnswered`), lock and unlock with the password; choose Not Now; lock and unlock again; then delete the key again, unlock with the password and choose Turn On Touch ID | The sheet "Unlock FX Vault with Touch ID" appears after the password unlock, Not Now is not asked again, Turn On enables Touch ID and the next lock shows "Unlock with Touch ID". Never shown on an ad-hoc build |
| 31 | Touch ID: reason on the lock screen | With Touch ID on: restart the Mac, open FX Vault; set the clock 15 days ahead and lock | "Password required: After a restart" and "Password required: Every 14 days" under the password field, no Touch ID button |
| 32 | Bulk paste | Copy a `.env` with several lines (one invalid). On the Variables tab press ⌘V on the table; on the Secrets tab choose ⋯ › Paste Multiple… and press ⌘V in the editor; also try the editor's Paste button and Clear; on an environment, paste a name that already exists | ⌘V opens the preview filled with the text; Paste Multiple… opens with the cursor in the editor; rows start as the tab's kind; a credential-looking variable shows Make Secret; the invalid line is listed with its line number; edits update the table without a Review step; the target is the open environment; Overwrite All switches every conflict; nothing is read from the clipboard until you paste |
| 33 | Share any combination | File › Share Project… on a repository with repository-level items and two environments: check the repository level plus one whole environment; then only two items of the other environment; import both files on a second Mac | The tree shows tri-state boxes, "With branch policy" on the whole environment and "Selected items only" on the mixed one; the counts per scope match; the receiver's preview offers a policy row only for the whole environment and keeps its own policy for the partial one |
| 34 | Connectivity banner | With a repository open: turn Wi-Fi off (no cable); turn it on again; then block GitHub only (Network Link Conditioner "100% Loss" with a profile limited to github.com, or a VPN that drops it) and open another repository | Offline: "No internet connection" within about 2 s; Sync, New Repository, Import, Add by name, Clone, Refresh are disabled with the explanation as help; local edits still save. Back online: the banner hides, the repository lists reload and the drift check runs again. GitHub blocked: "GitHub isn't responding" with Retry; Retry after unblocking clears it |
| 40 | gh login detection (v0.3.1) | (a) An Enterprise Managed User account (`name_code`) logged in to gh; (b) `export GH_TOKEN=…` in `~/.zshrc` with no stored account, then `env -u GH_TOKEN -u GITHUB_TOKEN gh auth login`; (c) a test user whose Homebrew belongs to another administrator; (d) `GH_CONFIG_DIR` set only in `~/.zshrc`. Each time: Copy Diagnostics and `--diagnose` | (a) Ready, the account in Settings › Accounts; (b) the setup screen explains `GH_TOKEN`, Check Again is ready after the login, Settings › Accounts shows the note; (c) the owner is named, Trust This gh works, Settings › Advanced lists it and Revoke asks again; (d) the accounts of that config dir appear. The reports name the gh, shell, probe mode and variables, and contain no token or variable value |
| 42 | Destinations: Azure Key Vault (v0.8.0, experimental) | **Only a sandbox vault in a subscription FractalX owns**, never a client's tenant. `az login`; Add Destination › Azure Key Vault; add `DATABASE_URL`; Sync; Refresh; delete it and Sync; lock the vault and Sync again. Also with `az` logged out | The vault shows `DATABASE-URL`; the delete is a soft delete (listed under deleted secrets); after the lock the next Sync asks `az` for a new token; logged out, the review blocks the destination and offers `az login` to copy. Live suite: `FXV_LIVE_DEST_AZ_TOKEN=1 FXV_LIVE_DEST_KEYVAULT=<vault> swift test --package-path Packages/FXVaultKit --filter LiveDestination` |
| 47 | Production behind its own confirmation (1.0, B3b) | Share Project on a repository with a staging and a production stage: check production (cancel Touch ID once, then accept); then a tree with a production environment checked by hand; Create, then Send with AirDrop to Mac B; then 1 day, open it on Mac B with the six words; set Mac B's clock (or wait) past the expiry and open it again; also open a 0.9 teammates file | Production starts unchecked with a production tag; cancelling Touch ID leaves it unchecked, accepting checks it and Create asks nothing more; a production environment in the tree asks for confirmation at Create and the note under the tree names it; Send with AirDrop is disabled until "I've saved it" and opens the AirDrop window; the passphrase file shows "Not verified"; after the expiry FX Vault refuses it with "This file expired"; the 0.9 teammates file shows "Wrong passphrase or damaged file" |
| 48 | From Files and Settings › Sharing (v0.9.0) | On Mac B after #47: the imported rows; Sync without including the file; Sync again including it; Push on Next Sync on another held row. On Mac A: Settings › Sharing | Imported rows show Held in the table and the Overview; the first Sync leaves them out and offers the file again; the second pushes them and they show Synced; Push on Next Sync releases only that row. Settings › Sharing lists both files as Active with their date, repositories, stages, counts and expiry time, and Show names lists the names per place, never values; Remove from List leaves the file alone |
| 49 | Upgrade drops Supabase and Vercel (1.0) | A 0.9 vault with a Key Vault, a Supabase and a Vercel destination (a throwaway copy of the vault folder); install 1.0, unlock; then open a 0.9 project file that carries a Vercel destination | One alert lists `owner/name · Supabase <ref>` and `owner/name · Vercel <project> (<environment>)`; OK closes it and the next unlock shows nothing; the Key Vault destination and its items are intact; nothing changed in Supabase or Vercel. The file's preview says "Left out: Vercel …" and imports the rest |
| 50 | Organization access (1.0, B4) | With an account that owns one organization and is a plain member of another, first without `admin:org` (check `gh auth status`): open Settings › Accounts; copy and run the commands; approve in the browser; Re-check | Without the scope the owned organization shows Needs admin:org with the commands and the other shows Org secrets need an org admin; after Re-check the owned one shows Ready; an SSO organization shows Needs SSO authorization with Open SSO Page |
| 51 | Organization secrets, read only (1.0, B5c) | With an account Ready for an organization that has secrets for all, private and selected repositories and a variable: select the organization's node in the sidebar; Import; then Remove from Vault… and confirm | The node opens the organization's place with Import; Import lists every secret with Value missing and every variable masked, each with its visibility ("Selected · N repositories" matching GitHub) and Updated; Remove from Vault brings back Import and nothing changes on GitHub |
| 52 | A place's header and ⋯ More (1.0, D6c3) | On a repository, an environment, an organization, a Key Vault and a folder: read the header; open ⋯ and use each item (New Secret, New Variable, Paste Multiple…, Import .env…, Export .env…, Copy To with and without a selection, Share Securely…, Deployment Branches… on an environment, Clone…, Refresh, Delete Selected… on one live row and on a selection of pending deletions only); right-click an environment row | The header reads "kind · parent · counts" ("1 without value" counts secrets only) with "N changed on GitHub · Review" after drift; Refresh shows Refreshing… until gh or `az` answers; Delete Selected… stays disabled with nothing selected or only pending deletions; actions the account may not take are disabled; the environment row menu offers Rename…, Duplicate Environment…, Share Securely…, Refresh and Delete Environment… (Revert Changes when something can be undone) |
| 53 | Sync run and finish (1.0, D6d-1) | Sync changes in a repository, one of its environments and a Key Vault, with one blocked change and one deletion (Review Deletions, then Delete); then a longer run and Cancel After Current; then Sync a secret turned into a variable with Sync Without Deleting | Every line goes from a ring to a spinner to a check (a cross when it fails), the blocked line reads "blocked · reason" with a dash, the deletions card comes last; Cancel After Current stops after the write in flight and keeps the full result; a run where nothing failed ends on the short finish ("Synced N changes", its places, what stays pending); the converted variable's line ends with a check. Light and dark match boards Sync-Progress, Sync-Done and Sync-Delete |
| 54 | Share Securely and opening a file (1.0, D6d-5) | Share a repository with production ticked: look over the dialog, Create File, copy the passphrase, tick "I've saved it", Save File…; on Mac B open it with a wrong passphrase, then the right one, and Import as Held; then open an expired file | One choosing dialog (repositories, stages with the production tag, the tree with its counts, the production note naming the place, Expires after) with Create in it; the passphrase on one line with Copy and "The clipboard clears in 30 s."; the delivery buttons wait for "I've saved it"; Open takes the six words in one mono field with the word count, a wrong passphrase shows "Wrong passphrase or damaged file" under it; the preview lists what the file adds, one dot per repository, over "Nothing reaches GitHub or Azure until you include it in Sync."; an expired file shows "This file expired", the file name and OK |
| 55 | Settings (1.0, D6d-6) | Open each Settings tab, light and dark, locked and unlocked; change Lock after inactivity and the clone folder; turn Touch ID off and on; in Accounts change an SSH alias, Test and Re-check; in Advanced set and clear the gh path override, then Reset Vault… with a wrong password and Cancel | Tabs match the Settings boards: group titles over rounded cards, small outline buttons, Reset Vault… in red; locked Security, Accounts and Sharing ask to unlock while General and Advanced work; the alias menu, Test and Re-check behave as before; the gh in use shows its version and path; the reset dialog shows the error, and Cancel erases nothing |
| 56 | Main window chrome (1.0, D6c2b) | In light and dark, at the default size, resized narrow and wide, in full screen and back, and with View › Hide Sidebar (⌃⌘S) | No title bar or title: the sidebar and the toolbar float as rounded glass panels 8 pt from the window's edges on the soft ground; close, minimize and zoom sit inside the sidebar's top corner, above its search field, show their symbols on hover and work; they stay there after a resize and after full screen; with the sidebar hidden the toolbar starts after them and ⌃⌘S or ⌘F brings the sidebar back; dragging the toolbar's empty part, the sidebar's top band or a gutter moves the window (the path text and the detail's empty parts do not: the path keeps its tooltip), and double-clicking them zooms (or minimizes, as System Settings › Desktop & Dock says); in an inactive window the first click on the toolbar's Sync button only activates the window; dragging the gutter after the sidebar resizes it between 240 and 400 pt, and the width is back after a relaunch; with the sidebar hidden the window narrows no further than with it shown, and ⌃⌘S then shows it without the detail running past the window edge; in full screen with the sidebar hidden the toolbar starts at the 8 pt inset; the recovery-key strip sits under the toolbar |
| 57 | Copy All (1.0, D6c4) | With Touch ID on, on an environment with a secret without a value and a variable: click Copy All; paste into a text editor; wait 30 s and paste again. Then turn Touch ID off and use Copy All from ⋯ on a Key Vault and an organization with the master password, once with a wrong one | Touch ID asks before anything is copied; the paste reads `# Secrets · N`, the secrets with the empty one as `KEY=`, a blank line, `# Variables · N`; after 30 s the clipboard is empty; the sheet says how many values were copied; a wrong password copies nothing and says so; a clipboard manager that honours the concealed marker does not keep it |
| 58 | Delete and Export .env (1.0, D6d-2) | Delete one synced secret, then a selection of a synced and a new item, in an environment, an organization, a Key Vault and a folder; press Return, then Esc, then Delete. Export .env from an environment into a git working tree that does not ignore `.env`, then into iCloud Drive | The dialog names the count and the place, lists the names and says what the next Sync does there; Return deletes nothing, Esc cancels, Delete marks synced items Deleted and removes new ones. Export is titled with the place; the warnings sit in one box; "Add /.env to .gitignore" beside its note adds that line; a secret and a variable with one name are two rows, each with its kind; the iCloud step shows Save to with the path |
| 59 | Folder, Key Vault and organization views (1.0, D6d-4) | On a repository with a linked secret, look at its tag, then edit it and type a new value; make one copy's environment read only and type again. On a Key Vault with a disabled secret and a certificate-backed one, Refresh before and after changing a secret in the Azure portal. Open an organization with an all, a private and a selected item | The tag says "2 places"; the editor lists each copy as "owner › repo › environment" with a checkbox and Same value or Differs, and the read-only one without a checkbox and "can’t update · read only". The Key Vault header says "No changes since your last sync", then "1 changed in Key Vault" with Review; under the table one line per hidden kind (its names as help; a name like github-token with a warning triangle) and the dash rule. Visibility reads "all repos", "private and internal", "selected · N repos" |
| 60 | Inherited organization items (1.0, B7a) | With an organization in the vault that has an all secret, a private variable and a selected secret, open a private repository of it, then a public one; give the selected secret a list with the repository; add a repository secret with the all secret's name; open an environment | The private repository lists the all secret and the private variable after its own rows, muted, "example-org · all repos" / "· private and internal", Status Inherited, no menu and no edit on double-click; the public one only the all secret; the selected one appears once its list names the repository; the repository's own secret says "· Overrides example-org" and the inherited row of that name is gone; the environment lists them too, minus what the repository level overrides. On a GitHub Free organization the private repository still lists them (FX Vault doesn't know the plan; GitHub doesn't give them to it) |
| 61 | Azure › subscription › vault (1.0, D6c6) | Connect Azure with vaults in two subscriptions; then, on a vault connected before 1.0 (a copy of a 0.9 vault folder), Refresh; search a subscription's name; close and open a subscription | The sidebar shows Azure, then each subscription by name with the cloud symbol and its vaults under it; the older vault sits directly under Azure until its Refresh, then moves under its subscription; the search shows that subscription open with its vaults only; the chevron closes and opens it; a vault's context menu and detail work as before |
| 62 | Organization Refresh (1.0, B7b) | In an imported organization, change on GitHub (web) one secret's visibility, add a variable and delete another; edit a third item here; then ⋯ More › Refresh, Review, and take each choice once; Refresh again | Refreshing… then "3 changed on GitHub · Review"; those rows say "Changed on GitHub"; the review lists them with Keep Local / Accept GitHub; Keep Local of a secret without a value is disabled with "Fill it first"; taking GitHub's deletion asks first, and so does taking GitHub's item over one added here too (add the same name on both sides); each resolved row loses its mark; the second Refresh says "Nothing changed on GitHub" and the next Sync sends only what Keep Local kept |

## CI (`release.yml`)

On a `v*` tag push, or by hand with `workflow_dispatch` and an optional `version` input:

1. **`meta`**: works out the version (from the input or the tag) and validates it.
2. **`adhoc`**: runs on `macos-26` and picks the newest GA `Xcode_26*.app` through
   `.github/actions/setup-toolchain`. It runs
   `scripts/release-local.sh --adhoc <version>`, which first runs the tests through
   `scripts/ci-local.sh`, then the ad-hoc gates:
   - entitlements without `keychain-access-groups` or `get-task-allow`
   - hardened runtime
   - a universal binary

   It uploads `FXVault-<version>-adhoc.dmg` and its `.sha256` as a 14-day workflow
   artifact. This DMG is **not** a release asset.
3. **`signed`**: optional, in environment `release`. It needs `adhoc` to succeed. It does
   real work only when all six secrets below are set (job-level `HAS_SIGNING` and
   `HAS_NOTARY`); otherwise it records a notice and does nothing. With the secrets set, it:
   - imports the `.p12` into a temporary keychain
   - installs the profile and writes `Config/Local.xcconfig`
   - stores the notary key as `fxvault-notary` in the temporary keychain
   - runs `scripts/release-local.sh --skip-tests --publish`; it publishes only on tags
   - attests the DMG with `actions/attest`
   - deletes the keychain, the profile and the key, even if a step failed

   | Secret / variable | Content |
   |-------------------|---------|
   | `MACOS_CERT_P12_BASE64` | base64 of the Developer ID Application `.p12`. Export it from Keychain Access; an OpenSSL 3 export needs `-legacy`, or `security import` rejects it |
   | `MACOS_CERT_PASSWORD` | the `.p12` password |
   | `MACOS_PROFILE_BASE64` | base64 of the *FX Vault Developer ID* profile |
   | `ASC_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect Team API key |
   | `APPLE_TEAM_ID` (variable) | `QYKC498D5D`, also the default |

**Current decision: none of these secrets are set.** Use only one publisher per version,
either the Mac or CI. Build provenance attestations (`gh attestation verify`) exist only
for releases that CI signed. A local release is verified with its `.sha256`, `spctl` and
`stapler validate`.

All actions are pinned to full commit SHAs. The workflow's default permission is
`contents: read`. Only the `signed` job gets `contents: write`, `id-token: write` and
`attestations: write`.

## Forks and ad-hoc builds

Forks build without an Apple account:

```sh
scripts/release-local.sh --adhoc --skip-tests 0.1.0
# or: open FXVault.xcodeproj and Run (Base.xcconfig is ad-hoc by default)
```

Ad-hoc builds limit what the app can do:
- **No Touch ID.** The toggle is disabled and shows *"Touch ID requires the official signed
  release."* The keychain group needs a profile signed by the team (D14).
- **Gatekeeper blocks the first open** of a downloaded ad-hoc build, such as the CI
  artifact. To allow it, either:
  - open System Settings > Privacy & Security and choose **Open Anyway** for FX Vault,
    then confirm, or
  - for a build you made or trust, run
    `xattr -dr com.apple.quarantine "/Applications/FX Vault.app"`.
- Each new ad-hoc build has a different code signature, so macOS asks for approval again
  after every update.
