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
   release (manual check 29).

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
| 11 | Layout | macOS 14 and 27, narrowest and widest window, light and dark: Onboarding (every step), Lock, Recovery reset, Preferences (each tab, locked and unlocked), the main window | Nothing clipped or overlapping; one screenshot per screen and OS |
| 12 | Local Network prompt | A fresh macOS user account, Nearby share | The system prompt shows the `NSLocalNetworkUsageDescription` text ("…to share configuration and chat with a nearby teammate.") |
| 13 | Gatekeeper | Download the DMG in Safari and open it | Only the standard "downloaded from the Internet" dialog; `spctl -a -vvv -t install` reports Notarized Developer ID |
| 14 | Sonoma smoke | macOS 14 VM: install with Homebrew, then onboarding, gh detection, import, sync on the spike repo | Everything works; `depends_on macos: :sonoma` allows the install |
| 15 | Spike repos | Import, edit, sync and drift review on the spike repos | Matches the M3/M5 verify notes |
| 16 | Touch ID: status codes | On the signed build, trigger a lockout (5 failed fingers) and an enrollment change while Touch ID is on | Lockout asks for the password and keeps the item; the enrollment change turns Touch ID off and asks to re-enable (confirms the Keychain status mapping in SECURITY-MODEL.md §5) |
| 17 | Re-authentication | Export .env, Share › File… and Share › Nearby… with Touch ID on; cancel once, choose "Use Master Password" once; repeat on an ad-hoc build | Each prompt names its purpose; cancel shows no error; the fallback focuses the password field; the ad-hoc build offers only the password |
| 18 | gh setup | Launch with gh missing, with gh older than 2.97, and logged out; then Check Again and Not Now | `GHSetupScreen` shows the matching kind with copyable commands; Check Again does not flicker; Not Now works offline until gh is ready; Sync and New Repository stay disabled without gh |
| 19 | Main window | Sidebar with several accounts and organizations, search, Import, Clone, Remove from vault, Add repository by name; ⌘N, ⇧⌘I, ⌃⌘L, ⇧⌘S and the Share menu with and without a selection | Groups and badges as in §10; menu items enable and disable with the selection and the lock; the Dock badge and Sync label show the pending count |
| 20 | Reveal and re-mask | Reveal a secret, then wait 30 s; reveal, switch to another app; reveal, change scope; reveal, lock | The value is masked again in each case; variables show in plain text |
| 21 | Sheet keyboard rules | Return and Esc in: Sync deletions review, drift review, nearby code check, share import preview, .env export iCloud warning, item editor (value field) | Return does nothing in the deletions review and the code check, never imports a share, picks "Choose Another Location" on the iCloud warning; Esc cancels |
| 22 | `.fxvault` open | With the vault locked, double-click two `.fxvault` files in Finder (and receive one by AirDrop) | The window comes back, unlock comes first, then one import sheet per file, one at a time |
| 23 | Share as file | Share › File…, copy the passphrase, Save… and AirDrop…; import the file on a second Mac | The passphrase copy clears after 30 s; the saved file is 0600; the staging folder under `$TMPDIR/io.fractalx.fxvault.shares/` is gone after the sheet closes or AirDrop ends; the import preview matches |
| 24 | Nearby (experimental) | Two signed builds on one network: send and receive, "Don't match" once, deny Local Network once, close the receive sheet | Same 6-digit code on both; mismatch stops both with nothing sent; denial shows the System Settings guidance; a closed receive sheet is no longer discoverable; the first HELLO is delivered (the sender starts the connection right before the session sends it) |
| 25 | .env files | Import: open panel shows `.env`, edit a key and kind in the table, pick an environment. Export: save into an iCloud Drive folder, then into a git repository that does not ignore `.env` | Hidden files are listed; table edits stick; the iCloud warning comes before any write; the `.gitignore` offer adds the line; the file is 0600 |
| 26 | New Repository and clone | Create with environments, rules and items, Clone on; Sync Now; then Clone from the Sync result without a clone folder set | Nothing reaches GitHub before Sync; the new repository is selected in the sidebar; Sync creates and clones it; Clone asks for a folder when none is set |
| 27 | Screen capture | Start a screen recording while the item editor, the New Repository item editor, the .env import sheet, a share passphrase or the recovery key is on screen | Those windows are blank in the recording (a value revealed in the main table is not protected) |
| 28 | Live write E2E | With approval for each repository: `FXV_LIVE_E2E=1 FXV_LIVE_E2E_WRITE=1 FXV_LIVE_E2E_FREE_ORG=<org> FXV_LIVE_E2E_REPORT=<file> swift test --package-path Packages/FXVaultKit --filter LiveE2E` | Passes; the report fills the open Q6 facts in API.md; delete the two `fx-vault-e2e*` repositories by hand afterwards |
| 29 | Touch ID: `--diagnose` | In Terminal: `"/Applications/FX Vault.app/Contents/MacOS/FXVault" --diagnose` | JSON only, no window or prompt: `isSignedWithAccessGroup` true, `keychainAccessGroup` `QYKC498D5D.io.fractalx.fxvault`, `biometryAvailable` true, `probe.add` 0 and `probe.delete` 0 (`passed` true). On an ad-hoc build: `probe.skipped` true, `skippedReason` `unsignedBuild` |
| 30 | Touch ID: unlock offer | With Touch ID off and the offer never answered (`defaults delete io.fractalx.fxvault preferences.touchIDOfferAnswered`), lock and unlock with the password; choose Not Now; lock and unlock again; then delete the key again, unlock with the password and choose Turn On Touch ID | The sheet "Unlock FX Vault with Touch ID" appears after the password unlock, Not Now is not asked again, Turn On enables Touch ID and the next lock shows "Unlock with Touch ID". Never shown on an ad-hoc build |
| 31 | Touch ID: reason on the lock screen | With Touch ID on: restart the Mac, open FX Vault; set the clock 15 days ahead and lock | "Password required: After a restart" and "Password required: Every 14 days" under the password field, no Touch ID button |
| 32 | Bulk paste | Copy a `.env` with several lines (one invalid). On the Variables tab press ⌘V on the table; on the Secrets tab choose Add › Paste Multiple… and press ⌘V in the editor; also try the editor's Paste button and Clear; on an environment, paste a name that already exists | ⌘V opens the preview filled with the text; Paste Multiple… opens with the cursor in the editor; rows start as the tab's kind; a credential-looking variable shows Make Secret; the invalid line is listed with its line number; edits update the table without a Review step; the target is the open environment; Overwrite All switches every conflict; nothing is read from the clipboard until you paste |
| 33 | Share any combination | Share › File… on a repository with repository-level items and two environments: check the repository level plus one whole environment; then only two items of the other environment; import both files on a second Mac (0.2.0), and the first one on a 0.1.x Mac | The tree shows tri-state boxes, "With branch policy" on the whole environment and "Selected items only" on the mixed one; the counts per scope match; the receiver's preview offers a policy row only for the whole environment and keeps its own policy for the partial one; 0.1.x opens the first file and rejects the second ("Wrong passphrase or damaged file") |
| 34 | Connectivity banner | With a repository open: turn Wi-Fi off (no cable); turn it on again; then block GitHub only (Network Link Conditioner "100% Loss" with a profile limited to github.com, or a VPN that drops it) and open another repository | Offline: "No internet connection" within about 2 s; Sync, New Repository, Import, Add by name, Clone, Refresh are disabled with the explanation as help; local edits still save. Back online: the banner hides, the repository lists reload and the drift check runs again. GitHub blocked: "GitHub isn't responding" with Retry; Retry after unblocking clears it |
| 35 | Nearby share without a shared network | Two signed 0.2.0 Macs about 2 m apart, Wi-Fi on but disconnected from every network (Option-click the Wi-Fi menu › Disconnect, or forget the network), Bluetooth on, no cable. Share › Nearby… on one, Receive Nearby… on the other; repeat once with both on the same Wi-Fi network | Each Mac finds the other, the 6-digit codes match, the import preview opens and the import completes, with and without a shared network |
| 36 | Nearby Chat without a shared network | Same setup as #35. Open Share › Nearby Chat… on both: check the names, connect, compare codes, send text both ways (including a long message and emoji), attach a secret with Touch ID, then "Save to my vault" on the other Mac; attach a variable and Dismiss it | Each Mac lists the other by its Settings › General name (not itself); both show the same code with no default button; messages appear in order with times; the receiver's card shows name, kind and scope but never the value; Save opens the import preview and the item lands in the vault; Dismiss imports nothing |
| 37 | Nearby Chat ends and wipes | During a chat, on one Mac at a time: close the chat window; End Chat; ⌃⌘L; sleep (`pmset sleepnow`); screen lock (⌃⌘Q); walk out of range (or turn Wi-Fi off); leave the chat idle for 10 minutes; close the main window | Every case ends the chat on both Macs with "Conversation ended. Nothing was saved." and an empty transcript; reopening the window starts at the people list; the window is not restored after relaunch; the Window menu lists Nearby Chat |
| 38 | Nearby Chat availability and permissions | Turn Wi-Fi off with the chat window open; turn it on without joining a network; from a fresh macOS user, open Nearby Chat first (before any share) and deny Local Network once, then allow it in System Settings | Wi-Fi off: "Turn on Wi-Fi to chat nearby"; Wi-Fi on without a network: available; no internet never blocks it. The Local Network prompt shows the text that mentions chat; denial shows the System Settings guidance and Try Again works after allowing |
| 39 | Nearby with the firewall | On the receiving Mac turn on the macOS firewall, then "Block all incoming connections"; try Receive Nearby and being listed in Nearby Chat | With the firewall on, FX Vault can receive (allowed when the firewall asks, or automatically for the signed app); with "Block all incoming connections" the other Mac cannot connect and reports a failed connection, as the README says |

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
