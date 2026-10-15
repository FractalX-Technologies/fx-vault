# FX Vault - Implementation Plan

**Status (2026-10-15):** v0.1.0 beta built and released: a universal DMG, Developer ID-signed, notarized and stapled, published on `FractalX-Technologies/fx-vault` (tag `v0.1.0`) and installed with `brew install --cask fractalx-technologies/tap/fx-vault`. Milestones 1–7 are implemented on `main` (3b0e9b9, 101b22c, b062759, 9bf1419). 967 package tests (13 of them opt-in live tests) and 288 app tests pass, CI is green on `macos-26` (blocking) and `xcode-27`, and the live write E2E suite passed against real GitHub (docs/API.md "Write run, 2026-10-15"). Nearby sharing ships as experimental. Still open: the §11 items marked *Pending* (hardware and manual checks, the second gh account, the rest of the Q6 facts) and the gaps marked *Not done* or *Gap*.

**Baseline:**
- Dev machine: macOS 27.0, Xcode 27.0 (27A266a), Swift 6.4.
- The code must stay Swift 6.3-compatible, because the blocking CI gate builds with Xcode 26.6.
- Deployment target: macOS 14.0.
- Dependencies: GRDB 7.11.1 and swift-sodium 0.11.0 (libsodium 1.0.22).
- gh 2.102.0 is installed (upgraded in Phase 0). The hard floor is **2.97.0** (it escapes environment names in `gh secret`/`gh variable` set, list and delete).
- XcodeGen is pinned at 2.45.4.

**Delivery authorization (Bryan, 2026-10-15, chat):** plan approved. Until the beta is delivered, Claude may autonomously commit, push, tag and publish releases on `FractalX-Technologies/fx-vault` (created **public** now), publish the cask to `FractalX-Technologies/homebrew-tap`, and run `brew upgrade gh`. Signing and notarization run **only on Bryan's Mac**: no certificates or Apple keys go to GitHub. Scope: as many milestones as possible; anything not fully verified ships marked *experimental*. Only the Apple values in the root `.env` may be used; it is never committed. The normal per-operation rule applies again after delivery.

**Process rules (from CLAUDE.md):**
- Claude never commits, pushes, tags or rewrites history without Bryan's explicit permission, given separately for each operation.
- Each milestone ends with the work left in the working tree, a demo, docs updated, and the Review section filled in.
- Bryan commits.

**Research artifacts:** the raw, unsanitized research was copied from the session scratchpad into `.research/` (must stay gitignored; see `.research/README.md`). The third step of M1 moves a sanitized subset into `docs/research/` (§12.4):
- `sharing/NearbyProtocolReference.swift` and `sharing/crosscheck.py`
- `deps-tooling/deps-probe/`
- `deps-tooling/xcodegen-final/`
- `github-rest-api/ops_compact*.json` and `env_ops.json`

---

## 1. Summary and key decisions

FX Vault is a native SwiftUI app for macOS 14 and later.

- **Source of truth:** a local GRDB/SQLite vault.
- **Encryption:** every value (secret and variable) is encrypted with AES-256-GCM per field, using a key derived from a random DEK.
- **Key wrapping:** the DEK is wrapped twice, once by Argon2id(master password) and once by HKDF(recovery key). Signed builds can also unlock with Touch ID.
- **GitHub access:** everything goes through the terminal and the resolved `gh` binary (Q2), with a separate `GH_TOKEN` per account. Native subcommands (`gh repo`, `gh secret`, `gh variable`, `gh org`, `gh auth`) cover everything they can; `gh api` is used only for environments and deployment branch policies, which have no native command. Values reach gh only on stdin, and gh seals secrets itself. No direct HTTP from the app.
- **Pending changes:** computed by a pure diff between each row's desired state and its last-synced snapshot.
- **Sync:** serial and throttled. Before writing, it checks the remote state (optimistic concurrency). Each write is journaled and verified by re-listing the scope with the native list command.

| # | Decision | Rationale |
|---|---|---|
| D1 | XcodeGen `project.yml` is the source of truth. The generated `FXVault.xcodeproj` is committed. All non-UI code lives in a local SPM package `FXVaultKit`. | The generated project is deterministic and path-independent (verified). Contributors only need Xcode. `swift test` covers the core. |
| D2 | Package targets: `VaultCore`, `VaultCrypto`, `VaultStore`, `GitHubKit`, `SyncEngine`, `EnvTools`, `SharingKit`, `VaultData`. The app target holds only Screens, ViewModels, AppKit managers, Theme and the string catalogs. The app never imports GRDB or Clibsodium. | Logic can be tested without UI. Dependencies stay contained. |
| D3 | Swift 6 language mode and `swift-tools-version: 6.1`. The package is nonisolated with `MemberImportVisibility`. The app uses `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` and Approachable Concurrency. No Swift 6.4-only features (SE-0493/0502/0504/0506/0508/0518/0520). | This setup compiled with no warnings in the probe. The Xcode 26.6 gate catches 6.4-only code. |
| D4 | **Native gh subcommands** for accounts, scopes, tokens, orgs, repos, templates, repo creation, secrets and variables (§8). `gh api` **only** for environments and deployment branch policies, as spec §4 says. Secret and variable values go to `gh secret set` / `gh variable set` on stdin, one call per item; gh fetches the public key and seals. No local sealing, no `gh api` for secrets, variables, repos or orgs, no direct HTTP. **(Q2, decided)** | Bryan: everything through the terminal and the GitHub CLI. Satisfies spec §4 literally. |
| D5 | gh **hard floor 2.97.0**; below it `GHSetupScreen` blocks with `brew upgrade gh`. | 2.97 fixes environment-name escaping in `gh secret`/`gh variable` set, list and delete (2.90 puts the raw name in the URL path), and brings three security fixes. |
| D6 | `X-GitHub-Api-Version: 2026-03-10`, defined once as a constant, sent only on the `gh api` environment and branch-policy calls. | No relevant endpoint changed between versions. Native commands pick their own API version. |
| D7 | Every process gets an allowlisted environment (§5.10), with `GH_TOKEN=<account token>`, `GH_TELEMETRY=false`, an empty working directory, and stdin always a Pipe. Success is exit code 0; failures are classified from gh's stderr and exit code (§8 E). | Selects the account without switching gh's active account. Prevents leaks through debug output, TTY detection or GH_REPO. Native commands expose no HTTP status or headers. |
| D8 | Argon2id **moderate** (ops 3, 256 MiB, 16-byte salt). Passwords are NFC-normalized. Minimum 12 characters **and** an estimated strength of at least 60 bits; the app also offers a generated 6-word passphrase. KDF parameters are bound into the wrap AAD and bounds-checked **before** the KDF runs. | About 0.3 s on an M5. Tampering with the parameters fails authentication and cannot be used for a denial of service. |
| D9 | Recovery key: 256 bits plus a 24-bit checksum, shown as 56 Crockford Base32 characters in 14 groups. It is turned into a key with HKDF-SHA256. A recovery reset **always rotates the DEK** and issues a new recovery key. | The key has full entropy. A leaked old key plus an old database backup cannot open data written afterwards. |
| D10 | Variable values are encrypted too. Names and metadata stay plaintext, and this is documented. `PRAGMA secure_delete=ON`. `wal_checkpoint(TRUNCATE)` runs after every key write and on lock. Directory mode 0700. No SQLCipher. | SQLCipher would require forking GRDB and shipping a binary. FileVault covers data at rest. |
| D11 | Desired-state rows. The diff compares row-bound HMAC fingerprints and never decrypts. The field AAD binds row id, repository, environment, kind and name. **Kind and scope cannot change once a row is synced.** | Coalescing comes for free. A tampered row cannot be decrypted under a different kind or scope. |
| D12 | One serial scheduler per account (`GHCommandScheduler`), one gh write command per item (never `--env-file`), limited to 60 writes/min and 450 writes/hour and seeded at launch from `sync_journal`. Idempotent commands (set, delete, environment PUT) are retried on 5xx and network errors. Rate limiting gets a fixed backoff (`Timeouts.rateLimitBackoff`, 60 s) up to `Limits.rateLimitRetries`, then the run stops and the rest stays pending. | Respects GitHub's secondary limits even across restarts. gh exposes no `retry-after`. |
| D13 | Secret drift: compare the listed `updatedAt` with the `remote_updated_at` recorded at verification. A write is "ours" when the re-listed `updatedAt` differs from the pre-write value recorded in preflight. Variable drift: compare fingerprints of the listed value. Every check is a full re-list with the native list command (**no ETags in v1**). | No clock skew. A third-party write between a scope's pre-write re-list and its verification re-list cannot be detected (`gh secret set` is unconditional); the window is kept short by re-listing each scope right before writing it and verifying it right after (§7.3), and is a documented residual risk (§5.14). Avoids the multi-page ETag and "dismissed drift disappears" bugs. |
| D14 | Touch ID is available **only in Developer ID-signed builds (team QYKC498D5D, Q1 decided) with the embedded profile**. It uses the data-protection keychain with `.biometryCurrentSet` and a key-check value (kcv). The master password is required after every restart and at least every 14 days. No Secure Enclave fallback. | Verified: -34018 without the entitlement, and a SIGKILL at launch with the entitlement but no profile. The Secure Enclave blob is not bound to the app. |
| D15 | Two entitlements files, selected through xcconfig. A SecTask check at runtime. The signed CI path writes `Config/Local.xcconfig` (`#include "Signed.xcconfig"`) and has a gate that checks entitlements on both paths. | Prevents both contributor-build crashes and a signed release that silently lacks Touch ID. |
| D16 | Auto-lock after **FX Vault inactivity** (default 5 min, suspended while a sync runs). Immediate lock on sleep, display sleep, session resign, protected-data loss, screen lock or screensaver. The first phase of the lock is synchronous. | App inactivity is stricter than system idle. The sync exemption stops long syncs from being cancelled. Locking synchronously means keys never survive into sleep. |
| D17 | Clipboard: `.currentHostOnly`, plus the Concealed, Transient and source markers. Cleared after 30 s only if `changeCount` has not changed. The clipboard is never read. | Reading the pasteboard triggers the macOS 15.4+ privacy alert. |
| D18 | Repos are created with `gh repo create OWNER/NAME --private\|--public …` (never `--clone`), then `gh repo view` for id, SSH URL and default branch. Cloning uses `/usr/bin/git clone` with the mapped SSH alias into a temporary sibling directory, renamed atomically when done. | gh's clone ignores SSH aliases. Retries never collide with a half-finished directory. |
| D19 | The SSH alias is checked with `ssh -G` (hostname) and `ssh -T` (authenticated login). Mapping is manual, with a **Test** button. | Catches aliases that point at the wrong account before any clone. |
| D20 | Environment rename: a plain local rename before the first sync. After sync, a guided recreate (**Q5**). Case-only renames are local only. | GitHub has no rename API, and names are case-insensitive, so a recreate on a case change would delete the environment. |
| D21 | Nearby protocol: commit-reveal X25519, a 6-digit SAS from 64-bit HKDF output mod 10^6, per-direction AES-GCM keys, and two phases (manifest, decision, payload). No automatic retry. | A commitment is mandatory, otherwise the SAS can be ground. Values move only after acceptance. |
| D22 | Nearby transport: Network framework (`NWListener`/`NWBrowser`/`NWConnection`, TCP, `acceptLocalOnly`) behind a `NearbyTransport` protocol (**Q3, decided**; approved spec deviation). | MultipeerConnectivity is deprecated in the Xcode 27 SDK and is not Sendable. |
| D23 | `.fxvault` v1: a fixed 64-byte header used as AAD (`headerLength` must be 64), Argon2id (t=3, 64 MiB, p=1), AES-256-GCM, and a 6-word EFF passphrase. | Everything is authenticated, and bounds are checked before the KDF. |
| D24 | One `Localizable.xcstrings` and one `InfoPlist.xcstrings` in the app. Packages throw typed errors only. All `LAContext` prompt strings are passed in from the app. | Package catalogs are ignored unless the main bundle declares the language. |
| D25 | Universal DMG built with `diskutil image create from` (falling back to hdiutil). Every official release is Developer ID-signed and notarized with an App Store Connect Team API key, and stapled (app and DMG) (**Q1, decided**). Ad-hoc builds are for forks only. The repo is `FractalX-Technologies/fx-vault` and the cask lives in `FractalX-Technologies/homebrew-tap` (**Q4, decided**). | Ad-hoc builds need re-approval after every update, and the official homebrew/cask repo is out of reach at launch. |
| D26 | CI: `macos-26` (Xcode 26.6) **blocks** merges. `xcode-27` runs as a non-blocking job. Releases build on `xcode-27`, with a runner-to-Xcode-path mapping. Every action is pinned to a SHA, plus Dependabot and gitleaks. | Keeps the code compatible with a GA toolchain. The preview runner's queueing cannot stall merges. |
| D27 | Optimistic concurrency: `SyncPreflight` re-lists every scope a sync will touch. Any item whose remote base changed is blocked as `remoteChanged` and routed to Drift review. | Sync never silently overwrites a teammate's rotation or a remotely created environment or variable. |
| D28 | `sync_journal`: before each write, a row is written with state `in_flight`, then updated to its outcome. The journal drives crash and timeout reconciliation, throttle seeding, suppression of "remote added" alerts for names we just deleted, and the last-run report. | One table replaces sync history, intents and ledgers. |
| D29 | `PathSegmentValidator` runs at every boundary (UI, GitHub import, share import, database load, gh command layer). It rejects `.`, `..`, empty strings and control or bidi characters. The host must be exactly `github.com`. | Stops dot-segment requests (for example `DELETE …/environments/..`) and path traversal in clone destinations. |
| D30 | `ReauthGate` (Touch ID item read, or master password) runs before .env export, .fxvault export and sending a nearby MANIFEST. **Master password only** for: new recovery key, change password, disable Touch ID, rotate DEK, reset vault. | Someone at an unlocked Mac cannot take a recovery key or bulk plaintext. |
| D31 | `PRODUCT_NAME = FXVault` (module `FXVault`), `CFBundleName`/`CFBundleDisplayName` = "FX Vault". The bundle is renamed to `FX Vault.app` when packaged. | Keeps the verified build configuration. Renaming the bundle directory does not invalidate the signature. |
| D32 | **Trailing newline normalization:** every value entry path (editor, .env import, share import, fill) strips trailing CR/LF and shows a visible notice. Values that come from GitHub (B8/B9 variable import, drift "Accept GitHub") are stored as listed and may end in CR/LF, so `SyncPlanner` also normalizes at push time: it pushes the stripped bytes, computes the expected fingerprint over them, and shows a notice for the affected items. The editor shows a hint for SSH/PEM keys: GitHub stores them without the final newline, and workflows usually add it back (`echo "$KEY" > key`). | `gh secret set` / `gh variable set` strip all trailing `\r\n` from stdin. Normalizing first keeps local == GitHub, so variable drift stays exact. |

---

## 2. Spec corrections and risks found in research

| Spec item | Problem (verified) | What we do |
|---|---|---|
| §4 `gh secret set` / `gh variable set` | Both strip all trailing `\r\n` from stdin, so PEM and OpenSSH keys lose their final newline. gh 2.90 does not escape environment names in the path. `--env-file` sends unbounded concurrent PUTs. | Used as the spec says (D4, Q2 decided): values on stdin only, one call per item. gh floor 2.97 (D5). Trailing newline normalization on entry (D32). |
| §2 fix scopes with `gh auth refresh -s` | There is no `--user` flag. It only works on the active account, needs a browser, and refuses to run while `GH_TOKEN` is set. | Show copyable commands `gh auth switch -h github.com -u <login>`, `gh auth refresh -h github.com -s repo,read:org`, `gh auth switch -h github.com -u <previous>`, plus **Re-check**. The required scopes are `repo` plus one of `read:org`/`write:org`/`admin:org`. Fine-grained tokens show "scopes unknown". |
| §2 login shell PATH | `zsh -l -c` skips `~/.zshrc`. GUI apps do not inherit `GH_CONFIG_DIR` or `XDG_*`. | Probe with `-l` first, then `-il`. Print only the allowlisted keys between markers (§8 A2). Offer a manual gh path override. |
| §3 clone with the SSH alias | `gh repo create --clone` and `gh repo clone` ignore aliases. | D18. |
| §4 rename environments | No REST rename exists. Secret values cannot be read back. Names are case-insensitive. | D20, §7.6 (Q5). |
| §4 paid-plan note | Broader than protection rules, and GitHub's docs contradict each other. Plan limits only show up as write errors. | Hedged copy plus a docs link. Write errors classified as plan-gated stay pending. A per-repo hint that the user can clear. |
| §5 compare `updated_at` with the last sync timestamp | Local clock skew and eventual consistency. | D13 plus pre-write `updatedAt` verification (§7.3). |
| §5 one-click Sync | Secondary limits are 80/min and 500/h, and the hourly budget is shared with all of the user's gh use. | D12. After the fixed backoff and retries the run stops, and the remaining items stay pending. |
| §3 list "all repos the account can access" | Natively, `gh repo list <owner>` lists only repos **owned** by that owner (`ownerAffiliations: OWNER`), run for the account and the orgs it is a **member** of (`gh org list`). Not covered: repos where the account is a collaborator but not an owner or org member, whether the owner is a user or an organization (outside-collaborator access). Without `read:org`, `gh org list` may silently omit orgs. | **Add repository by name** (`gh repo view OWNER/NAME`). Documented limitation. |
| §1 Touch ID together with §9 optional signing | Biometric keychain items need a profile-authorized entitlement. | D14/D15. The README says Touch ID needs the official signed build. |
| §1 lock when the screen locks | No public API exists, and the notification can be spoofed. | Every signal is used as a lock-only trigger, documented as best effort. Sleep is fully covered. |
| §1 clear the clipboard only if it still holds the value | Reading the pasteboard triggers the privacy alert. | Compare `changeCount` instead (D17). |
| §1 auto-lock after inactivity | Long throttled syncs take more than 5 minutes. | The inactivity timer is suspended while a sync runs. Sleep and screen lock still lock and cancel. |
| §1 encrypt secret values with the DEK | Wording only. | Fields are encrypted with `K_field = HKDF(DEK, …)`, and fingerprints use `K_fp`. Both derive from the DEK, which keeps the keys separated by purpose. |
| §1 never pass secrets as argv, while `GH_TOKEN` goes in the environment | Same-user processes can read `GH_TOKEN`. Repo, environment and item names in gh argv are visible to every local user through `ps`. | Accepted and documented. The same user can already run `gh auth token`. Values only ever go to stdin; `--body`/`-b` and `--env-file` are forbidden (§5.10). |
| §1 field-level encryption | Names are readable in `vault.sqlite` and its `-wal` file. | Documented. Variables are encrypted. `secure_delete` and checkpoints are on. |
| §3 import / §6 .env names | GitHub stores names uppercase, allows only `[A-Za-z0-9_]`, no leading digit and no `GITHUB_` prefix. | Uppercase on entry, suggest fixes, check duplicates case-insensitively. |
| §6 pre-mark secrets (TOKEN/KEY/PASSWORD/SECRET/PRIVATE) | Misses DSNs, URLs with credentials, `*_PASS`, and so on. | We keep the spec list and add more key patterns and value heuristics (§5.13). Preflight asks for confirmation before pushing a variable that looks like a credential. |
| Permissions (implicit) | Environments need admin. Whether a WRITE collaborator can list, set and delete repo-level secrets and variables is **unverified**: GitHub's docs say repository secrets and variables need admin (or ownership of a personal repo), and gh's `secret list` error reads "Must have admin rights". Archived repos are read-only. | Capabilities come from `viewerPermission` (ADMIN / MAINTAIN, WRITE / TRIAGE, READ) and `isArchived`. The repo-level capability for WRITE depends on the M3 spike result (Q6); until then WRITE is treated as read-only for items. Tabs the user cannot edit are read-only and say why. |
| §6 duplicate / §3 import | Secret values cannot be fetched. | The value-missing flag carries over, and Sync blocks those items. |
| §7b MultipeerConnectivity | Deprecated as a whole in the macOS 27 SDK and not Sendable. | D22 (Q3, approved deviation). |
| §7b "encryption required" | MC `.required` is unauthenticated. Network framework TCP has no transport encryption, so HELLO metadata (display name, versions) is cleartext on the LAN. | The SAS is the only authentication. Every app frame is encrypted under SAS-confirmed keys. Cleartext HELLO metadata is documented, and the display name is editable. |
| §7b 6-digit code from the transcript | Without a commitment, an attacker can grind keys (RFC 6189 §4.4.1.1). | Commit-reveal is mandatory. Both suites and both max versions are in the transcript. |
| §7 preview, then accept | Pushing values with the preview leaks them before consent. | Nearby uses two phases. `.fxvault` files are decrypted in memory and discarded if rejected. |
| §7b Local Network | Permission tracking depends on the code signature. Reset only exists from macOS 27.2. | Nearby is supported on signed builds only. Test with a second macOS user. |
| §9 right-click → Open | Removed in macOS 15. Apple Silicon builds are always at least ad-hoc signed. | Document the Privacy & Security → **Open Anyway** route or `xattr -dr com.apple.quarantine`. Users repeat it after every ad-hoc update. |
| §9 `brew install --cask fx-vault` | The official repo needs 225+ stars, a repo older than 30 days and notarization. The `fractalx` GitHub name belongs to someone else. | `brew install --cask fractalx-technologies/tap/fx-vault`. The cask is written in the official style. |
| Tech stack: macOS 14 | The `macos-14` runners retire on 2026-11-02. | Deployment target stays 14.0, with a manual Sonoma VM smoke test before each release. |

**Other risks:**
- swift-sodium has no upstream CI. It is used only for Argon2id (one file), and every known-answer test comes from an independent implementation.
- `xcode-27` is a preview runner and can queue. Its job does not block merges, and the release workflow can fall back to `macos-26` (Xcode 26.6).
- Some write behavior is unverified: whether an identical-value `gh secret set` changes `updatedAt`, environment DELETE and its variables, whether fields omitted from an environment PUT keep existing reviewers, Free-plan private errors as gh prints them, value normalization through gh (including empty values), gh's stderr for 403/404/422/SAML/rate limits, whether a WRITE collaborator can manage repo-level secrets and variables, and the response to an already-existing branch-policy POST. The M3 write spike covers these (Q6).
- gh's stderr wording is not a stable interface. The classifier matches `HTTP (\d{3}):` (native), `gh: … (HTTP nnn)` / `gh: HTTP nnn` (`gh api`) and `GraphQL:` forms plus short fragments, and the fixtures are re-recorded when the gh floor moves.
- Only one gh account is logged in today, so a second one is needed to demo multi-account support (Bryan action in Phase 0).

**Noticed outside scope:** `admin-fractalx/fnx-mac` release.yml uses `runs-on: macos-14`, which retires 2026-11-02, and its actions are unpinned. The `fnx` cask has a postflight that does nothing (`"\#{appdir}"`). This is flagged as a separate task.

---

## 3. Repository and project structure

```
FXVault/
├── project.yml                         # XcodeGen truth (projectFormat xcode16_0, syncedFolder, options.xcodeVersion pinned)
├── .xcodegen-version                   # 2.45.4 (+ sha256 of release zip)
├── FXVault.xcodeproj/                  # generated, committed (drift check)
├── Config/
│   ├── Base.xcconfig                   # ad-hoc defaults; CODE_SIGN_IDENTITY = -; CODE_SIGN_ENTITLEMENTS = Config/FXVault.entitlements; #include? "Local.xcconfig"
│   ├── Signed.xcconfig                 # DEVELOPMENT_TEAM, Developer ID identity, FXVault-Signed.entitlements, PROVISIONING_PROFILE_SPECIFIER (no secrets)
│   ├── Local.xcconfig.example          # `#include "Signed.xcconfig"`; Local.xcconfig gitignored (CI writes it on the signed path)
│   ├── Info.plist                      # generated from project.yml `info:`
│   ├── FXVault.entitlements            # ad-hoc: app-sandbox=false only
│   └── FXVault-Signed.entitlements     # + keychain-access-groups [$(AppIdentifierPrefix)io.fractalx.fxvault]
├── App/
│   ├── FXVaultApp.swift                # Window("FX Vault", id: "main"), Settings, Commands; test-mode → AppContainer.preview
│   ├── AppDelegate.swift               # open .fxvault URLs → AppViewModel.pendingImports; terminate → clipboard check
│   ├── AppContainer.swift              # composition root (live / preview / test)
│   ├── AppViewModel.swift              # VaultPhase .onboarding/.locked/.unlocked; gh status (starts at launch)
│   ├── Screens/
│   │   ├── Root/RootScreen.swift
│   │   ├── Onboarding/OnboardingScreen.swift, OnboardingViewModel.swift, Steps/*StepView.swift
│   │   ├── Lock/LockScreen.swift, LockViewModel.swift, RecoveryResetScreen.swift, RecoveryResetViewModel.swift
│   │   ├── GHSetup/GHSetupScreen.swift, GHSetupViewModel.swift
│   │   ├── Main/MainScreen.swift, MainViewModel.swift, SidebarView.swift, ScopeListView.swift   # views driven by MainViewModel
│   │   ├── RepoDetail/RepoDetailScreen.swift, RepoDetailViewModel.swift, ConfigTableView.swift
│   │   ├── ItemEditor/ConfigItemEditorScreen.swift, ConfigItemEditorViewModel.swift
│   │   ├── Environment/EnvironmentSettingsScreen.swift (+VM), DuplicateEnvironmentScreen.swift (+VM), RenameEnvironmentScreen.swift (+VM)
│   │   ├── CreateRepo/CreateRepoScreen.swift, CreateRepoViewModel.swift
│   │   ├── Sync/SyncScreen.swift, SyncViewModel.swift, Steps/{SyncSummaryView,DeletionConfirmView,SyncProgressView,SyncResultView}.swift
│   │   ├── Drift/DriftReviewScreen.swift, DriftReviewViewModel.swift
│   │   ├── EnvFile/EnvImportScreen.swift (+VM), EnvExportScreen.swift (+VM)
│   │   ├── Sharing/ShareExportScreen.swift (+VM), ShareImportScreen.swift (+VM), NearbyShareScreen.swift (+VM)
│   │   └── Preferences/PreferencesScreen.swift, PreferencesViewModel.swift, GeneralSettingsView.swift, AdvancedSettingsView.swift,
│   │                   SecuritySettingsScreen.swift, SecuritySettingsViewModel.swift, AccountsSettingsScreen.swift, AccountsSettingsViewModel.swift
│   ├── Components/                     # SecretValueEditor (NSViewRepresentable), MaskedValueCell, SyncToolbarButton, StatusChip,
│   │                                   # RecoveryKeyGridView, SASCodeView, PassphraseView, BranchPolicyEditor, EmptyStateView
│   ├── Managers/                       # ClipboardManager, AutoLockManager, PreferencesManager (AppKit-bound)
│   ├── Helpers/
│   │   ├── Theme/                      # Theme, Colors (asset semantic colors), Typography, Spacing, Radius, Durations
│   │   └── Extensions/                 # VaultError+Extension.swift, GHError+Extension.swift, SyncError+Extension.swift,
│   │                                   # ShareError+Extension.swift, EnvParseIssue+Extension.swift, Date+Extension.swift
│   └── Resources/                      # Assets.xcassets, Localizable.xcstrings, InfoPlist.xcstrings
├── AppTests/                           # view-model tests (Swift Testing), app-hosted in test mode (no side effects)
├── Packages/FXVaultKit/
│   ├── Package.swift                   # tools 6.1, macOS 14, Swift 6, defaultLocalization "en", MemberImportVisibility
│   ├── Package.resolved                # committed; single source of pins
│   ├── Sources/
│   │   ├── VaultCore/                  # Models/*Model.swift, Validation/{PathSegmentValidator,GitHubNameValidator,EnvironmentNameValidator,
│   │   │                               # RepoNameValidator,DisplayNameSanitizer}.swift, Limits.swift, Timeouts.swift,
│   │   │                               # Errors/{VaultError,ValidationError}.swift, SecretBytes.swift, Clock.swift, Identifiers.swift
│   │   ├── VaultCrypto/                # Argon2id.swift (import Clibsodium), KDFParameters.swift, FieldCipher.swift, AADBuilder.swift,
│   │   │                               # KeyWrap.swift, KeyCheckValue.swift, RecoveryKey.swift, CrockfordBase32.swift, ValueFingerprinter.swift,
│   │   │                               # VaultKeyring.swift, PasswordStrength.swift, CryptoError.swift
│   │   ├── VaultStore/                 # DatabaseFactory, VaultMigrator, Records/*, VaultStore, AccountStore, RepoStore, ConfigStore, SyncJournalStore
│   │   ├── GitHubKit/                  # Process/{CommandRunning,ProcessRunner,CommandSpec,StdinPayload}.swift
│   │   │                               # Environment/{ShellEnvironmentResolver,ProcessEnvironmentBuilder}.swift
│   │   │                               # CLI/{GHLocator,GHVersion,GHAuthService,GHTokenCache,AuthStatusDTO,ScopeChecker}.swift
│   │   │                               # Commands/{GHCommandService,GHCommandScheduler,GHRepoRef,GHReposCommands,GHSecretsCommands,
│   │   │                               #   GHVariablesCommands,GHOrgsCommands,GHTemplatesCommands}.swift   # native gh argv builders + JSON decoding
│   │   │                               # API/{GHEnvironmentsAPI,GitHubPath,APIResponseParser}.swift   # gh api: environments + branch policies only
│   │   │                               # DTOs/* (native --json shapes), Errors/{GHError,GHStderrClassifier,StderrRedactor}.swift,
│   │   │                               # SSH/{SSHConfigParser,SSHAliasResolver}.swift, Git/GitService.swift
│   │   ├── SyncEngine/                 # RepoSnapshotModel, RemoteSnapshotModel, ConfigChangeModel, ChangeSetBuilder, ChangeSetNormalizer,
│   │   │                               # ChangeSummaryModel, SyncPreflight, SyncPlanner, SyncExecutor, SyncResultModel, WriteVerifier,
│   │   │                               # DriftDetector, DriftModel, SyncError
│   │   ├── EnvTools/                   # DotEnvParser, DotEnvSerializer, KeyNormalizer, CredentialClassifier, SecureFileWriter, GitignoreChecker, EnvParseIssue
│   │   ├── SharingKit/                 # Model/{SharePackageModel,SharePackageValidator}, File/{FxVaultHeaderModel,FxVaultFileCodec,KeyDeriving},
│   │   │                               # Passphrase/PassphraseGenerator + Resources/eff_large_wordlist.txt,
│   │   │                               # Nearby/{NearbyCrypto,NearbyFrame,NearbyHandshake,NearbyTransport,NWNearbyTransport},
│   │   │                               # Import/ShareImportPlanner, ShareError
│   │   └── VaultData/                  # Repositories/{VaultRepository,AccountsRepository,RepoCatalogRepository,ConfigRepository,SyncRepository,
│   │                                   # DriftRepository,SharingRepository}.swift; Managers/{VaultManager,KeychainManager,BiometricAuthManager,
│   │                                   # BuildCapabilities,ReauthGate}.swift; ShareImporter.swift
│   └── Tests/  (one target per module) + Fixtures/ (sanitized native gh --json outputs, gh stderr samples, gh api -i outputs
│                                       #   for environments/branch policies, KAT vectors, .env samples, reference .fxvault)
├── scripts/  make-dmg.sh, sync-strings.sh, check-linkage.sh, smoke-launch.sh, ci-local.sh, lint.sh, check-docs.sh,
│             coverage.sh, sanitize-fixture.sh, check-fixtures.sh, bump-cask.sh
├── ci/ExportOptions-DeveloperID.plist
├── Casks/fx-vault.rb                   # template; canonical copy in FractalX-Technologies/homebrew-tap
├── docs/  ARCHITECTURE.md, STRUCTURE.md, API.md (gh/git catalog), DATABASE.md (GRDB schema), SECURITY-MODEL.md,
│          SHARING-PROTOCOL.md, RELEASING.md (manual checklist), research/ (sanitized probes + KAT generators)
├── tasks/todo.md, tasks/lessons.md
├── .claude/rules/fxvault-security.md, .claude/rules/fxvault-architecture.md
├── .github/workflows/{ci.yml,release.yml}, dependabot.yml, CODEOWNERS, pull_request_template.md, ISSUE_TEMPLATE/
├── .gitleaks.toml                      # + denylist: FractalX-Technologies, admin-fractalx, QYKC498D5D, real repo names (Fixtures, docs/research)
├── README.md, LICENSE (MIT, (c) 2026 FractalX), SECURITY.md, CONTRIBUTING.md, THIRD_PARTY_NOTICES.md, CHANGELOG.md
└── .gitignore                          # .env, *.env (+ !**/Tests/Fixtures/*.env for synthetic samples), .research/, Config/Local.xcconfig, .build/, DerivedData/, .spm/, *.xcuserstate
```

**`project.yml`** follows the minimal spec verified in research:
- App bundle ID `io.fractalx.fxvault`, `PRODUCT_NAME: FXVault`, `ENABLE_HARDENED_RUNTIME: YES`, `SWIFT_VERSION: "6.0"`, string catalog settings.
- Info: `CFBundleName`/`CFBundleDisplayName` "FX Vault", `LSApplicationCategoryType` developer-tools, `NSLocalNetworkUsageDescription`, `NSBonjourServices [_fxvault-share._tcp]` (TCP only, D22).
- `UTExportedTypeDeclarations`: `io.fractalx.fxvault.share`, conforms to `public.data`, extension `fxvault`, MIME `application/vnd.fractalx.fxvault`.
- `CFBundleDocumentTypes`: role Viewer, rank Owner.
- Test target: `GENERATE_INFOPLIST_FILE: YES`.
- Signing settings live **only** in the xcconfig files.

---

## 4. Architecture

### 4.1 Layers (FractalX MVVM)

```
SwiftUI Screen ──► @Observable @MainActor [Name]ViewModel
                         │
                         ▼
          VaultData Repositories (Sendable facades)
     ┌──────────┬──────────────┬──────────────┬──────────────┐
     ▼          ▼              ▼              ▼              ▼
  Managers   Services        Stores         SyncEngine     SharingKit
  (local)    (remote)        (local, GRDB)  (pure domain   (pure protocol
  VaultMgr   GHCommandSvc    VaultStore…    + executor)    + transport)
  Keychain   GHAuthService
  Biometric  GitService
  (app) ClipboardManager, AutoLockManager, PreferencesManager
```

`.claude/rules/fxvault-architecture.md` records how this maps onto the FractalX rule `ViewModel → Repository → Service | Manager`:
- A **Store** is a local Manager over GRDB.
- **SyncEngine** and **SharingKit** are pure domain services that repositories call.
- View models depend only on repositories.

### 4.2 Module dependency graph (acyclic)

```
VaultCore ◄── VaultCrypto ◄── VaultStore
   ▲   ▲          ▲             ▲
   │   └── GitHubKit            │
   │         ▲                  │
   │         └── SyncEngine ────┘ (+ VaultCrypto)
   ├── EnvTools
   └── SharingKit ──► VaultCrypto
VaultData ──► all of the above
App ──► VaultData, VaultCore, and the value types of SyncEngine, SharingKit and EnvTools   [never GRDB / Clibsodium]
```

`Clibsodium` is imported only in `Argon2id.swift` (swift-sodium is used for Argon2id only, as the spec says). `GRDB` is imported only in VaultStore and is never re-exported.

### 4.3 Concurrency

**App target:** MainActor by default. View models are `@Observable`. Work that needs a lot of CPU (Argon2id, bulk re-encryption) lives in the package or runs in `@concurrent` functions.

**Package:** nonisolated.
- `ProcessRunner` is a stateless `Sendable` struct.
- Actors: `GHCommandScheduler` (one per account), `SyncExecutor` (one run at a time, cancellable).
- `GHTokenCache` is a lock-protected store with a **synchronous** `purge()`, so the lock path can call it without suspending.

**`VaultKeyring`:** a `final class: Sendable` around `OSAllocatedUnfairLock<(keys: UnlockedKeys?, generation: UInt64)>`.
- `withKeys<R: Sendable>(_ body: (borrowing UnlockedKeys) throws -> R) throws -> R` copies the keys out while holding the lock, **releases the lock**, then runs the synchronous, non-escaping body. Nested calls are therefore safe, and `lock()` never waits behind bulk work.
- `lock()` sets the keys to nil and increments `generation`. Writers compare the generation before committing, and work that started before a lock fails with `.locked`.
- There are no public `SymmetricKey` accessors. `FieldCipher` and `ValueFingerprinter` are static functions that take the key for each call and never store it.
- Long jobs re-enter `withKeys` for each item.

**Database:** `any DatabaseWriter`, which is a `DatabasePool` on disk and a `DatabaseQueue()` in tests and previews. Repositories expose Sendable values or `AsyncThrowingStream`s backed by `ValueObservation.values(in:)`.

**Sync bookkeeping:**
- The journal row with state `in_flight` is written before each GitHub write.
- The outcome and `synced_*` columns are written with a **synchronous** `writer.write` immediately after the response.
- No async GRDB writes are used here, because a cancelled task would roll back and the item would be pushed again.

**SyncActivityAssertion:** held by `SyncExecutor` while a run is active. `AutoLockManager` skips the inactivity rule while it is held. Every other trigger still locks.

**Nearby transport:** queue-confined `@unchecked Sendable`, exposing `events: AsyncStream<TransportEvent>` and `send(Data) async throws`. Only Data, String, enums and UUIDs cross isolation boundaries.

### 4.4 Errors

Typed `Sendable` errors with no localized text:
- `VaultError`: `wrongPassword`, `invalidRecoveryKey`, `locked`, `corrupted(VaultCorruption)`, `biometryInvalidated`, `biometryUnavailable(reason)`, `passwordRequired(reason: .restart|.periodic)`, `cancelled`
- `CryptoError`
- `ValidationError`: `invalidName(NameRule)`, `invalidPathSegment`, `valueTooLarge(limit:)`, `emptyValue`, `scopeFull(kind:limit:)`, `duplicateName`, `nameReservedByPendingChange`
- `GHError`: `notInstalled`, `versionTooOld(found:required:)`, `notAuthenticated`, `tokenRevoked`, `missingScopes`, `adminRequired`, `writeAccessRequired`, `samlRequired(URL?)`, `planGated`, `orgPolicyForbidsCreate`, `notFound`, `validation(String)`, `rateLimited`, `serverError(status)`, `network`, `timeout`, `indeterminate`, `unexpected(exitCode:)`
- `SyncError`: includes `remoteChanged`, `blockedValueMissing`, `dependencyFailed`
- `EnvParseIssue`, `ShareError`

The app maps each error in `[Type]+Extension.swift` to a `localizedTitle`, a `localizedMessage` and a `recoveryAction`, using `String(localized: "error.gh.adminRequired", defaultValue: "You need admin access to \(repo) to manage environments.")`.

### 4.5 Logging

- `os.Logger(subsystem: "io.fractalx.fxvault", category: vault|gh|sync|sharing|ui)`.
- Never logged: values, tokens, stdin, process environments, response bodies, passphrases.
- Names are logged only with `privacy: .private`.
- gh calls are logged as a command template (`secret set {n} --repo={o}/{r} --env={e}`, matching the argv builders; for `gh api`, the method plus `repos/{o}/{r}/environments/{e}`), the exit code and the classified error.
- `StderrRedactor` runs before any display or log. It replaces the current operation's plaintext and the patterns `gh[opusr]_[A-Za-z0-9]{20,}` and `github_pat_[A-Za-z0-9_]{20,}`.
- No log files. GRDB keeps `publicStatementArguments = false`.

### 4.6 Localization

- One `Localizable.xcstrings` and one `InfoPlist.xcstrings`. English only for now.
- Keys are static and dot-namespaced. Interpolation goes in `defaultValue`. Plurals use catalog variations.
- `BiometricPrompt { reason, fallbackTitle }` is built in the app with `String(localized:)` and passed to `VaultManager`/`ReauthGate`.
- `scripts/lint.sh` fails if any `Sources/` file assigns a literal to `localizedReason` or `localizedFallbackTitle`.
- CI and `ci-local.sh` run `scripts/sync-strings.sh` (build, then `xcrun xcstringstool sync`) and compare the catalog's shasum before and after.

### 4.7 Conventions enforcement

- Domain value types end in `Model`. Protocols, services, stores, errors and DTOs are exempt.
- Constants live in `VaultCore/Limits.swift` and `Timeouts.swift`, and UI constants in `Helpers/Theme`. No magic numbers.
- `scripts/lint.sh` (run in CI) fails on `try!`, `as!`, a force unwrap `)!` or `]!`, `URL(string:…)!`, and `print(` in Sources/App.
- SwiftFormat (preinstalled on runners) runs in check mode.

---

## 5. Security design

### 5.1 Key hierarchy

```
vault_id  = 16 random bytes (vaults row)
DEK       = SymmetricKey(.bits256), dek_version starts at 1
K_field   = HKDF-SHA256(DEK, salt: vault_id, info: "fxvault/v1/field-enc", 32)
K_fp      = HKDF-SHA256(DEK, salt: vault_id, info: "fxvault/v1/fingerprint", 32)
kcv       = HMAC-SHA256(DEK, "fxvault/v1/kcv")[0..<16]   (vaults.kcv; constant-time compare after every unwrap)
K_pw      = Argon2id13(UTF8(NFC(password)), salt16, ops 3, mem 268435456 B) → 32 B  [crypto_pwhash, caller-owned buffers, sodium_memzero]
K_rec     = HKDF-SHA256(recoveryKey32, salt: vault_id, info: "fxvault/v1/kek/recovery", 32)
Touch ID  = DEK in data-protection keychain item (signed builds only)
```

### 5.2 Wrap format (`key_wraps.wrapped_dek`, 62 bytes)

```
[0] format=0x01 [1] aead=0x01 [2..13] nonce [14..45] ct(DEK) [46..61] tag
AAD = u8(format) ‖ u8(aead) ‖ LP("fxvault/v1/dek-wrap") ‖ LP(method) ‖ LP(vault_id) ‖ u32be(dek_version)
      ‖ u8(kdf_alg) ‖ u32be(ops|0) ‖ u64be(mem_bytes|0) ‖ LP(salt|empty)          LP(x) = u32be(len) ‖ x
```

**Before the KDF:** require `kdf_alg == 1`, 2 ≤ ops ≤ 10, 64 MiB ≤ mem ≤ 1 GiB and `salt.count == 16`. Otherwise throw `.corrupted`.

A GCM failure on the password wrap means `.wrongPassword`. A kcv mismatch after a successful unwrap means `.corrupted`.

**Change password:** re-wrap with a fresh salt and nonce. A checkbox **"My password may be compromised: rotate the vault key"** is on by default and runs `rotateDEK`.

**Recovery reset:** unwrap with K_rec, set the new password, and **always** run `rotateDEK`, which issues and shows a new recovery key.

**`rotateDEK` (one transaction):**
1. Generate DEK′ (`dek_version+1`).
2. Re-encrypt every `*_ct` column under the new AAD.
3. Recompute fingerprints.
4. Re-wrap for password and recovery (new recovery key).
5. Store the new kcv.
6. Replace the Touch ID item.
7. After commit, run `PRAGMA wal_checkpoint(TRUNCATE)`.

SECURITY-MODEL.md states that backups made before a rotation can still be opened with the credentials that were valid at that time.

### 5.3 Recovery key text format

- Payload: `key(32) ‖ SHA256("fxvault/v1/recovery-check" ‖ key)[0..<3]` = 35 bytes = **56 Crockford Base32 characters**, shown as **14 groups of 4** on two rows.
- Decoding uppercases, maps I/L to 1 and O to 0, strips `-` and whitespace, and rejects U. A checksum mismatch gives `.invalidRecoveryKey`.
- Onboarding shows the key once (Copy goes through ClipboardManager), warns the user to store it in a password manager, then asks for **2 randomly chosen groups**. The key is never persisted.
- Showing a new recovery key from Preferences requires the master password (D30).

### 5.4 Field encryption and fingerprints

- Blob: `0x01 ‖ AES.GCM.SealedBox.combined` under K_field.
- **AAD:** `LP("fxvault/v1/field") ‖ LP(table) ‖ LP(column) ‖ LP(row_uuid 16B) ‖ LP(repository_uuid 16B) ‖ LP(environment_uuid|empty) ‖ LP(kind) ‖ LP(name_for_column) ‖ u32be(dek_version)`.
  - `name_for_column` is `name` for `value_ct` and `synced_name` for `synced_value_ct`.
  - A rename re-encrypts `value_ct`, which is cheap. A kind or scope flip in the database fails decryption.
- Columns covered: `config_items.value_ct` and `config_items.synced_value_ct` (secrets and variables).
- Fingerprint: `HMAC-SHA256(K_fp, LP(row_uuid) ‖ value)` in `value_fp` and `synced_fp`.
- Duplicate, import and share all re-encrypt under new row ids in one transaction.
- `synced_value_ct` is set to NULL when it becomes obsolete: after "Accept GitHub" drift, and after a verified push of a changed value (it is then replaced by the new value).

### 5.5 Keychain and Touch ID

**Signed builds** (`BuildCapabilities.hasKeychainAccessGroup` is true when the SecTask entitlement is present). The item is created with:
- `kSecClassGenericPassword`, service `io.fractalx.fxvault.dek`, account `touchid-v1-<vault_id hex>`, the access group from the entitlement
- `kSecUseDataProtectionKeychain: true`, `kSecAttrSynchronizable: false`
- access control `WhenPasscodeSetThisDeviceOnly` with `.biometryCurrentSet`
- the DEK bytes, wiped after use

**Unlock:**
- `SecItemCopyMatching` off the main actor, with a fresh `LAContext`. Its `touchIDAuthenticationAllowableReuseDuration` is 0, and the prompt strings come from the app.
- The returned key must pass the kcv check. On a mismatch, delete the item and fall back to the password.

**When the master password is still required:**
- After a restart: compare `kern.bootsessionuuid` with the value stored at the last password unlock.
- When the last password unlock is more than 14 days old.
- After an enrollment change: the stored `biometry_state_hash` (`domainState.biometry.stateHash` on macOS 15+, `evaluatedPolicyDomainState` on 14) differs.

**Other operations:**
- **Presence check:** `interactionNotAllowed`; -25308 means present, -25300 means absent.
- **Enable:** first deletes every item for the service whose account is not `touchid-v1-<current vault_id>`.
- **Disable:** requires the master password.
- `resetVault()` and `rotateDEK()` delete and recreate the item.

**Error mapping:**
- -25300 or -25293 → invalidated (delete, offer to re-enable)
- -128 or `.userCancel` → cancel
- `.userFallback` → password field
- `.biometryLockout` → password

`ctx.invalidate()` runs on every lock.

**Ad-hoc builds:** the toggle is disabled with the note *"Touch ID requires the official signed release."*

### 5.6 ReauthGate (D30)

- `ReauthGate.authorize(.export | .share | .nearbySend)` reads the Touch ID item, verifying the kcv, or verifies the master password by unwrapping. It never uses `.deviceOwnerAuthentication`, which would accept the macOS login password.
- `ReauthGate.authorizeWithPassword(.newRecoveryKey | .changePassword | .disableTouchID | .rotateKey | .resetVault)` accepts the master password only.

### 5.7 Auto-lock

**Triggers (each can only lock):**
- `NSWorkspace` notifications `.willSleep`, `.screensDidSleep`, `.sessionDidResignActive`
- `NSApplication.protectedDataWillBecomeUnavailableNotification`
- the distributed notifications `com.apple.screenIsLocked` and `com.apple.screensaver.didstart`
- closing the main window

**Inactivity:**
- A local `NSEvent` monitor (key, mouse and scroll events) stamps `lastInteraction` with `ContinuousClock.now`, which keeps advancing during sleep.
- A `DispatchSourceTimer` on a utility queue fires every 15 s. It is unaffected by modal or tracking run-loop modes.
- It locks when the elapsed time is at least the timeout (default 300 s; options 1/2/5/10/15/30/60 min), unless a `SyncActivityAssertion` is held.

### 5.8 Lock procedure

**Phase A (synchronous, on the main actor, before any suspension point):**
1. `VaultKeyring.lock()`
2. `GHTokenCache.purge()`
3. `LAContext.invalidate()`
4. `AppViewModel.phase = .locked`, which clears every revealed value and editor buffer through observation

**Phase B (fire-and-forget, after Phase A):**
- dismiss app-owned sheets, modals and Settings sheets
- `SyncExecutor.cancel()`, cancel any nearby session, terminate child processes
- `ClipboardManager.clearIfOwned()`
- `PRAGMA wal_checkpoint(TRUNCATE)`

### 5.9 Clipboard

```
pb.prepareForNewContents(with: .currentHostOnly)
item: .string = value; "org.nspasteboard.ConcealedType" = Data(); "org.nspasteboard.TransientType" = Data(); "org.nspasteboard.source" = "io.fractalx.fxvault"
owned = pb.changeCount; after Durations.clipboardClear (30 s): if pb.changeCount == owned { pb.clearContents() }
```

The same check runs on lock and on terminate. The clipboard is never read.

### 5.10 Process runner rules

**Basics:**
- `Process` with an absolute `executableURL` and an argv array. A shell string is never used, except for the shell probe in §8 A2.
- `currentDirectoryURL` is `~/Library/Caches/io.fractalx.fxvault/empty-cwd` (0700).
- stdin is **always** a Pipe. The `StdinPayload` (`SecretBytes`) is written, the pipe is closed, and the payload is wiped.
- stdout and stderr are drained concurrently, capped at 32 MiB and 1 MiB.
- Timeouts come from `Timeouts.swift`: `auth token` 60 s, other gh commands 30 s (`repo list` 120 s), `ssh -T` 15 s, shell probe 5 s, `git clone` 300 s. On timeout: SIGTERM, then SIGKILL after 2 s.

**gh environment (allowlist):**

```
HOME USER LOGNAME TMPDIR PATH=<resolved> LANG=en_US.UTF-8
[GH_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME — only if captured]
GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1
GH_PAGER=cat PAGER=cat NO_COLOR=1 CLICOLOR=0 GH_SPINNER_DISABLED=1 GH_TELEMETRY=false DO_NOT_TRACK=1
GH_TOKEN=<account token>   # all calls except `auth status` / `auth token`
```

- Never present: `GH_DEBUG DEBUG GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO GH_FORCE_TTY CLICOLOR_FORCE GH_EDITOR GH_BROWSER`. A test asserts this.
- **Values go only through stdin** (`gh secret set` / `gh variable set` read stdin when `--body` is absent; `gh api --input -` for environment JSON).
- Forbidden gh flags (asserted by the argv builders and a test): `--body`/`-b`, `-f`/`--env-file`, `--no-store`, `--verbose`, `--show-token`, `--cache`, `--clone`, and `gh api` `-f`/`-F`/`--raw-field`/`--field`.
- Flag values that come from user data use the `--flag=value` form (`--env=<E>`, `--repo=<O>/<R>`) so they can never be parsed as flags; positional names already match `^[A-Z_][A-Z0-9_]*$`.

**gh binary trust (`GHLocator`):**
- Reject a candidate if the file or its parent directory is group- or world-writable, or if it is not owned by the user or root.
- The resolved absolute path and version are shown in Preferences › Accounts.
- A change between launches raises a warning.

**git and ssh:**
- Executables are `/usr/bin/git` and `/usr/bin/ssh` (absolute paths).
- Environment: `HOME USER PATH SSH_AUTH_SOCK LANG GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15"`.
- Every invocation in a user-chosen directory runs as `/usr/bin/git -c core.fsmonitor= -c core.hooksPath=/dev/null -c protocol.allow=never -c protocol.ssh.allow=always -C <dir> …`.
- SSH aliases must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and are passed after `--`.
- Host-key checking is never weakened. If the host is unknown, the user is told to run `ssh -T git@<alias>` once in Terminal.

### 5.11 Secret value entry and display

**`SecretValueEditor`** is an NSViewRepresentable NSTextView with:
- automatic quote, dash and text substitution, spelling correction, continuous spell check, grammar check and text completion all **off**
- `allowsUndo = false`
- `writingToolsBehavior = .none` on macOS 15+
- `EnableSecureEventInput` while it has focus
- trailing CR/LF stripped on commit with a visible notice, plus the SSH/PEM key hint (D32)

**Windows and display:**
- Windows and sheets that show values set `isRestorable = false`. No values in `@SceneStorage`.
- Revealed cells re-mask on `NSApplication.didResignActive` and 30 s after a reveal.
- Best effort: `NSWindow.sharingType = .none` on the recovery-key and reveal sheets.

### 5.12 Memory hygiene

- `SecretBytes`: a final class around `UnsafeMutableRawBufferPointer`. Its deinit wipes with `memset_s`, and `description`, `debugDescription` and `customMirror` all return `<redacted>`.
- Values are decrypted only when needed: reveal, copy, edit, sync, export, share.
- For a push (secret or variable), the value goes from decryption into `SecretBytes`, is written to gh's stdin pipe, the pipe is closed and the buffer is wiped. gh receives the plaintext and seals secrets itself (residual risk, §5.14).
- A `String` copy exists only for the cell currently being revealed or edited.

### 5.13 Export and credential heuristics

**`SecureFileWriter`:**
- Opens a sibling temp file with `open(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600)`, writes, calls `fsync`, then `rename`. Never uses `Data.write(.atomic)`.
- Before writing, checks `URLResourceValues.isUbiquitousItem`, paths under `~/Library/Mobile Documents`, and Desktop/Documents when iCloud Desktop & Documents sync is on. In those cases it shows an explicit **"This folder syncs to iCloud"** warning and notes that Spotlight indexes the file.

**Git checks:** run `rev-parse --show-toplevel`, `check-ignore -q`, **and** `ls-files --error-unmatch`. If the file is tracked, show "already committed: remove it from history".

**`CredentialClassifier`:** a key is pre-marked as a secret if it contains any of:
- the spec list: TOKEN, KEY, PASSWORD, SECRET, PRIVATE
- PASS, PWD, CREDENTIAL, AUTH, DSN, CERT, PEM, SIGNING, WEBHOOK

…or if its value:
- contains URL userinfo (`://[^/@]+:[^/@]+@`)
- is a PEM block or JWT
- has a known token prefix (`ghp_`, `github_pat_`, `sk_live_`, `AKIA`, `xox[bp]-`)
- is at least 20 characters with at least 3.5 bits/char of entropy

`SyncPreflight` asks for blocking confirmation before pushing a variable that matches, and before any secret→variable conversion (which is done as duplicate plus delete, D11).

### 5.14 Threat model

**In scope:**
- a stolen or copied disk while locked
- other local users (no values in argv; files 0600; directory 0700)
- shoulder surfing
- clipboard leaks
- accidental `.env` commits and iCloud upload
- a person at an unlocked Mac using recovery-key, export or share paths (ReauthGate)
- nearby MITM (commit-reveal SAS)
- an intercepted `.fxvault` file (Argon2id plus a 77.5-bit passphrase)
- malicious share packages (validator and merge defaults)
- partial or indeterminate sync results (journal)
- leaked old credentials combined with old backups (DEK rotation)

**Out of scope:**
- malware or root running as the user, **including same-user write access to the vault or to `~/.zshrc`, `~/.ssh/config` and `PATH` while the vault is locked**. Such code can already replace gh or git. The field AAD still makes kind and scope tampering fail decryption.
- a compromised gh token or GitHub account
- keyloggers
- a compromised build machine

**Residual risks (in SECURITY-MODEL.md):**
- `GH_TOKEN` is visible to same-user processes while gh runs.
- Repo, environment and item **names** appear in the gh argv while it runs, visible to every local user.
- Names and metadata are plaintext on disk.
- Swift `String` copies cannot be wiped reliably.
- Screen-lock detection is best effort.
- Ad-hoc builds have no Touch ID and unstable TCC grants.
- We trust the gh and git binaries we resolve (`GHLocator` permission checks). gh receives secret **and** variable plaintext on stdin and seals secrets itself, so a replaced gh binary could read values.
- Verification accepts a secret write as ours when `updatedAt` changed from the pre-write value. A write by someone else between that scope's pre-write re-list and its verification re-list is either silently overwritten (before our write; `gh secret set` is unconditional) or accepted as ours (after it). Throttling and verification retries can stretch this window to minutes; per-scope re-list right before writing and verification right after keep it as short as possible.
- Values lose trailing CR/LF (D32); the user is told on entry.
- Nearby HELLO metadata (display name, versions) is cleartext on the LAN.

---

## 6. Data model (GRDB)

**Storage:**
- `~/Library/Application Support/FX Vault/vault.sqlite` (plus `-wal` and `-shm`). Debug builds use `FX Vault Dev/`. Directory mode 0700.
- `DatabasePool`. `prepareDatabase` runs `PRAGMA secure_delete = ON` and turns on foreign keys.

**Formats:**
- Timestamps are ISO-8601 UTC TEXT. UUIDs are lowercase TEXT; the AAD uses the raw 16 bytes.
- `name_key` columns hold the Swift `lowercased()` of the NFC name, which is a Unicode case fold. SQLite `NOCASE` is not used for Unicode.

**Migrations:**
- `DatabaseMigrator`. **A migration is frozen once any build has run it.** Changes always go into a new migration.
- `eraseDatabaseOnSchemaChange` is never used.
- `MigrationTests` applies the migrations both fresh and step by step from every earlier version.

**Migration `v1_vault` (M1)**
```sql
CREATE TABLE vaults (                       -- single row
  id INTEGER PRIMARY KEY CHECK (id = 1),
  vault_id BLOB NOT NULL CHECK (length(vault_id) = 16),
  format_version INTEGER NOT NULL DEFAULT 1,
  dek_version INTEGER NOT NULL DEFAULT 1,
  kcv BLOB NOT NULL CHECK (length(kcv) = 16),
  biometry_state_hash BLOB,
  last_password_unlock_at TEXT, last_password_boot_session TEXT,
  created_at TEXT NOT NULL);
CREATE TABLE key_wraps (
  method TEXT PRIMARY KEY CHECK (method IN ('password','recovery')),
  kdf_alg INTEGER NOT NULL CHECK (kdf_alg IN (1,2)),         -- 1 argon2id13, 2 hkdf-sha256
  ops_limit INTEGER, mem_limit_bytes INTEGER, salt BLOB,
  wrapped_dek BLOB NOT NULL CHECK (length(wrapped_dek) = 62),
  dek_version INTEGER NOT NULL, updated_at TEXT NOT NULL,
  CHECK (kdf_alg = 2 OR (ops_limit IS NOT NULL AND mem_limit_bytes IS NOT NULL AND length(salt) = 16)));
```

**Migration `v2_accounts_repos` (M2)**
```sql
CREATE TABLE accounts (
  login TEXT PRIMARY KEY COLLATE NOCASE,         -- GitHub logins are ASCII
  host TEXT NOT NULL DEFAULT 'github.com' CHECK (host = 'github.com'),
  ssh_host_alias TEXT, ssh_verified_login TEXT, ssh_verified_at TEXT,
  is_present INTEGER NOT NULL DEFAULT 1,
  last_seen_at TEXT NOT NULL);
CREATE TABLE repositories (
  id TEXT PRIMARY KEY,
  account_login TEXT NOT NULL REFERENCES accounts(login) ON UPDATE CASCADE,
  github_id TEXT UNIQUE,                         -- gh --json `id` (GraphQL node id)
  owner_login TEXT NOT NULL, owner_type TEXT NOT NULL CHECK (owner_type IN ('User','Organization')),
  name TEXT NOT NULL, description TEXT,
  is_private INTEGER NOT NULL, is_archived INTEGER NOT NULL DEFAULT 0, is_fork INTEGER NOT NULL DEFAULT 0,
  default_branch TEXT,
  has_admin INTEGER NOT NULL DEFAULT 0, has_push INTEGER NOT NULL DEFAULT 0,   -- from viewerPermission
  origin TEXT NOT NULL CHECK (origin IN ('imported','created')),
  is_env_plan_gated INTEGER NOT NULL DEFAULT 0,   -- clearable hint
  is_unavailable INTEGER NOT NULL DEFAULT 0,      -- e.g. SAML not authorized, or no longer listed
  imported_at TEXT NOT NULL, last_refreshed_at TEXT, created_at_github TEXT);
CREATE UNIQUE INDEX repositories_owner_name ON repositories(owner_login COLLATE NOCASE, name COLLATE NOCASE);
```

**Migration `v3_config` (M2, used by import)**
```sql
CREATE TABLE environments (
  id TEXT PRIMARY KEY,
  repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 255), name_key TEXT NOT NULL,
  synced_name TEXT, synced_name_key TEXT,     -- NULL = never synced
  is_deleted INTEGER NOT NULL DEFAULT 0,      -- tombstone (only with synced_name)
  branch_policy TEXT NOT NULL DEFAULT 'all' CHECK (branch_policy IN ('all','protected','custom')),
  synced_branch_policy TEXT CHECK (synced_branch_policy IN ('all','protected','custom')),
  foreign_rules_json TEXT,                    -- reviewers / wait_timer / app rules / can_admins_bypass (read-only)
  github_env_id INTEGER,
  remote_updated_at TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX environments_repo_name ON environments(repository_id, name_key);

CREATE TABLE config_items (
  id TEXT PRIMARY KEY,
  repository_id TEXT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  environment_id TEXT REFERENCES environments(id) ON DELETE CASCADE,   -- NULL = repository level; immutable once synced
  kind TEXT NOT NULL CHECK (kind IN ('secret','variable')),          -- immutable once synced
  name TEXT NOT NULL CHECK (name = upper(name) AND length(name) BETWEEN 1 AND 255),
  value_ct BLOB, value_fp BLOB,               -- value_ct NULL = secret value missing locally
  is_deleted INTEGER NOT NULL DEFAULT 0,
  synced_name TEXT,                           -- NULL = never pushed → pending add
  synced_value_ct BLOB, synced_fp BLOB,
  force_push INTEGER NOT NULL DEFAULT 0,      -- set by "Keep local" drift resolution; cleared after verified push
  remote_updated_at TEXT,
  verify_state TEXT NOT NULL DEFAULT 'verified' CHECK (verify_state IN ('verified','pending')),
  pre_write_updated_at TEXT,                  -- verification baseline (§7.3); the journal's started_at records when a write began
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  CHECK (kind = 'secret' OR value_ct IS NOT NULL),
  CHECK ((value_ct IS NULL) = (value_fp IS NULL)));
CREATE UNIQUE INDEX config_items_scope_name ON config_items(repository_id, COALESCE(environment_id, ''), kind, name);
```

**Migration `v4_sync_journal` (M3)**
```sql
CREATE TABLE sync_journal (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  account_login TEXT NOT NULL,
  repository_id TEXT REFERENCES repositories(id) ON DELETE SET NULL,
  op TEXT NOT NULL,                           -- ConfigChangeModel.kind raw value
  command TEXT NOT NULL,                      -- gh command id, e.g. secret.set, variable.delete, repo.create, api.env.put
  is_write INTEGER NOT NULL,
  scope_label TEXT NOT NULL, target_key TEXT NOT NULL, item_name TEXT,   -- names only, never values
  state TEXT NOT NULL CHECK (state IN ('in_flight','succeeded','failed','skipped','indeterminate','reconciled')),
  exit_code INTEGER, error_code TEXT,         -- gh exit code + GHStderrClassifier result
  started_at TEXT NOT NULL, pre_write_updated_at TEXT, finished_at TEXT);
CREATE INDEX sync_journal_account_time ON sync_journal(account_login, started_at);
-- retention: rows older than 24 h deleted at launch, except the latest run (shown as "last sync report")
```

**Migration `v5_create_policies` (M4)**
```sql
ALTER TABLE repositories ADD COLUMN create_spec_json TEXT;   -- {auto_init, gitignore_template, license_template, clone_after}
ALTER TABLE repositories ADD COLUMN clone_path TEXT;
CREATE TABLE deployment_branch_patterns (
  id TEXT PRIMARY KEY,
  environment_id TEXT NOT NULL REFERENCES environments(id) ON DELETE CASCADE,
  pattern TEXT NOT NULL CHECK (length(pattern) BETWEEN 1 AND 255),
  type TEXT NOT NULL CHECK (type IN ('branch','tag')),
  github_policy_id INTEGER,                   -- reset to NULL when policy leaves 'custom'
  is_deleted INTEGER NOT NULL DEFAULT 0,
  UNIQUE (environment_id, pattern, type));
```

**Migration `v6_sharing` (M6)**
```sql
ALTER TABLE config_items ADD COLUMN provenance TEXT NOT NULL DEFAULT 'local';  -- local | github | share
ALTER TABLE config_items ADD COLUMN provenance_detail TEXT;                    -- share packageId + unverified sender name
CREATE TABLE imported_share_packages (
  package_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, imported_at TEXT NOT NULL, sender_name TEXT);
```

**UserDefaults (`PreferencesManager`, non-secret):** `defaultCloneFolder` (default `~/Developer`, created on first clone), `autoLockMinutes` (5), `ghPathOverride`, `lastResolvedGHPath`, `nearbyDisplayName`, `lastSelectedRepoId`.

**Domain models (VaultCore):**
- `AccountModel`, `RepoModel`, `EnvironmentModel`
- `ConfigItemModel`: exposes `valueState: .present|.missing` and `provenance`, never a value
- `BranchPatternModel`
- `DeploymentBranchPolicyModel`: `.all | .protectedBranches | .custom([BranchPatternModel])`
- `RepoCapabilityModel`: `.full | .repoLevelOnly | .readOnly(reason)`. Whether WRITE maps to `.repoLevelOnly` or `.readOnly(.adminRequired)` is set from the M3 spike result (WRITE-collaborator test).

---

## 7. Sync model

### 7.1 Change derivation (pure)

`ChangeSetBuilder.build(_ snapshot: RepoSnapshotModel) -> ChangeSetModel` uses only fingerprints and flags.

| Row state | Change |
|---|---|
| repo `github_id == nil` | `.createRepository(spec)` |
| env `synced_name == nil`, not deleted | `.upsertEnvironment(name, policy, isNew: true)` |
| env `synced_name_key != name_key` | `.renameEnvironment(from:to:)` → §7.6 |
| env `synced_name_key == name_key`, `name != synced_name` (case only) | local only. GitHub keeps the stored case, and the UI notes this. |
| env `branch_policy != synced_branch_policy` | `.upsertEnvironment(isNew: false)` |
| unsynced or deleted patterns while policy is `custom` | `.reconcileBranchPatterns(env)` |
| env tombstone | `.deleteEnvironment(syncedName)`. Its children are implied. |
| item `synced_name == nil`, not deleted | `.set…(isNew: true)` |
| item `name != synced_name` | `.set…(new, isNew: true)` + `.delete…(synced_name)` |
| item `synced_name != nil`, `value_fp != nil`, (`synced_fp == nil` OR `value_fp != synced_fp` OR `force_push`) | `.set…(isNew: false)` |
| item tombstone | `.delete…(synced_name)` |
| a secret change that needs `value_ct == nil` | `.blocked(.valueMissing)` |

**Normalization pass (`ChangeSetNormalizer`):**
- Group by `(repo, scope, kind, foldedRemoteName)` and keep **one** final operation for each remote key.
- A set plus a delete on the same key becomes the set, and the delete is dropped.
- An environment create plus a delete on the same `name_key` becomes an upsert.
- Invariant (asserted in tests): no key is in both the upsert set and the delete set.

**Editing rules that keep the model consistent:**
- Adding or renaming into a name that has a tombstone **revives the tombstone row**: the new value moves onto it and the source row becomes a tombstone. A swap (A↔B) is therefore two value modifications.
- `EnvironmentNameValidator` rejects a new or renamed environment whose `name_key` equals any other row's `name_key`, or the `synced_name_key` of a row with a pending rename or delete.
- Kind and scope cannot change once a row is synced. The editor offers **"Convert to variable / Move to…"**, which creates a new row plus a tombstone; for secret→variable it asks for confirmation (§5.13).

**Coalescing:**
- add then edit = add
- add then delete = the row is removed
- edit back to the synced value = no change
- delete then re-add = revive

**Revert:** restores `value_ct := synced_value_ct` and `name := synced_name`, and clears `is_deleted` and `force_push`. **Discard all** reverts the whole repo.

**Filling a value-missing secret:** the default is "Fill local value (already on GitHub)", which sets `value_*` and `synced_* := same` with no pending change. A toggle offers **"Push this value on next Sync"**.

**Pending count:** executable changes after normalization. An environment rename or delete counts as 1. Blocked items are shown separately.

### 7.2 Summary format

```
FractalX-Technologies/api                         (new repository · private · README · Swift .gitignore · MIT)
  Repository        2 added, 1 modified              + SENTRY_DSN (secret)  + API_URL (variable)  ~ STRIPE_KEY (secret)
  production        3 added, 1 modified, 1 deleted   policy: custom (release/*)
  staging → stage   renamed (recreated on GitHub)
  qa                deleted — contents fetched live at confirmation
Blocked: DB_PASSWORD in production — value missing locally
Changed on GitHub since your last check: API_TOKEN (Repository) — review before syncing
FX Vault write limit this hour: 412 of 450 (other gh or GitHub activity also counts toward GitHub's limits)
```

Only names are shown, never values.

### 7.3 Execution (`SyncPreflight` → `SyncPlanner` → `SyncExecutor`)

**Preflight:**
- The vault is unlocked and the account token is present.
- `ScopeChecker` returns `.ok | .missing | .unknown`; `.unknown` passes for fine-grained tokens.
- Capability (from `viewerPermission`, via `RepoCapabilityModel`): admin for environment changes; for repo-level changes, the permission the M3 spike established (admin, or write if the spike confirms it). The repo must not be archived.
- Name rules apply (`^[A-Z_][A-Z0-9_]*$`, no `GITHUB_` prefix, and PathSegmentValidator).
- Limits from the M3 spike: each value at most 48,000 bytes and not empty (after D32 normalization). At most 100 secrets per scope, 500 repo variables and 100 variables per environment. A warning above about 256 KB of repo variables.
- Confirmation for credential-looking variables.
- **Optimistic concurrency (D27):** re-list every touched scope (B3/B4/B6–B9) and run `DriftDetector` against each change's base. A change whose base moved becomes `.blocked(.remoteChanged)`. Examples: secret `updatedAt` ≠ `remote_updated_at`, variable fingerprint ≠ `synced_fp`, a create target that already exists, an environment policy that differs. Each secret's listed `updatedAt` (or its absence) is stored as `pre_write_updated_at` on the row and the journal row: the verification baseline.
- The throttle budget is seeded from `sync_journal` (writes in the last 60 min per account).

**Execution, per repo** (one gh command per item, serial, values on stdin):
1. **Create the repo.** Journal row `in_flight`, then C1 (`gh repo create`, no `--clone`), then the normalized `name` from the URL gh prints on stdout, then B2 (`gh repo view`) to confirm it and get `id`, `sshUrl` and `defaultBranchRef`. This starts a **freshRepo** window of 90 s: every "not found" for that repo is retried every 1 s for up to 60 s and is never classified as plan-gated.
2. **Environment create or policy change** (including rename targets): C2 (`gh api`), then B4 to confirm; a failed C2 may still have created the environment, so B4 decides. Compare `protection_rules` (excluding branch_policy) with `foreign_rules_json`, and warn if they changed. If the policy left `custom`, reset `github_policy_id = NULL` on its patterns.
3. **Pattern reconcile** (policy custom): fresh B5, POST the missing patterns (200, including a followed redirect for an existing pattern, or a 303 both count as success; see C3), DELETE the extras.
4. **Items, one scope at a time:** immediately before writing a scope, re-list it (B6–B9), refresh each secret's `pre_write_updated_at` and re-run the `remoteChanged` check for that scope's items (not only once per run in preflight). Then variable upserts (C7), then secret upserts (C5), then that scope's verification (step 6) before the next scope. gh fetches the scope's public key and seals each secret itself.
5. **Deletes** of variables and secrets (C6/C8; "not found" counts as success only when a list of the same scope succeeds right after it, otherwise `.notFound` and the change stays pending). Each success is also recorded so drift does not report the deleted name as "remote added".
6. **Verification (`WriteVerifier`):** re-list each touched scope with the native list command (B6–B9) right after its writes.
   - Variable: verified when the listed value's fingerprint equals the fingerprint of the bytes gh actually stored (the normalized value, D32).
   - Secret: verified when it is listed and its `updatedAt` differs from `pre_write_updated_at` (a new secret: when it is listed); then `remote_updated_at := updatedAt`. How an identical-value set behaves comes from the spike (Q6). A third-party write between the pre-write re-list and this re-list is a residual risk (§5.14).
   - Items that are missing or not yet updated are retried every 2 s for up to 60 s. After that they stay `verify_state = pending` and are finished by the **pending-verification pass**.
   - **Pending-verification pass:** runs before `DriftDetector` on every drift run (§7.7), on the same re-list. Variable: fingerprint equal → verified. Secret: `updatedAt` ≠ `pre_write_updated_at` → verified and `remote_updated_at := updatedAt`. After `Limits.pendingVerifyChecks` passes without a match → `verify_state := 'verified'` and the push counts as failed: a secret gets `force_push := 1` (pending re-push, shown as "Unverified"); a variable is left to `DriftDetector`, which reports `fp(remote) != synced_fp` as drift. The Q6 spike result for identical-value sets may refine the secret rule. Only rows still pending after the pass are skipped by `DriftDetector`.
7. **Environment deletes** (C9), including rename sources, but **only** once verification succeeded. They go through the deletion confirmation.
8. **Optional clone** (§8 D3).

**Dependencies:**
- A failed repo create skips everything in that repo.
- A failed environment PUT skips its patterns and items.
- A failed rename verification keeps the old environment.

**Indeterminate outcomes:** a timeout after the process started, a 5xx, a network error, or a crash with `in_flight` rows.
- Idempotent commands (secret and variable set, deletes, environment PUT) are retried up to 2 times with backoff.
- `gh repo create` is never retried; it is reconciled with B2 using facts that do not depend on the local clock: adopt the repo when the preflight B2 for that name (recorded in the journal) returned "Could not resolve to a Repository" **and** B2 now finds it with the expected owner and visibility. Otherwise the item is reported as a conflict for the user to resolve. `createdAt` is never compared with the local `started_at`.
- At launch, leftover `in_flight` rows are reconciled by re-listing (secret `updatedAt` vs `pre_write_updated_at`, variable fingerprint) before a new sync is allowed.

**Throttle:**
- At most 60 writes/min and 450/h, with a 1 s gap once a batch has more than 10 writes. A `gh variable set` on an existing variable counts as 2 writes (gh POSTs, gets 409, then PATCHes). An environment variable set also costs 1 GraphQL read (repository-ID lookup) before its 1–2 REST writes.
- Rate limited (classified from stderr, §8 E): wait `Timeouts.rateLimitBackoff` (60 s), retry at most `Limits.rateLimitRetries` (2) times, then stop the run with `.rateLimited`; the remaining items stay pending.

**Tokens:** on `.tokenRevoked` (stderr `HTTP 401`), purge that account's token and re-run A4 once. If the token changed, retry once. **Re-check** also invalidates the cache.

### 7.4 Partial failure

- Each outcome is written synchronously (journal plus `synced_*`). A failed item stays pending automatically.
- The result view has **Succeeded / Failed / Skipped / Blocked** sections, each with a localized reason and an action:
  - admin required ("Must have admin rights") → "Ask an admin"
  - SAML → "Authorize" (the URL gh printed, if any)
  - rate limited → "Sync again later"; the rest stays pending
  - plan-gated → explanation and docs link; sets the clearable `is_env_plan_gated` hint
  - token revoked (401) → re-authenticate in Terminal
  - remoteChanged → "Review drift"
- Cancellation stops after the call in flight. Completed items stay synced, and unverified ones stay `pending`.

### 7.5 Deletion confirmation

- If the change set contains any deletion, the primary button is **"Review N deletions…"**.
- For each environment being deleted, the app **fetches B4/B5/B7/B9 live** and lists the union of local and remote names. Remote-only names are marked *"not in your vault: will be lost"*, and foreign rules from the fresh GET are listed.
- If that fetch fails, the view shows *"contents unknown"* and requires an extra acknowledgement.
- The view also warns: *"Workflows that still reference `qa` will recreate it empty."*
- "Delete N items on GitHub" stays disabled until the user checks "I understand this cannot be undone". Neither button is the default, and Return does nothing.

### 7.6 Environment rename (synced, M4; Q5)

1. Case-only rename (same `name_key`): local only, with no GitHub calls.
2. Preflight blocks the rename while any secret in the environment is value-missing, and offers "Enter values".
3. Show a warning that deployment history, reviewers, wait timers, custom app rules and workflow `environment:` references do not carry over.
4. Execute: PUT the new environment (C2), POST its patterns (C3), set every variable and secret (C7/C5, values on stdin), then verify.
   - **Guard:** if the new environment's `github_env_id` equals the old one's, abort without deleting.
5. **Once verification succeeds, persist two facts:**
   - the row moves to its new remote identity (`synced_name := new`, new `github_env_id`, children synced and verified);
   - a separate tombstone row holds the old remote identity.

   The old environment's DELETE is then an ordinary pending deletion. It goes through §7.5 and can be retried if it fails.
6. Item renames follow the same split: the new name is synced on the moved row, and a tombstone row holds the old name.

### 7.7 Drift detection (M5)

`DriftDetector.detect(local: RepoSnapshotModel, remote: RemoteSnapshotModel, fingerprint:) -> [DriftModel]` is a pure function.

**When it runs:** on opening a repo (debounced to once per 2 min per repo), on **Refresh**, and in sync preflight. Each run is a full re-list with the native commands (`gh secret list` / `gh variable list` follow every page at `per_page=100`, verified in gh's source) plus `gh api --paginate` for environments (B3–B9); there are no ETags. The pending-verification pass (§7.3 step 6) runs first on the same re-list; items still `verify_state = pending` after it are ignored, and names deleted successfully in the last 10 min (per the journal) are not reported as "remote added".

**What it reports:**
- Variable modified: `fp(remote.value) != synced_fp`.
- Secret modified: listed `updatedAt != remote_updated_at`.
- Remote added: no local row. Or a never-synced local row with the same name, which is a conflict.
- Remote deleted: a synced, non-tombstoned row is missing on GitHub.
- Conflict: changed remotely while also pending locally.
- Environment added or deleted remotely.

Alert copy: *"Secret API_TOKEN was changed on GitHub on Oct 12"*.

| Drift | Keep local | Accept GitHub |
|---|---|---|
| Variable modified | `synced_fp := fp(remote)`, which makes it pending modify | `value := remote`, `synced := remote` |
| Secret modified | `force_push := 1` (needs a local value) | `value_ct := nil`, `synced_value_ct := nil`, `remote_updated_at := remote`, then prompt "Enter new value" in fill mode |
| Remote added | Tombstone with `synced_name` set (pending delete) | Import: variable with its value, secret as value-missing (`provenance = github`) |
| Remote deleted | `synced_name := nil` (pending add) | Delete the local row |
| Environment added or deleted remotely | Pending delete, or re-create | Import, or delete locally |

### 7.8 Value-missing secrets

- Shown with a "Value missing" chip. They cannot be revealed or copied.
- Export skips them and lists their names.
- Duplicate carries the flag over.
- Share sends the name only.
- Sync blocks them, and so does environment rename.
- A share can fill them (§9.5).

---

## 8. gh and git command catalog (becomes `docs/API.md`)

**Conventions:**
- `GH` is the resolved absolute path. Every call goes through `GHCommandService` with the §5.10 environment; A3 and A4 run without `GH_TOKEN`, everything else with the account's token.
- **Native gh subcommands for everything they cover.** `gh api` (written `API` below) is used **only** for environments and deployment branch policies (B3–B5, C2–C4, C9). No other `gh api` call, no direct HTTP.
- `{O}`, `{R}`, `{E}` and `{N}` pass `PathSegmentValidator` and the GitHub name validators before any argv is built. User-derived flag values use the `--flag=value` form (`--repo=<O>/<R>`, `--env=<E>`); gh ≥ 2.97 escapes the environment name in the URL.
- **Success is exit code 0.** Native commands expose no HTTP status or headers: stdout is parsed only on success, and failures are classified from stderr plus the exit code (E).
- `--json` output is decoded with strict DTOs whose fixtures come from the spike; unknown fields are ignored.
- Values only on stdin (§5.10). One write command per item, serial (D12); never `--env-file`.
- `API` means `GH api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2026-03-10"`. `GitHubPath` percent-encodes each segment with the ASCII unreserved set and **throws on dot-segments**. List reads use `--paginate --slurp` (exit code plus stderr, like native commands). Single-object reads and writes add `-i`, and `APIResponseParser` reads the status line and body. Bodies go through `--input -` with JSON on stdin; `-X` is always explicit.

### A. Discovery and auth (no GH_TOKEN unless noted)

| Op | argv | Parse / notes |
|---|---|---|
| A1 version | `GH --version` | `^gh version (\d+)\.(\d+)\.(\d+)`. Below 2.97.0 blocks with the upgrade screen. |
| A2 shell probe | `<pw_shell> -l -c '<script>'`, falling back to `-i -l -c`. The script prints `__FXV_B__`, then for each key in `PATH GH_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME SSH_AUTH_SOCK` prints `printf '%s=%s\0' "$k" "$(/usr/bin/printenv $k)"`, then `__FXV_E__`. fish gets its own variant. | env `FXVAULT_RESOLVING_ENV=1`, stdin /dev/null, 5 s. Only those keys are ever captured. |
| A3 accounts and scopes | `GH auth status --hostname github.com --json hosts` | Per account: login, `state`, active flag, `scopes`. `state`: `success` means OK; `timeout` means offline; `error` is decided from the `error` field: network fragments (`error connecting to`, `dial tcp`, `no such host`, …) mean offline, `HTTP 401`/`Bad credentials` mean re-login, anything else is shown as an unexpected error. `scopes` is the raw `X-OAuth-Scopes` header (`gist, read:org, repo`): split on `,` and trim whitespace; an absent key (it is `omitempty`) or empty value means `.unknown` (e.g. fine-grained tokens). |
| A4 token | `GH auth token --hostname github.com --user <login>` | 60 s timeout. Trim the output and keep it in memory only. |
| A5 orgs | `GH org list --limit <Limits.orgListMax>` (GH_TOKEN) | One login per line (no `--json` in gh). Each login is validated. Lists only orgs the account is a member of. Needs `read:org`; without it the list can be incomplete (likely public memberships only) **without any error**, so the scope warning also notes that orgs may be missing. |

### B. Read

| Op | argv | Notes |
|---|---|---|
| B1 repos | `GH repo list <owner> --limit <Limits.repoListMax> --json id,name,nameWithOwner,owner,isPrivate,visibility,isArchived,isFork,viewerPermission,viewerCanAdminister,defaultBranchRef,sshUrl,createdAt`, run for the account login and each A5 org (GH_TOKEN) | `viewerPermission` ADMIN → admin; ADMIN/MAINTAIN/WRITE → push. Owner type comes from which list it was. Invalid names are skipped and logged. A SAML error for one org marks that org's imported repos unavailable with an "Authorize SAML for <org>" banner; other owners continue. A count equal to the limit shows "List truncated: add by name". **Not covered:** repos where the account is a collaborator but not an owner or org member, whether the owner is a user or an organization (outside-collaborator access) → B2. |
| B2 repo | `GH repo view <O>/<R> --json <B1 fields>` | **Add repository by name**, name availability ("Could not resolve to a Repository" means **probably available**: gh returns the same error for a repo the token cannot see; C1's "already exists" → `.validation` is the authoritative check), the follow-up to C1, and create reconciliation (expected owner and visibility, §7.3). |
| B3 environments | `API --paginate --slurp "repos/{O}/{R}/environments?per_page=100"` | Policy and protection_rules (foreign rules stored read-only). |
| B4 environment | `API -i repos/{O}/{R}/environments/{E}` | Confirms after a PUT. 404 means absent. |
| B5 patterns | `API --paginate --slurp "repos/{O}/{R}/environments/{E}/deployment-branch-policies?per_page=100"` | Only when custom is true; otherwise a 404 means none. |
| B6/B7 secrets | `GH secret list --repo=<O>/<R> [--env=<E>] --json name,updatedAt` | gh requests `per_page=100` and follows every page. "Must have admin rights" makes the scope read-only and unknown. |
| B8/B9 variables | `GH variable list --repo=<O>/<R> [--env=<E>] --json name,value,updatedAt,createdAt` | Same pagination. Values are encrypted on import, and the stdout buffer is wiped after decoding. |
| B10 templates | `GH repo gitignore list`, `GH repo license list` | Plain text parsed by line (license: key column first). Cached for the session. |

### C. Write (one command per item; values and JSON on stdin)

| Op | argv | Success / special cases |
|---|---|---|
| C1 create repo | `GH repo create <O>/<N> --private\|--public [--description=<D>] [--add-readme] [--gitignore=<T>] [--license=<L>]`, never `--clone`; then B2 | Exit 0 means created. With non-TTY stdout gh prints exactly one line, the new repo's URL (`https://github.com/<owner>/<normalized-name>`): it is the primary source of the normalized name, so the name is known even if B2 fails during the freshRepo window. B2 confirms it and supplies `id`, `sshUrl`, `defaultBranchRef`. With an `OWNER/` prefix gh first does REST `GET users/<owner>`, so `HTTP 404: Not Found (…/users/<owner>)` means the owner is invalid (`.validation`), not plan-gated and not a freshRepo delay. gh uses REST when README or templates are set and GraphQL otherwise, so errors start with `HTTP 4xx:` or `GraphQL:`. "already exists" → `.validation`. An org-policy message → `.orgPolicyForbidsCreate`. Never retried (§7.3). |
| C2 env upsert | `API -i -X PUT repos/{O}/{R}/environments/{E} --input -` · `{"deployment_branch_policy": null \| {true,false} \| {false,true}}` | 200, then B4. Never sends wait_timer, reviewers or prevent_self_review. "billing plan", or a 404 that persists after the freshRepo window while B2 succeeds, means plan-gated. |
| C3 pattern add | `API -i -X POST …/deployment-branch-policies --input -` · `{"name","type"}` | 200 = created, or an existing pattern after gh's HTTP client followed GitHub's 303 redirect (`-i` shows only the final response); a 303 surfaces only if it had no `Location` (exit 1, `gh: HTTP 303`). Both 200 and 303 count as success; the policy id comes from the 200 body (a bare 303 is followed by a B5 re-list). The spike records which happens. |
| C4 pattern delete | `API -i -X DELETE …/deployment-branch-policies/{id}` | 204. A 404 counts as done. |
| C5 secret set | `GH secret set <N> --repo=<O>/<R> [--env=<E>]`, value on stdin | Exit 0 means written; gh fetches the public key, seals and PUTs. Verified through B6/B7 `updatedAt` (§7.3). gh strips trailing CR/LF; `SyncPlanner` pushes normalized bytes (D32). |
| C6 secret delete | `GH secret delete <N> --repo=<O>/<R> [--env=<E>]` | Exit 0. `HTTP 404` (also returned for a missing environment or an inaccessible repo) counts as done only when a B6/B7 list of the same scope succeeds right after it; otherwise `.notFound` and the change stays pending. |
| C7 variable set | `GH variable set <N> --repo=<O>/<R> [--env=<E>]`, value on stdin | Upsert: gh POSTs and PATCHes on 409, so no create/update split. With `--env`, gh first runs a GraphQL repository-ID lookup on every call (errors read `failed to look up repository O/R: GraphQL: …`). gh sends `value` with `omitempty`, so an empty value sends no `value` field: one reason preflight rejects empty values. Exit 0; verified by fingerprint through B8/B9, with the expected fingerprint computed over the normalized bytes gh stores (D32). |
| C8 variable delete | `GH variable delete <N> --repo=<O>/<R> [--env=<E>]` | Exit 0. `HTTP 404` counts as done only when a B8/B9 list of the same scope succeeds right after it; otherwise `.notFound` and the change stays pending. |
| C9 env delete | `API -i -X DELETE repos/{O}/{R}/environments/{E}` | 204. A 404 counts as done only when a B3 list of the repo's environments succeeds right after it and no longer shows `{E}`; otherwise `.notFound` and the change stays pending. Guarded by the rename id check. |

### D. git and ssh (`/usr/bin/git`, `/usr/bin/ssh`, environment and flags from §5.10)

| Op | argv | Notes |
|---|---|---|
| D1 resolve alias | `/usr/bin/ssh -G -- <alias>` | Reads `hostname`. Only github.com is valid. |
| D2 verify alias | `/usr/bin/ssh -T -o BatchMode=yes -o ConnectTimeout=10 -- git@<alias>` | Exit 1 plus `Hi (\S+)!` gives the login. If that login is not in gh, show the UI state "Authenticates as X, which is not logged into gh: run gh auth login". |
| D3 clone | `git … clone -- git@<alias>:<O>/<N>.git <folder>/.<N>.fxvault-clone-<uuid>`, then rename to `<folder>/<N>` | The destination is standardized and must be inside the chosen folder. Fails early if `<N>` exists. Retries on exit 128 three times, 3 s apart, **unless** stderr matches `Permission denied|Repository not found|Host key verification failed`, in which case it shows alias guidance and the D2 result. On failure, only the temp directory is removed. An EPERM gets Files and Folders guidance. |
| D4 repo root | `git … -C <dir> rev-parse --show-toplevel` | |
| D5 ignored? | `git … -C <root> check-ignore -q -- <rel>` | 0 means ignored. |
| D6 tracked? | `git … -C <root> ls-files --error-unmatch -- <rel>` | 0 means tracked, which shows the "already committed" warning. |

### E. Error classification (`GHStderrClassifier`, in priority order)

Input: the exit code, the redacted stderr, and for `API -i` calls the status line. The status comes from:
- native commands: `HTTP (\d{3}): ` anywhere in stderr (unanchored, because gh wraps it, e.g. `failed to delete secret X: HTTP 404: Not Found (…)`);
- `gh api` (no `HTTP nnn:` form; it prints `gh: …` and adds no "Try authenticating" line): `^gh: (.*) \(HTTP (\d{3})\)$` or `^gh: HTTP (\d{3})$`; a `gh: <errors> (<message>)` line has no status and is matched by fragments only;
- a `GraphQL: <message>` line (repo list, some creates, and `failed to look up repository O/R: GraphQL: …` before environment variable sets);
- the `-i` status line.

Exit codes (`gh help exit-codes`): 0 ok, 1 error, 2 cancelled, 4 authentication required. With `GH_TOKEN` set, a 401 exits 1, not 4.

1. 401 or "Bad credentials" → `.tokenRevoked` (refresh the token once, §7.3). Checked **first**: on a native 401 gh also prints `Try authenticating with:  gh auth login -h github.com`, which must not route the error to `.notAuthenticated`.
2. Exit 4, or "You are not logged into any GitHub hosts" → `.notAuthenticated` (never on the bare fragment "gh auth login")
3. "SAML" (with the URL from `Authorize in your web browser:\s+(\S+)`, which matches native commands' two spaces and `gh api`'s one, or a `github.com/orgs/<org>/sso` link when present) → `.samlRequired`
4. 429, "secondary rate limit" or "API rate limit exceeded" → `.rateLimited` (fixed backoff, D12)
5. "Must have admin rights" → `.adminRequired`
6. "Resource not accessible" or "repository read permissions" → `.writeAccessRequired`; `needs the "(.+)" scope` or "missing required scopes" → `.missingScopes`
7. C1 with an organization policy message → `.orgPolicyForbidsCreate`
8. "billing plan" → `.planGated`
9. 404, "Not Found" or "Could not resolve to a Repository" → `.notFound` (the caller may reclassify it)
10. 422 or "already exists" → `.validation`
11. 500/502/503/504 → `.serverError`
12. `dial tcp|no such host|connection refused|connection reset|i/o timeout|TLS handshake timeout|error connecting to |check your internet connection` → `.network` (gh prints only the last two for DNS failures, the usual offline case, when `GH_DEBUG` is unset)
13. Runner timeout on a write after the process started → `.indeterminate`; on a read → `.timeout`
14. Anything else (including exit 2) → `.unexpected(exitCode:)`

Rules match on status codes and short fragments, never on whole sentences. The fragment table is checked against the stderr recorded in the M3 spike and re-recorded when the gh floor moves.

---

## 9. Sharing

### 9.1 `.fxvault` v1 byte layout

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | magic `46 58 56 41 55 4C 54 1A` |
| 8 | 2 | formatVersion u16 BE = 1 |
| 10 | 2 | headerLength u16 BE = 64 (**must equal 64 for v1**) |
| 12 | 1 | kdfId = 1 (Argon2id v1.3) |
| 13 | 1 | aeadId = 1 (AES-256-GCM) |
| 14 | 4 | opsLimit u32 BE (3) |
| 18 | 4 | memLimitKiB u32 BE (65536) |
| 22 | 1 | parallelism = 1 |
| 23 | 1 | flags = 0 |
| 24 | 16 | salt |
| 40 | 12 | nonce |
| 52 | 12 | reserved (zero) |
| 64 | n | ciphertext ‖ tag(16), AAD = header[0..<64] |

**Key:** `Argon2id(passphrase normalized to w1-…-w6, salt, t, m)` → 32 bytes.

**Reader order:**
1. size ≤ 16 MiB + 80
2. magic
3. version 1
4. headerLength == 64
5. known kdf and aead ids
6. bounds: 1 ≤ t ≤ 10, 8192 ≤ mKiB ≤ 1048576, p == 1, reserved bytes zero
7. **then** ask for the passphrase
8. Argon2id (`@concurrent`)
9. GCM open
10. JSON (≤ 16 MiB)
11. validate
12. replay check (§9.5)
13. preview

Every failure shows the same message: "Wrong passphrase or damaged file".

**Writer:**
- Runs `ReauthGate(.share)` first.
- Fresh passphrase, salt and nonce for every export. Default name `FX Vault Share 2026-10-14.fxvault`. Created with SecureFileWriter (0600).
- Sent through `NSSharingServicePicker` or a save panel.

**KAT:** the research header vector (key `0x42×32`, t=3, m=65536, salt `80..8f`, nonce `90..9b`, 108-byte file) is kept, and is re-checked with Python `cryptography` AESGCM.

### 9.2 Passphrase

- 6 words from the EFF large wordlist, minus `drop-down felt-tip t-shirt yo-yo` (7,772 words, 77.5 bits), drawn with `SystemRandomNumberGenerator` and joined with `-`.
- Input is lowercased, split on non-letters, and must contain exactly 6 words, each validated as typed (the list is prefix-free).
- Shown once with Copy (concealed and transient, cleared after 30 s), the hint *"Send the passphrase through a different app than the file"*, and an "I've saved it" confirmation.
- Attribution: EFF, CC BY. Wordlist sha256 `addd3553…996b903e`.

### 9.3 Payload schema (`SharePackageModel`)

The draft schema is kept, plus `packageId` (UUID) and `createdAt`:

```json
{ "schema": "io.fractalx.fxvault.share", "schemaVersion": 1, "packageId": "UUID", "createdAt": "…Z",
  "producer": {"app":"FX Vault","version":"1.0.0"}, "sender": {"displayName":"Bryan"},
  "scope": "secret|environment|repository",
  "repository": { "host":"github.com", "owner":"…", "name":"…", "githubRepoId":"R_…",
    "secrets":[{"name","value"|null,"valueState","githubUpdatedAt"|null,"syncState"}], "variables":[…],
    "environments":[{"name","deploymentBranchPolicy":{"type","patterns":[{"name","type"}]},"secrets":[],"variables":[]}] } }
```

**Manifest:** the same document with every value set to null. Value hashes are never included.

**`SharePackageValidator`:**
- host must be exactly `github.com`
- owner `^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`
- repo name passes `RepoNameValidator` (not `.`, `..` or `*.git`)
- every name passes `PathSegmentValidator`
- environment names are NFC and contain no C0/C1, bidi (U+200E/F, U+202A–E, U+2066–9), zero-width (U+200B–D, U+FEFF) or leading/trailing whitespace
- GitHub item-name rules, uniqueness by fold key, and the scope rules
- counts 100/100/500/100, values ≤ 48,000 bytes
- patterns: 1–255 characters, no control or bidi characters, type branch or tag, at most 50 per environment

### 9.4 Nearby protocol v1 (`NearbyHandshake`, transport-agnostic)

**Roles:** I is the initiator (sender: browses and connects). R is the responder (receiver: advertises only while the "Receive nearby" sheet is open).

**Network transport:**
- Bonjour `_fxvault-share._tcp` with a **random service instance name for each session**. The TXT record holds only `v=1`.
- `NWParameters.acceptLocalOnly = true` and cellular prohibited. The listener closes after the first accepted connection.
- Framing: a 4-byte big-endian length prefix.

```
(1) I→R HELLO_I 0x01: maxVerI | suiteI=0x01 | C(32) | u16 len + nameI (sanitized NFC ≤ 63 B)
      C = SHA256(LP("fxvault/nearby/v1/commit") ‖ maxVerI ‖ suiteI ‖ LP(pkI) ‖ LP(nI))
(2) R→I HELLO_R 0x02: maxVerR | suiteR | pkR(32) | nR(32) | u16 len + nameR      (only after C received)
(3) I→R REVEAL_I 0x03: pkI | nI   (only after HELLO_R); R recomputes C → mismatch ⇒ ABORT + security warning
(4) abort unless suiteI == suiteR; ver = min(maxVerI, maxVerR) ≥ 1
    TH = SHA256(LP("fxvault/nearby/v1/transcript") ‖ maxVerI ‖ maxVerR ‖ ver ‖ suiteI ‖ suiteR ‖ LP(C)
                ‖ LP(pkI) ‖ LP(nI) ‖ LP(nameI) ‖ LP(pkR) ‖ LP(nR) ‖ LP(nameR))
    ss = X25519 (CryptoKit rejects low-order; also abort if all-zero)
    SAS = BE_UInt64(HKDF(ss, salt TH, "fxvault/nearby/v1/sas", 8)) mod 10^6 → "ddd ddd"
    k_i2r / k_r2i = HKDF(ss, TH, "fxvault/nearby/v1/key/i2r" | ".../r2i", 32)
(5) Both screens show SAS + sanitized peer name; "Codes match" / "Don't match" equal weight, no default, Return disabled
(6) CONFIRM 0x10 (encrypted) from each side after its user confirms
(7) I→R MANIFEST 0x11 — only after I's user confirmed, ReauthGate(.nearbySend) passed, and a valid CONFIRM from R arrived
(8) R→I DECISION 0x12 {accept: Bool, itemIds: [...]} — nothing else
(9) I→R PAYLOAD_CHUNK 0x13 … PAYLOAD_END 0x14 {u64 totalLength, SHA256(payload)}; I sends only manifest ∩ itemIds, aborts on unknown ids
(10) R→I RESULT 0x15 {ok: Bool}
(11) CLOSE 0x7E; ABORT 0x7F(reason) — plaintext before keys, encrypted after
Encrypted frame: [ver][type][seq:8 BE][ct][tag:16]; AAD = first 10 bytes; nonce = 0^4 ‖ seq; exact seq per direction
```

**Limits:** handshake frames ≤ 512 B, encrypted frames ≤ 64 KiB, payload ≤ 16 MiB, seq < 2^32, one peer.

**Timeouts:** handshake 30 s, SAS 120 s, idle 30 s, session 10 min.

**Abort conditions** (wipe keys, no resume, **no automatic retry**; every attempt needs a new user action): unknown version or suite, a suite mismatch, an unexpected message, a commitment mismatch, a bad key, a GCM failure, a sequence mismatch, an oversize frame, a PAYLOAD_END mismatch, "Don't match", a timeout, a disconnect, a second peer.

After an abort that follows REVEAL, or two failed handshakes in a row, the app shows *"Someone nearby may be trying to intercept this share."*

**KATs:**
- Defining C over `maxVerI` keeps the research C vector (all versions were 1).
- **TH now includes both suites, so the research SAS `762 202` no longer applies.** In M6 we update `NearbyProtocolReference.swift` and `crosscheck.py`, regenerate pkI, pkR, C, TH, SAS, k_i2r, k_r2i and CONFIRM, and pin the output. The name-change negative case is kept: changing nameR must change the SAS.

### 9.5 Receiver merge (`ShareImportPlanner`, pure → `ShareImporter`, one transaction)

**Preconditions:**
- The vault is unlocked.
- The target repo is resolved by owner/name. If `githubRepoId` is present and differs from the local `github_id`, the import is **blocked** with an explanation.
- If the repo has not been imported, offer a one-click import through an account with access (B2). If no account has access, reject.

**Replay check:** a `packageId` that was already imported, a `createdAt` older than 7 days, or a `createdAt` older than the local row's `updated_at` each raise a warning that needs confirmation.

**Preview (nearby):** the chips **New / Fills missing value / Value not included / Exists locally** are computed from the manifest. **Same / Differs** are computed only after the payload arrives, and the user confirms once more before anything is applied. (Files go through a single preview with all chips.) Values are never shown.

| Incoming vs local | Default | Pending? |
|---|---|---|
| No local item | Add | Synced if the sender says synced and its `githubUpdatedAt` equals the receiver's known GitHub `updated_at` (variables: the value equals GitHub's). Otherwise pending add. |
| Local secret value missing | Fill | No, if `githubUpdatedAt` equals the local `remote_updated_at`. Otherwise pending modify. |
| Identical fingerprint | Skip | No |
| Different | **Keep mine** (the user can switch to Overwrite; "Overwrite all" exists) | Overwrite makes it pending modify |
| Same name exists locally under the other kind | **Skip**, with a warning | No |
| Incoming value missing | Add as value-missing if absent, otherwise skip | No |
| Environment missing locally | Create it locally with its policy | Pending create, unless B3 shows it on GitHub |
| **Existing environment, different policy** | **Keep mine**, shown as its own "Deployment branches differ" row. A widening change (to `all`, protected→all, or added wildcards) shows a security warning and needs a second confirmation. | Only if accepted |

**Provenance:** filled or added values get `provenance = share` plus `packageId` and the sender name, shown as a **"from share, unverified"** chip. The chip clears after a verified push or a drift-confirmed match, and the .env export warning lists these items.

The importer re-encrypts with the receiver's DEK under new row ids and records the `packageId`. Nothing syncs automatically.

---

## 10. UI map

**Scenes:**
- `Window("FX Vault", id: "main")` with `RootScreen`, plus `Settings` with `PreferencesScreen`.
- **Closing the main window locks the vault**, and the app keeps running (`applicationShouldTerminateAfterLastWindowClosed = false`).
- `.fxvault` URLs are queued in `AppViewModel.pendingImports`. `NSApp.activate()` plus `openWindow(id: "main")` brings the window back, it unlocks first if needed, then the `ShareImportScreen` sheet opens.

**RootScreen phases (`AppViewModel`):** gh detection (A1–A3) starts in `init`, and a non-blocking gh status row ("GitHub CLI not found: how to install") appears on Welcome and on the LockScreen.
1. **`OnboardingScreen`:** Welcome (gh status) → Create password (≥ 12 characters plus strength of at least 60 bits, "Generate passphrase", confirm) → Recovery key (grid, Copy, warning) → Confirm 2 groups → Touch ID (signed builds only) → Done.
2. **`LockScreen`:** password `SecureField`, "Unlock with Touch ID", "Forgot password? Use recovery key" → `RecoveryResetScreen`.
   - Touch ID auto-prompts only when `NSApp.isActive` and the scene phase is `.active`, and only when the password is not required (restart or 14 days).
3. **`GHSetupScreen`** after unlock, if gh is missing, **older than 2.97.0** (upgrade screen: found version, why 2.97 is required, copyable `brew upgrade gh`), or has no accounts. Copyable `brew install gh`, `brew upgrade gh`, `gh auth login`, plus **Check again**.
4. **`MainScreen`:** a three-column `NavigationSplitView`.

**MainScreen columns:**
- **Column 1 (`SidebarView`):**
  - search
  - accounts, each with a scope warning icon and SAML banner where needed, then Personal and each org as disclosure groups, then repos
  - badges: private, archived, fork, unavailable
  - context menu: Import, Clone, Share, Remove from vault
  - repos not yet imported are dimmed and show **Import** in the detail column
  - per account, **Add repository by name…** (`owner/name`, checked with B2) for repos where the account is a collaborator but not an owner or org member (user- or org-owned, outside-collaborator access), which gh cannot list
- **Column 2 (`ScopeListView`):**
  - "Repository" followed by one row per environment, each with a pending dot and a value-missing count
  - footer **+ New environment**
  - row context menu: Rename, Duplicate…, Export .env…, Share…, Delete
- **Column 3 (`RepoDetailScreen`):**
  - header: `owner/name`, visibility, capability chip ("Admin" / "Write: repo-level only" (only if the M3 spike confirms WRITE can manage repo-level items) / "Read-only: admin required" / "Read-only: archived"), **Clone**, Refresh, drift banner ("3 changes on GitHub — Review")
  - a segmented **Secrets | Variables** picker over **one** `Table` (`ConfigTableView`) with columns Name, Value (masked with an eye toggle, or a "Value missing" chip; variables in plaintext), Updated, Status (Synced/Added/Modified/Deleted/Blocked/Unverified share), and row actions (Reveal, Copy, Edit, Revert, Delete, Convert/Move…)
  - environment scopes add "Deployment branches: Selected (2 rules) — Edit" and the plan note *"Some environment features on private repositories depend on your GitHub plan. Learn more."*
  - read-only scopes explain why

**Toolbar:**
- Search
- **New Repository** (⌘N)
- **Import .env** (⇧⌘I)
- **Share** (File… / Nearby…)
- **Lock** (⌃⌘L)
- **Sync** (⇧⌘S): `.borderedProminent`. The **count is part of the label** ("Sync 5"), with monospaced digits, `.help`, and an accessibility label. The count is also mirrored to `NSApp.dockTile.badgeLabel`. Disabled at 0, while locked, and while a sync runs (it then shows progress).

**Sheets:**
- **`ConfigItemEditorScreen`:** kind (locked once synced), name (auto-uppercase plus validation), value in `SecretValueEditor`, fill-or-push toggle for value-missing secrets.
- **`EnvironmentSettingsScreen`:** name and `BranchPolicyEditor` (All / Protected only, with a warning / Selected patterns with a branch|tag picker).
- **`RenameEnvironmentScreen`**, **`DuplicateEnvironmentScreen`**.
- **`CreateRepoScreen`:** owner picker (account plus orgs from A5; an org policy that forbids the chosen visibility is reported from the create error), name with a live availability check (shown as "Probably available"; a taken name is confirmed only by the create error), description, Private/Public, README, .gitignore, license, an inline section for environments, secrets and variables, and **Clone to my Mac** (on by default, showing the destination; the folder is chosen with NSOpenPanel).
- **`SyncScreen`:** Summary → Deletions (live fetch) → Progress (n of m, current item, FX Vault write limit this hour, Cancel) → Result.
- **`DriftReviewScreen`**.
- **`EnvImportScreen`:** file or paste → table of Key (with fixes), Kind (pre-marked), Conflict (Skip/Overwrite), Target scope.
- **`EnvExportScreen`:** ReauthGate → warning (plaintext, iCloud, tracked file) → save panel → gitignore offer.
- **`ShareExportScreen`:** ReauthGate → scope tree → passphrase → save or AirDrop.
- **`ShareImportScreen`:** passphrase → preview and merge choices → apply.
- **`NearbyShareScreen`:**
  - Send: peers → handshake → `SASCodeView` → ReauthGate → waiting for the decision → progress → result.
  - Receive: "Waiting for a teammate…" → SAS → manifest preview → Accept/Reject → Same/Differs confirmation → result.

**Preferences (phase-aware `PreferencesViewModel`):**
- **General** and **Advanced** use UserDefaults and work in every phase:
  - General: clone folder (NSOpenPanel), auto-lock (1/2/5/10/15/30/60 min), and a note that the vault always locks on sleep, screen lock and window close, and that the timer pauses during a sync.
  - Advanced: gh path and version (2.97.0 or later required), gh override, "FX Vault disables gh telemetry for its own calls", Reveal vault folder, **Reset vault…** (master password plus typing "reset").
- **Accounts** and **Security** say *"Unlock FX Vault to change these settings"* while locked, and their sheets are dismissed on lock:
  - **Security:** Touch ID toggle (or the unsigned note), Change master password… (with the rotate checkbox), Create new recovery key… (master password), clipboard info.
  - **Accounts:** login, token state, scopes (OK / missing with copyable fix commands / unknown), the resolved gh path, an SSH alias picker (from `~/.ssh/config`), **Test** ("Authenticates as <login>", or "Authenticates as X, which is not logged into gh"), **Re-check** (refreshes the token cache).

Light and dark mode come from semantic asset colors. Every dimension and duration comes from `Helpers/Theme`.

---

## 11. Milestones

**Every milestone ends with:**
- every item checked, with its Verify evidence
- `scripts/ci-local.sh` green
- `scripts/check-docs.sh` green
- a demo
- the work left in the working tree, and Bryan asked to commit
- the Review section filled in

**Evidence notes (2026-10-15).** Test paths without a prefix are under `Packages/FXVaultKit/Tests/`; numbers in parentheses count `@Test` functions; "RELEASING #n" is row n of the manual checklist in docs/RELEASING.md.

### Milestone 1: Project setup and vault

- [ ] **Phase 0:** Q1–Q4 decided (2026-10-14); Q5 default adopted; Q6 asked at the start of M3 (§13). Bryan runs `brew upgrade gh` (to ≥ 2.97.0), creates `FractalX-Technologies/fx-vault` (Q4, private until M7), logs a second account into gh (likely the second SSH identity), and says whether the root `.env` should move out of the project. Claude writes a `.gitignore` containing at least `.env`, `*.env` and `.research/` **before** running `git init` (no commit). **Verify:** `gh --version` reports ≥ 2.97.0; `git rev-parse --git-dir` succeeds; `git check-ignore -q .env .research` exits 0; `gh repo view FractalX-Technologies/fx-vault --json name` returns; `gh auth status --json hosts` lists 2 accounts. *Pending: manual — Bryan logs a second account into gh (`gh auth status` lists only one) and decides where the root `.env` lives (still in the project, gitignored). Done: gh 2.102.0 installed; `.gitignore` covers `.env`, `*.env` and `.research/`; git repository on `main`; `FractalX-Technologies/fx-vault` exists and is public.*
- [x] Write `tasks/todo.md` from this plan and create `tasks/lessons.md`. **Verify:** both files exist (done during planning, 2026-10-14).
- [x] Preserve the research artifacts after sanitizing them (§12.4). **Verify:** `ls docs/research` shows NearbyProtocolReference.swift, crosscheck.py, deps-probe/, ops_compact.json; `scripts/check-fixtures.sh` (gitleaks plus the denylist) exits 0. *Done differently: there is no `docs/research/`. The nearby reference (`NearbyProtocolReference.swift`, `crosscheck.py`) is in `SharingKitTests/Fixtures/kat/` and the Argon2id/AES-GCM KAT generator in `VaultCryptoTests/Fixtures/kat/generate_kat.py`; `deps-probe/` and `ops_compact*.json` stay only in the gitignored `.research/`. `check-fixtures.sh` was replaced by `scripts/check-secrets.sh`, the CI gitleaks job and the hashed-denylist test (`GitHubKitTests/LiveGHTests.swift`).*
- [x] Scaffold `.gitignore`, `LICENSE`, `project.yml`, `.xcodegen-version`, `Config/*` (Base, Signed, Local.example, both entitlements), the App skeleton, both `.claude/rules/*.md`, and `scripts/lint.sh`. **Verify:** `xcodegen generate && xcodebuild -project FXVault.xcodeproj -scheme FXVault -destination 'platform=macOS' build` has 0 warnings; regenerating gives an identical `shasum` for `project.pbxproj`; `scripts/lint.sh` exits 0. *Done: every listed file plus `Config/Tests.xcconfig`; CI and `scripts/ci-local.sh` regenerate the project and fail on drift; `scripts/lint.sh` passes. Gap: the two `.claude/rules/*.md` files were never created.*
- [x] `Packages/FXVaultKit/Package.swift`: tools 6.1, GRDB `from: "7.11.1"`, swift-sodium `.upToNextMinor(from: "0.11.0")` (product `Clibsodium`), MemberImportVisibility. Targets VaultCore, VaultCrypto, VaultStore, VaultData, each with tests. **Verify:** Package.resolved pins grdb.swift 7.11.1 and swift-sodium 0.11.0; `swift build --package-path Packages/FXVaultKit 2>&1 | grep -c warning` is 0. *Done: tools 6.1, MemberImportVisibility, 8 module targets each with a test target plus `FXVaultTestSupport`; `Package.resolved` pins grdb.swift 7.11.1 and swift-sodium 0.11.0; no compiler warnings in the v0.1.0 `ci-local` log.*
- [x] VaultCore basics: `SecretBytes`, `Clock`, `Limits`, `Timeouts`, `VaultError`. **Verify:** `SecretBytesTests` (description is redacted, bytes are zeroed after `wipe()`). *Done: `VaultCoreTests/SecretBytesTests.swift` (13: redacted descriptions, `wipe()` zeroes). `Clock` is named `VaultClock` (lessons.md: no names that shadow the standard library).*
- [x] `Argon2id` (Clibsodium `crypto_pwhash`, `.argon2id13`, NFC, `sodium_memzero`) and `KDFParameters` (`.moderate`, `.testing` = ops 1 / 8 MiB, bounds). **Verify:** a KAT generated independently with Python `argon2-cffi` (`hash_secret_raw(type=ID, parallelism=1)`), with the script in `docs/research/kat/`; an NFC-equivalence test; a spy-deriver test showing out-of-bounds parameters are rejected before the KDF; the timing is logged for information only (`.serialized`). *Done: `VaultCryptoTests/Argon2idTests.swift` (12, `.serialized`: independent vectors, NFC equivalence, timing logged) and `KATTests.swift`, with vectors from `Fixtures/kat/generate_kat.py` (argon2-cffi) kept next to them instead of `docs/research/kat/`; out-of-bounds parameters are rejected before the KDF (`SpyKeyDeriver` in `KeyWrapTests.swift`).*
- [x] `FieldCipher` (static functions) and `AADBuilder` (row, repo, env, kind, name, dek_version). **Verify:** a KAT from Python `cryptography` AESGCM; changing any AAD component fails; tampered nonce, ciphertext or tag fails; an unknown format byte is rejected; empty and 48,000-byte values round-trip. *Done: `VaultCryptoTests/FieldCipherTests.swift` (13: every AAD component, nonce/ciphertext/tag tamper, unknown format bytes, empty and 48,000-byte round trip) and AES-GCM vectors from pyca/cryptography in `KATTests.swift`.*
- [x] `KeyWrap` (62 bytes, format and aead bytes in the AAD) and `KeyCheckValue`. **Verify:** a layout test; a wrong password gives `.wrongPassword`; a tampered `ops_limit` fails before the KDF (spy); a kcv mismatch gives `.corrupted`. *Done: `VaultCryptoTests/KeyWrapTests.swift` (16: 62-byte layout, `.wrongPassword`, tamper rejected before the KDF with a spy, kcv mismatch is `.corrupted`).*
- [x] `RecoveryKey` and `CrockfordBase32`. **Verify:** round trip, 56 characters and 14 groups; detects every single-character substitution and adjacent transposition on a sample key; I/L/O mapping; U rejected. *Done: `VaultCryptoTests/RecoveryKeyTests.swift` (12: 56 characters in 14 groups, every single substitution and adjacent transposition, I/L/O mapping, U rejected).*
- [x] `ValueFingerprinter`, `VaultKeyring` (copy-out under the lock, generation counter) and `PasswordStrength`. **Verify:** equal values in different rows give different fingerprints; `withKeys` called inside `withKeys` does not deadlock; after `lock()`, `withKeys` throws `.locked` and a test-hook weak reference to the key storage is nil; the strength estimator rejects `password1234` and accepts a generated 6-word passphrase. *Done: `VaultCryptoTests/VaultKeyringTests.swift` (17: per-row fingerprints, nested `withKeys`, `.locked` after `lock()`, weak storage reference is nil) and `PasswordStrengthTests.swift` (10: rejects `password1234`, accepts generated 6-word passphrases).*
- [x] VaultStore: `DatabaseFactory` (0700, `secure_delete`, foreign keys), `v1_vault`, and the incremental migration test harness. **Verify:** `PRAGMA secure_delete` returns 1; the directory mode is 0700; `MigrationTests` pass fresh and step by step. *Done: `VaultStoreTests/MigrationTests.swift` (15: `secure_delete` and foreign keys on every connection, directory 0700 and files 0600, fresh and step-by-step migrations v1–v7).*
- [x] `VaultManager`: create, unlock (password, Touch ID), lock, changePassword (optional rotate), resetPassword (always rotates), rotateDEK, enable/disable Touch ID, resetVault. Uses `KDFParameters.testing` in tests. **Verify:** `VaultManagerTests` with `DatabaseQueue()` and `FakeBiometricKeyStore`; after rotation, the old password and a database copy taken before rotation cannot decrypt rows written after it; `wal_checkpoint` runs after key writes. *Done: `VaultDataTests/VaultManagerTests/VaultManagerTests.swift` (27, including `preRotationCopyCannotOpenDataWrittenAfterRotation` and `keyWritesLeaveTheWALEmpty`) and `VaultSessionTests.swift` (6), with `FakeBiometricKeyStore` and `KDFParameters.testing`.*
- [x] `ReauthGate`. **Verify:** tests show the password-only operations reject a Touch ID read, and the export, share and nearby operations accept either method. *Done: `VaultDataTests/VaultManagerTests/ReauthGateTests.swift` (8, parameterized over every purpose).*
- [ ] `KeychainManager`, `BiometricAuthManager` (prompt strings injected), `BuildCapabilities` (SecTask, biometry state hash, boot session). **Verify:** unit tests with fakes cover invalidation, the restart and 14-day password requirements, and orphan cleanup; the manual checklist entry "Touch ID" in `docs/RELEASING.md` is completed with screenshots on a signed build; an ad-hoc build shows the disabled toggle with the note. *Pending: manual — RELEASING #1–5 and #16 (Touch ID enable, unlock, cancel, re-enrollment, restart, status codes) on the signed build, with screenshots. Done: `VaultBiometricsTests.swift` (21: invalidation, restart and 14-day rules, orphan cleanup) and `VaultPlatformTests.swift` (14); the ad-hoc toggle note is covered by `AppTests/PreferencesViewModelTests.swift` (`unsignedBuildDisablesTheToggle`).*
- [x] **Bryan action:** create the explicit App ID `io.fractalx.fxvault` (Keychain Sharing) and the Developer ID profile "FX Vault Developer ID" under team QYKC498D5D (Q1), and fill in `Config/Local.xcconfig`. **Verify:** `codesign -dv` shows the team; `Contents/embedded.provisionprofile` exists; running from Xcode with the debugger attached, `SecItemAdd` with `.biometryCurrentSet` returns 0. If not, Bryan creates an Apple Development certificate and a macOS development profile and uses them for Debug. *Done: profile "FX Vault Developer ID" (team QYKC498D5D, app ID `QYKC498D5D.io.fractalx.fxvault`, keychain group) installed and `Config/Local.xcconfig` in place; `scripts/release-local.sh` checks both in preflight and the signed v0.1.0 build used them. The runtime `SecItemAdd` check is part of the Touch ID manual items.*
- [ ] `AutoLockManager` (DispatchSourceTimer, ContinuousClock, SyncActivityAssertion, injected sources) and the two-phase lock procedure. **Verify:** unit tests for each trigger, the timeout, a modal flag, and the sync assertion; a test that `keyring.isLocked` is true synchronously after a trigger; manually, `pmset sleepnow`, ⌃⌘Q and closing the window each lock. *Pending: manual — RELEASING #6–9 (`pmset sleepnow`, ⌃⌘Q, idle and window close on a real Mac). Done: `AppTests/AutoLockManagerTests.swift` (13: each trigger, timeout, sync assertion, window close) and `AppViewModelTests.swift` (`manualLockRunsBothPhases`). A crash in the inactivity ticker (MainActor check on a dispatch queue) was found and fixed in 9bf1419.*
- [x] `ClipboardManager`. **Verify:** a test on a uniquely named `NSPasteboard(name:)`: cleared when `changeCount` matches, left alone after a foreign write. *Done: `AppTests/ClipboardManagerTests.swift` (7, on a uniquely named `NSPasteboard(name:)`: cleared when `changeCount` matches, foreign writes left alone, cleared on lock). The real-clipboard check is RELEASING #10.*
- [x] Theme, catalogs, `scripts/sync-strings.sh`, and the lint rule for prompt literals. **Verify:** `scripts/sync-strings.sh` leaves the catalog's shasum unchanged; `scripts/lint.sh` exits 0. *Done: `App/Helpers/Theme/`, `Localizable.xcstrings` and `InfoPlist.xcstrings`, `scripts/sync-strings.sh [--check]`, and the prompt-literal rule in `scripts/lint.sh`. Gap: the strings check runs only by hand, not in CI.*
- [ ] UI: Onboarding (gh status row, strength check, generated passphrase), Lock, RecoveryReset, phase-aware Preferences (General and Security), and the placeholder three-column MainScreen with one Table and a segmented picker. **Verify:** view-model tests (`OnboardingViewModel`, `LockViewModel`, `PreferencesViewModel` for every phase); screenshots on macOS 14 (VM) and 27 recorded in the RELEASING.md "Layout" entry. *Pending: manual — RELEASING #11: layout screenshots on macOS 14 (VM) and 27, narrow and wide, light and dark. Done: every screen (the full main window replaced the placeholder); `AppTests/OnboardingViewModelTests.swift` (9), `LockViewModelTests.swift` (10), `RecoveryResetViewModelTests.swift` (4), `PreferencesViewModelTests.swift` (12, every phase).*
- [x] `SecretValueEditor`. **Verify:** a unit test that the text `"--'\t` round-trips byte for byte and that a trailing `\r\n` is stripped with the notice (D32); a check that undo, substitutions and Writing Tools are off. *Done: `AppTests/SecretValueEditorTests.swift` (6: byte-for-byte round trip, trailing CRLF stripped with the notice, substitutions, undo and Writing Tools off).*
- [x] App test mode (`AppContainer.preview` when `XCTestConfigurationFilePath` is set). **Verify:** `xcodebuild test` creates nothing under `~/Library/Application Support` (shasum of a directory listing before and after) and runs no shell probe. *Done differently: `AppTests/AppSmokeTests.swift` (`hostedTestsRunSideEffectFree`: the test host runs `.preview`, with no vault directory and no side effects) instead of a before/after shasum of `~/Library/Application Support`.*
- [ ] Release smoke: ad-hoc Release archive, renamed to `FX Vault.app`. **Verify:** `lipo -info` shows `x86_64 arm64`; `scripts/check-linkage.sh` (otool lists only /usr/lib and /System) passes; `Contents/Frameworks` is absent or empty; `scripts/smoke-launch.sh` (`open -W -a … --args --smoke-test`) exits 0. *Not done: only partly covered. `scripts/release-local.sh --adhoc` archives, renames to `FX Vault.app` and checks `lipo` (arm64 + x86_64), hardened runtime and entitlements, and the Release workflow runs it on every tag; `check-linkage.sh`, the `Contents/Frameworks` check and `smoke-launch.sh` / `--smoke-test` were never built.*
- [x] CI `ci.yml`. Blocking `macos-26` job: package tests, app tests, XcodeGen drift (pinned zip plus sha256), lint, SwiftFormat check, gitleaks. Non-blocking `xcode-27` job: the same plus the strings check. **Verify:** `scripts/ci-local.sh` passes locally (hash-based checks, not dependent on git state); the first CI run after Bryan pushes is green on `macos-26`. *Done: `.github/workflows/ci.yml` (`macos-26` blocking, `xcode-27` non-blocking, gitleaks 8.30.1 as its own job, XcodeGen pinned and sha256-checked in `.github/actions/setup-toolchain`); `scripts/ci-local.sh` passes; all three jobs are green on 9bf1419 (the b062759 run failed on an Xcode 26 type-check timeout, fixed in 9bf1419). Gaps: no SwiftFormat check and no strings check in CI.*
- [x] Docs: README stub, ARCHITECTURE.md, STRUCTURE.md, DATABASE.md (v1), SECURITY-MODEL.md (key hierarchy, rotation, lock, threat model), SECURITY.md, and `scripts/check-docs.sh` (asserts that every migration and table appears in DATABASE.md). **Verify:** `scripts/check-docs.sh` exits 0. *Done: README, docs/ARCHITECTURE.md, STRUCTURE.md, DATABASE.md (v1–v7), SECURITY-MODEL.md, SECURITY.md. Gap: `scripts/check-docs.sh` was never built, so this and every later "check-docs" Verify was checked by reading.*

**Done when (demo):**
1. Fresh launch, gh status visible on Welcome.
2. Create a strong password.
3. The recovery key is shown and copied, and the clipboard empties after 30 s.
4. Confirm 2 groups.
5. Enable Touch ID on a signed build.
6. ⌃⌘L locks, and Touch ID unlocks.
7. A wrong password shows "Incorrect password".
8. A recovery reset rotates the key and shows a new recovery key.
9. A 1-minute idle (demo setting) locks.
10. Sleep and closing the window lock.

Both test suites are green.

### Milestone 2: gh detection, accounts, SSH aliases, repo listing and import

- [x] `CommandRunning`, `ProcessRunner`, `StdinPayload`, `StderrRedactor`. **Verify:** `/bin/cat` stdin round trip; a timeout kills `/bin/sleep 60` (SIGTERM, then SIGKILL); the output cap holds; the redactor masks both token patterns. *Done: `GitHubKitTests/ProcessRunnerTests.swift` (14: `/bin/cat` round trip, SIGTERM then SIGKILL on timeout, stdout and stderr caps, no inherited descriptors) and the `StderrRedactor` suite in `DecodingTests.swift` (both token patterns, every classic prefix).*
- [x] `ShellEnvironmentResolver` (only allowlisted keys, markers, `-l` then `-il`, fish variant) and `ProcessEnvironmentBuilder` (gh and git). **Verify:** marker extraction from noisy fixtures; a test that unrequested variables are never captured; an allowlist test asserting the forbidden keys are absent; argv property test (random values never appear in argv). *Done: `GitHubKitTests/EnvironmentTests.swift` (exact allowlists, markers in noisy output, `-l` then `-il` fallback, flavor flags for fish and csh) and the argv property test in `CommandBuilderTests.swift` (`randomValuesNeverAppearInArgv`).*
- [x] `GHLocator` (override, Homebrew paths, shell PATH, MacPorts/Nix/~/.local, permission checks, warning on path change) and `GHVersion`. **Verify:** unit tests (a world-writable fixture is rejected; `2.96.9` is too old, `2.97.0` passes); manually, launching from Finder resolves `/opt/homebrew/bin/gh` at ≥ 2.97.0. *Done: GHLocator and GHVersion suites in `EnvironmentTests.swift` (world- and group-writable rejected, `admin` group accepted, 2.96.9 rejected, 2.97.0 accepted); a Finder-like launch resolved `/opt/homebrew/bin/gh` 2.102.0 (`VaultDataTests/Live/LiveE2EReadOnlyTests.swift`, API.md "Observed behavior").*
- [x] `GHSetupScreen`. **Verify:** pointing the override at a nonexistent path shows the install screen; a fake gh reporting 2.90.0 shows the upgrade screen with `brew upgrade gh`; a fixture with no accounts shows `gh auth login`. *Done: `App/Screens/GHSetup/`; `AppTests/GHStatusProbeTests.swift` (8: missing, outdated, no accounts, shown only when unlocked, Check Again) and `EnvironmentTests.swift` (`overrideToANonexistentPathIsNotInstalled`, `oldVersionIsRejected`). Adds **Not Now** (ARCHITECTURE decision 20). Manual pass: RELEASING #18.*
- [ ] `GHAuthService` (A3–A4), `GHTokenCache` (synchronous purge, refresh on `.tokenRevoked`), `ScopeChecker` (ok, missing, unknown, from the A3 `scopes` field). **Verify:** decoding the sanitized `auth status --json hosts` fixture, including an absent `scopes` key, `"gist, read:org, repo"` parsed as three trimmed scopes, and a `state: "error"` entry with a DNS `error` classified as offline (not re-login); an `HTTP 401` stderr followed by a new token retries once; manually, both accounts are listed with scope status. *Pending: manual — showing both accounts with their scope status needs Bryan's second gh account. Done: `GitHubKitTests/DecodingTests.swift` (auth status with one, several and no accounts; `"gist, read:org, repo"`; DNS error is offline) and `ServiceTests.swift` (token cache with a synchronous purge, one refresh after `HTTP 401`, no caching across a purge).*
- [x] Scope-fix UI. **Verify:** a missing-scope fixture renders the switch/refresh/switch-back commands with the right logins; Re-check invalidates the token cache (test). *Done: `AppTests/AccountsSettingsViewModelTests.swift` (switch, refresh and switch-back commands with the right logins; `recheckForgetsTheCachedToken`); the commands come from `ScopeChecker`.*
- [x] gh command layer: `GHCommandService` (runs argv through `ProcessRunner`, exit code 0 = success), `GHCommandScheduler`, `GHRepoRef`, the argv builders `GHReposCommands`/`GHSecretsCommands`/`GHVariablesCommands`/`GHOrgsCommands`/`GHTemplatesCommands`, `GHEnvironmentsAPI` with `GitHubPath` and `APIResponseParser` (gh api: environments and branch policies only), `PathSegmentValidator`, `GHStderrClassifier`. **Verify:** argv builder tests for every §8 op (`--repo=`/`--env=` forms, no forbidden flag, no `--clone`); a property test that random values never appear in argv and always arrive on stdin; JSON decoding tests on sanitized native `--json` fixtures (`repo list`, `repo view`, `secret list`, `variable list`, `auth status`) and the plain-text `org list`/`gitignore list`/`license list`; the stderr classifier table (`HTTP 401/403/404/422/5xx`, wrapped native errors such as `failed to delete secret X: HTTP 404: …`, `gh api` forms `gh: Not Found (HTTP 404)` and `gh: HTTP 404`, `GraphQL:` including `failed to look up repository O/R: GraphQL: …`, "Must have admin rights", "secondary rate limit", "SAML" with both the two-space native and one-space `gh api` "Authorize in your web browser:" lines, "You are not logged into any GitHub hosts", "Could not resolve to a Repository", network fragments including `error connecting to api.github.com` / `check your internet connection`, exit codes 1/2/4); a fixture `HTTP 401: Bad credentials (https://api.github.com/user)\nTry authenticating with:  gh auth login -h github.com` with exit 1 classifies as `.tokenRevoked`; `a/b c` encodes to `a%2Fb%20c` and an en dash encodes correctly; `.`, `..`, `%2E%2E` and `a/..` are rejected at both the validator and `GitHubPath`; a `gh api --paginate --slurp` fixture with 2 pages decodes. *Done: `GitHubKitTests/CommandBuilderTests.swift` (19: every §8 op, forbidden flags, `gh api` only for environments and policies, dot segments, `a%2Fb%20c`, en dash), `ServiceTests.swift` (33), `DecodingTests.swift` (25: native `--json`, plain-text lists, 2-page `--paginate --slurp`, the plan's 401 fixture) and `Fixtures/gh/stderr-cases.json` (48 cases, 14 marked synthetic until they are re-recorded).*
- [x] Migration `v2_accounts_repos` and `AccountsRepository`. **Verify:** store tests plus the incremental migration test. *Done differently: migration `v2_accounts_repos` (`VaultStoreTests/MigrationTests.swift`, `StoreTests.swift`); accounts are served by `AccountStore` plus `VaultData/Accounts/GitHubEnvironmentRepository` (`VaultDataTests/AccountsTests/GitHubEnvironmentTests.swift`), with no separate `AccountsRepository`.*
- [ ] `SSHConfigParser` (Host lists, Include globs, case-insensitive keywords, quoted values, wildcards skipped, invalid aliases rejected) and `SSHAliasResolver` (§8 D1, D2). **Verify:** parser fixtures, including an alias that starts with `-`; manually, both configured aliases are listed, Test shows each login, and the state "authenticates as an account not in gh" renders when it applies. *Pending: manual — listing both aliases and testing each login needs the second identity's gh account. Done: SSHConfigParser and SSHAliasResolver suites in `GitHubKitTests/SSHAndGitTests.swift` (Includes, cycles, wildcards, unsafe aliases including a leading `-`); one alias authenticated live (API.md "Clone and .env").*
- [ ] `RepoCatalogRepository` (A5, then B1 per owner; B2 for **Add repository by name**) and the sidebar grouped account → owner, with search, badges and the add-by-name entry. **Verify:** a grouping unit test; a test that a SAML error for one org marks only that org unavailable; an add-by-name test (valid, not found, invalid name); manually, every repo of both accounts and their orgs appears, search filters them, and a collaborator repo owned by another user and a repo in an org where the account is only an outside collaborator are each added by name. *Pending: manual — both accounts' repositories and organizations, plus add-by-name of a collaborator repository and of an outside-collaborator organization repository (needs the second account). Done: `VaultDataTests/CatalogTests/RepoCatalogTests.swift` (grouping, one SAML org marked unavailable alone, add by name valid, not found and invalid) and `AppTests/SidebarViewModelTests.swift` (7).*
- [x] Import (B3, B5, B6–B9) into `v3_config`. Secrets are value-missing with `remote_updated_at`; variables are encrypted with the synced snapshot equal to the current value; foreign rules are stored; `name_key` is computed. **Verify:** importing a real repo with environments; a byte scan of `vault.sqlite*` finds no known variable value; the "Must have admin rights" stderr fixture leaves the environment read-only. *Done: `RepoCatalogTests.swift` (`importStoresEnvironmentsSecretsAndVariables`, `variableValuesNeverReachTheDatabaseFile`, `adminRequiredLeavesTheScopeUnreadableAndReadOnly`); real repositories with environments were imported by the live E2E suites (`VaultDataTests/Live/`).*
- [ ] Read-only `RepoDetailScreen` (scopes column, one Table with the Secrets/Variables picker, reveal and copy for variables, capability chip). **Verify:** a `RepoDetailViewModel` test with a fake repository; screenshot recorded in RELEASING.md "Layout". *Pending: manual — screenshot for RELEASING #11 "Layout". Done: `AppTests/RepoDetailViewModelTests.swift` (8); the screen also edits since M3.*
- [x] Docs: API.md sections A, B, D1–D2 and E; DATABASE.md v2/v3; ARCHITECTURE.md process layer. **Verify:** `scripts/check-docs.sh` exits 0. *Done: docs/API.md A, B, D, E and "Observed behavior"; DATABASE.md v2 and v3; ARCHITECTURE.md GitHubKit section. No `check-docs.sh` (see M1).*

**Done when:** from a Finder launch with no shell PATH, gh ≥ 2.97 is detected; both accounts show their scope status; both SSH aliases resolve and pass Test; the sidebar lists every repo of each account and its orgs grouped by owner, with search, and a repo can be added by name; importing a real FractalX-Technologies repo shows its environments, its variables with values, and its secrets marked "Value missing".

### Milestone 3: Environments, secrets and variables CRUD, pending changes, Sync

- [ ] **Write spike** (Q6: asked at the start of M3, before any GitHub write; Bryan's approval required for each repo). On throwaway repos, record:
  - whether an identical-value `gh secret set` changes `updatedAt` (and the same for `gh variable set`);
  - Free-plan private errors for environments, environment secrets and branch policies, as gh prints them (stderr and exit code);
  - whether DELETE of an environment removes its secrets and variables;
  - whether fields omitted from an environment PUT keep existing reviewers;
  - value normalization through gh: trailing LF/CRLF, leading or trailing spaces, Unicode and empty values (variable and secret), compared through `gh variable list`;
  - gh's stderr text and exit code for 403 (admin, write), 404, 422, SAML and rate limiting, saved as classifier fixtures;
  - whether a WRITE (not admin) collaborator can list, set and delete repo-level secrets and repo-level variables (decides the WRITE mapping in `RepoCapabilityModel`);
  - what C3 returns for a pattern that already exists: a followed redirect (200 with the existing policy) or an unfollowed 303.

  **Verify:** findings in `docs/API.md § Observed behavior`; fixtures saved through `scripts/sanitize-fixture.sh`; `scripts/check-fixtures.sh` exits 0. *Pending: manual — partly done. The opt-in write suite (`VaultDataTests/Live/LiveE2EWriteTests.swift`) passed against real GitHub on 2026-10-15, on a public repository and on a Free-plan private organization repository (API.md "Write run, 2026-10-15": C2 PUT returns 200, environment secret and variable sets succeed, C3 returns 404 and is now classified `.planGated`). Still open: identical-value `updatedAt`, whether a PUT keeps reviewers, whether C9 removes an environment's items, value normalization through gh, real 403/422/SAML/rate-limit stderr (14 classifier cases are still synthetic), WRITE-collaborator rights, and C3 on an existing pattern (200 or 303). The suite records these as `q6.*` keys, but the saved report holds only the Free-plan `step7.*` keys. `sanitize-fixture.sh` and `check-fixtures.sh` were never built. Next: rerun with `FXV_LIVE_E2E_REPORT` on an approved throwaway repository and copy the facts into API.md.*
- [ ] **Bryan action:** invite the second account as a write (not admin) collaborator on a spike repo. **Verify:** `gh repo view <O>/<R> --json viewerPermission` with that account's token shows `WRITE`. *Pending: manual — needs Bryan's second gh account first (only one is logged in). Until then WRITE collaborators stay read-only for items (`VaultCoreTests/ModelTests.swift` `defaultPolicyTreatsWriteAsReadOnly`, `SyncEngineTests/ExecutionTests/PreflightPlannerTests.swift`).*
- [x] `GitHubNameValidator`, `EnvironmentNameValidator` (fold key, reserved names during a pending rename or delete), `ValueLimits` (per the spike). **Verify:** table tests including `Producción`/`PRODUCCIÓN`, bidi and zero-width characters, and leading or trailing spaces. *Done: `VaultCoreTests/GitHubNameValidatorTests.swift` (8) and `EnvironmentNameValidatorTests.swift` (10: `Producción`/`PRODUCCIÓN`, bidi and zero-width characters, spaces, fold keys); the value limit is `Limits.maxValueBytes` (48,000) through `ValueNormalizer` (`ValueNormalizerTests.swift`), not tuned by the spike.*
- [x] `ConfigRepository` CRUD with coalescing, tombstone revival, kind and scope immutable once synced, and Convert/Move. **Verify:** coalescing matrix tests (add→edit, add→delete, delete→re-add, edit→revert, swap, rename into a tombstone). *Done: `VaultDataTests/ConfigTests/ConfigItemTests.swift` (20) and `SyncEngineTests/Diff/DiffEditPlannerTests.swift` (23): add→edit, add→delete, delete→re-add, edit→revert, swap, rename into a tombstone, kind and scope locked once synced, Convert/Move.*
- [x] Environment create, delete and local rename (unsynced, or case-only). **Verify:** tests for uniqueness by fold key, the 255-character limit, and a case-only rename producing no change. *Done: `VaultDataTests/ConfigTests/ConfigEnvironmentTests.swift` (11: fold-key uniqueness, name validation, case-only rename gives no change) and the 255-character limit in `VaultCoreTests/EnvironmentNameValidatorTests.swift`.*
- [x] `ChangeSetBuilder`, `ChangeSetNormalizer`, `ConfigChangeModel`, `ChangeSummaryModel`. **Verify:** table-driven `SyncDiffTests` with at least 35 cases, including delete plus rename-into, environment tombstone plus create with different case, swap, and `force_push`; a test of the invariant that no key is both upserted and deleted. *Done: `SyncEngineTests/Diff/DiffSyncTests.swift` (a table of at least 35 cases, enforced by `tableHasAtLeastThirtyFiveCases`, run through derivation and the "no key both upserted and deleted" invariant), plus `DiffSnapshotTests.swift` and `DiffSummaryTests.swift`.*
- [ ] Editor (`SecretValueEditor`, fill or push, credential confirmation, trailing CR/LF normalization with notice and the SSH/PEM hint, D32), Revert, Discard all, and the live "Sync N" label and dock badge. **Verify:** view-model tests, including a PEM value whose trailing newline is stripped with the notice shown; the label updates via ValueObservation in a test; manual check on narrow and wide windows on macOS 14 and 27, recorded in RELEASING.md. *Pending: manual — narrow and wide windows on macOS 14 and 27 (RELEASING #11). Done: `AppTests/ItemEditorViewModelTests.swift` (24, including `trailingNewlinesAreAnnouncedAndStripped`), Revert and Discard all (`ConfigItemTests.swift`), the live count and Dock badge (`AppTests/AppViewModelTests.swift` `pendingCountFollowsTheVault`, `pendingCountDrivesDockBadge`).*
- [x] `CredentialClassifier` (shared with M5). **Verify:** table tests (DSN, URL with credentials, PEM, JWT, token prefixes, entropy). *Done: `EnvToolsTests/CredentialClassifierTests.swift` (9 parameterized tables: DSN, URL with credentials, PEM, JWT, token prefixes, entropy).*
- [x] Migration `v4_sync_journal` and `SyncJournalStore` (24 h retention, latest run kept). **Verify:** store test plus the incremental migration test. *Done: `VaultStoreTests/SyncJournalStoreTests.swift` (6, including `retentionKeepsTheLatestRunAndUnresolvedRows`) and the per-migration test. Migration `v7_journal_fingerprints` was added before release so reconciliation records what was actually pushed.*
- [x] `SyncPreflight` (including optimistic concurrency, `pre_write_updated_at` capture and throttle seeding), `SyncPlanner`, `SyncExecutor` (one gh command per item, values on stdin, journal, synchronous success writes, verification by native re-list, indeterminate reconciliation, freshRepo, 5xx retry, token refresh on `.tokenRevoked`, fixed rate-limit backoff, cancellation). **Verify:** executor tests with `FakeCommandRunner` scripting exit codes and stderr:
  - exit 0, "Must have admin rights", "billing plan", "secondary rate limit" (backoff, then stop with items pending), `HTTP 503` then success, a timeout after the process started, `HTTP 401` then a new token, "Not Found" on delete followed by a successful same-scope list (done) and by a failing list (`.notFound`, still pending);
  - a remote change between preflight and write, caught by the per-scope re-list right before that scope's writes;
  - verification: secret `updatedAt` changed vs unchanged from `pre_write_updated_at`, variable fingerprint equal vs different;
  - the pending-verification pass: a pending secret whose `updatedAt` later changes becomes verified; one that stays unchanged for `Limits.pendingVerifyChecks` passes gets `force_push` and is pending again; a pending variable whose fingerprint later matches becomes verified;
  - an imported variable whose GitHub value ends in `\n` is renamed (set new + delete old) and then verifies (expected fingerprint computed over the normalized bytes);
  - launch with leftover `in_flight` rows;
  - stdin carries the value and argv never does; a `gh variable set` update counts 2 writes in the throttle.

  Assertions cover ordering, failed items staying pending, cancellation keeping completed items synced, and unverified items being `pending`. *Done: `SyncEngineTests/ExecutionTests/ExecutorItemTests.swift` (23), `PreflightPlannerTests.swift` (18) and `ReconcilerVerifierTests.swift` (19) cover every case above with `FakeCommandRunner` and `GitHubSimulator`; `pre_write_updated_at` comes from the executor's per-scope re-list (ARCHITECTURE decision 6).*
- [x] `SyncScreen` (summary with the FX Vault hourly write limit (local throttle, not GitHub's quota) and blocked items, deletions with live fetch, progress, result) and `SyncActivityAssertion` wired to AutoLock. **Verify:** view-model tests; a test that the inactivity timeout does not lock during a run but sleep does. *Done: `AppTests/SyncViewModelTests.swift` (18: summary with the 450-per-hour limit, blocked items, deletions with live fetch and no default button, activity held for the whole run, a lock cancels) and `AutoLockManagerTests.swift` (`syncAssertionSuspendsInactivityOnly`, `syncAssertionDoesNotBlockSystemSignals`).*
- [x] Docs: API.md C2 and C5–C9 plus Observed behavior; ARCHITECTURE.md sync section; DATABASE.md v4. **Verify:** `scripts/check-docs.sh` exits 0. *Done: API.md C and "Observed behavior", ARCHITECTURE.md SyncEngine and VaultData sections, DATABASE.md v4 (and v7). Gap: API.md still has the "Pending: write spike (Q6). Not run" paragraph next to the "Write run" paragraph; reword it after the spike rerun.*

**Done when (on the spike repo):**
- Create `staging`, add 2 secrets and 2 variables, edit 1 synced item and delete 1.
- The label reads "Sync 6". The summary shows the counts and the deletion confirmation is passed.
- After Sync, `gh secret list -R <O>/<R> [--env staging]` and `gh variable list -R <O>/<R> [--env staging]` show the items, and the label reads "Sync" with no count.
- Change a secret on GitHub, then edit it locally: Sync blocks it as "Changed on GitHub".
- Sync with the write-only second account: environment items are blocked with the app's admin-required message (`error.gh.adminRequired`) and stay pending; repo-level items behave as the spike established for WRITE collaborators (succeed if WRITE can manage them, otherwise blocked with the same admin-required message and pending).

### Milestone 4: Repo creation, cloning, deployment branch restrictions, synced rename

- [x] Migration `v5_create_policies`. **Verify:** store test plus the incremental migration test. *Done: `VaultStoreTests/MigrationTests.swift` (per-migration test) and `StoreTests.swift` (`environmentRoundTripWithCustomPatterns`).*
- [x] Template pickers (B10), owner picker (account plus A5 orgs), `RepoNameValidator` (rejects `.`, `..` and `.git`), debounced availability (B2). **Verify:** view-model tests with a fake service, including an org-policy create error shown inline and the item left pending. *Done: `AppTests/CreateRepoViewModelTests.swift` (23: owners and templates cached per account, local name rules, 500 ms debounced "Probably available", a taken name blocks Create) and `VaultDataTests/CreationTests/RepoCreationTests.swift`. Gap: the org-policy create error exists only as a synthetic classifier case; no view-model test shows it inline.*
- [x] `CreateRepoScreen` with staged environments and items, Clone on by default. `createRepository` runs first, with freshRepo retries and reconciliation of indeterminate creates. **Verify:** a planner test (create before everything else); C1 argv tests (visibility, README, templates, never `--clone`); executor tests (exit 0 with the stdout URL giving the normalized name, then B2 confirming it; B2 failing during freshRepo while the name is still known from stdout; `HTTP 404 … /users/<owner>` classified as an invalid owner; a `GraphQL:` "already exists" error; a timeout followed by an adopted repo (preflight B2 "Could not resolve", then B2 finds it with the expected owner and visibility, with the Mac clock set ahead of the server), never a second create; a timeout where B2 then finds the repo with a different visibility is reported as a conflict, not adopted; a "not found" during freshRepo is never plan-gated). *Done: `SyncEngineTests/ExecutionTests/ExecutorEnvironmentTests.swift` (create first, name from stdout, freshRepo, invalid owner, adoption after a timeout with the Mac clock ahead, other-visibility conflict, never plan-gated during freshRepo), C1 argv in `CommandBuilderTests.swift`, `RepoCreationTests.swift`; a public repository with README, `.gitignore` and license was created live (API.md "Write run"). Gap: no executor test for the GraphQL "already exists" error.*
- [x] `GitService.clone` (temp sibling plus rename, classified retries, destination containment, EPERM guidance) and the **Clone** button. **Verify:** unit tests for argv and env, a stale temp directory not blocking a retry, and `..` rejected; manually, `git -C ~/Developer/<name> remote -v` shows the mapped alias. *Done: GitService suite in `GitHubKitTests/SSHAndGitTests.swift` (temp sibling then rename, exit 128 retries, existing destination, `..` rejected); a live clone through the alias gives `origin` = `git@<alias>:<O>/<N>.git` (API.md "Clone and .env").*
- [x] `BranchPolicyEditor` with `DeploymentBranchPolicyModel` and the plan note. **Verify:** model serialization tests: `.all` → null, `.protectedBranches` → {true,false}, `.custom` → {false,true}. *Done: shared `App/Components/BranchPolicyEditorView.swift` and `BranchPolicyFormModel.swift`; `null`, `{true,false}` and `{false,true}` bodies in `CommandBuilderTests.swift` (`environmentBodiesGoOnStdin`) and `VaultCoreTests/ModelTests.swift`; `AppTests/EnvironmentBranchPolicyFormTests.swift` (5); plan note in `RepoDetailViewModelTests.swift`.*
- [x] Pattern reconciliation (C2–C4), the custom→all reset, foreign-rules comparison, and the clearable plan-gated hint. **Verify:** executor tests: an existing pattern returned as 200 (followed redirect) and as 303 both counted as success, 404 when not custom, custom→all→custom re-posting patterns, foreign rules changed producing a warning. *Done: `ExecutorEnvironmentTests.swift` (`patternsCountA200AndABare303AsSuccess`, `reconcileDeletesTombstonedAndExtraPatterns`, `customToAllToCustomResetsAndRepostsThePatterns`, `changedForeignRulesProduceAWarning`, `a404OnAPatternPostOfAVisibleRepositoryIsPlanGated`, `aPolicyChangeIsBlockedWhileGitHubListsOtherProtectionRules`); a B5 404 means "no patterns" (`ServiceTests.swift`). Gap: the plan-gated hint (`isEnvPlanGated`) is set on failure but the user cannot clear it.*
- [x] Guided rename (§7.6) with the case-only and same-id guards and two-fact persistence. **Verify:** planner test (create, copy, verify, delete as a separate pending deletion); executor tests: verification fails and the old environment is kept; same env id aborts; a declined deletion leaves a tombstone that can be retried; preflight blocks on value-missing. *Done: `ExecutorEnvironmentTests.swift` (copy, verify, old environment left as a pending deletion; same environment id aborts; failed verification keeps the old one; preflight blocks on value-missing), `ExecutorItemTests.swift` (`declinedItemDeletionLeavesARetryableTombstone`), `ReconcilerVerifierTests.swift` (`anInFlightRenameCopyOnlyGetsItsJournalState`); a guided rename passed live.*
- [x] Docs: API.md C1–C4 and D3; ARCHITECTURE.md create, clone and rename. **Verify:** `scripts/check-docs.sh` exits 0. *Done: API.md C1–C4 and D3; ARCHITECTURE.md SyncEngine, VaultData and UI feature contract sections. No `check-docs.sh`.*

**Done when (each created repo approved by Bryan and listed for him to delete):**
- A single Sync creates a new **public** repo with README, Swift .gitignore and MIT, a `production` environment with custom pattern `release/*`, 1 secret and 1 variable.
- The repo is cloned into `~/Developer/<name>` through the mapped alias, and GitHub shows the rule.
- Renaming `production` to `prod` is guided, verified and confirmed.
- On a Free-org **private** repo, the plan-gated path shows the friendly explanation and the items stay pending.

### Milestone 5: Drift detection and bulk tools

- [x] `DriftDetector` (pure, full re-list, ignores pending items, suppression from the journal), `DriftRepository`, the banner and `DriftReviewScreen`. **Verify:** `DriftTests` cover every §7.7 row times both resolutions, a 150-item variable list (decoded from a native `gh variable list --json` fixture) with a change past item 100, the pending-verification pass running before detection (resolved rows are checked, still-pending rows skipped), and a recently deleted name not reported as added. *Done: `SyncEngineTests/Drift/DriftTests.swift` (37: every §7.7 kind with both resolutions, 150 variables decoded through `GHVariablesCommands.decodeList` with a change at item 120, pending rows skipped after the pass, recent deletions not reported as added), `VaultDataTests/DriftTests/DriftRepositoryTests.swift` (27) and `AppTests/DriftReviewViewModelTests.swift` (12). Drift was resolved both ways live.*
- [x] `DotEnvParser`. It handles `export`, `#` comments, inline comments only on unquoted values after whitespace, single-quoted literals, double quotes with `\n \r \t \" \\`, multi-line double quotes, CRLF, BOM and blank lines. It does not expand variables and warns on `${…}`. Duplicates: the last wins, with a warning. `KeyNormalizer` and `CredentialClassifier` are integrated. **Verify:** at least 40 table cases plus a round-trip property test `parse(serialize(x)) == x`. *Done: `EnvToolsTests/DotEnvParserTests.swift` (table of at least 40 cases, enforced by `tableHasAtLeastFortyCases`), `DotEnvSerializerTests.swift` (`roundTripProperty`) and `KeyNormalizerTests.swift`.*
- [x] `EnvImportScreen`. **Verify:** view-model tests; importing `Fixtures/sample.env` (12 lines) pre-marks the expected secrets and suggests key fixes. *Done: `AppTests/EnvFileImportViewModelTests.swift` (14, including `sampleFilePreMarksSecretsAndSuggestsKeyFixes` on the 12-line `EnvToolsTests/Fixtures/sample.env`).*
- [x] `DuplicateEnvironmentScreen` (re-encrypt under new ids, carry value-missing, copy the policy). **Verify:** a repository test that values decrypt under the new AAD and value-missing flags carry over. *Done: `VaultDataTests/ConfigTests/ConfigEnvironmentTests.swift` (`duplicateReEncryptsUnderTheNewIdentity`) and `AppTests/EnvironmentViewModelTests.swift` (`duplicateCopiesPolicyAndValuesAndCarriesValueMissing`, `duplicateIntoADeletedNameIsRefused`).*
- [ ] `EnvExportScreen` with ReauthGate, `SecureFileWriter`, the iCloud warning, and the gitignore and tracked checks (§8 D4–D6) with hardened git flags. **Verify:** a serializer quoting test; a test that the file is created 0600 with no window of wider permissions (`stat` right after creation); temp-git-repo tests for ignored, not ignored and tracked; a test that a repo `core.fsmonitor` is not executed; manual Touch ID prompt in the RELEASING.md entry. *Pending: manual — the Touch ID prompt on export (RELEASING #17) and the .env flows (#25). Done: `EnvToolsTests/SecureFileWriterTests.swift` (`createsAnOwnerOnlyFileWithNoWiderWindow`), `DotEnvSerializerTests.swift`, `GitignoreTests.swift` (temporary git repositories: ignored, not ignored, tracked), `VaultDataTests/EnvFilesTests/EnvFileTests.swift` (`gitServiceCheckerUsesHardenedGit` asserts `core.fsmonitor=` in argv), `AppTests/EnvFileExportViewModelTests.swift` (20).*
- [x] Docs: ARCHITECTURE.md drift and bulk tools; API.md drift reads. **Verify:** `scripts/check-docs.sh` exits 0. *Done: ARCHITECTURE.md (SyncEngine drift, `DriftRepository`, EnvFile feature) and API.md F (`DriftRepository` reads B2–B9). No `check-docs.sh`.*

**Done when:**
- After changing a variable and a secret on github.com, opening the repo shows *"Secret API_TOKEN was changed on GitHub on Oct 12"*, and both resolutions work.
- A messy `.env` imports with correct marks and fixed keys.
- `staging` duplicates into `production`.
- Export needs re-authentication, writes a 0600 file, warns on iCloud folders, and offers the `.gitignore` entry.

### Milestone 6: Sharing (file first, then nearby)

- [x] `SharePackageModel` and `SharePackageValidator`. **Verify:** validator tests (host, owner, repo, dot-segments, bidi and zero-width names, kinds, limits, patterns, scope rules). *Done: `SharingKitTests/SharePackageValidatorTests.swift` (rejection table) and `SharePackageModelTests.swift` (15).*
- [x] `FxVaultHeaderModel`, `FxVaultFileCodec` (injected `KeyDeriving`) and the Argon2id deriver (t=3, 64 MiB). **Verify:** header KAT; flipping any header byte fails; t or m changes fail; a truncated tag fails; `headerLength != 64` is rejected; bounds are rejected before the KDF (the spy is never called). *Done: `SharingKitTests/FxVaultFileCodecTests.swift` (18: header vector, each of the 64 header bytes flipped, t and m changes, truncated tag, wrong sizes, bounds rejected before the KDF with the spy never called); the deriver is `VaultData/Vault/Argon2idSharingDeriver.swift` (`VaultPlatformTests.swift` `sharingDeriverMatchesArgon2id`).*
- [x] `PassphraseGenerator` and THIRD_PARTY_NOTICES. **Verify:** 6 words, all in the list, no hyphenated words; normalization of case, whitespace and separators. *Done: `SharingKitTests/PassphraseGeneratorTests.swift` (8: six listed words, hyphenated words filtered, normalization, a tampered wordlist is refused); THIRD_PARTY_NOTICES.md lists the EFF wordlist with its sha256.*
- [x] Migration `v6_sharing`. **Verify:** store test plus the incremental migration test. *Done: `VaultStoreTests/MigrationTests.swift` (per-migration test) and `StoreTests.swift` (`recordsAndDetectsReplays`).*
- [ ] `ShareExportScreen` (ReauthGate, scope tree, passphrase with the separate-channel hint, save or AirDrop) and UTType registration. **Verify:** a view-model test that ReauthGate is called; double-clicking a `.fxvault` file while the window is closed reopens it and shows the import sheet. *Pending: manual — double-click a `.fxvault` file with the window closed (RELEASING #22) and Save / AirDrop (#23). Done: `AppTests/SharingExportViewModelTests.swift` (9, re-authentication first), `MainViewModelTests.swift` (`importSheetOpensAfterUnlockOneFileAtATime`, `onlyShareFilesAreQueuedOnce`), UTType and document type in `project.yml`.*
- [x] `ShareImportPlanner` (pure) and `ShareImporter`, covering policy differences, kind collisions, githubRepoId mismatch, provenance and replay. **Verify:** planner tests for every §9.5 row; an importer test of re-encryption with the receiver's DEK; a replayed packageId warns. *Done: `SharingKitTests/ShareImportPlannerTests.swift` (21: every §9.5 row, policy cases, kind collision, repo-id mismatch, replay, provenance) and `VaultDataTests/SharingTests/ShareFileTests.swift` (11: re-encryption with the receiver's DEK, replay confirmation).*
- [x] Update `NearbyProtocolReference.swift` and `crosscheck.py` for the revised transcript, and regenerate the vectors. **Verify:** Swift and Python produce identical hex for pkI, pkR, C, TH, SAS, k_i2r, k_r2i and CONFIRM; the vectors are committed to `Tests/Fixtures/nearby_kat.json`. *Done differently: the vectors are in `SharingKitTests/Fixtures/nearby_kat.json` (not `Tests/Fixtures/`) and the generators in `SharingKitTests/Fixtures/kat/`; SHARING-PROTOCOL.md records that both produce byte-identical output, and `NearbyKATTests.swift` (5) reproduces the vectors through the state machine.*
- [x] `NearbyCrypto`, `NearbyFrame`, `NearbyHandshake` and `InMemoryTransportPair`. **Verify:** tests for the KATs, a full I↔R run, a MITM relay (SAS values differ; no data without both confirmations), commitment mismatch, suite mismatch, replay, reorder, truncation, wrong direction, downgrade, low-order or all-zero keys, oversize frames, timeouts, DECISION with unknown ids aborting, and no automatic retry. *Done: `SharingKitTests/NearbyHandshakeTests.swift` (32: full run, commitment and suite mismatch, downgrade, low-order keys, replay, reorder, truncation, reflection, oversize, unknown DECISION ids) and `NearbySessionTests.swift` (14: in-memory and relay transports, MITM codes differ, timeouts, no retry).*
- [ ] Transport (Q3 decided: `NWNearbyTransport`, `acceptLocalOnly`, random instance name, single connection) and the Info.plist keys. **Verify:** two signed builds (two Macs or a second macOS user) discover each other; the Local Network denial path shows guidance (RELEASING.md entry). *Pending: manual — two signed builds on one network and the Local Network denial path (RELEASING #12, #24); nearby ships as experimental. Done: `SharingKit/Nearby/NWNearbyTransport.swift` (`acceptLocalOnly`, random `FXVault-` instance name, single connection), Info.plist `NSLocalNetworkUsageDescription` and `_fxvault-share._tcp`, `AppTests/SharingNearbyViewModelTests.swift` (`aDeniedLocalNetworkShowsGuidance`).*
- [ ] `NearbyShareScreen` and `SASCodeView`. **Verify:** a test that neither button is the default; a test that ReauthGate runs before MANIFEST; a manual run recorded. *Pending: manual — a recorded two-Mac run (RELEASING #24). Done: `AppTests/SharingNearbyViewModelTests.swift` (12, including `neitherCodeAnswerIsADefaultButton`, `reauthenticationRunsBeforeTheManifestIsSent`, `dontMatchAbortsBothSidesWithNothingTransferred`) and `VaultDataTests/SharingTests/NearbyShareTests.swift` (5).*
- [x] Docs: SHARING-PROTOCOL.md (layouts and the new vectors); SECURITY-MODEL.md (SAS is the only authentication, cleartext HELLO metadata). **Verify:** `scripts/check-docs.sh` exits 0. *Done: docs/SHARING-PROTOCOL.md (layouts and vectors) and SECURITY-MODEL.md §10–11 (commit-reveal SAS, cleartext HELLO metadata). No `check-docs.sh`.*

**Done when:**
- Mac A exports an environment to `.fxvault` and AirDrops it.
- Mac B enters the 6 words, previews, fills its value-missing secrets without creating pending changes, sees "Keep mine" defaults for items that differ, and sees "from share, unverified" chips.
- A nearby share shows the same code on both screens; B accepts, values arrive, and B confirms Same/Differs before applying.
- Pressing "Don't match" on either side aborts with nothing transferred.

### Milestone 7: Distribution

- [ ] README: features, light and dark screenshots, install (tap command and DMG), verifying a download (`shasum -c`, `gh attestation verify`, `gh release verify-asset`, `spctl -a -vvv -t install`), first launch for ad-hoc builds (Open Anyway or `xattr`), requirements (macOS 14+, gh ≥ 2.97, git, SSH), security model summary, telemetry note, building from source. **Verify:** `scripts/check-docs.sh` checks the required README headings; Bryan signs off in the Review section. *Pending: manual — light and dark screenshots (the README has none) and Bryan's sign-off. Done: Features, Requirements (macOS 14+, gh ≥ 2.97, git, SSH), Install, First launch, Verify a download (`shasum -c` and `spctl`; attestations only for CI-signed releases; no `gh release verify-asset`), Opening an ad-hoc build, Security model, telemetry note, Building from source. No `check-docs.sh` heading check.*
- [x] `scripts/make-dmg.sh` (rename to `FX Vault.app`, `diskutil image create from --format ULFO` falling back to hdiutil, `hdiutil verify`). **Verify:** a local DMG mounts and shows `FX Vault.app` and an Applications link; the app launches from it. *Done: `scripts/make-dmg.sh` (ULFO through `diskutil image create from` with the hdiutil fallback, `hdiutil verify`, a read-only test mount that shows `FX Vault.app` and `Applications`); it built the published `FXVault-0.1.0.dmg`. Launching from the DMG is RELEASING #13–14.*
- [x] `ci/ExportOptions-DeveloperID.plist` and `.github/workflows/release.yml`:
  - triggered by `v*` tags and `workflow_dispatch`, with `environment: release`
  - a runner-to-Xcode map (`xcode-27` → `Xcode_27.0.app`, `macos-26` → `Xcode_26.6.app`) that fails fast if the path is missing
  - job-level `HAS_SIGNING` and `HAS_NOTARY`
  - signed path: write `Config/Local.xcconfig` with `#include "Signed.xcconfig"`, temporary keychain import (legacy p12), archive and export
  - gates: `codesign --verify --deep --strict`; entitlements **contain** `keychain-access-groups`; the embedded profile's team equals `APPLE_TEAM_ID`; no `get-task-allow`; `syspolicy_check distribution`
  - notarize and staple the app, then build, sign, notarize and staple the DMG, then `spctl`
  - ad-hoc path gate: entitlements **lack** `keychain-access-groups`, plus the smoke launch
  - strings check; sha256; `actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6`; `gh release create --verify-tag`
  - every action pinned to a SHA, `dependabot.yml`, `CODEOWNERS`

  **Verify:** a `workflow_dispatch` dry run on a test tag produces an ad-hoc DMG that passes the ad-hoc gates. *Done differently: official releases are signed, notarized and published from Bryan's Mac with `scripts/release-local.sh --publish` (the gates above; the app and the DMG are each notarized and stapled). `release.yml` builds an ad-hoc verification DMG on `macos-26` (newest `Xcode_26*.app` by glob, no runner-to-Xcode map) and has an optional signed job that runs only when the `release` environment holds the six secrets (none are set, so there is no attestation). Every action is SHA-pinned. Not built: `dependabot.yml` and `CODEOWNERS`. The v0.1.0 tag run takes the place of the `workflow_dispatch` dry run (its ad-hoc job was still running when this was written).*
- [x] Cask `Casks/fx-vault.rb`: version, sha256, url, name, desc, homepage, `livecheck :github_latest`, `depends_on macos: :sonoma`, `depends_on formula: "gh"`, `app "FX Vault.app"`, zap of the Application Support, Caches, Preferences and Saved Application State paths, a caveat that `--zap` deletes the vault, no postflight. Plus the tap bump job (GitHub App token) running `brew style` and `brew audit --cask --new --online`. **Verify:** the audit passes against the signed release. *Done 2026-10-15: fx-vault 0.1.0 pushed to FractalX-Technologies/homebrew-tap (c2db897); `brew style` no offenses; `brew audit --cask --online --strict` clean; `brew install --cask fractalx-technologies/tap/fx-vault` installed it on the maintainer's Mac, `spctl` reports Notarized Developer ID, and the signed app launched and stayed running (no AMFI kill with the keychain entitlement). Done differently: no tap bump job or GitHub App; `scripts/bump-cask.sh` renders the cask and the maintainer (or Claude with authorization) pushes it.*
- [ ] **Bryan actions:** make the repo public; enable release immutability, private vulnerability reporting and a `v*` tag ruleset; create the `release` environment with secrets `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_PROFILE_BASE64`, `ASC_KEY_P8_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and the variable `APPLE_TEAM_ID`; install the tap GitHub App. **Verify:** `gh secret list --repo FractalX-Technologies/fx-vault --env release --json name` lists all six names and `gh variable list --repo FractalX-Technologies/fx-vault --env release --json name` lists `APPLE_TEAM_ID`. *Pending: manual — enable release immutability (off) and a `v*` tag ruleset (none). Done: the repository is public and private vulnerability reporting is on. Done differently: no `release` environment secrets and no tap GitHub App, because signing stays on Bryan's Mac (RELEASING.md "Current decision").*
- [ ] Manual Sonoma (macOS 14) VM smoke test of the release DMG. **Verify:** RELEASING.md "Sonoma smoke" entry completed (onboarding, gh detection, import, sync on the spike repo). *Pending: manual — RELEASING #14 on a macOS 14 VM with the notarized DMG installed through the tap.*
- [x] Docs: RELEASING.md, CONTRIBUTING.md, CHANGELOG.md, final SECURITY.md. **Verify:** `scripts/check-docs.sh` exits 0. *Done: docs/RELEASING.md (setup, release steps, gates, 28-item manual checklist), CONTRIBUTING.md, CHANGELOG.md (0.1.0 - Beta), SECURITY.md (private reporting plus security@fractalx.io). No `check-docs.sh`.*

**Done when:**
- Bryan pushes `v1.0.0`, and the workflow publishes a notarized, stapled, universal `FXVault-1.0.0.dmg` with its `.sha256` and attestation.
- `spctl` reports "Notarized Developer ID".
- `brew install --cask fractalx-technologies/tap/fx-vault` installs it, it launches with only the standard first-open dialog, and Touch ID works.

### v0.1.1: bulk paste and Touch ID (requested by Bryan, 2026-10-15)

Decisions: Touch ID keeps requiring the master password after a restart and at least every 14 days. Publishing 0.1.1 (commit, push, tag, signed release, cask bump) is authorized for this delivery only.

- [x] **Paste many at once.** "Paste Multiple…" in the table's Add menu and ⌘V on the secrets/variables table open the import preview prefilled with the clipboard (user-initiated paste only, no background pasteboard reads). **Verify:** view-model tests for prefill, scope and kind defaults; ⌘V handler test. *Done: RepoDetail split Add button + ⌘V (.onPasteCommand); EnvPasteViewModel tests.*
- [x] **Live preview.** Pasted or edited text is parsed as you type (debounced) and the table updates without a separate Review step; parse issues show line numbers. **Verify:** view-model tests for live parse, debounce and issues. *Done: 300 ms debounce, no Review step; unquoted PEM lines rejected (review P-1).*
- [x] **Kind follows the tab.** From the Variables tab every row defaults to Variable and from the Secrets tab to Secret; credential-looking variables only get a warning badge with a one-click switch; "Mark all as Variable / Secret" buttons. The toolbar Import .env keeps auto-detection. **Verify:** tests for both defaults, bulk marking and the warning. *Done: defaultKind context, Make Secret badge, Mark All.*
- [x] **Target scope** defaults to the scope that is open (repository or environment). **Verify:** test. *Done: defaults to the open scope; Overwrite All added.*
- [x] **Touch ID discoverability.** After a password unlock, if Touch ID is available but off, offer it once (Enable / Not now, remembered). The lock screen explains why the password is required (restart or 14 days). **Verify:** LockViewModel/AppViewModel tests. *Done: TouchIDOfferScreen after password unlock; lock-screen reason; errSecAuthFailed no longer disables Touch ID.*
- [x] **`--diagnose` launch argument.** Prints JSON (version, signed, keychain access group, biometry availability or reason, and an add+delete of a probe item with `.biometryCurrentSet` in the data-protection keychain) and exits without UI. Never reads a biometric item and never prints secrets. **Verify:** unit test of the report shape; run on the signed 0.1.1 build: probe add returns 0. *Done: on the signed 0.1.1 installed via Homebrew, `--diagnose` reports isSignedWithAccessGroup true, biometryAvailable true, probe add 0 / delete 0 (errSecSuccess).*
- [x] Release 0.1.1: CHANGELOG, signed + notarized DMG, GitHub release, cask bump, `brew upgrade --cask fx-vault` on this Mac. **Verify:** `spctl` Notarized Developer ID; brew shows 0.1.1. *Done: v0.1.1 published (first archive hit an Apple timestamp-service outage; retried), cask 4acc4cb in the tap, `brew upgrade --cask fx-vault` shows 0.1.1, spctl Notarized Developer ID.*

### v0.1.2: fixes from Bryan's first use (2026-10-15)

Root cause of "my vault was deleted after brew upgrade": about 45 Debug copies (agents' build folders) were registered with LaunchServices as "FX Vault" / io.fractalx.fxvault; Bryan opened one at 07:42, which uses the separate `FX Vault Dev` folder (vault intact there, kept per Bryan). The release app uses `FX Vault`. Stray copies were unregistered and stale build folders removed. Publishing 0.1.2 is authorized.

- [x] Debug builds are "FX Vault Dev" / io.fractalx.fxvault.dev with a visible DEV badge; Release identity unchanged. **Verify:** generated Info.plist per configuration; release gates pass. *Done: project.yml Debug identity, DEV chip, BundleIdentityTests; release gate_app_name added.*
- [x] Filling a value-missing secret is a pending push by default ("Already matches GitHub" opt-out). **Verify:** ConfigRepository + editor tests; Sync count increments. *Done: default push; "Already matches GitHub" opt-out; 1005 package + 356 app tests.*
- [x] "Push on Next Sync" for synced secrets (force push; Revert clears it). **Verify:** repository, change-set and view-model tests. *Done: force-push request with a 5 s clock margin; Revert keeps values (review F4).*
- [x] Release 0.1.2 (signed, notarized, cask, `brew upgrade`, `--diagnose`). **Verify:** brew shows 0.1.2; probe add 0. *Done: v0.1.2 published, cask bumped, `brew upgrade` here shows 0.1.2 named "FX Vault", spctl Notarized, `--diagnose` passed.*

### v0.2.0: flexible sharing, connectivity banner, nearby chat (requested by Bryan, 2026-10-15)

Decisions (Bryan): chat is 1:1 and ephemeral (nothing written to disk); a secret or variable can be attached in chat and saved by the receiver through the normal share preview; publishing 0.2.0 (commit, push, tag, signed release, cask bump) is authorized for this delivery only.

- [x] **Share any combination.** The share scope tree becomes multi-select with tri-state checkboxes: repository level only, one or more environments, repository level + environments, or individual secrets/variables. Works for `.fxvault` files and nearby send. Files written by 0.1.0 still import; the format change (if any) is versioned and documented in docs/SHARING-PROTOCOL.md. **Verify:** ShareScopeTreeModel tests for every combination; package round trip of a repo-level + one-environment selection; validator tests. *Done: tri-state scope tree; schema v2 only for partial environments; 0.1.x fixtures import.*
- [x] **Connectivity banner.** NWPathMonitor-based monitor plus GitHub reachability from gh `.network` failures. Offline banner at the top of the main window ("No internet connection: changes stay local"), and a separate "GitHub is not responding" state. Sync, Import, New Repository, Refresh and drift checks are disabled with an explanation while offline, and drift re-checks when the connection returns. **Verify:** monitor tests with an injected path source; view-model tests for disabled actions and banner states. *Done: ConnectivityMonitor + GitHubReachability; network actions gated; drift re-check on reconnect.*
- [ ] **Nearby without shared Wi-Fi.** The Network framework transport enables peer-to-peer Wi-Fi (AWDL, as AirDrop does: Wi-Fi + Bluetooth on, no router or internet needed). The Info.plist Bonjour services are updated. **Verify:** parameter tests; manual two-Mac check with Wi-Fi networks disconnected. *Done in code (includePeerToPeer); Pending: manual two-Mac check with Wi-Fi networks off.*
- [ ] **Nearby chat (experimental).** A separate window. Only while it is open you are visible to nearby Macs under your display name. Connect, then both compare the 6-digit code (same commit-reveal X25519 handshake with a "chat" purpose bound into the transcript), then end-to-end encrypted 1:1 text. Messages live only in memory and are wiped on close, lock or disconnect. Chat-specific idle timeout and keepalive. **Verify:** protocol tests over InMemoryTransportPair (full chat, MITM relay with different codes, purpose confusion between share and chat rejected, oversize/replay/reorder aborts); view-model tests for wipe on close/lock. *Done in code + protocol tests (KATs, MITM, purpose separation, floods); Pending: manual two-Mac check.*
- [x] **Attach a secret or variable in chat.** Requires Touch ID or the master password to send. The receiver sees a card (name, kind, repo/environment, never the value) with "Save to my vault", which runs the share import preview and merge, or Dismiss. **Verify:** tests for ReauthGate on send, card without value, import through ShareImportPlanner/ShareImporter. *Done: ReauthGate on send, value-free card, import via share preview.*
- [x] Release 0.2.0: CHANGELOG, README (sharing, offline banner, nearby chat marked experimental, requirements for AWDL), signed + notarized DMG, GitHub release, cask bump, `brew upgrade --cask fx-vault` here. **Verify:** `spctl` Notarized Developer ID; `--diagnose` probe OK; brew shows 0.2.0. *Done: v0.2.0 published after full tests, cask bumped, `brew upgrade` here shows 0.2.0 with both Bonjour services, spctl Notarized, `--diagnose` passed.*

### v0.3.0: FractalX design language (requested by Bryan, 2026-10-15)

Approved mockup: https://claude.ai/artifact/Y8NqmJi2nGx7DcGtzHmQGD (main window light/dark, lock, onboarding, sync review, icon/tokens). Source: fractalx.io (Geist Sans + Geist Mono, warm off-white #F6F5F3 / ink #0B0C0E, dark #0B0C0E / #111820, brand #0B6FA4 / #3BA3DD, pill buttons, 24 px cards, hairline borders, mono uppercase labels, 3×3 mark). Icon: dark squircle, off-white 3×3 mark, brand-blue outlined center cell. Publishing 0.3.0 is authorized. Built after 0.2.0 is merged.

- [x] Design tokens in Helpers/Theme (colors light/dark from the mockup, type scale, radii, spacing, durations 140 ms) + docs/DESIGN.md. **Verify:** token tests; no hardcoded colors outside Theme (lint). *Done: 17 color sets light/dark, Geist type scale, radii, spacing, durations; docs/DESIGN.md; lint rule for literals.*
- [x] Bundle Geist Sans + Geist Mono (OFL 1.1, THIRD_PARTY_NOTICES + Credits) via ATSApplicationFontsPath; fallback to system fonts. **Verify:** font registration test; Release build contains the fonts. *Done: geist-font v1.7.2 (OFL 1.1, checksums in THIRD_PARTY_NOTICES), FontRegistry fallback, Credits regenerated.*
- [x] Components: pill button styles (primary/secondary/outline/ghost), section label (mono uppercase), chips, cards, inputs, segmented control, banner, table styling, window chrome background, dot-grid backdrop. **Verify:** component snapshot/view tests where practical. *Done: App/Components/Design (buttons, labels, chips, cards, fields, segmented pill, banner, dot grid, brand mark, step counter, sheet chrome, table styling).*
- [x] Screens: main window (sidebar, scopes, detail table), toolbar Sync pill with count, lock, onboarding (mono step counter + side panel), preferences, every sheet (sync review, drift, editors, create repo, env import/export, sharing, nearby, chat), banners. **Verify:** view-model tests unchanged and green; manual light/dark pass. *Done: all screens restyled; rendered light/dark snapshots reviewed against the mockup (19 findings, 18 fixed, native table header separators documented as a known limit).*
- [x] App icon: 3×3 mark with blue center, all macOS sizes (generated by script). **Verify:** asset catalog complete; icon visible in Finder/Dock. *Done: scripts/make-icon.swift, all sizes regenerated.*
- [x] Release 0.3.0 (signed, notarized, cask, `brew upgrade`). **Verify:** brew shows 0.3.0; spctl OK; `--diagnose` OK. *Done: v0.3.0 published after full tests, cask bumped, `brew upgrade` here shows 0.3.0 with Geist fonts and new icon, spctl Notarized, `--diagnose` passed, signed app stayed up 30 s with no crash report.*

### v0.3.1: gh login not detected on a teammate's Mac (reported by Bryan, 2026-10-15)

Report: Homebrew gh 2.102.0, `gh auth login` done and Terminal says logged in, but FX Vault does not pick it up. **Confirmed root cause:** the teammate's accounts are GitHub Enterprise Managed Users with an underscore in the login (`<handle>_<shortcode>`, two accounts, both stored in the keyring with repo + read:org); `OwnerLoginValidator` allowed only alphanumerics and hyphens and `GHAccountStatusModel.accounts(from:)` dropped them silently, so FX Vault saw zero accounts. Version is not the cause by itself (minimum 2.97.0). Probable causes: (a) GH_TOKEN/GITHUB_TOKEN exported in the shell, so Terminal's gh uses it and `gh auth login` stores nothing, while FX Vault strips those variables; (b) the shell probe uses `-l -c` first, so ~/.zshrc-only settings (PATH, GH_CONFIG_DIR, XDG_CONFIG_HOME) are missed; (c) gh owned by another non-root user is rejected and an older gh elsewhere may be picked. Publishing 0.3.1 is authorized.

- [x] **EMU logins:** accept `_` in logins/owners everywhere (accounts, tokens, scopes, SSH, repo refs, catalog, creation, sync, sharing); never drop an unusable account silently. **Verify:** table tests with synthetic EMU logins; auth-status fixture with two EMU accounts. *Done: OwnerLoginValidator accepts `_` (not first, 39-char limit per GitHub docs); unusable accounts surfaced; EMU fixtures in every layer.*
- [x] Use the same gh as Terminal (shell `command -v gh` first after the override). **Verify:** candidate-ordering tests. *Done: `command -v gh` from the shell is the first candidate; no silent fallback.*
- [x] Shell probe runs interactive login first, falls back to login-only. **Verify:** probe tests for zsh/bash/fish with .zshrc-only settings. *Done: `-i -l -c` first, `-l -c` fallback; real-shell tests zsh/bash/sh/tcsh.*
- [x] Detect GH_TOKEN/GITHUB_TOKEN presence (names only, never values) and show `env -u GH_TOKEN -u GITHUB_TOKEN gh auth login`. **Verify:** redaction test; setup-screen state tests. *Done: names only (FXV_SET flags); `env -u` guidance verified on macOS.*
- [x] Consent-based trust for a gh owned by another non-root user (path + uid, revocable). **Verify:** locator and preferences tests; SECURITY-MODEL updated. *Done: Trust This gh (path + uid), revocable in Advanced; not the default button.*
- [x] Copy Diagnostics on the setup screen and a `gh` section in `--diagnose` (sanitized). **Verify:** report tests; real run on this Mac. *Done: shared sanitized report; real run on this Mac recorded.*
- [x] Release 0.3.1. **Verify:** brew shows 0.3.1; spctl OK; `--diagnose` shows the gh section. *Done: v0.3.1 published after full tests, cask fbd645f, `brew upgrade` here shows 0.3.1, spctl Notarized; signed `--diagnose`: keychain probe passed, gh ready (interactive probe, shell gh), account ok via keyring.*

### v0.3.2: window header overlap and narrow-window layout (reported by Bryan, 2026-10-15)

Report: the sidebar's account avatar and login sit under the close/minimize/zoom buttons. **Confirmed root cause** (reproduced in the app's own `Window` scene with an in-memory vault; offscreen snapshots never showed it): AppKit sizes the main `NavigationSplitView` from each column's minimum height, which SwiftUI measures at zero width. With no repository selected, the scope column's wrapped "No repository selected" message measures 967.5 pt, so the split view was 967.5 pt tall in a 720 pt window and was centered: the top 98 pt of every column (ACCOUNTS label, first account row) went under the title bar and the sidebar footer below the window. Second overlap found on the way: below about 1,060 pt of window width the detail's header and add actions (597 pt minimum) were drawn under the scope column and past the window edge.

- [x] Every column takes the window's height (`mainColumnHeight()`: `frame(minHeight: 0, maxHeight: .infinity)`). **Verify:** `MainWindowLayoutTests.emptyColumnsKeepTheWindowHeight` fails on 3e61012 and passes; real-scene capture: split view 720 pt, ACCOUNTS below the traffic lights, footer visible, sidebar rows scroll under the title bar with the system soft edge. *Done.*
- [x] The detail fits its narrowest column: Clone/Refresh under the title, tags stacked, Paste Multiple/Add under the pill when a row does not fit (`ViewThatFits`); the table scrolls sideways. **Verify:** `MainWindowLayoutTests.detailFitsItsNarrowestColumn` (minimum 597 → 372 pt, column minimum 420) fails before and passes; 900 pt window capture without overlap. *Done.*
- [x] SSH alias of a second identity is not listed. **Confirmed root cause:** FX Vault's own parser reads both aliases from Bryan's `~/.ssh/config` (copy run through the live code path), but gh has only one account logged in (`gh auth status`), and Settings › Accounts lists aliases only inside gh's accounts' menus, so the second identity had no place and nothing explained it; aliases also never loaded when gh detection failed. Fix: "SSH aliases without an account" with `gh auth login` and **Check Again** (reloads the tab and the sidebar), aliases loaded before gh detection, the alias Test's "not logged in" text says how to add the account. **Verify:** `AccountsSettingsViewModelTests` (`githubAliasesNoAccountUsesAreListed`, `aliasesLoadWithoutGH`, `checkAgainListsANewAccountInTheTabAndTheSidebar`). *Pending: manual — Bryan logs the second account in with `gh auth login`, chooses Check Again, maps the alias, Test.*
- [x] Full checks and docs. **Verify:** `scripts/ci-local.sh` passes. *Done: ci-local passed (XcodeGen drift, package and app tests, lint, check-secrets); DESIGN.md (Main window), ARCHITECTURE.md (Accounts, decisions 69–70), CHANGELOG 0.3.2, lessons.*
- [x] CI on `main` red since 3e61012: `ProcessRunnerTests` `timeoutTerminatesWithSIGTERM` and `cancellationTerminatesTheProcess` required the whole run to take < 5 s; the hosted macos-26 runner took 6.2–6.4 s twice (every test running at that moment was slow, pure validation included). The bound is now 30 s: far below the 60 s the child sleeps, so the test still proves the child was stopped. **Verify:** the suite passes locally; CI green on `main`. *Fix committed with Bryan's approval.*
- [x] Release 0.3.2 (authorized by Bryan for this delivery: commit, push, tag, signed and notarized release, cask bump, `brew upgrade` here). **Verify:** brew shows 0.3.2; spctl Notarized Developer ID; `--diagnose` passes with the gh section. *Done: CI green on 18c4cd6, tag v0.3.2, signed and notarized DMG published (sha256 102e23d2…), cask 0cd5091, `brew upgrade` here shows 0.3.2, spctl Notarized Developer ID, `brew audit --online` passes; signed `--diagnose`: version 0.3.2 (22), keychain probe passed, gh ready with one account. Pending: manual — Bryan checks the window with no repository selected and the SSH aliases section after logging in the second account.*

### v0.4.0 (proposed): bulk actions, copy between scopes, environment actions, repository configuration in chat (requested by Bryan, 2026-10-15)

Decisions (Bryan, 2026-10-15): Q1 deletions are staged and confirmed in Sync's deletion review (no immediate GitHub delete); Q2 copy and paste within the same repository only (other projects go through chat or file); Q3 the receiver of a repository configuration can **Import into…** an existing repository and **Save as File…** (encrypted `.fxvault`), no plaintext `.env` export from chat; Q4 (default) secrets without a value are copied and shared by name and stay "Value missing", as Duplicate environment does.

Request: select several secrets/variables and delete them (also on GitHub); copy and paste between repository level and environments; create and delete environments; send a whole repository's configuration through the chat so a friend can import it into a project they already have or keep it as a file. Constraint from Bryan: some accounts lack access to some things, so every action follows the account's permission and says why it is unavailable instead of hiding it.

What exists (mapped 2026-10-15): the table already allows ⌘/⇧-click multi-selection but nothing uses it (context menu only for one row); delete is one item at a time, staged as a tombstone and deleted on GitHub by Sync after the §7.5 review; Convert or Move… moves one item within the repository; Duplicate environment copies into a new environment only; environments can already be created (admins), renamed, duplicated and deleted (scope list context menu, synced with the §7.5 review); chat attachments are one item with a value; whole-repository sharing exists only as `.fxvault` file / Nearby Share and imports only into the same `owner/name` (GitHub id must match).

- [ ] **Multi-select actions.** With 2+ rows selected: a selection bar above the table ("3 selected" · Copy to… · Revert · Delete…), the same items in the context menu, ⌫ deletes, ⌘A selects all. One transaction for the batch (`ConfigRepository` bulk delete/revert over the existing internal `batch`). Rows the account cannot edit are skipped with the reason. **Verify:** RepoDetailViewModel tests (selection actions, mixed synced/unsynced, read-only scope), ConfigRepository bulk tests (one transaction, revert restores all).
- [ ] **Delete on GitHub.** Bulk delete stages GitHub deletions (synced items) and removes never-synced items; the confirmation names the count and the first names; Sync shows them in the existing deletion review. **Verify:** view-model + SyncViewModel tests that N deletions reach the review and "Sync Without Deleting" keeps them pending.
- [ ] **Copy between scopes.** ⌘C on selected rows copies them to an in-app clipboard (values never go to the system pasteboard; cleared on lock); ⌘V in another scope pastes them (or "Copy to…" picks the scope); conflicts: Skip / Overwrite / Overwrite All; values are decrypted and re-encrypted inside the vault; the target must be editable by the account. Plain-text ⌘V keeps opening the .env import. **Verify:** ConfigRepository copy tests (repo level ↔ environment, environment ↔ environment, conflicts, value-missing secrets, permissions), paste-routing tests (items vs .env text).
- [ ] **Environment actions in plain sight.** An environment menu (•••) in the detail header (Settings, Rename, Duplicate, Delete…) next to the existing context menu; "New Environment" stays visible but disabled with "Needs admin access" for accounts without admin. **Verify:** ScopeListViewModel/RepoDetail tests for admin, write and read-only accounts.
- [ ] **Repository configuration in chat.** Attach a whole repository (repository level + environments, secrets with values, variables, branch policies) as one chat card, after Touch ID or the master password; the payload is the existing share package over the chat's encrypted channel (attachment limit raised to the share limit). The receiver's card offers **Import into…** (any repository in their vault, environments mapped by name, missing environments created only when their account is admin, everything else skipped with the reason) and **Save as File…**. **Verify:** SharingKit tests (package attachment round trip, size limit), ShareImportPlanner tests for a different target owner/name and for non-admin targets, chat view-model tests (reauth, card without values, save as file).
- [ ] Docs (ARCHITECTURE, SHARING-PROTOCOL, SECURITY-MODEL, DESIGN, CHANGELOG), full checks, release 0.4.0 only after Bryan says so.

### Stretch (v1.1, not in v1 scope)

- Drift UI for environment policies and patterns. Preflight still blocks policy pushes when the remote policy changed.
- Cheaper drift checks (native list commands expose no ETags; only the `gh api` environment reads could use them).
- Automatically suggesting SSH alias mappings from `ssh -T`.
- An fnmatch preview field in `BranchPolicyEditor`.
- Persisted sync history beyond the 24 h journal.

---

## 12. Testing strategy

### 12.1 Framework and coverage

- Swift Testing (`@Test`, `#expect`, parameterized tables) in every package target and in AppTests.
- `scripts/coverage.sh` runs `swift test --enable-code-coverage` and `llvm-cov report`, and fails below **85% line coverage** for VaultCrypto, SyncEngine, EnvTools and SharingKit. It runs in the blocking CI job.
- Tests that perform real Argon2id work are `.serialized`. Every other test uses `KDFParameters.testing`.

### 12.2 Fakes and seams

- `CommandRunning` → `FakeCommandRunner`: matches argv, scripts exit code, stdout (sanitized native `--json` and plain-text fixtures, `gh api -i` fixtures for environments) and stderr (recorded gh error texts), and records stdin.
- `BiometricKeyStoring` → `FakeBiometricKeyStore`.
- `IdleEventSource`, `LockSignalSource` → fakes.
- `Clock` → `ManualClock` (rate-limit backoff, verification retries, the 14-day rule).
- `KeyDeriving` → a fast fake plus a spy.
- `NearbyTransport` → `InMemoryTransportPair` and `RelayTransport` (MITM).
- Databases: an in-memory `DatabaseQueue()`, and a `DatabasePool` in a temp directory for disk tests.
- AppTests run in test mode (`AppContainer.preview`) with no side effects on the host.

### 12.3 Coverage by spec requirement

| Area | Tests |
|---|---|
| Encryption | FieldCipher KAT (independent, Python `cryptography`), AAD components including kind and scope, tamper cases, empty and 48,000-byte values, on-disk byte scan |
| Key wrapping | Argon2id KAT (independent, `argon2-cffi`), NFC, bounds before the KDF, wrap layout, wrong password, KDF parameter tamper, kcv, recovery codec, password change, rotation (old credentials cannot open new data), Touch ID invalidation and restart/14-day rules, keyring lock and generation |
| .env parsing | 40+ table cases, normalizer, credential classifier, serializer round-trip property, secure file creation, gitignore and tracked checks |
| Sync diff | Coalescing, normalization invariant, tombstone revival, swap, case-only rename, rename guards, env delete, pattern reset, force_push, blocked items, preflight remote change, planner ordering and dependencies, executor partial failure, indeterminate outcomes, fixed rate-limit backoff and 5xx, verification by `updatedAt` change and variable fingerprint, cancellation, journal seeding, trailing CR/LF normalization |
| Drift | Every kind times both resolutions, lists over 100 items, pending verification skip, deletion suppression |
| Sharing protocol | Regenerated nearby KATs, full run, MITM, commitment and suite mismatch, replay, reorder, truncation, direction, downgrade, low-order keys, oversize, timeouts, no auto-retry, minimal DECISION and RESULT; `.fxvault` KAT, tamper, bounds, headerLength; passphrase; validator; merge matrix including policy widening, kind collision, repo-id mismatch, replay, provenance |
| gh layer | Env allowlist; argv builder tests for every §8 op (`--repo=`/`--env=` forms, forbidden flags absent); stdin-only property test (random values never in argv, always on stdin); `GHStderrClassifier` table (native `HTTP nnn:`, `gh api` `gh: … (HTTP nnn)` / `gh: HTTP nnn`, `GraphQL:`, fragments, 401 before "gh auth login", exit codes 1/2/4); JSON decoding of native `--json` fixtures (`auth status`, `repo list`, `repo view`, `secret list`, `variable list`) and plain-text `org list`/templates; `gh api` `-i` parser and `--paginate --slurp` decoding for environments; percent-encoding and dot-segment rejection; version floor 2.97.0; shell probe captures only allowlisted keys; SSH parser and alias validation; gh path permissions |
| App | Onboarding, Lock, Preferences (every phase), Sync, ItemEditor, EnvImport, Export, Share and Nearby view models; ReauthGate is called on every gated path |

### 12.4 Fixture hygiene (public repo)

- Fixtures come **only** from the throwaway spike repos, using synthetic values (`FXV_FIXTURE_*`).
- `scripts/sanitize-fixture.sh` rewrites owner, repo, environment and item names (and repo node ids) to placeholders in stdout, stderr and `-i` fixtures, replaces values with deterministic dummies, and strips `x-github-request-id`, `etag`, `x-ratelimit-*` and `set-cookie`.
- `scripts/check-fixtures.sh` runs gitleaks (pinned) and a denylist (`FractalX-Technologies`, `admin-fractalx`, `QYKC498D5D`, real repo names) over `Tests/Fixtures` and `docs/research`. It runs in CI and before each milestone ends.
- Public OpenAPI extracts (`ops_compact*.json`) are kept as they are. Everything else copied from the scratchpad is reviewed by hand first.

### 12.5 Manual checklist (`docs/RELEASING.md`, each with screenshot evidence)

- Touch ID (enable, unlock, cancel, re-enrollment, restart requirement)
- locks on sleep, screen lock, idle and window close
- clipboard clearing
- Layout on macOS 14 and 27 (narrow and wide windows)
- Local Network prompt from a fresh user account
- Gatekeeper and `spctl`
- Sonoma smoke test
- import, sync and drift on the spike repos

---

## 13. Decisions (answered 2026-10-14)

1. **Signing and notarization (Q1): decided.** Team **QYKC498D5D** signs with Developer ID. Bryan creates the explicit App ID `io.fractalx.fxvault` (Keychain Sharing) and a Developer ID provisioning profile; notarization uses an **App Store Connect Team API key**. Every official release is signed and notarized; ad-hoc builds exist only for forks, without Touch ID (D14, D25).
2. **GitHub access (Q2): decided.** Bryan: *"Debemos usar el cli de github, no usaremos api ni nada. Todo sera por terminal y el cli de github"* (everything through the terminal and the GitHub CLI). Applied as: native gh subcommands for everything they cover; `gh api` only for environments and deployment branch policies (spec §4); no local sealing, no `gh api` for secrets, variables, repos or orgs, no direct HTTP (D4). Consequences: gh floor 2.97.0 (D5), values on stdin only and one call per item (§5.10, D12), trailing newline normalization (D32), errors classified from stderr and exit codes (§8 E), verification by native re-list (D13), outside-collaborator repos (user- or org-owned) added by name (§2). This satisfies spec §4 literally, so it is no longer a spec deviation.
3. **Nearby transport (Q3): decided.** Network framework (`NWListener`/`NWBrowser`/`NWConnection`) behind `NearbyTransport` (D22). Approved spec deviation; display names travel in cleartext on the LAN, which is documented.
4. **Repo owner (Q4): decided.** `FractalX-Technologies/fx-vault`; cask in `FractalX-Technologies/homebrew-tap` (`brew install --cask fractalx-technologies/tap/fx-vault`).

**Remaining open items:**

5. **Renaming an environment that already exists on GitHub (Q5).** *Default adopted (spec requires rename); Bryan can override.* Guided "Rename (recreate on GitHub)": verified, blocked while any value is missing, and the old environment is deleted only through a separate confirmation (D20, §7.6). Alternatives: rename only before the first sync, then Duplicate plus Delete; or no rename.
6. **Write spike (Q6).** *Asked at the start of M3, before any GitHub write.* Scope (§11 M3): identical-value set and `updatedAt`, Free-plan private environment and branch-policy errors as gh prints them, environment DELETE semantics, whether fields omitted from an environment PUT keep existing reviewers, value normalization through gh (including empty values), gh's stderr for 403/404/422/SAML/rate limits, whether a WRITE collaborator can list, set and delete repo-level secrets and variables, and what an already-existing branch-policy POST returns (200 after a followed redirect, or 303).
   - (a) Approve creating `fx-vault-spike-private` (FractalX-Technologies, Free org) and `fx-vault-spike-public` (admin-fractalx). You delete them afterwards, since the token has no `delete_repo` scope.
   - (b) Use repos you name.
   - (c) Skip the spike and rely on defensive handling.
   - **Recommended:** (a).

**Bryan actions (not decisions):**
- Phase 0: `brew upgrade gh` (≥ 2.97.0), create `FractalX-Technologies/fx-vault`, log in a second gh account, and decide where the root `.env` should live. (Claude runs `git init`, no commit.)
- M1: App ID and Developer ID profile.
- M3: invite the second account as a write collaborator on the spike repo.
- M4: approve each demo repo.
- M7: public repo settings, the `release` environment secrets, and installing the tap GitHub App.

---

## Review

### Milestone 1 - Review

- Shipped: the XcodeGen project, the FXVaultKit package, the vault (create, password and Touch ID unlock, lock, change password, recovery reset that always rotates the DEK, Reset vault), ReauthGate, auto-lock, the clipboard manager, Onboarding, Lock, Recovery reset and Preferences, and CI (`macos-26` blocking, `xcode-27`, gitleaks). VaultCore 88, VaultCrypto 90 and VaultStore 64 tests, with KATs from independent Python generators.
- Deviations: `Clock` became `VaultClock`; `LAError.userFallback` maps to `VaultError.passwordFallbackRequested` (ARCHITECTURE decision 18); a lock before a new recovery key is confirmed wipes it and leaves a reminder banner, and Reset vault is offered while locked (decision 19); test mode is checked by `AppSmokeTests`; fixture hygiene uses `check-secrets.sh`, gitleaks and a hashed denylist test instead of `check-fixtures.sh`.
- Gaps (never built): `.claude/rules/*.md`, `docs/research/`, `scripts/check-docs.sh`, `coverage.sh` (85% gate), `check-linkage.sh`, `smoke-launch.sh`, and SwiftFormat and strings checks in CI.
- Found late: the inactivity ticker crashed the app about 15 s after launch (MainActor check on a dispatch queue); fixed in 9bf1419.
- Manual checks pending: Touch ID on the signed build (RELEASING #1–5, #16), locks on sleep, screen lock, idle and window close (#6–9), clipboard (#10), layout screenshots on macOS 14 and 27 (#11); Bryan: second gh account and the root `.env` location.

### Milestone 2 - Review

- Shipped: the GitHubKit process layer (`posix_spawn` runner, allowlisted environments, login-shell probe, `GHLocator` trust checks, 2.97.0 floor), auth, token cache and scope checks, closed argv builders with `gh api` only for environments and branch policies, the stderr classifier (48 cases), the SSH config parser and alias test, the catalog with import and add by name, the sidebar, the repository detail view and `GHSetupScreen`. GitHubKit has 151 tests.
- Deviations: accounts live in `GitHubEnvironmentRepository` plus `AccountStore` (no `AccountsRepository`); GH setup offers Not Now (decision 20); variables are decrypted for the visible scope only (decision 22); an empty Personal group is hidden and accounts known only to the vault keep their repositories (decision 24); `errors[]` details of `gh api` responses now reach the classifier.
- Verified live (read-only): a Finder-like launch finds `/opt/homebrew/bin/gh` 2.102.0; the shapes of auth status, org list and repo list; `ssh -T` through the alias; secret and variable `updatedAt` have whole-second precision (a documented residual risk for writes less than a second apart).
- Known gaps: 14 classifier cases are still synthetic; repositories reached only as an outside collaborator must be added by name (documented limitation).
- Manual checks pending: everything that needs a second account (two accounts with scope status, a second SSH alias, collaborator add-by-name); the layout screenshot of the detail view.

### Milestone 3 - Review

- Shipped: `ConfigRepository` CRUD with coalescing and tombstones, the pure diff (at least 35 table cases), `SyncPreflight` with optimistic concurrency, `SyncPlanner`, the serial throttled `SyncExecutor` (values on stdin only, journal, verification by re-list, launch reconciliation), the item editor and the Sync sheet. SyncEngine has 167 tests.
- Deviations (ARCHITECTURE decisions 5, 6, 9, 10, 13, 14, 21, 25–27): preflight uses `RemoteBaseChecker`; `pre_write_updated_at` comes from the executor's per-scope re-list; an item rename deletes the old name only after the set is verified; pending-verification miss counts live in memory; one credential confirmation per run; editing a secret starts empty. Migration `v7_journal_fingerprints` was added before release so a value edited after an indeterminate push stays pending.
- Q6 is only partly answered: the write suite passed on a public repository and a Free-plan private repository, but the facts listed in the spike item are still open. Until they are confirmed, preflight blocks policy changes on environments that list other protection rules, and WRITE collaborators stay read-only for items.
- Docs: API.md still says the write spike was "Not run" next to the "Write run" results; fix after the rerun.
- Manual checks pending: the editor on narrow and wide windows on macOS 14 and 27; inviting the second account as a WRITE collaborator; spike repositories and the live write run with a report (RELEASING #15, #28).

### Milestone 4 - Review

- Shipped: migration v5, New Repository staging (nothing reaches GitHub before Sync), C1 that is never retried with adoption of timed-out creates, clone through the SSH alias (temporary sibling, then rename), the shared branch policy editor, pattern reconciliation (200 and 303 both count as success) and the guided environment rename.
- Verified live: a public repository created with README, `.gitignore` and license, environments with custom and protected-branch policies, a guided rename and a clone through the alias. On a Free-plan private repository, C2 PUT and environment secrets and variables succeed but C3 returns 404, which is now classified as plan-gated.
- Deviations (decisions 7, 8, 12, 17, 28–31, 35): a guided rename posts all its patterns; reconciliation deletes every GitHub pattern that is not wanted locally, including a teammate's; a synced environment rename is reported as a recreate on GitHub; staged repositories record the viewer as admin until the next Sync; Clone in the Sync result asks for a folder when none is set.
- Gaps: the plan-gated hint cannot be cleared by the user; the org-policy create error and the GraphQL "already exists" error have no view-model or executor tests.
- Manual check pending: New Repository and clone (RELEASING #26).

### Milestone 5 - Review

- Shipped: the pure `DriftDetector` (full re-list, journal suppression), `DriftRepository` (debounced check on open, stale-resolution check), the drift banner and review sheet, the `.env` parser (at least 40 cases plus a round-trip property), `.env` import, `.env` export (ReauthGate, 0600 `SecureFileWriter`, iCloud warning, hardened git checks) and Duplicate environment.
- Deviations (decisions 1–4, 15, 23, 32, 33): fingerprinting moved into `RemoteSnapshotModel`; secret Keep Local also records GitHub's `updatedAt`; a new `environmentPolicyModified` drift kind; timestamps compared within 1 ms; resolutions re-read the scope from GitHub; git uses the login-shell environment; export runs the git checks before the write; pasted `.env` text is cleared once parsed.
- Verified live: drift from a simulated teammate resolved once with Keep Local and once with Accept GitHub; `.env` export detected `.gitignore` rules in a real repository and wrote a 0600 file.
- Manual checks pending: the Touch ID prompt on export (RELEASING #17) and the `.env` file flows (#25).

### Milestone 6 - Review

- Shipped: the share package schema and validator, the `.fxvault` v1 codec (64-byte header as AAD, Argon2id 64 MiB), EFF passphrases, the merge planner and importer (re-encryption under the receiver's DEK, replay warning), the nearby protocol (commit-reveal X25519 with a 6-digit SAS and KATs checked against Python), `NWNearbyTransport`, and the share export, import and nearby sheets. SharingKit has 119 tests.
- Deviations (decisions 16, 34): an import re-plans inside the write transaction; an incoming variable without a value is skipped; an environment GitHub already lists is created as synced; the scope tree checks one node at a time. The KAT generators live in `SharingKitTests/Fixtures/kat/` rather than `docs/research/`.
- Nearby sharing ships as experimental: it has not been verified between two Macs.
- Manual checks pending: two signed builds on one network (RELEASING #24), the Local Network prompt from a fresh user (#12), opening `.fxvault` files with the window closed (#22) and share as file on a second Mac (#23).

### Milestone 7 - Review

- Shipped: the README, `scripts/make-dmg.sh`, `scripts/release-local.sh` (preflight, signing gates, notarization and stapling of the app and the DMG, publishing), `release.yml` (ad-hoc verification DMG plus an optional signed job), the cask template and `bump-cask.sh`, and RELEASING.md, CONTRIBUTING.md, CHANGELOG.md and SECURITY.md. v0.1.0 (beta, not the planned v1.0.0) is published with `FXVault-0.1.0.dmg` and its `.sha256`.
- Deviations: signing and notarization run only on Bryan's Mac, so the `release` environment has no secrets and releases carry no build attestation (the README says so); the tap is bumped by hand with `bump-cask.sh` instead of a bump job with a GitHub App; the ad-hoc CI job picks Xcode by glob on `macos-26`.
- Gaps: no `dependabot.yml` or `CODEOWNERS`; release immutability and a `v*` tag ruleset are not enabled, so `gh release verify-asset` is not offered; the README has no screenshots.
- Manual checks pending: the cask in the tap plus `brew audit` and `brew install`, the Sonoma VM smoke test (RELEASING #14), Gatekeeper on a downloaded DMG (#13), the full RELEASING.md checklist on the notarized build, and Bryan's README sign-off.
