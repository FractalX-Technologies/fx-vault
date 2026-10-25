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

Decisions (Bryan, 2026-10-15): Q1 deletions are staged and confirmed in Sync's deletion review (no immediate GitHub delete); Q2 copy and paste within the same repository only (other projects go through chat or file); Q3 the receiver of a repository configuration can **Import into…** an existing repository and **Save as File…** (encrypted `.fxvault`), no plaintext `.env` export from chat; Q4 (default) secrets without a value travel by name in shares as before; copy between scopes leaves them out and names them.

Request: select several secrets/variables and delete them (also on GitHub); copy and paste between repository level and environments; create and delete environments; send a whole repository's configuration through the chat so a friend can import it into a project they already have or keep it as a file. Constraint from Bryan: some accounts lack access to some things, so every action follows the account's permission and says why it is unavailable instead of hiding it.

What exists (mapped 2026-10-15): the table already allows ⌘/⇧-click multi-selection but nothing uses it (context menu only for one row); delete is one item at a time, staged as a tombstone and deleted on GitHub by Sync after the §7.5 review; Convert or Move… moves one item within the repository; Duplicate environment copies into a new environment only; environments can already be created (admins), renamed, duplicated and deleted (scope list context menu, synced with the §7.5 review); chat attachments are one item with a value; whole-repository sharing exists only as `.fxvault` file / Nearby Share and imports only into the same `owner/name` (GitHub id must match).

- [x] **Multi-select actions.** With 2+ rows selected: a selection bar above the table ("3 selected" · Copy to… · Revert · Delete…), the same items in the context menu, ⌫ deletes, ⌘A selects all. One transaction for the batch (`ConfigRepository` bulk delete/revert over the existing internal `batch`). Rows the account cannot edit are skipped with the reason. **Verify:** RepoDetailViewModel tests (selection actions, mixed synced/unsynced, read-only scope), ConfigRepository bulk tests (one transaction, revert restores all). *Done: `RepoDetailSelectionActions` (N selected, Push on Next Sync, Revert, Delete…, Deselect) in place of the add actions, `ConfigSelectionMenu`, ⌫ via `onDeleteCommand`, ⌘A verified in the real window; `ConfigRepository.deleteItems/revertItems/requestPush` in one `ItemEditBatch` transaction; tests: `ConfigBulkItemTests` (6), `RepoDetailSelectionTests` (5).*
- [x] **Delete on GitHub.** Bulk delete stages GitHub deletions (synced items) and removes never-synced items; the confirmation names the count and the first names; Sync shows them in the existing deletion review. **Verify:** view-model + SyncViewModel tests that N deletions reach the review and "Sync Without Deleting" keeps them pending. *Done: one confirmation names the rows on GitHub and the count removed at once; Sync's existing deletion review lists them (`syncReviewCountsEveryDeletion`), "Sync Without Deleting" keeps them pending (existing `syncWithoutDeletingLeavesThemOut`).*
- [x] **Copy between scopes.** ⌘C on selected rows copies them to an in-app clipboard (values never go to the system pasteboard; cleared on lock); ⌘V in another scope pastes them (or "Copy to…" picks the scope); conflicts: Skip / Overwrite / Overwrite All; values are decrypted and re-encrypted inside the vault; the target must be editable by the account. Plain-text ⌘V keeps opening the .env import. **Verify:** ConfigRepository copy tests (repo level ↔ environment, environment ↔ environment, conflicts, value-missing secrets, permissions), paste-routing tests (items vs .env text). *Done: ⌘C/⌘V and Copy To › (row menu, selection menu, selection bar); conflicts ask Replace / Keep Existing / Cancel; secrets without a value are left out and named (Q4 resolved this way: a value-missing copy would only add a blocked row); tests: `ConfigCopyItemTests` (6), `RepoDetailCopyTests` (6), `ClipboardManagerTests.itemNamesAreTransientAndRecognizedUntilSomethingElseIsCopied`.*
- [x] **Environment actions in plain sight.** An environment menu (•••) in the detail header (Settings, Rename, Duplicate, Delete…) next to the existing context menu; "New Environment" stays visible but disabled with "Needs admin access" for accounts without admin. **Verify:** ScopeListViewModel/RepoDetail tests for admin, write and read-only accounts. *Done: `ScopeActionsMenu` (••• in the detail header) reuses `ScopeContextMenu`; "New Environment" already stayed visible and disabled with "Environments need admin rights on the repository"; test `environmentActionsFollowThePermission` (ADMIN, WRITE, READ).*
- [x] **Repository configuration in chat.** Attach a whole repository (repository level + environments, secrets with values, variables, branch policies) as one chat card, after Touch ID or the master password; the payload is the existing share package over the chat's encrypted channel (attachment limit raised to the share limit). The receiver's card offers **Import into…** (any repository in their vault, environments mapped by name, missing environments created only when their account is admin, everything else skipped with the reason) and **Save as File…**. **Verify:** SharingKit tests (package attachment round trip, size limit), ShareImportPlanner tests for a different target owner/name and for non-admin targets, chat view-model tests (reauth, card without values, save as file). *Done as chat version 2 (`maxVer` 2 in HELLO, bound into the transcript; a 0.2/0.3 peer negotiates 1 and the Whole Repository tab explains the update; nothing is offered and no authorization is used). The payload provider rebuilds the package with the offer's entry ids and sends it only when every `value_fp`, the shape and the value states are unchanged. Import Into… plans the package for the chosen repository (owner, name, GitHub id from the vault row); a repository the account cannot change is listed with the reason and cannot be chosen (the planner does not check permissions, so the target list does: archived, or admin required when the package has environments). Save as File… reuses `ShareExportViewModel` (`.fileExport`, fresh passphrase) and keeps the package for a later import. Tests: SharingKit `NearbyChatConfigurationTests` (7) and `ShareRepositoryEntryIDTests` (2); VaultData `NearbyChatConversationTests` (3 new: import into another repository, offer withdrawn after a value change, saved as a file and still imported); App `NearbyChatViewModelTests` (7 new: names and counts, Import Into with target choice and preview, Save as File then import, closing/cancelling states, one sheet at a time, older peer, target permissions); visual snapshots for the picker, cards, target list, preview, Save as File and the selection bar (light and dark).*
- [x] Docs (ARCHITECTURE, SHARING-PROTOCOL, SECURITY-MODEL, DESIGN, CHANGELOG) and full checks. **Verify:** `scripts/ci-local.sh` passes. *Done: ARCHITECTURE decisions 71–76 and the SharingKit, VaultData and NearbyChat API notes; SHARING-PROTOCOL §7.1 (chat version 2) and the §8 compatibility table; SECURITY-MODEL §6 and §10.1; DESIGN (selection bar, repositories in chat); CHANGELOG Unreleased; strings synced (`sync-strings.sh --check` clean). Every ci-local step passed (package and app tests, lint, check-secrets) except the XcodeGen version gate: this Mac has XcodeGen 2.46.0 since Homebrew upgraded it on 2026-10-15 16:02, `.xcodegen-version` pins 2.45.4; `project.yml`, `FXVault.xcodeproj` and `Config/Info.plist` are unchanged from `main`, whose CI drift check passed with 2.45.4.*
- [x] Release 0.4.0 (authorized by Bryan on 2026-10-15: commit, merge to main, push, tag, signed and notarized build, cask bump, `brew upgrade` here; XcodeGen 2.45.4 from the pinned release zip, sha256-verified, used from a temporary folder because Homebrew had upgraded this Mac's to 2.46.0). **Verify:** brew shows 0.4.0; spctl Notarized Developer ID; `--diagnose` passes. *Done: CI green on 848705a (macos-26, xcode-27, gitleaks), tag v0.4.0, signed and notarized DMG published (sha256 f4eb22b1…), the release ran the full ci-local with the drift check, cask 5d219d6, `brew upgrade` here shows 0.4.0 (24), spctl Notarized Developer ID, `brew audit --cask --online` passes; signed `--diagnose`: version 0.4.0 (24), keychain probe passed, gh ready with one account. Pending: manual — a chat between two Macs on 0.4.0 (attach a whole repository, Import Into another repository, Save as File) and one with a 0.3.2 Mac (the Whole Repository tab explains the update).*

### v0.4.1 (proposed): copy across repositories, linked copies (requested by Bryan, 2026-10-15)

Decisions (Bryan, chat, 2026-10-15): every recommendation accepted (QL1 yes: copies stay linked, with Update everywhere); Claude takes the remaining decisions. Implementation authorized; commits still need Bryan's permission. Ships first; independent of the two sections below.

Request (Bryan, chat, 2026-10-15): some secrets and variables are reused in several repositories and environments. Select them, ⌘C, then ⌘V in other repositories and environments, and the copies must carry a visible mark so they are easy to identify. This reverses v0.4.0's Q2 (copy within the same repository only).

What exists (mapped 2026-10-15): ⌘C copies the selected rows to the in-app clipboard (names on the pasteboard as transient markers, never values; cleared on lock). ⌘V or Copy To › pastes into another scope of the **same** repository; anywhere else `RepoDetailViewModel.pasteCopiedItems` shows `main.detail.paste.otherRepository`. `ConfigRepository.copyConflicts` / `copyItems` run in one `batch(repositoryID:)` transaction; conflicts ask Replace / Keep Existing / Cancel; value-missing secrets are left out and named (`ItemCopyResultModel.withoutValue`). Fingerprints are row-bound (D11), so two rows cannot be compared without decrypting.

| # | Decision | Rationale |
|---|---|---|
| L1 | ⌘V and Copy To › accept any scope of any repository in the vault, whatever account it belongs to, when that account can edit the target (`requireEditable`). Values are decrypted from the source row and encrypted for the target row (its AAD) in one transaction on the target repository. Copy To › gets a searchable repository list. | The in-app clipboard is already app-wide; only the same-repository guard and the per-repository batch stand in the way. |
| L2 | Every paste **links** the source and its copies: `config_items.link_id` (shared by the group). Copying a linked item to a new place adds the copy to the same group; a Convert/Move or rename keeps the link on the row that now holds the item. Same value / Differs is computed when it is shown or used (decrypted in memory, compared in constant time, wiped), not stored. | The link is what makes copies identifiable. A stored group fingerprint was dropped (Claude, 2026-10-15): every value write path would have to keep it current, and the sync diff (D11) never needs it. |
| L3 | **Linked chip** on every member of a group with 2 or more places (a link symbol and the count); its popover lists each place (account · repository · scope) as Same value / Differs / Value missing / Pending and opens it. Row menu: Show Linked Copies, Unlink. | Seen at a glance in the table and explained on hover, without a new screen. |
| L4 | **Update everywhere:** saving a new value on a linked item offers "Also update 2 linked copies" (a checklist where the places that still had the old value are checked). Each one becomes an ordinary pending change, so one Sync pushes them all through the usual review (and, later, the space gates). | Rotating a shared key (for example a DSN used in 5 repositories) becomes one edit instead of five. |
| L5 | Links are local metadata: they never travel in shares, chat or `.env` files. Deleting a row takes it out of its group; Revert does not change links. | The share formats stay unchanged. |

Question (Bryan): **QL1** Do copies stay linked with Update everywhere, or do they only show a "copied" mark? **Answer: linked, with Update everywhere.**

- [x] **Copy across repositories (L1).** Paste and Copy To › for any editable scope in the vault; the notice texts that say "same repository" are rewritten. **Verify:** ConfigRepository tests (repository to repository, across accounts, environment to another repository's repository level, conflicts, value-missing secrets, a target the account cannot edit, the copy decrypts only as its target row); RepoDetail paste-routing tests (another repository pastes; the same scope still says so). *Done: `copyItems` reads sources by id from any repository inside one write on the target (`ItemEditBatch`), `isInPlace` replaces the scope-only check (repository level to another repository's repository level was skipped before); the copied items moved into `ClipboardManager` (`copyItems`, `itemsToPaste`, `forgetCopiedItems` on lock and quit), because the detail view model is rebuilt per repository; Copy To ends with "Another Repository…" (`CopyToRepositoryScreen`/`ViewModel`: accounts, search, scopes with the read-only reason, Replace / Keep, outcome with Show → `MainActions.open`). Tests: `ConfigLinkedCopyTests` (copy into another repository, another account, conflicts), `RepoDetailCopyTests` (paste into another repository, Another Repository… presents the sheet, texts), `CopyToRepositoryViewModelTests` (list, search, source scope left out, copy and Show, Replace).*
- [x] **Links (L2, L5).** Migration `v9_item_links` (`link_id`, a partial index, CHECK with `IS NULL OR` first, lessons); the link follows Convert/Move and tombstone revival. **Verify:** migration test from a v8 database; writer tests (move and rename keep the link; revert and delete leave it); no link data in share or export output. *Done: `MigrationTests` (step by step from every version, seed read back), `ConstraintTests.linkIDIsAUUIDOrNull`, `ConfigLinkedCopyTests` (move and rename keep the link, a deleted copy leaves the count, Duplicate does not link). Share and export formats were not touched (no field added), so no link can travel.*
- [x] **Linked chip and popover (L3).** **Verify:** view-model tests (count, the four states, open a place, Unlink); light and dark snapshots. *Done: `LinkedChip` and `LinkedCopiesPopover` (`LinkedCopiesView.swift`), Show Linked Copies and Unlink in the row menu; tests: `ConfigLinkedCopyTests` (comparisons `.same`/`.differs`/`.valueMissing`/`.unknown`, read-only `editBlock`, Unlink clears a last partner), `RepoDetailCopyTests.linkedCopiesPopoverListsOpensAndUnlinks`; snapshots `main-linked`, `linked-popover` (light and dark) reviewed.*
- [x] **Update everywhere (L4).** **Verify:** view-model and ConfigRepository tests (the default checks follow the old value; every checked place becomes pending in one transaction; unchecked places are untouched; places the account cannot edit are listed with the reason). *Done: the item editor's "Linked copies" field (shown once a new value is typed), `updateLinkedCopies(from:to:)`; tests: `ConfigLinkedCopyTests` (pending changes, value-missing fill with a requested push, all or nothing with a read-only target, a stranger refused), `CopyToRepositoryViewModelTests` (checked copy updated, differing copy untouched, unchecking leaves the copy); snapshot `item-editor-linked` reviewed.*
- [x] **Docs and checks.** ARCHITECTURE (L1–L5), DATABASE (`v9_item_links`), SECURITY-MODEL (links are plaintext metadata), DESIGN (chip, popover, update sheet), README, CHANGELOG. **Verify:** `scripts/ci-local.sh` passes. *Done: ARCHITECTURE decisions 77–80 and the Config/RepoDetail notes, DATABASE `v9_item_links`, SECURITY-MODEL §2 and §7, DESIGN, STRUCTURE, README, CHANGELOG Unreleased; strings synced (`sync-strings.sh --check` clean, the three replaced keys removed). Each ci-local step run separately (this Mac has XcodeGen 2.46.0; the pinned 2.45.4 from the sha256-verified release zip regenerated the project with no change): package tests, app build and the full app suite (549 tests) pass, `lint.sh` OK, `check-secrets.sh` OK.*

### v0.5.0 (proposed): teammates nearby in the main window, ping (requested by Bryan, 2026-10-15)

Decisions (Bryan, chat, 2026-10-15): every recommendation accepted (QT1 Teammates, QT2 toolbar); Claude takes the remaining decisions. Implementation authorized; commits still need Bryan's permission. Ships before shared spaces (v0.6.0), which reuse its device identity, pairing and discovery.

Request (Bryan, chat, 2026-10-15): take nearby people out of the Nearby Chat window. While someone uses the app, the people nearby appear by themselves as bubbles in the main window (one or several), without searching for them, and you can ping one so that their Mac plays a sound.

What exists (mapped 2026-10-15): Nearby Chat is a separate window. The Mac advertises the user's display name (`_fxvault-chat._tcp`, link-local, LAN and AWDL) **only while that window lists people**, and every connection needs the 6-digit code (SECURITY-MODEL, "Unwanted visibility"). No identity survives a session, so a person cannot be recognized the next time.

| # | Decision | Rationale |
|---|---|---|
| T1 | **Device identity:** each vault gets an Ed25519 signing key and an X25519 agreement key (CryptoKit), stored encrypted in the vault under a new HKDF subkey of the DEK (`fxvault/v1/device-key`). | Works in ad-hoc builds (no keychain entitlement) and is locked with the vault. |
| T2 | **Teammates:** two Macs pair once by comparing the 6-digit code (the nearby commit-reveal handshake with a new purpose `.team`); each then keeps the other's public keys, GitHub login (as claimed), display name and Mac name. Preferences › Teammates lists and removes them. | As in Nearby today, the code check is what binds a key to a person, but it happens only once. |
| T3 | **Discovery:** one Bonjour service `_fxvault-team._tcp` (LAN and AWDL). A Mac visible to teammates advertises a rotating pseudonym (an HMAC of a per-pair key and a 15-minute window) that only its teammates recognize; strangers see a random name. Teammates connect with a paired handshake (static keys plus ephemeral X25519, transcript signed with Ed25519), with no code. | Being visible all day must not broadcast your name to everyone in Wi-Fi range. |
| T4 | **Who can see me** (Preferences › Nearby): Nobody / **Teammates** (default) / Everyone nearby. Everyone nearby also advertises the display name, as the chat window does today, and lists the other people who chose it; they appear without the teammate dot and can be offered a chat (with the code) but not pinged. | Strangers cannot send pings; the open behaviour stays available on purpose. |
| T5 | **Bubbles:** an avatar stack in the main window's toolbar, next to the Sync pill: one circle with initials per person (Theme tokens), a dot for teammates, "+N" after 4. A person appears with a short scale-in when detected and leaves 30 s after the last sighting, so bubbles do not flicker. A click opens a popover with the name, the Mac, when they were last seen, **Ping** and **Chat**. | Visible while working, no search, in a place macOS users know from shared documents. |
| T6 | **Ping:** a signed PING over the paired handshake, teammates only. The receiver plays a sound and bounces the sender's bubble; when FX Vault is not frontmost it posts a notification with the sound ("Bryan pinged you", with Ping Back), so Focus and Do Not Disturb apply. Limits: 1 ping per teammate every 10 s and 5 per minute; Mute per person and for everyone. | A tap on the shoulder, not a noise source. |
| T7 | **Chat from a bubble** opens Nearby Chat already connected. With a teammate the paired handshake replaces the code (chat version 3); with someone from Everyone nearby, today's code flow (version 2). | One click from seeing someone to talking to them. |
| T8 | **Energy:** advertise and listen while FX Vault runs with the vault unlocked (so pings arrive); browse only while the main window is visible; everything stops on lock, sleep and screen lock. | Browsing over peer-to-peer Wi-Fi costs battery and can add Wi-Fi latency, and nothing can run while the keys are locked. |

Questions (Bryan): **QT1** Is the default visibility Teammates or Everyone nearby? **Answer: Teammates.** **QT2** Do the bubbles go in the toolbar or float in a corner of the window? **Answer: the toolbar.**

- [x] **Device identity and teammates (T1, T2).** Migration `v10_teammates` (`device_identity`, a single row, and `teammates`); pairing purpose `.team` with its own labels and Bonjour type (`NSBonjourServices` in `project.yml`). **Verify:** pairing tests over `InMemoryTransportPair` (a relay with different codes fails; confusion with share or chat is rejected); keys wiped on lock; KAT vectors cross-checked by `Fixtures/kat/crosscheck.py`. *Done differently: pairing is purpose `.pair` (`_fxvault-pair._tcp`, `fxvault/pair/v1`), presence is `.team`. Keys are sealed as secret fields (`SecretFieldAAD`, `UnlockedKeys.seal/open`) and re-sealed by DEK rotation. Tests: `TeamProtocolTests` (cards, keys, pairing, self-pairing refused, pairing vs chat labels), `TeamKATTests` (Swift byte for byte against `crosscheck.py --write-team`; Python's Ed25519 signatures verify in CryptoKit), `TeamRepositoryTests` (created once, survives lock, sealed announce keys, removal renews the announce key, card updates, DEK rotation), `MigrationTests`, `ConstraintTests.teamTablesCheckIdsKeysAndFlags`, `SecretFieldTests`.*
- [x] **Discovery and paired handshake (T3, T4).** **Verify:** pseudonym tests (a teammate recognizes it, a stranger sees a random name, it rotates every window); handshake tests (unknown key refused, replay refused, KATs); visibility tests (Nobody advertises nothing; Everyone nearby lists strangers without Ping). *Done: `TeamPseudonym`/`TeamPresenceMatcher`, `TeamSessionMachine` (SIGMA-style, responder hidden from non-teammates), `TeamRouter` preamble routing, `NWTeamListener`; `NearbyChannel` extracted from `NearbyKeyExchange` (all 214 earlier SharingKit tests still pass). Added a CARD_UPDATE request so remaining teammates learn the renewed announce key. Tests: `TeamProtocolTests` (stranger refused before the responder reveals itself, AUTH meant for another teammate refused, tamper/replay/malformed, card update and forged card), `TeamPresenceTests` (pseudonym advertised, teammate recognized, stranger ignored, Nobody, Everyone nearby, grace period).*
- [x] **Bubbles (T5).** `NearbyPresenceModel` (appear, 30 s grace, overflow, order) and the toolbar view. **Verify:** model tests with an injected clock; view-model tests; light and dark snapshots at the minimum window width, reviewed in the app's own window (lessons). *Done as `TeamPresenceManager` (+ `NearbyPersonModel`) and `NearbyPresenceView` in both toolbars; snapshots `presence-bubbles`, `presence-popover` reviewed. Pending: manual — the main window on screen at its minimum width with bubbles (needs two Macs).*
- [x] **Ping (T6).** PING frame, rate limits, and sound and notification managers behind protocols. **Verify:** protocol tests (a teammate's ping arrives; stranger and replayed pings are refused; limits hold); manager tests with fakes (frontmost plays the sound, background posts the notification); manual check on two Macs. *Done: `PingAlerting` (`SystemPingAlerts`, `RecordedPingAlerts`); tests: `TeamPresenceTests` (ping delivered and alerted, cooldown, muted and Mute all bounce silently, 5 per minute). Pending: manual — two Macs, frontmost sound and background notification.*
- [x] **Chat from a bubble (T7).** Chat version 3 for teammates; version 2 unchanged. **Verify:** chat protocol tests (version 3 without a code between teammates, version 3 refused for an unknown key, a version 2 peer negotiates 2); view-model test that opens the chat from a bubble. *Done: TEAMMATE_IDENT (chat v3); the chat reaches the teammate through its presence (`PreambleTransport`, preamble `chat`), handed to the Nearby Chat window through `AppViewModel.startChat` (one-slot mailbox); "Teammate" chip in the chat header. Tests: `TeamProtocolTests` (teammates skip the code, a stranger compares it, an older peer compares it), `TeamPresenceTests.teammatesChatWithoutTheCode` (two chat windows reach `.chatting` with nobody pressing Codes match).*
- [x] **Docs and checks.** SECURITY-MODEL (device keys, teammates, visibility modes, pings; "Unwanted visibility" rewritten), SHARING-PROTOCOL (pairing, pseudonyms, paired handshake, chat version 3, ping), DATABASE (`v10_teammates`), ARCHITECTURE, DESIGN (bubbles, popover, Preferences › Teammates and Nearby), README, CHANGELOG. **Verify:** `scripts/ci-local.sh` passes. *Done: SECURITY-MODEL §2 and §10.2, SHARING-PROTOCOL §10, DATABASE `v10_teammates`, ARCHITECTURE decisions 81–88 and the SharingKit/VaultData/app notes, DESIGN, STRUCTURE, README, CHANGELOG; `NSBonjourServices` and the Local Network text in project.yml (Info.plist regenerated with the pinned XcodeGen 2.45.4); strings synced, lint, check-secrets and every test suite pass (see the v0.6.0 note for the full run).*

### v0.6.0 (proposed): shared spaces, one versioned source of truth between teammates, no cloud (requested by Bryan, 2026-10-15)

Decisions (Bryan, chat, 2026-10-15): every recommendation accepted (Q1–Q4 below), and Q4 "as safe as possible"; Claude takes the remaining decisions. Implementation authorized; commits still need Bryan's permission. Builds on v0.5.0 (device identity, teammates, discovery).

Request (Bryan, chat, 2026-10-15): two or more people who hold the same repository's or environment's secrets and variables stay in sync, with versions that show who changed what and when, so there is one source of truth between them. Everything stays local: no cloud, no server, no extra repository. Each push writes a version marker variable on GitHub, so a Mac that does not have that version knows it is behind and whom to get it from. **Before anything is pushed, FX Vault always syncs first, verifies, and only then pushes.**

What exists (mapped 2026-10-15): each vault is its own source of truth (§1). GitHub never returns secret values, so drift (§7.7) can say that a teammate changed a secret but cannot give the value: Accept GitHub clears it and asks for a fill, and Keep Local re-pushes the old value over the teammate's rotation. Sharing (`.fxvault`, Nearby Share, chat attachments) is a one-time copy. History is only the 24 h `sync_journal`, names only. Pieces to reuse: the nearby commit-reveal X25519 handshake with the 6-digit code and per-purpose labels (`NearbyPurpose`, `NWNearbyTransport` over the LAN and AWDL, `InMemoryTransportPair` for tests); CryptoKit (Curve25519 signing and key agreement, AES-GCM, HPKE on macOS 14); the D27 preflight re-list and the per-scope re-list before writes (`SyncPreflight`, `RemoteBaseChecker`, `SyncExecutor+Items`, `WriteVerifier`); the journal and launch reconciliation (`SyncReconciler`). Every variable listing goes through `GHCommandScheduler.listVariables` (B8/B9), so there is one place to split off the marker.

**Design (proposed)**

| # | Decision | Rationale |
|---|---|---|
| S1 | A **space** is one scope (repository level or one environment) of one repository (GitHub repo id) plus its member devices. "Share with Teammates" creates one space per chosen scope with the same members. Spaces are opt-in; a scope without one behaves as today. | One key, one log and one marker per scope. Someone can be in `staging` and not in `production`. |
| S2 | **Members are teammates** (v0.5.0, T1–T2): devices paired once with the 6-digit code, each with an Ed25519 signing key and an X25519 agreement key. A space adds no identity of its own. | One pairing serves spaces, bubbles, ping and chat. |
| S3 | **Versions, linear per space.** Version N = header {space id, N, parent hash, epoch, author device, time, signature} + payload {optional reason, item changes: set/delete, kind, name, value, fingerprint, GitHub `updatedAt` after verification}. The payload is AES-GCM under the space key of its epoch; the fingerprint is an HMAC under a key derived from the space key, so every member shows the same short fingerprint; hash = SHA-256 of header and ciphertext. A version is created only by a verified push and describes exactly what GitHub now holds; local edits stay drafts until then. Rollback = stage an older value; its push is a new version. | The marker (S4) serializes publishes, so numbers are linear. History is never rewritten. The database still holds no plaintext values, and names are encrypted too. |
| S4 | **Marker variable** `FXVAULT_SPACE`, in the scope it describes (a repository variable, or an environment variable), JSON of at most 512 bytes: `{"f":1,"space","v","state":"publishing\|published","head","by","dev","at","sig"}`, signed by the author device (`fxvault/v1/space-marker`). `at` is for display only; order comes from `v` and `head`. The name is reserved (validators refuse it for user items) and split off in `listVariables`: tables, drift, `.env` export and sharing never see it; capacity checks count it as one slot. | The only space data on GitHub: a number, a login, a time and a hash. It comes with the B8/B9 listing that preflight already runs, so the check costs no extra gh call. |
| S5 | **Pull, verify, then push** (Bryan's rule), inside Sync, for every scope with a space: (1) **catch up**: read the marker; if it is ahead of the local head, fetch the missing versions from any reachable member device; (2) **verify**: the marker's signature and author, every received version (signature, author is a member of its epoch, parent hash, number + 1), the marker's `head` equals the local head, and GitHub's listing equals the head version (secret `updatedAt`, variable fingerprint), which extends D27; (3) **claim**: write the marker `publishing` v+1 and re-read it; (4) **push** with the existing executor; (5) **record** version v+1 from what `WriteVerifier` confirmed; (6) **publish**: write the marker `published`, re-read it; (7) **send** v+1 to reachable members. A scope that fails (1)–(3) is blocked with its reason and nothing is pushed in it; other scopes still sync. | Nobody can push over a version they do not have. A race or an outside change is found before the push, or right after it at the latest, never silently. |
| S6 | **No cloud.** Versions travel Mac to Mac over v0.5.0's teammate discovery and paired handshake (T3: LAN and AWDL, no code, rotating pseudonyms), plus an optional per-member address (host:port, for example a Tailscale name) for Macs that are not nearby. Any member relays any version; signatures make relaying safe. Runs only while the vault is unlocked: on unlock, on app focus, every 2 min, and in S5 step (1). | Keeps "no server, no direct HTTP". GitHub only carries the marker. |
| S7 | **Members and keys.** Adding = choosing a teammate (v0.5.0, T2); the space key and the history reach that device over the paired handshake when it is reachable. Removing = a signed key rotation (new epoch; the new key is wrapped with HPKE for each remaining device, so it can travel through any member) plus a **rotation checklist** naming every secret the removed device received. All members are equal in v0.5. | Cryptography only cuts future access; the checklist is the honest part. |
| S8 | **Receiving a version** applies it to the vault in one transaction: values re-encrypted under the local DEK, each item marked synced with the version's `updatedAt`, value-missing secrets filled. An item with a local pending edit becomes a conflict: Keep Mine (stays a draft, published on top) or Take Theirs. | Closes the drift gap: a teammate's rotation arrives with its value. |
| S9 | **Drift in space scopes** has three answers: explained by a version (accepted silently); behind (the marker is ahead: "Get v9 from ana", and Keep Local / Accept GitHub are not offered, because they would overwrite or drop the new value); changed outside FX Vault (GitHub moved with no version for it: today's choices plus a warning, and the resolution becomes the next version). | The dangerous Keep Local over a teammate's rotation is no longer offered. |
| S10 | New target `SpaceKit` (pure: version log, marker codec, gate decision, peer protocol; depends on VaultCore and SharingKit's transport). Persistence in VaultStore (migration `v11_spaces`, `SpaceStore`), orchestration in VaultData (`SpaceRepository`). SyncEngine sees only an injected `SyncSpaceGating` protocol. *As built: the core lives in SharingKit `Space/` (it needs the device keys and sessions SharingKit owns); SyncEngine sees `SyncSpaceCoordinating` and VaultCore's `SpaceGateDecision` only (ARCHITECTURE decision 89).* | SyncEngine stays independent of the transport, and the gate is a pure function that table tests can cover. |

**Questions (Bryan), answered 2026-10-15:**
- **Q1** While a scope is behind, is every push in it blocked, or are pushes of items the missing versions did not touch allowed? **Answer: blocked (strict).**
- **Q2** Does a new member receive the full history with old values, or only the current state plus the names and dates of older versions? **Answer: the full history** (rollback needs it).
- **Q3** Can another member take over a `publishing` claim older than 15 min (`Timeouts.spaceClaimStale`) after an explicit confirmation recorded in the next version or can only its author finish it? **Answer: yes, after the confirmation.**
- **Q4** Remote Macs by address (Tailscale or similar) in v0.6 or later? **Answer: in v0.6, as safe as possible:** off by default and turned on per teammate on **both** Macs; used only for space sync (no ping or chat); no Bonjour for it; the listener accepts only the paired handshake from a teammate who has it on and closes anything else before any space data; the outgoing side connects only to the address typed for that teammate and aborts unless the peer proves that teammate's key; failed attempts back off per source (5 failures close the listener for 10 min); each remote session shows in Members with the address and time.

- [x] **Space crypto.** Space keys per epoch encrypted under the DEK with an AAD that binds space id and epoch; version header signing and hashing; space fingerprints; HPKE wraps for rotation; domain labels `fxvault/v1/space-*`. **Verify:** SpaceKit tests (sign and verify; a tampered header, payload or parent hash is rejected; a wrong epoch key is rejected); KAT vectors in `SpaceKitTests/Fixtures/space_kat.json`, cross-checked by `Fixtures/kat/crosscheck.py` as the nearby ones are; keys are wiped on lock (lock test). *Done (labels are `fxvault/space/v1/*`): SharingKit `Space/` (SpaceLog, SpaceKeychain, SpaceCrypto, SpaceVersionBuilder), keys sealed with `SecretFieldAAD` (space id ‖ epoch) and re-sealed by DEK rotation. `SpaceProtocolTests` (chain, tamper, epochs, membership), `SharingKitTests/Fixtures/space_kat.json` from `crosscheck.py --write-space` (HKDF, AES-GCM, Ed25519 and HPKE from Python's `cryptography`; `SpaceKATTests` reproduces the bytes, verifies signatures and opens the HPKE wraps), `SpaceRepositoryTests` (keys unreadable while locked, survive a DEK rotation).*
- [x] **Migration `v11_spaces`.** `spaces` (scope, repository, epoch, head version and hash, last marker seen), `space_keys` (per epoch, ciphertext), `space_members` (teammate, address, added and removed version, last synced), `space_versions` (header, payload ciphertext, signature, hash; unique per space and version). No plaintext values; CHECK constraints test `IS NOT NULL` before comparing (lessons). **Verify:** migration test from a v8 database; `SpaceStore` tests (append only, unique version, cascade when the repository is removed). *Done as `spaces` (with `claimed_version`), `space_keys`, `space_versions` (the signed wire form) and `teammate_addresses` (members live in the signed log, not in a table; addresses are per teammate, Q4). `MigrationTests` (every step from v1, frozen ids), `ConstraintTests.spaceTablesCheckVersionsHashesAndAddresses` (CHECKs with explicit `IS NULL`, one space per scope, unique version, cascade).*
- [x] **Marker (S4).** Codec (canonical JSON, at most 512 bytes, signature); `FXVAULT_SPACE` reserved in `GitHubNameValidator` and split off in `GHCommandScheduler.listVariables` (returned beside the listing, never in it); marker writes go through the same scheduler, throttle and journal. Fixtures use `owner-a` / `user-a` names only (lessons). **Verify:** codec tests (unknown format, oversize, bad signature, unknown author, `v` going backwards); listing tests (no table, drift, export or share sees the marker; capacity counts it; a user item named `FXVAULT_SPACE` is refused); journal rows for marker writes. *Done: `SpaceMarkerModel`, `NameRule.reservedName`, `listVariableScope` / `splitSpaceMarker`, `setSpaceMarker` (same queue and throttle). Not journaled: `spaces.claimed_version` records a claim until its `published` marker is confirmed and `SpaceClaimReconciler` finishes it at unlock (decision 91). Tests: `SpaceProtocolTests` (codec, signature, unknown author), `SpaceKATTests` (canonical JSON from Python), `CommandBuilderTests.spaceMarkerCommands` / `listingsSplitTheSpaceMarkerOff`, `GitHubNameValidatorTests`, capacity in preflight counts the marker slot.*
- [x] **Gate: pull, verify, then push (S5).** Pure `SpaceGate.decide(marker:localHead:versions:remote:)` → `.upToDate | .behind(by:login:) | .publishing(by:since:) | .forked | .changedOutside(items) | .invalidMarker | .markerMissing`. `SyncPreflight` runs catch-up and then the gate for each space scope and blocks with new `SyncBlockReason`s (`spaceBehind`, `spacePublishing`, `spaceForked`, `spaceChangedOutside`, `spaceMarkerInvalid`). The executor claims before the scope's first write, re-reads the claim, records the version from `WriteVerifier`'s results, then publishes and re-reads. Partial failure: the version holds only verified items and the rest stay pending. A crash between claim and publish is finished by launch reconciliation from the journal. **Verify:** gate table tests for every state; executor tests with the fake runner: the claim is written before any item write; a claim lost on re-read stops the scope before any write; another member claiming between publish and re-read is reported as forked; a partial failure publishes only verified items; a crash after the push, then a relaunch, publishes; a behind scope pushes nothing while the other scopes of the same run still sync. *Done: `SpaceGate.decide` → `SpaceGateDecision` (clear, ahead, behind, publishing(isStale), forked, invalidMarker, notAMember; "changed outside" stays D27's `remoteChanged`), `SyncBlockReason.space` / `.sharedEnvironment`, claim and re-read before the first write, publish and re-read after the repository's steps, takeover after a confirmation (Q3). Tests: `SpaceProtocolTests` (11 gate cases), SyncEngine `SpaceSyncTests` (behind scope blocked while another scope syncs, claim before the first write and publish after, lost claim, definitive claim failure, stale takeover, failed publish kept for reconciliation, forked after publish, shared environment rename blocked, launch reconciliation), VaultData `SpaceRepositoryTests` (end to end over one simulated GitHub, partial failure, crash then unlock).*
- [x] **Peer sync (S6).** Over v0.5.0's discovery and paired handshake (T3). Protocol: HELLO with each space's head, send the versions above the peer's head, verify each before storing, abort on any failure (Nearby's frame limits); optional address per member. **Verify:** protocol tests over `InMemoryTransportPair` (catch up 1 and N versions; relay through a third device; an unknown device is refused; a tampered version is refused and nothing is stored; forked heads are reported; replay, reorder and oversize abort); manual: two Macs on one Wi-Fi, two Macs over AWDL with no network, two Macs through a VPN address. *Done in code: spaces service `0x03` (SPACE_HEADS, SPACE_FETCH, SPACE_VERSION, SPACE_CHUNK), pull-only with pull-back, whole logs for new spaces; `SpaceSyncManager` (seen nearby, every 2 min while active, after a publish, Get Updates); remote listener and outgoing address (Q4). Tests: `TeamSpaceSyncTests` (catch up N, new space as a whole log, non-member, up to date, service split, chunk overrun, malformed bodies, addresses, backoff), `SpaceRepositoryTests` (relay through a third Mac, tampered version stores nothing, forked, gap, busy), AppTests `SpaceSyncTests` (two Macs over the fake nearby network: share, pull-back, Get Updates; remote listener on for allowed teammates only). Pending: the three manual two-Mac checks.*
- [x] **Received versions (S8) and drift (S9).** One transaction per version; conflicts listed in a "Teammate changes" review (Keep Mine / Take Theirs); drift's new kinds and texts. **Verify:** VaultData tests (a value-missing secret is filled; a pending edit becomes a conflict; an applied item is not reported as drift); DriftDetector table tests for explained, behind and changed outside. *Done differently: received versions apply the newest snapshot in one transaction; a local draft stays on top (Keep Mine) and is named in the "Got v7 from Ana" notice; Take Theirs is History › Restore This Value (no separate review sheet). Drift: findings in a scope whose marker is ahead are a teammate's change (no Keep Local / Accept GitHub, Get Updates instead); explained findings disappear once the version is applied; changed outside stays the existing findings. Tests: `SpaceRepositoryTests` (missing secret filled, draft kept on top, drift behind then explained), AppTests drift copy through `DriftReviewViewModel`.*
- [x] **Members (S7).** Add (choose a teammate), remove (rotation, HPKE wraps, rotation checklist), list (login, Mac name, version, last synced, address). **Verify:** a removed device cannot decrypt versions of the new epoch; a rotation reaches a member through a relay; the checklist names every secret the removed device received. *Done: `addMembers` (whole history), `removeMembers` (new epoch, checklist), both claiming and publishing the marker; the space sheet's Members tab. Tests: `SpaceRepositoryTests` (added member gets the history and relays, removed member stores but cannot open the next epoch and becomes `.notAMember`, checklist), AppTests (remove from the sheet).*
- [x] **UI.** Scope menu › Share with Teammates… (choose scopes; requires the scope fully synced with no value-missing secrets, otherwise says what to fix); a space chip in the detail header (Shared · v7 / Behind · v9 by ana / ana is publishing / Changed outside FX Vault); History (per scope: versions with author, Mac, time, reason and changed names; per item: versions with a short fingerprint, Reveal after Touch ID or the master password, Restore This Value); Members; the Sync sheet shows each scope's space state, a "Get Updates from Teammates" action and an optional "What changed?" note. **Verify:** view-model tests per screen and state; light and dark snapshots; a manual pass in the app's own window. *Done: `ShareSpaceScreen`, `SpaceScreen` (History, Members, Reveal with Touch ID or the password, Restore), the scope row symbol and the "Shared · v7" chip (behind and publishing are shown in the Sync sheet and drift review rather than on the chip), the Sync sheet (one issue per blocked shared scope with Get Updates or Take Over…, "What changed?"), Preferences › Teammates › Outside this network, the notice under the bubbles. Tests: AppTests `SpaceSyncTests`, `SyncSpaceSheetTests`; snapshots `space-share`, `space-history`, `space-members`, `sync-summary-space`, `settings-teammates-remote` (light and dark, reviewed). Pending: a manual pass in the app's own window.*
- [x] **Docs and checks.** SECURITY-MODEL (space keys and epochs, marker, peer sync threat table, residual risks below), SHARING-PROTOCOL (version format, marker, space protocol, KATs), DATABASE (`v11_spaces`), API (marker reads and writes), ARCHITECTURE (S1–S10, SpaceKit), STRUCTURE (new target), DESIGN (screens), README (Shared spaces, experimental), CHANGELOG. **Verify:** `scripts/ci-local.sh` passes. *Done: SECURITY-MODEL §2, §6, §9, §10.3; SHARING-PROTOCOL §11; DATABASE `v11_spaces`; API (B8/B9 split, the marker write, callers); ARCHITECTURE decisions 89–98 and the SharingKit, SyncEngine, VaultData and app notes; STRUCTURE; DESIGN; README; CHANGELOG. Checks run step by step (2026-10-16), since `ci-local.sh` needs XcodeGen 2.45.4 on PATH and Homebrew has 2.46.0: project regenerated with the pinned 2.45.4; `swift test` (every package suite); xcodebuild test, ad-hoc: **577 app tests in 51 suites passed** plus every package suite (TEST SUCCEEDED); `scripts/lint.sh` OK; `scripts/check-secrets.sh` OK; `scripts/sync-strings.sh` up to date.*
- [x] Release 0.6.0 (authorized by Bryan on 2026-10-16: one commit with v0.4.1, v0.5.0 and v0.6.0, then publish; v0.4.1 and v0.5.0 were never released on their own). **Verify:** CI green on the commit; brew shows 0.6.0; spctl Notarized Developer ID; `--diagnose` passes. *Done: full `ci-local.sh` before the commit (XcodeGen 2.45.4 from the scratch folder first on PATH); gitleaks would have flagged the v0.5.0 `team_kat.json` vectors, so `.gitleaks.toml` allowlists `team_kat.json` and `space_kat.json` (synthetic, from crosscheck.py). Commit 176a608, CI green (macos-26, xcode-27, gitleaks), tag v0.6.0, the release ran the full ci-local again, signed and notarized DMG published (sha256 52076078…), cask 176d02c (pushed with gh's credential helper for that push only), `brew upgrade` here shows 0.6.0 (26), spctl Notarized Developer ID, `brew audit --cask --online` passes; signed `--diagnose`: version 0.6.0 (26), keychain probe passed, gh ready with one account. Pending: manual — the two-Mac checks in the Review below, on 0.6.0.*

Residual risks (detected, not prevented; documented in SECURITY-MODEL): two members claiming at the same moment (`gh variable set` has no compare-and-swap; the re-reads after the claim and after publishing find it, and the scope shows Forked); a repository admin changing a secret in GitHub's web UI (Changed outside FX Vault); a member publishing a bad value (signed, in the history, revertible); removed members keep what they saw (rotation checklist); a Mac that never reaches another member stays behind and cannot push that scope (by design, Q1).

Later (not in v0.6): two-person approval for protected scopes, required reasons there, macOS notifications for new versions, a 6-digit history code to compare in person, member roles.

**Review (2026-10-16).** v0.4.1, v0.5.0 and v0.6.0 are implemented in the working tree, uncommitted (Bryan commits). Every automated check passes: package suites (VaultStore 67, VaultData 319, SyncEngine 192, SharingKit 262 and the rest), 577 app tests, lint, check-secrets, strings. Deviations from the plan, all recorded above and in ARCHITECTURE decisions 89–98: the space core lives in SharingKit, versions are full snapshots, marker writes are tracked by `claimed_version` instead of the journal, teammates' changes keep local drafts on top (Take Theirs through History), and the space chip shows the version (behind and publishing appear in Sync and drift review). Pending manual checks, all on two Macs: bubbles and ping sound and notification (v0.5.0); a teammate chat without the code (v0.5.0); share a scope, push on one Mac, see the other blocked until Get Updates, then the history on both (v0.6.0), on one Wi-Fi, over AWDL with no network, and through a Tailscale address with Outside this network turned on on both Macs (the macOS firewall may ask to allow incoming connections the first time); a manual pass of the new sheets in the app's own window.

### v0.7.0: folders in the sidebar, sent to teammates, teammates always visible (requested by Bryan, 2026-10-16)

Decisions (Bryan, chat, 2026-10-16): Q1 first "synced folders now", then, after seeing the cost, **send a copy now and sync folders later** (the recommendation); Q2 sidebar section plus compact toolbar button (recommended); Q3 flat folders (recommended). Implementation authorized with that change; commits still need his permission.

Request (Bryan, chat, 2026-10-16): as a mobile developer, create folders of his own in the sidebar (for example "Mobile App") that hold secrets and variables used by several repositories; copy and paste them into other repositories, or share them with teammates nearby. Also a redesign so teammates nearby are always visible instead of appearing only as toolbar bubbles when someone is around.

What exists (mapped 2026-10-16): every `config_items` row belongs to a repository (`repository_id NOT NULL`) and a scope; copy and paste (v0.4.0/v0.4.1) moves items between scopes of any repository and links the copies (`link_id`), and editing a linked item offers to update its copies. Teammates (v0.5.0) appear as an avatar stack in the toolbar (`NearbyPresenceView`) only while one is nearby. Shared scopes (v0.6.0, `fxvault-space/v1`) keep one **linear** signed log per scope, ordered by the GitHub marker (pull, verify, then push); their epoch keys, HPKE wraps, member model, team-session transport (`TeamService.spaces`), remote access and `SpaceSyncManager` loop are reusable, but a folder has no GitHub marker to order edits.

**Design (proposed)**

| # | Decision | Rationale |
|---|---|---|
| F1 | A **folder** is a named collection of secrets and variables that belongs to no repository or account and is never pushed by itself. Names are 1–64 characters and unique (case-insensitive). Items follow GitHub's naming rules so they can be pasted anywhere. Order is the user's (drag in the sidebar). | A library of shared keys ("Mobile App", "Firebase", "Stripe test") that repositories copy from. |
| F2 | **Separate tables**, migration `v12_folders`: `folders` (id, name, name_key unique, sort_order, times) and `folder_items` (id, folder_id cascade, kind, name, value_ct and value_fp NOT NULL, link_id, times; unique per folder, kind, name). Values sealed under the DEK with their own AAD (table, column, item id); DEK rotation re-seals them. Names are plaintext metadata, as repository and item names are. | No GitHub sync path (planner, preflight, executor, drift, scope spaces) reads these tables, so a folder item can never reach GitHub by mistake. A folder secret always has its value (nothing comes from GitHub). |
| F3 | **Sidebar:** a FOLDERS section above ACCOUNTS, shown whenever the vault is unlocked, with "New Folder…" (also ⇧⌘N, as in Finder). Row: folder symbol, name, item count. Context menu: Rename, Send to Teammate ›, Export .env…, Delete… (says that copies in repositories stay, unlinked from it) The search field also filters folders. | "Dynamic" folders that are always one click away, like repositories. |
| F4 | **Folder detail:** selecting a folder shows the same table (Secrets / Variables tabs, reveal and re-mask, Copy Value, Add, Paste Multiple…, Import .env, edit, delete, link chip) through an adapter over `ConfigTableView`, without the sync column. Changes are saved at once (there is no GitHub side). | Reuse; one table to learn. |
| F5 | **Copy and paste in every direction:** folder → any repository scope (pending for Sync), repository → folder, folder → folder; ⌘C/⌘V, Copy To › Folder › …, Copy To › Another Repository…, and dragging rows onto a folder or repository in the sidebar. Same Replace / Keep Existing prompt; values never reach the pasteboard. | The existing copy rules, extended to a new kind of place. |
| F6 | **Linked across folders and repositories:** a copy keeps one `link_id` group that spans `config_items` and `folder_items`. Editing a folder item's value lists its repository copies (checked when they still had the old value); Save updates them as changes for the next Sync. The Linked popover lists folder places as "Folder · Mobile App". | Rotating a shared key becomes: edit it once in the folder, then Sync. |
| F7 | **Send a copy of a folder to a teammate** (Q1): from the teammate's row (Send Folder…), the folder's menu, or Nearby Chat › Attach › Folder. Chat version 4 adds a folder card (name and counts; values travel only when the receiver chooses). The receiver chooses **Save as Folder** (a new folder, or merge into one of theirs with Replace / Keep), **Import Into…** (a repository scope, pending for Sync) or **Save as File…**. Re-authentication before values leave, as today. Share › File… also accepts a folder. A 0.6 peer negotiates version 3 and the Folder tab explains the update. Each person keeps their own copy; nothing stays in sync. | Reuses the verified teammate chat (no code), the share package and the import preview. Synced folders come later (see below). |
| N1 | **Teammates always visible:** a TEAMMATES section pinned at the bottom of the sidebar, above the footer (it does not scroll away). Every paired teammate is listed: avatar, name, a green "Nearby" dot or "Seen 2 h ago", muted icon; nearby first. A click opens the person popover (Ping, Chat, Send Folder…; disabled with the reason when not nearby). Others nearby who are not teammates appear as "Others nearby · N" with Chat (code check). The header shows this Mac's visibility ("Visible to teammates") with a menu to change it. With no teammates: "Add Teammate…" and one line on what pairing does. "Got v9 from Ana" appears on her row. | Presence, pairing and actions in one place that is always on screen. |
| N2 | **Toolbar:** the avatar stack becomes one compact button (people symbol and the number nearby) that opens the same list as a popover, so it still works with the sidebar hidden; a ping bounces it and the teammate's row. | Keeps the toolbar calm; nothing is hidden when the sidebar is collapsed. |

**Questions (answered 2026-10-16)**

- **Q1** Sharing a folder: one-off send, or synced folders now? **Answer: a copy now (F7), synced folders later.**
- **Q2** Where teammates live? **Answer: sidebar section plus the compact toolbar button** (N1, N2).
- **Q3** What a folder holds? **Answer: a flat list of secrets and variables** ("Mobile App · Prod" is another folder).

**Checklist**

- [x] **Migration `v12_folders` and `FolderStore`.** `folders`, `folder_items`, and for sync `folder_keys` (epoch keys sealed) and `folder_changes` (folder, author, seq, hash, data; unique per folder, author, seq). **Verify:** MigrationTests (from v11), ConstraintTests (NOT NULL values tested with `IS NULL`, cascade on folder delete, kind and name checks, lowercase device ids). *Done differently: no sync, so only `folders` and `folder_items` (name_key unique, items unique per folder, kind and name, `value_ct`/`value_fp` NOT NULL, `link_id` indexed); `FolderStore` with observation and `LinkCountQuery` (link groups across both tables, also used by `ConfigStore`). MigrationTests (v12 seed: a folder item in the same link group as a repository item) and ConstraintTests (`folderTablesCheckNamesValuesAndCascade`) pass; VaultStore 68 tests.*
- [x] **`FolderRepository` (VaultData).** Create, rename, reorder, delete; item add, edit, delete, Paste Multiple…, Import and Export .env; observation; DEK rotation re-seals folder values and keys. **Verify:** VaultData tests for each, plus a sync test proving planner, preflight and drift never see a folder item with the same name as a repository item. *Done: create, rename, reorder, delete, items, reveal, `save(_:as:conflicts:)`; `FolderItemWriter` (GitHub names, unique per kind, `Limits.maxFolderItems` 1,000); `FolderFieldAAD` (the §5.4 layout with table `folder_items`, KAT `folder_field` vectors from generate_kat.py); `EnvFileRepository` place overloads; `DEKRotator` re-seals folder values. VaultData `FolderRepositoryTests` (13) include `noSyncInputSeesAFolderItem` and DEK rotation.*
- [x] **Copy and links across folders and repositories.** `copyConflicts`/`copyItems` accept folder sources and targets; link groups span both tables; the editor's linked update covers repository copies of a folder item. **Verify:** folder → repository is a linked pending add; repository → folder; Replace and Keep; rotation from a folder updates the copies that had the old value; deleting a folder leaves its copies unlinked. *Done: `ItemCopySource` reads either table; `ConfigRepository.copyItems`, `linkedCopies(of:)` (`LinkedCopyModel.place`), `unlink`, `updateLinkedCopies` and `reveal` take folder items; `FolderRepository.copyItems` takes repository items. Tests in `FolderRepositoryTests` (copies both ways, Replace and Keep, rotation from a folder, unlink and folder deletion).*
- [x] **Send a folder (SharingKit, App).** Chat version 4 folder card; Save as Folder (new or merge), Import Into…, Save as File…; Share › File… for a folder; Send Folder… from the teammate's row and the folder's menu. **Verify:** SharingKit tests (round trip, size limit, version 3 peer refused before authorization, KAT vectors if the transcript changes), import planner tests for a folder target, chat view-model tests; snapshots of the folder card and picker. *Done: share schema 3 (scope `folder`, a `folder` object on the wire, `intoRepository` for Import Into; the planner and nearby share refuse a folder), chat version 4 (`folderAttachmentsVersion`), `NearbyChatConversation.offerFolder` / `saveFolderAttachment` / `previewFolderAttachment`, `SharingRepository.openFileContents` / `saveFolder` / `importDraft`; App: `FolderDestinationModel`/`View` in Import Share and the chat's save sheet, the picker's Folder tab, folder cards, Send Folder from a teammate (the picker opens on the folder after the chat is verified; Touch ID or the password still first). Tests: SharingKit `FolderPackageTests` (8), VaultData `FolderSharingTests` (2) and 2 chat conversation tests, AppTests `FolderSharingAppTests` (7). KAT for chat transcripts unchanged (frames and labels unchanged; tests pass max versions explicitly).*
- [x] **Sidebar folders and folder detail (App).** **Verify:** SidebarViewModel and folder detail view-model tests (create, rename, delete, search, drag rows onto a folder, ⌘C/⌘V both ways); snapshots light and dark. *Done: `SidebarFoldersSection`, `FolderOverviewView` (column 2), `FolderDetailScreen`/`ViewModel` over the now generic `ConfigTableView` (`ConfigTableModel`, `ConfigValueRevealer`, `ItemCopyFlow`), `FolderNameScreen`, `FolderContextMenu`, ⇧⌘N, the item editor, `.env` import/export and Copy to Another Repository on an `ItemPlaceModel`. Tests: AppTests `FolderViewModelTests` (12) and the sidebar test in `FolderSharingAppTests`; snapshots `main-folder`, `main-folder-variables`. Not done: dragging rows onto a folder or repository, and dragging folders to reorder (the order is stored and `reorderFolders` exists); Copy To and ⌘C/⌘V cover the same moves.*
- [x] **Teammates in the sidebar (App).** TEAMMATES section, compact toolbar button, popover with Send Folder…, visibility menu, empty state. **Verify:** TeamPresence and sidebar tests (nearby first, last seen, muted, others nearby, ping bounce); snapshots light and dark, and a pass in the app's own window at the minimum size (lessons). *Done: `SidebarTeammatesSection` (every paired teammate, nearby first with the green dot, last seen, muted, others nearby, the eye visibility menu, Add Teammate… opening Settings › Teammates), the toolbar's people button with its list, Send Folder in the person popover. Tests: `teammateRowsListNearbyTeammatesFirst`, `sendFolderOpensAChatThatAttachesIt`; snapshots `main-sidebar-teammates`, `presence-popover-folder`, `presence-bubbles` (now the button). Pending: a pass in the app's own window at the minimum size.*
- [x] **Docs and checks.** DATABASE (`v12_folders`), SECURITY-MODEL (folder values, names as metadata, sending a folder), SHARING-PROTOCOL (chat version 4, folder package), ARCHITECTURE, DESIGN, STRUCTURE, README, CHANGELOG, gitleaks allowlist for new KAT files. **Verify:** `scripts/ci-local.sh` passes. *Done: DATABASE `v12_folders`, SECURITY-MODEL §2, §6, §7, §10.1 and §11, SHARING-PROTOCOL §1.1, §1.3 (schema 3), §8 and §10.8 (chat version 4), ARCHITECTURE decisions 99–105 and the VaultCore, VaultStore and VaultData notes, STRUCTURE, DESIGN (sidebar, folder columns, people button, received folder, snapshot list), README, CHANGELOG Unreleased; strings synced. `scripts/ci-local.sh` with the pinned XcodeGen 2.45.4 first on PATH: XcodeGen drift check, every package suite (VaultStore 68, VaultData 336, SharingKit 270, SyncEngine 192 and the rest), 599 app tests in 53 suites, lint and check-secrets pass; then `folderDetailFitsItsNarrowestColumn` added (MainWindowLayoutTests 3/3). gitleaks finds nothing (the new KAT vectors are in the allowlisted `kat_vectors.json`).*
- [x] Release 0.7.0 (authorized by Bryan on 2026-10-16: "Sí" to commit and publish, plus a local build to look at). **Verify:** CI green on the commit; brew shows 0.7.0; spctl Notarized Developer ID; `--diagnose` passes. *Done: a Debug build ("FX Vault Dev", its own vault) opened for Bryan; commit 7922fd2, CI green (macos-26, xcode-27, gitleaks), tag v0.7.0, the release ran the full ci-local again, signed and notarized DMG published (sha256 a08b8c8d…), cask 460e339, `brew upgrade` here shows 0.7.0 (27), spctl Notarized Developer ID, `brew audit --cask --online` passes; signed `--diagnose`: version 0.7.0 (27), keychain probe passed, gh ready. Pending: the manual checks in the Review above.*

**Review (2026-10-16).** Folders, sending a copy and teammates in the sidebar are implemented in the working tree, uncommitted (Bryan commits). Deviations: no synced folders (Bryan's Q1 answer changed to a copy now, sync later); no drag and drop of rows or folders yet (Copy To and ⌘C/⌘V cover it; the order is stored); the visibility menu is an eye symbol instead of a "Visible to teammates" label, which did not fit the sidebar. Pending manual checks: the new sidebar and folder columns in the app's own window at the minimum size and in dark mode; Send Folder and a received folder (Save as Folder, Import Into) between two Macs on 0.7; a folder `.fxvault` file opened on 0.6 shows "Wrong passphrase or damaged file".

Later (not in v0.7): **synced folders** (`fxvault-folder/v1`). Design notes from 2026-10-16: there is no GitHub marker to order edits, so each member device appends to its own signed chain (author, seq, previous hash, epoch, version vector, encrypted put/delete/rename/members ops); sync exchanges version vectors; the folder is the deterministic replay of every known change (causality, then seq and author), so edits made apart never fork; concurrent edits of one item keep the later one, record both in the history and show "Ana changed API_KEY while you did" with Use Mine; members, epochs, HPKE wraps, history and re-authentication as in scope spaces; incoming changes to items with repository copies offer Update Copies… and never change a repository by themselves.

### v0.8.0: runtime destinations, stage overview, fxvault.yml (requested by Bryan, 2026-10-16)

Request (Bryan, chat, 2026-10-16): besides GitHub Actions variables (build time) the team has runtime variables for backends and frontends, and often keeps the secrets in Azure Key Vault; organize them per repository. The proposal (classify each value by who reads it and when; one value, one source; destinations next to GitHub scopes; a names-only `fxvault.yml` in each repository) was drawn as a five-board canvas ("FX Vault Destinations": stage matrix, who reads what, Key Vault destination, multi-provider Sync review, manifest). Then: "Hazlo empieza, implementa y publica después de testear", which authorizes the implementation and, after the tests pass, the 0.8.0 release (commit, tag, push, notarized DMG, cask).

The three open questions were taken as recommended (Bryan said "hazlo" without changing them): the providers are Azure Key Vault, Supabase and Vercel; Key Vault is the team's shared source that FX Vault edits as one more remote; the manifest lives in each repository.

**Design**

| # | Decision | Rationale |
|---|---|---|
| R1 | A **destination** is a place outside GitHub that one vault repository's code reads at runtime: an Azure Key Vault, one Supabase project's Edge Function secrets, or one Vercel project environment (production, preview or development). It has an optional **stage** (environment-name rules; suggested from the repository's GitHub environments). Removing a destination from FX Vault never deletes anything remotely. | The grouping people think in ("what does production need?") without changing how GitHub scopes work. |
| R2 | **Separate tables**, migration `v13_destinations`: `provider_connections`, `destinations`, `destination_items`. Values sealed with `DestinationFieldAAD` (table `destination_items`, row, destination, kind, name), row-bound fingerprints; DEK rotation re-seals them and the connection tokens. `ItemPlaceModel` gains `.destination`. | As with folders, no GitHub path (planner, preflight, executor, drift, spaces, sharing) reads these tables, so a destination item can never be pushed to GitHub by mistake; copy, links, the table and the editor still work through the place. |
| R3 | **Items** follow GitHub's naming rules (so copy and links work everywhere) plus the provider's: Key Vault and Supabase hold secrets only (a variable copied there becomes a secret); Supabase reserves `SUPABASE_`; Vercel maps secret → `encrypted`, variable → `plain`, and a remote `sensitive` value imports as a secret whose value is missing. Key Vault names are mapped (`DATABASE_URL` ↔ `DATABASE-URL`); remote names that cannot map back are listed as not usable with the reason, never dropped. | Each provider's real constraints, stated where the user acts. |
| R4 | **Access.** Key Vault through the user's `az login`: `az account get-access-token --resource https://vault.azure.net` (absolute path, argv, no shell, allowlisted environment), the token kept in memory for its lifetime; the data plane over HTTPS (api-version 7.4). Supabase (`api.supabase.com/v1`) and Vercel (`api.vercel.com`) through personal access tokens added in Settings › Destinations, sealed in the vault, validated when added. One ephemeral `URLSession` (no cache, no cookies, 30 s), values only in request bodies, bodies never logged. | The Supabase CLI cannot take a value on stdin, and the Vercel CLI needs a linked folder; HTTPS keeps every value out of argv and files. Azure users already sign in with `az` (SSO, MFA). |
| R5 | **Sync** covers GitHub and the repository's destinations in one review, grouped by destination with how it is reached. Destination writes run after GitHub's, each journaled (`dest\|<id>\|item\|<kind>\|<NAME>`), then confirmed by re-listing: Key Vault by a new version, Supabase by the value's digest, Vercel by `updatedAt`. Each destination is re-listed first; an item that changed remotely since the last sync is blocked as "changed in <provider>". Key Vault deletes are soft deletes (never purged); re-adding a soft-deleted name recovers it, then sets the value. | The existing guarantees (journal, verification, optimistic concurrency) for the new remotes. |
| R6 | **Drift**: Refresh lists each destination; remote adds, changes and deletes since the last sync show as a banner with Review (Keep Mine / Use Remote). Key Vault and Vercel values are read when accepted; a Supabase change can only mark the value missing (the API returns digests). | Teammates edit Key Vault directly; FX Vault must notice. |
| R7 | **UI**: the scope column gains **Overview** at the top, a BUILD · GITHUB ACTIONS label over today's scopes, a RUNTIME section (provider symbol, name, stage, count, pending dot) and Add Destination…. The destination detail is the same table (an adapter, as for folders) under a header with stage → target and the provider's rules. Add Destination: provider, target (Key Vault: vault name and optional tenant; Supabase and Vercel: picked from the connection's projects), stage, then an import of what is there. | Deviation from the canvas: the stage switcher moves into the Overview header, because a repository can have many environments; GitHub scopes stay as they are. |
| R8 | **Overview** (per stage): columns GitHub (repository level plus the environment named like the stage) and every destination of that stage; rows every name in them plus the manifest's vars for the stage. Cells: Synced, Will push, Missing, Value missing, Differs (a linked copy with another value), Extra (not in `fxvault.yml`), Blocked, — (not used). | The canvas' first board. |
| R9 | **`fxvault.yml`** is read from the default branch (`gh api …/contents/fxvault.yml`, names only) and parsed as a strict YAML subset with line-numbered issues. FX Vault never writes to the repository in v0.8: it can generate a manifest from the current state and a `.env.example` per target, to copy. The manifest check adds Missing (including a destination not added yet, with Add Destination as the fix), Extra, Blocked and kind mismatches. | Names in the repository go through pull requests; values never do. |
| R10 | **Blocked public values**: a Vercel item whose name has a public prefix (`NEXT_PUBLIC_`, `VITE_`, `EXPO_PUBLIC_`, …) and whose value looks like a credential blocks Sync with the reason and two fixes: change the value, or Mark as Public (stored per item, for keys meant to be public such as an anon key). | The `sk_live_` in `NEXT_PUBLIC_STRIPE_KEY` mistake, without blocking real public keys forever. |
| R11 | **Not in v0.8**: a Local destination (Export .env covers it), Vercel git-branch and custom environments (listed as not usable), Key Vault certificates, keys and purge, destinations in `.fxvault` packages, chat and shared scopes. | Scope. |
| R12 | Destinations, the Overview and the manifest check ship marked **experimental**. | They talk to three new services; live checks are limited to the accounts on this Mac. |

**Checklist**

- [x] **Core models (VaultCore).** `DestinationID`, `DestinationProvider`, `DestinationModel`, `DestinationItemModel`, `ConnectionModel`, `ItemPlaceModel.destination`, provider name rules and the Key Vault name mapping, public prefixes. **Verify:** VaultCore tests for every rule and the mapping round trip. *Done: VaultCore 91 tests; Supabase and Vercel names must already be uppercase (`NameRule.notUppercase`).*
- [x] **AAD and KAT (VaultCrypto).** `DestinationFieldAAD`, `ConnectionTokenAAD`; vectors added by `generate_kat.py`. **Verify:** KATTests; a destination blob never opens as a repository or folder item. *Done: VaultCrypto 93 tests. Deviation: tokens reuse `SecretFieldAAD` (table `provider_connections`, the connection id as row key) instead of a new `ConnectionTokenAAD`.*
- [x] **Migration `v13_destinations` and `DestinationStore` (VaultStore).** **Verify:** MigrationTests (from v12, seed ladder), ConstraintTests (checks, cascades, unique names per destination), link counts across three tables. *Done: VaultStore 74 tests (seed ladder from v12, `DestinationStoreTests`).*
- [x] **Providers (new `DestinationKit`).** HTTP transport, Key Vault, Supabase and Vercel clients (list, read, set, delete, recover; projects and teams for the pickers), error classification, `az` token provider. **Verify:** request and decoding tests against recorded fixtures through a fake transport; redaction; no value in any URL, header or log. *Done: DestinationKit 134 tests; JSON written and scanned on `SecretBytes`, host allowlist, redirects refused.*
- [x] **Manifest (EnvTools).** `ManifestParser`, model, serializer, `.env.example`. **Verify:** reader, schema, round-trip and fuzz tests. *Done: EnvTools 145 tests.*
- [x] **`DestinationRepository`, `ConnectionRepository` (VaultData).** Destinations CRUD, items through a writer, import, Refresh and drift, Sync (plan, preflight, execute, verify, journal), copy sources and link groups across three tables, reveal, DEK rotation. **Verify:** VaultData tests with a fake provider for each path, including blocked public values, soft-deleted Key Vault names, interrupted writes and remote changes. *Done: VaultData 369 tests (`DestinationRepositoryTests`, `DestinationSyncRepositoryTests` with a fake remote). Connections live in `DestinationRepository`; sync in the `DestinationSyncRepository` actor; access checks in `DestinationAccessRepository`.*
- [x] **Overview and manifest check (VaultData).** **Verify:** matrix and check tests for each cell state. *Done: `StageOverviewTests`.*
- [x] **App.** Scope column sections, destination detail, Add Destination, Settings › Destinations, Overview, Sync review groups, destination drift review, manifest panel. **Verify:** view-model tests; snapshots light and dark; a pass in the app's own window. *Done: 609 app tests; snapshots reviewed (fixed "1 things", a duplicated Show Check, `Settings….`, middle-truncated destination titles). The in-app pass is RELEASING #41–44.*
- [ ] **Live checks.** Key Vault and Vercel against throwaway resources on this Mac's accounts (deleted afterwards); Supabase stays fake-tested unless a token is available. **Verify:** recorded in docs/API.md. *Partial: the Vercel round trip passed against a throwaway project (deleted afterwards) and the `az` token path passed. The Key Vault data plane was not run: the only Azure subscription on this Mac belongs to a client's tenant (see lessons.md). Supabase is fake-tested.*
- [x] **Docs and checks.** DATABASE, SECURITY-MODEL (networking, tokens), API, ARCHITECTURE, DESIGN, STRUCTURE, README, CHANGELOG. **Verify:** `scripts/ci-local.sh` passes; gitleaks finds nothing. *Done: DATABASE `v13_destinations`, SECURITY-MODEL §2, §4, §6–§9, §10.4 and §11, API §B11, §G (HTTPS endpoints, `az`), ARCHITECTURE (DestinationKit, decisions 106–117, app shell), DESIGN (screens, snapshots, known limits), STRUCTURE, README, CHANGELOG 0.8.0, RELEASING #41–44; strings synced (second run: no change). `scripts/ci-local.sh` with XcodeGen 2.45.4 first on PATH: every package suite (VaultData 372, DestinationKit 134, EnvTools 145, GitHubKit 186 and the rest), 612 app tests, lint and check-secrets pass. gitleaks on the files to commit finds nothing (JWT-shaped test values are joined at runtime).*
- [x] **Release 0.8.0** (authorized: "publica después de testear"). **Verify:** CI green; brew shows 0.8.0; spctl Notarized Developer ID; `--diagnose` passes. *Done: full `ci-local.sh` before the commit (XcodeGen 2.45.4 first on PATH); commit 764c1e2, CI green (macos-26, xcode-27, gitleaks), tag v0.8.0, the release ran the full ci-local again, signed and notarized DMG published (sha256 f63f5efc…), cask b686c1c (pushed with gh's credential helper for that push only), `brew upgrade` here shows 0.8.0 (28), spctl Notarized Developer ID, `brew audit --cask --online` passes; signed `--diagnose`: version 0.8.0 (28), keychain probe passed, gh ready. Pending: RELEASING #41–44 (Key Vault only on a sandbox vault).*

**Review (2026-10-16).**
- **Shipped.** Runtime destinations (Azure Key Vault, Supabase, Vercel), the stage Overview and the `fxvault.yml` check, marked experimental.
- **Deviations from the plan** (ARCHITECTURE decisions 106–117):
  - destination writes are journaled in their own `destination_journal` table, not as `dest|…` keys in `sync_journal`;
  - connection tokens reuse `SecretFieldAAD`;
  - the stage switcher sits in the Overview header;
  - a provider asking for more than 60 s of backoff fails the request instead of waiting.
- **Found while writing the docs, fixed before the release:**
  - The fingerprint of the value sent was journaled only after the write returned. A run interrupted mid-write was settled with the row's *current* fingerprint, so an edit made before the next review could be marked synced without being pushed. The fingerprint is now journaled `in_flight` before the request (`anEditAfterAnInterruptedWriteStaysPending`).
  - Supabase's listed digest (an unkeyed SHA-256 of the secret) was stored as is in `remote_version`, `pre_write_version` and the journal. A stolen database would have allowed offline guessing of weak values. Only a keyed marker (HMAC under `K_fp`) is stored now. DEK rotation re-keys the markers it can verify (`supabaseDigestsAreStoredOnlyAsKeyedMarkers`, `dekRotationReKeysSupabaseMarkers`).
  - Cleanup: a duplicated public-value check now uses `PublicValuePolicy`, and the unused `Limits.destinationReadConcurrency` is removed.
- **Snapshot review fixes:** "1 things to fix", a doubled Show Check, `Settings….`, middle-truncated destination titles, and every count string now has a singular form.
- **Live checks:**
  - Ran: the Vercel round trip against a throwaway project (deleted afterwards) and the `az` token path.
  - Not run: the Key Vault data plane, because the only Azure subscription on this Mac is a client's. Supabase is fake-tested only.
- **Known gaps:**
  - The Overview matrix scrolls sideways at the default width with three or more places.
  - The `az` path override and `AZURE_CONFIG_DIR` support in DestinationKit are not reachable from the app.
- **Manual checks pending:** RELEASING #41–44, with #42 (Key Vault) only on a sandbox vault Bryan provides.

### v0.9.0: share a project as a file (requested by Bryan, 2026-10-17)

Request (Bryan, chat, 2026-10-17): share secrets and environments "online", as one file sent over WhatsApp or email that holds the variables of several repositories; the receiver opens it, FX Vault opens the project and imports it. Designed in a /grilling session (Q1–Q13 below); Bryan confirmed the shared understanding ("si"). **Implementation waits for his OK on this plan**; commits, tags, pushes and the release each need their own permission.

What exists (mapped 2026-10-17): Share as File… writes a `.fxvault` v1 file (64-byte header as AAD, Argon2id 64 MiB, AES-256-GCM, 6-word passphrase). It holds one repository (an item, an environment, the whole repository or a subset) or one folder, in share schema 1 to 3. Opening it works like this:
- the header is checked before the passphrase is asked for;
- `ShareImportPlanner` previews the merge, which never deletes anything;
- `ShareRepositoryImporter` offers to import a missing repository from GitHub in one click;
- the package id is recorded in `imported_share_packages`.

Delivery already uses `NSSavePanel` or `NSSharingServicePicker` (`ShareFileDelivery`). Teammates (v0.5.0) hold verified Ed25519 and X25519 keys, but only from pairing nearby. Spaces (v0.6.0) already wrap keys for teammates with HPKE (X25519, SHA-256, ChaCha20-Poly1305). Destinations (v0.8.0) never travel in share packages (R11).

**Design (agreed 2026-10-17)**

| # | Decision | Rationale |
|---|---|---|
| P1 | **Contents** (Q1, Q6): one or more repositories chosen by the sender. Each carries its repository-level items, its GitHub environments (whole or partial, as today) and its runtime destinations (target, stage, items with values). Folders can be added as an option. Never included: connection tokens, `az` sessions, GitHub accounts or SSH aliases. | A product spans app, web and backend repositories. A leaked file must not give access to anyone's accounts. |
| P2 | **Selection** (Q7): the sender picks stages first, and they apply to every chosen repository. A stage selects the GitHub environment named like it (the Overview's fold key) and that stage's destinations. A tree per repository then adjusts the selection (repository level checked by default, then each environment, each destination and each item). A **production stage** starts unchecked and asks for confirmation when checked. A stage is production when any word of its name (split on non-letters) is `prod`, `production`, `prd` or `live`, ignoring case; the rule lives in one place in VaultCore. | Staging can go to a contractor without production travelling by accident. |
| P3 | **Two protections** (Q2, Q5, Q13). **Teammates** (1–10 paired devices): a random 32-byte content key is wrapped for each recipient with HPKE, using the spaces suite. A recipient slot holds only `HMAC(fileSalt, deviceID)[0..<8]`. The sender's device id and an Ed25519 signature over the header, the slots and the payload digest travel inside the ciphertext. The receiver sees "From <name>, verified". **Passphrase**: Argon2id as in v1, with the sender's name unverified. A selection that includes a production stage can only be sent to teammates. | Safe to send in the same chat as anything else. Recipients stay hidden from the channel. Production never travels under a passphrase that can be forwarded with it. |
| P4 | **Remote pairing** (Q4): Add Teammate › Not Nearby…, in four steps. (1) A exports an invitation card: public signing and agreement keys and names, signed, without the announce key. (2) B opens it and writes a reply: B's card plus B's announce key sealed to A with HPKE, signed over both cards. (3) Both apps show a **6-word code**, EFF words derived from both cards, the invitation's nonce and a fresh nonce that B draws for the reply (inviter first; about 77 bits). The exchange happens asynchronously, without commit-reveal, so a 6-digit code could be brute-forced; because B's nonce is drawn after the invitation B holds is fixed, a relay needs a second preimage (about 2^77), not a birthday collision. (4) They compare the code on a call, and each side confirms. A's announce key reaches B in A's first teammates file to B, or through the existing card update the first time they meet nearby. A teammate paired remotely is a normal teammate (`teammates.paired_via = 'remote'`). | The teammate mode works with remote teammates. The announce key stays "known only to teammates" (SHARING-PROTOCOL §10.2) even though the cards cross WhatsApp. |
| P5 | **Transport** (Q3): file only, no server. The file is written 0600 to a temporary folder and handed to `NSSharingServicePicker` (Mail, WhatsApp, Messages, AirDrop), or saved with `NSSavePanel`. The temporary copy is deleted when the sheet closes. The default name includes no repository or stage: `FX Vault share 2026-10-17.fxvault`. | Nothing hosted to secure. Chats and mail show the file name to everyone. |
| P6 | **Expiry and sent log** (Q10). The sender picks 1, 7 (default) or 30 days. `expiresAt` travels inside the ciphertext (signed in teammate mode), and FX Vault refuses to open a file after that date. The copy says plainly that FX Vault enforces the expiry, not the cryptography. Each export writes a `sent_shares` row: time, expiry, mode, recipients (teammate ids or "passphrase") and names only (repositories, stages, item names). Settings › Sharing lists these rows, each with what to rotate. | A file lives for years in a chat. The log tells you what to rotate if one leaks. |
| P7 | **Receiver** (Q8). The open sheet lists each repository: ✓ already in your vault, ⇣ will be imported from GitHub with your account (the existing importer), ✕ no access (skipped, naming the access it needs). Below that is today's merge preview for each scope, plus the destinations. An existing destination with the same target key is merged; a new one is created without a connection. Import applies everything in one transaction, then opens the Overview of the first imported repository at the first shared stage. Opening the same file again later imports what was skipped, after the "already imported" replay warning. | Missing access to one repository never blocks the rest. |
| P8 | **Held until confirmed** (Q9). An imported item that the remote does not have is saved with `share_hold` (the package id) and stays out of Sync's plan. "Does not have" means the name is missing on GitHub, or the value is missing or different on a readable destination. Sync shows a **From Files** review, like the deletions review, grouped by file and sender. Confirm puts the items into the run; Keep Local clears the hold, and those items wait for an explicit Push on Next Sync. Items the remote already has arrive synced. | Opening a file never changes GitHub or production silently. |
| P9 | **Links** (Q11). Copies linked to each other inside the file travel as per-file link tokens. The receiver gives fresh `link_id`s to the rows it adds or replaces. Rows it keeps ("keep mine") keep their own links. Links to items outside the file are dropped. | Coordinated rotation works on the receiver's side too, without exposing the sender's link ids. |
| P10 | **Format** (Q12): `.fxvault` format 2 (same magic, formatVersion 2, a mode byte for passphrase or teammates) and share schema 4 (`bundle`: repositories, their destinations, folders, link tokens, `expiresAt`). Every export writes this format, including a single repository: Share as File… becomes this sheet. v1 files stay readable forever. FX Vault 0.8 shows its damaged-file error, and the release notes say receivers need 0.9. Limits: 16 MiB payload, 10 recipients, 50 repositories. | One path, with one set of guarantees. |
| P11 | **Not in v0.9**: sending a bundle nearby or in chat, revoking a sent file (rotating the value is the remedy) and a hosted link. Remote pairing and teammate files ship **experimental** until they are checked between two Macs. | Scope. |

**Questions (answered by Bryan, 2026-10-17, /grilling; every answer was the recommended option)**

- **Q1** What the file holds: **several repositories chosen by the sender**, each with its GitHub scopes and runtime destinations.
- **Q2** Protection: **a paired teammate's key, or a passphrase** for everyone else.
- **Q3** "Online": **a file only**, through the share sheet; no server.
- **Q4** Remote teammates: **pair by card file plus a code compared on a call**.
- **Q5** Recipients per file: **1 to 10 teammates**.
- **Q6** Destinations: **target and values, never tokens**; the receiver connects their own account.
- **Q7** Selection: **by stage, production unchecked** and confirmed, then a tree per repository.
- **Q8** A repository the receiver cannot access: **import the rest and skip it**, with the reason.
- **Q9** After import: **nothing reaches a remote without confirmation** in Sync's From Files review.
- **Q10** Expiry: **chosen at export (1, 7 or 30 days), plus a sent log**.
- **Q11** Links: **those inside the file travel**.
- **Q12** Versions: **one sheet, always the new format**; old files stay readable.
- **Q13** Production: **only to teammates**, never with a passphrase.

**Checklist**

- [x] **VaultCore.** Production stage rule, bundle selection model, expiry choices, `Limits` (recipients 10, repositories 50). **Verify:** tests for the stage rule (`Production`, `prod-eu`, `prd`, `live`, and `product`, `preview` and `reproduce` are not production) and for each limit. *Done: `StageRisk`, `ShareExpiryChoice`, `SentShareModel`, the format 2 and pairing limits and timeouts; `StageRiskTests` (VaultCore 95 tests). The selection model moved to VaultData (wave 2).*
- [x] **Format 2 codec (SharingKit).** Header with the mode byte; passphrase mode; teammate mode (HPKE wraps, opaque slots, signature and sender id inside the ciphertext); `inspect` before any passphrase or key; v1 still opens. **Verify:** round trips in both modes; a wrong recipient, a tampered header, slot, ciphertext or signature, swapped slots and an unknown sender all fail as `invalidFile`; KAT vectors from an independent Python generator (passphrase mode with a fixed salt and nonce; teammate mode decrypt-only, with HPKE checked against RFC 9180 vectors); the v1 KAT is unchanged; gitleaks allowlist entries for the new fixture files. *Done: `FxVaultFileV2Codec`, `FxVaultHeaderV2Model`, `ShareTeammateKeyModel`; 35 tests; KAT `file_v2_kat.json` from `file_v2_kat.py` (passphrase file byte for byte; a deterministic teammates file with HPKE written from RFC 9180, cross-checked with `cryptography`). A tampered salt, recipient count or own slot id can surface as `notARecipient` (those bytes pick the slot and cannot be authenticated without a key).*
- [x] **Schema 4 bundle (SharingKit).** Model, coder, validator, manifest, filtering and wiping; destinations with target and stage; link tokens; `expiresAt`; the planner per repository (a block reason per repository instead of for the whole package), destinations merged by target key, link assignment. **Verify:** validator table tests; planner tests with mixed ✓ ⇣ ✕ repositories, a destination merge, links kept and dropped, an expired file refused, and a replay per repository. *Done: `Bundle/ShareBundle{Model,Coder,Validator,PlanModel,Planner}`, `ShareDocumentCoder` (dispatch on `schemaVersion`), `ShareItemModel.linkToken`; 35 tests. Folders carry an `id`; schemas 1–3 refuse links.*
- [x] **Remote pairing (SharingKit).** Invitation and reply cards, signatures, the 6-word code, the sealed announce key. **Verify:** a KAT for the code; a tampered card, a wrong signature, a reflected reply and this device's own card are refused; a test that the invitation bytes never contain the announce key. *Done: `RemotePairing`, `RemotePairingProtocol`, `TeamPublicCardModel`; 25 tests; KAT `pairing_kat.json` from `pairing_kat.py`. The code transcript is inviter first (see P4).*
- [x] **Migration `v14_project_shares` (VaultStore).** `sent_shares`; `share_hold` on `config_items` and `destination_items`; `teammates.paired_via`. **Verify:** MigrationTests from v13 (seed ladder) and ConstraintTests (checks with `IS NOT NULL`, per lessons). *Done: `sent_shares`, `share_hold` with partial indexes, `teammates` rebuilt (nullable `announce_ct`, `paired_via`, and `announce_ct IS NOT NULL OR paired_via = 'remote'`); `SentShareStore`, hold methods on `ConfigStore`/`DestinationStore`; VaultStore 83 tests, VaultData 376.*
- [x] **VaultData.**
  - **Export:** selection to bundle, values read inside `session.read`, link tokens, `ReauthGate` `.fileExport`, sealing for teammates with `TeamRepository`'s keys, the sent log.
  - **Import:** draft and apply in one transaction, re-encryption, destinations created without a connection, holds, links.
  - **Pairing:** remote pairing persistence.
  - **Sync:** the planner leaves out held rows.

  **Verify:** tests for each path, including `heldItemsNeverReachTheSyncPlan` and `connectionTokensNeverEnterABundle` (encode a bundle and scan the JSON for every stored token). *Done: `SharingRepository+ProjectShare` (stage options, selection, preview, export in both modes with the sent log, inspect, open, import missing repositories, re-plan, apply in one transaction), `ProjectShareImporter` (holds after every value write, links, destinations without a connection, folders through `FolderItemWriter`), `CatalogShareRepositoryAccess`; `HeldChangeFilter`, `ShareHoldRepository`, `heldShares` in the Sync review, `startRun(…includeHeld:)` and `DestinationSyncRepository.run(…includeHeld:)`, the Overview's Held cell; `TeamRepository+Pairing`. VaultData 427 tests (24 project share, 18 held, 10 remote pairing), VaultStore 85. Deviations: no separate Keep Local action (a file left out stays held and is offered again); the verified sender is stored in `imported_share_packages.sender_device_id`; a value the user types releases the hold, a rename keeps it; environments and branch policies are not held (they show in Sync's normal review).*
- [x] **App.** The share sheet (repositories, stages, tree, recipients, expiry, delivery); the open sheet (repository list, preview, verified sender, expired file); Sync's From Files review; Settings › Sharing (sent log); Add Teammate › Not Nearby…; entry points (File menu, repository menu, "Share Stage…" in the Overview header). **Verify:** view-model tests; snapshots light and dark, with counts of one; a pass in the app's own window at the minimum size. *Done: `ProjectShareScreen`/`ViewModel` (contents with repositories, stages, production confirmation and the tree; Send to; expiry; Touch ID; Share… and Save… from a 0600 temporary file deleted on close), the open sheet for bundles (`ProjectShareImportView`, verified sender, ✓/⇣/✕, preview per repository, destinations, folders; Import opens the Overview at the first stage), `SharingSettingsScreen` (sent log), `SyncHeldSharesView` (From Files, off by default), the Held chip and Overview cell, `RemotePairingSheet` (Not Nearby…, experimental), the `.fxvcard` type; File › Share Project… (⌥⌘S, since ⇧⌘S is Sync), the repository menu and the Overview's Share Stage…. App 664 tests in 61 suites; 15 new snapshot pairs reviewed. Deviations: the bundle preview shows one repository at a time; changing stages resets manual tree adjustments; the Held chip names the sender in its tooltip. Not done: the pass in the app's own window at the minimum size (RELEASING).*
- [x] **Docs and checks.**
  - SHARING-PROTOCOL: §1 schema 4, §2 format 2, §3 the code, §10 remote pairing.
  - SECURITY-MODEL: files in chats, opaque recipients, expiry enforced by the app, held imports, the announce key, residual risks.
  - DATABASE: `v14`.
  - ARCHITECTURE: decisions 118 and later.
  - DESIGN, STRUCTURE, README, CHANGELOG.
  - RELEASING: new manual rows on two Macs (remote pairing, a teammate file sent through a chat, a passphrase file, an expired file, the From Files review).

  **Verify:** `scripts/ci-local.sh` passes (XcodeGen 2.45.4 first on PATH); gitleaks on a scratch copy of the files to commit finds nothing. *Done: SHARING-PROTOCOL §1.4, §2.1, §5.1, §6.1, §8, §10.9; SECURITY-MODEL §10.5 and §11; DATABASE `v14_project_shares`; ARCHITECTURE decisions 118–137; DESIGN, STRUCTURE, README, CHANGELOG 0.9.0, RELEASING #45–48; strings synced (second run: no change); `.gitleaks.toml` lists the two new KAT fixtures. `scripts/ci-local.sh` passes: VaultCore 95, VaultCrypto 93, VaultStore 85, GitHubKit 186, EnvTools 145, SharingKit 367, SyncEngine 192, VaultData 428, DestinationKit 134, App 661 in 61 suites, lint and check-secrets. gitleaks on the 1,069 files to commit finds nothing (a UUID test constant named `linkToken` is joined at runtime).*
- [ ] **Release 0.9.0**, only after Bryan's permission for the commit, tag, push and publish.

**Review (2026-10-17).**
- **Built:** project share files end to end:
  - format 2 with the passphrase and teammates modes;
  - share schema 4, the bundle;
  - remote pairing by `.fxvcard` with a 6-word code;
  - migration v14;
  - export and import in VaultData;
  - holds in Sync and the Overview;
  - the Share Project sheet, the open sheet, Sync's From Files, Settings › Sharing and Add Teammate › Not Nearby….

  Every `.fxvault` file FX Vault writes is now format 2, including Nearby Chat's Save as File…. Format 1 files still open.
- **Deviations from the plan:**
  - There is no separate Keep Local: a file left out stays held and is offered at every Sync.
  - A value the user types releases a hold; a rename keeps it.
  - Environments and branch policies are not held. A new environment waits while all its items are held.
  - The verified sender is stored in `imported_share_packages.sender_device_id`.
  - A teammate without an announce key gets a random, never-stored one in `teammateCards()`.
  - The pairing code transcript is inviter first, with the reply's nonce.
  - The bundle preview shows one repository at a time.
  - Changing stages resets manual tree adjustments.
  - The share shortcut is ⌥⌘S, because ⇧⌘S is Sync.
- **Found and fixed during integration:**
  - The app tests imported VaultStore, which `scripts/lint.sh` refuses. Fixed with a VaultData `@_spi(Testing)` helper (lessons.md).
  - A test constant tripped gitleaks.
  - Two snapshots shared a name.
  - Chat's Save as File still wrote format 1.
  - The pairing confirm button outweighed Cancel; both now have the same weight.
  - An unreachable export path was left over and is now removed.
- **Not verified live:** remote pairing and teammate files between two Macs, and anything at the minimum window size in the app's own window. Both ship experimental. Manual checks: RELEASING #45–48.

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

---

## FX Vault 1.0: simple and secure — slices

Brief: [docs/design/V1-BRIEF.md](../docs/design/V1-BRIEF.md). Mode: careful (Bryan, 2026-10-25). Branch `feat/v1-simplify`, worktree `../FXVault-v1`.

Gates (every slice, in order):
- Design slices: boards in `docs/design/mockup/v1/` render in light and dark at 960×640; anton reviews them against the brief and `docs/DESIGN.md`; no code changes.
- Build slices: `scripts/ci-local.sh` (XcodeGen drift, `swift build` + `swift test` of FXVaultKit, `xcodebuild` build + test ad-hoc, `scripts/lint.sh`, `scripts/check-secrets.sh`), XcodeGen 2.45.4 first on PATH.
- e2e twice (from B0 on): the XCUITest suite against a throwaway vault in a temporary Application Support folder and `gh`/`az` fakes; never a real account.
- review (myself, then `review-code`, `review-tests`, `review-security` when it touches crypto, store, gh/az or entitlements) → gate → commit (explicit paths) → push → CI green.

Bryan (2026-10-25): delete whatever is unused; this covers writing the migration that drops the removed features' tables on this branch (it reaches a vault only when a 1.0 build runs; the release stays reserved). Automatic mode overnight.

Reserved for Bryan: the table rebuild that moves destinations to Key Vaults, any write to a real GitHub organization or Key Vault, merge to `main`, tag and release 1.0.

Design (designer, reviewed by anton):
- [x] D1 Start and onboarding: welcome, recovery reset, master password, recovery key and confirm, Touch ID, GitHub setup, connect GitHub (organizations, `admin:org` approval), connect Azure, first import, fill values from notes, notch unlock. Writes: `docs/design/mockup/v1/`.
- [x] D2 Main window: sidebar GitHub › org › repo › env, Azure › subscription › vault, Folders; empty states; offline banner; place actions, delete and export; quick vault (⌃⌥V); Share Securely.
- [x] D3 Place view: Notes (placeholders for masked values, Reveal, Copy All) and Table; edit review; file secrets (`.p8`, `.pem`, `.json`).
- [x] D4 Organization and Key Vault specifics: visibility (all, private, selected repos), inherited and shadowed names on a repository, vault name mapping; New Repository, New Environment and the Folder view.
- [x] D5 Sync review, drift review (keep mine / take GitHub's), Settings after the removals (quick-vault shortcut, Sharing log, Touch ID), the menu bar item, and connecting Azure or another GitHub account after onboarding.

Build (maykel, mark, yati, anton; split further once each design is approved):
- [x] B0 XCUITest target with a throwaway-vault launch mode and `gh`/`az` fakes; one smoke flow (onboarding → main). e2e: the smoke flow twice.
- [x] B1 Move `PassphraseGenerator` to VaultCrypto; cut the Spaces hooks from SyncEngine and `DEKRotator`. e2e: smoke flow.
- [x] B2 Remove the sharing, chat, teammates and spaces screens and managers, the Bonjour and `.fxvault`/`.fxvcard` entries in `project.yml`. e2e: smoke flow, nothing about teammates in the UI.
- [x] B3 Remove the teammate, nearby, chat and spaces parts of SharingKit and `VaultData` (keep passphrase files: File, Passphrase, Bundle, Import); the tables stay, unread. Remove Supabase, Vercel, Overview and `fxvault.yml`.
- [x] B3c Remove the stage Overview and `fxvault.yml`: EnvTools `Manifest/`, `GHManifestAPI`, VaultData `Destinations/Overview/`, the Overview screens and row. Add Destination keeps its stage suggestions (moved to `DestinationRepository`); after an import FX Vault opens the repository at the first stage's environment instead of the Overview. e2e: smoke flow.
- [x] B3d Remove Supabase and Vercel (DestinationKit remotes and account clients, connections, settings, Add Destination). Migration `v16_drop_runtime_providers` deletes their destinations, items, journal and tokens (Bryan, 2026-10-25: delete them) and keeps their names in `retired_destinations` for a one-time notice after unlock; nothing is deleted remotely. A 0.9 file that carries them imports without them, and the preview says so. Key Vault stays. e2e: smoke flow.
- [x] B3b Share Securely: passphrase `.fxvault` export of an org, repository or environment, and the open/preview/held import, from D2's Share boards; **Send with AirDrop** of that file (system share, Bryan 2026-10-25).
- [x] B4 `admin:org` scope check per organization and the refresh flow (copyable commands and Re-check).
- [ ] B4b In-app Approve (D1's device code) through `gh auth refresh`: needs a check against a real gh login first (non-TTY behaviour, the browser step); reserved for Bryan's real account.
- [x] B5 Organization list commands and store (additive migration); read-only organization node. Split: B5a GitHubKit listings [x]; B5b store and import [x]; B5c the read-only node and its e2e [x].
- [x] B6 Organization writes with visibility and repositories, always sending the synced visibility and full repository list. Split: B6a GitHubKit commands [x]; B6b1 local changes in the store (`v19`) [x]; B6b2 organization Sync in VaultData (review, run, confirm) [x]; B6b3a the editable organization detail and access picker [x]; B6b3b the Sync group and the badge [x].
- [ ] D6 Design pass after B6b3b: compare every screen with the D1–D5 boards (snapshots side by side) and fix the gaps in small slices; list what waits for later features (notes, drift, settings, menu bar, quick vault, Share Securely).
  - Gaps found 2026-10-25 (boards rendered with Playwright from `docs/design/mockup/v1/`, app from the snapshot suites): D6a tables as Main2/Org-Visibility (33 pt rows, sentence-case 12 pt headers, Status as a dot and text, not a chip); D6b Sync sheet as Sync-Review (one compact card per place with an icon and kind, `+ ~ − !` lines with a short detail, fixes inline, footer "N changes in M places · deletions · blocked" beside Cancel / Sync N Changes); D6c window chrome as Main2 (sidebar and toolbar as floating glass panels, breadcrumb from the provider, ⌘K search field and the Sync pill in the toolbar, sidebar search ⌘F, GitHub / Azure / Folders sections; the detail header "kind · parent · counts" with Copy All, Notes | Table and ⋯).
  - Waiting for their features: Notes view and file secrets (B9), inherited/shadowed names and drift marks (B7), Settings tabs, menu bar, quick vault (B10).
- [ ] B7 Organization drift and verify; inherited and shadowed names on a repository.
- [x] B8 Azure discovery (`az account list`, `az keyvault list`) and Key Vault as a source. Split: B8a discovery, package layer [x]; B8b1 Key Vaults of their own in the store (`v18`) [x]; B8b2 Connect Azure (requirements, subscriptions and vaults, import), the vaults in the first-import summary [x]; B8b3 the sidebar Azure node opening the vault (and Show in Sidebar for a linked copy there) [x]; B8c1 Sync of the vaults of their own (review, run, badge) [x]; B8c2a Remove from FX Vault for a vault of its own [x]; B8c2b dropped (2026-10-25, Bryan: 0.9's repository Key Vaults stay under their repositories; no migration).
- [ ] B9 Notes view read-only, then editable with the change review.
- [ ] B10 File secrets: picker and drop, base64 option, limits (GitHub 48 KiB, Key Vault 25 KiB), trailing-newline notice.
- [ ] B11 New start, onboarding, notch unlock island (`LAAuthenticationView`), allowlisted setup-command runner and main window from D1–D2; macOS 26 deployment target.

Review D1 — start and onboarding (2026-10-25):
- Boards: 16 in `docs/design/mockup/v1/` (Welcome light/dark, recovery reset, password, recovery key, confirm, Touch ID, GitHub setup, connect GitHub, connect Azure, first import, fill values, 4 notch states).
- Decisions (Bryan): minimal black and white with Liquid Glass; macOS 26 minimum; notch island is the only unlock after onboarding; fill values from notes; setup commands run in an embedded allowlisted terminal; first-import check animation and Glass sound.
- Review: anton found 4 blockers (recovery confirmation with the key visible, missing gh setup states, incomplete `admin:org` command, one value matched to several places), 7 improvements and 5 nits; all applied. Six comments by Bryan on the canvas applied and resolved.
- Docs: `docs/design/V1-BRIEF.md`; `docs/DESIGN.md` gains the 1.0 section (the v0.3.0 sections still describe the code until B11).
- Commit: `f157237` `docs(design): add 1.0 brief, slice plan and start/onboarding boards`.

Review D2 — main window, actions, quick vault, share (2026-10-25):
- Boards: 21 on page "Main window" (home, expanded, dark, repository with inherited org names, sync failed, ⌘K, offline, actions menu, delete GitHub/Key Vault, export, quick vault ×4, share pick/passphrase/open/preview/expired).
- Decisions (Bryan): variables plain in Notes, secrets masked; place actions and delete at next Sync; quick vault from the notch on ⌃⌥V with expand; Share Securely as passphrase files, production allowed behind Touch ID (relaxes 0.9).
- Review: anton, two rounds — 3 blockers on the main window (missing account/scope lines, unclear Approve, no drift) and 6 security blockers on the new rows (secret copy in quick vault without Touch ID, production ticked, share without Touch ID, preview before passphrase, expiry before decrypt, org name in file name); all applied. His "export board missing" was a timing miss: the board existed.
- Commit: `f03186f` `docs(design): add main window, actions, quick vault and share boards`.

Review D3 — place view (2026-10-25):
- Boards: 9 on page "Place view" (edit, paste, secret value, review, reveal, table, file drop, file sheet, errors).
- Review: anton found 4 blockers (notes need an AppKit token text view, typing aids corrupt values, pasted values must become tokens, kind is fixed after Sync) and 6 improvements (48,000-byte limit after Base64, per-source name rules, all trailing CR/LF removed, reveal outside edit only, override removal, inherited rows read-only); verified in code (`Limits.maxValueBytes`, `Timeouts.revealRemask`, `DestinationRules`) and applied; build notes in the brief.
- Commit: `56cd273` `docs(design): add place view boards`.

Review D4 — organizations, Key Vault, create, folders (2026-10-25):
- Boards: 8 on page "Organizations, Key Vault, folders" (org visibility, org secret detail, Key Vault place, Key Vault name rules, New Repository, New Environment, folder, linked-copy update); D1–D3 boards touched only for the traffic-light layer and "private and internal".
- Review: anton found 3 blockers (case-insensitive Key Vault collisions, new Key Vault versions drop contentType and exp unless resent, names-only org secrets can't change visibility because setting a secret needs its value) and 5 improvements (private and internal, GitHub Free notes, README/description/license/account on New Repository, branch vs tag patterns, linked-copy checkboxes); all applied; he corrected my brief: disabled Key Vault secrets are listed, so greyed is right.
- Commit: `5201ac5` `docs(design): add organization, Key Vault, create and folder boards`.

Review D5 — sync, drift, settings, menu bar (2026-10-25):
- Boards: 12 on page "sync" (sync review, delete confirmation, progress, done; drift review; settings General, Security, reset confirmation, Accounts, Sharing, Advanced; menu bar).
- Review: anton found 2 blockers (gh shown below the 2.97.0 floor with a trust row that only exists for a gh owned by another user; a blocked org secret contradicting the org's Ready state) and 7 changes (deletions keep their own confirmation step, deletes run last, 60 writes a minute is FX Vault's limit, variable drift shows both values, Take GitHub's then Fill Value, concealed clipboard wording, per-account Test, SSH alias, GH_TOKEN and per-tenant Azure state); verified in code (`GHVersion.minimum`, `Limits.writesPerMinute`, `ClipboardManager`) and applied. Credential-looking variable note left out: no example variable fits.
- Commit: `9b043d5` `docs(design): add sync, drift, settings and menu bar boards`.

Review B0 — XCUITest target and throwaway vault (2026-10-25, automatic):
- Built: `UITesting` configuration (Debug + `FXVAULT_UI_TESTING`, app "FX Vault UI Test", `io.fractalx.fxvault.uitesthost`); `AppContainer.uiTest(root:)` over a vault in `$TMPDIR/fxvault-uitests/<uuid>`, the in-process scripted gh (owner-a, example-org, api-service; read commands only), fake Touch ID, in-memory settings, private pasteboard, inert lock sources; `--diagnose` off there. `Shared/AccessibilityID.swift` in app and tests. `FakeGHOutput` in GitHubKit/Testing replaces two AppTests helpers. `AppContainer.sandboxed(...)` shared by preview and UI test.
- e2e: `OnboardingSmokeTests` (create vault → recovery key → confirm 2 groups → open → sidebar shows owner-a, example-org, api-service, no "Could not be listed"); seen failing with the org's repo stub removed; green twice in `scripts/ci-local.sh`.
- Gates: `scripts/ci-local.sh` green (package tests, 661 app tests, Release build, no `fxvault-uitests` string in Debug or Release binaries, UI tests ×2, lint, check-secrets). Not in GitHub CI: hosted runners may refuse UI automation.
- Review: anton — 3 blockers (Release check never ran, plan edits mixed in, test stopped at the account row) and 6 changes (activate like live, duplicated container code, swallowed missing group, positional fields, deleting a running suite's folder, fake PATH to Homebrew, README tip disabling a macOS protection); all applied. Plan edits committed apart (`0ab5f7b`, quoting Bryan).
- Commit: `2a98f50` `test(ui): add XCUITest suite on a throwaway vault`.

Review B1–B3a — remove teammates, nearby, chat and spaces (2026-10-25, automatic):
- Built: B1, B2 and the sharing half of B3 as one change (they don't build apart). Removed teammates, pairing, presence, nearby (Bonjour, Local Network), chat and spaces from the app, SharingKit, VaultData and SyncEngine. Kept: passphrase `.fxvault` files (format 2 passphrase mode; v1 still opens), open/preview/held import, Share Project with the system share.
- `PassphraseGenerator` stays in SharingKit: the module is kept, so the B1 move is not needed.
- Migration `v15_drop_teammates` drops the removed tables, then a WAL checkpoint. Old settings (nearby display name and visibility, mute pings, remote space port) are deleted at launch.
- 0.9 compatibility: a teammates file is refused as `invalidFile`; `FXVAULT_SPACE` stays reserved and is hidden from listings; sent-share rows to teammates read "Removed teammate"; held rows still show Verified.
- Interim rule: production values are refused when sharing (`productionNotShared`). B3b brings in the brief's rule: production behind Touch ID, unticked by default.
- Tests: `HeldShareSnapshotTests` (held renders moved out of a deleted suite); 7 tests ported from `SharingExportViewModelTests` to `ProjectShareExportViewModelTests`; `settingsOfTheRemovedFeaturesAreDeleted`; `droppingTheTeammateTablesLeavesNoKeyBytesInTheWAL` (seen failing before the checkpoint); v14→v15 seed checks `sender_device_id`. Ported checks seen failing under mutations (no passphrase wipe, no saved gate, no settings cleanup).
- Test files removed: 43, all for removed features; Bryan approved and ran the deletion (2026-10-25).
- Gates: XcodeGen drift OK; `swift test` all suites green; `xcodebuild test` 561 app tests green; Release build OK; no UI-testing code in the binaries; UI tests ×2 green (`OnboardingSmokeTests`); lint OK; check-secrets OK (1,002 files). The first overnight run stopped at the UI tests because the screen was locked (automation mode needs an unlocked session); re-run after Bryan unlocked it and approved the deletion.
- Review: anton found 1 blocker (a test file on the deletion list still covered kept behaviour → 7 tests ported) and 6 changes:
  - WAL copies of dropped keys → checkpoint plus test.
  - v14→v15 test too thin → extended.
  - Orphan settings left on disk → deleted, with a test.
  - Production allowed in folders' copies → documented as a residual risk (SECURITY-MODEL).
  - Comment nits → fixed.
  - Cross-purpose authorization → no change; the types keep the purposes apart (`EnvExportAuthorizationModel` vs `ShareAuthorizationModel`, `.fileExport` only).
- Left in B3: remove Supabase, Vercel, Overview and `fxvault.yml` (Azure Key Vault stays).
- Commit: `aa669f8` `refactor(sharing)!: remove teammates, nearby, chat and spaces`.

Review B3c — remove the Overview and `fxvault.yml` (2026-10-25, automatic):
- Removed: EnvTools `Manifest/`, `GHManifestAPI` (B11) and `GHCommandScheduler.manifest`, `Limits.maxManifestBytes`, VaultData `Destinations/Overview/`, the Overview screens, row and `MainViewModel.overview`, Share Stage… (`ShareExportContext.stage`) and the manifest suggestion in Add Destination.
- Kept: Add Destination's stage suggestions, now `DestinationRepository.stageSuggestions` (destination stages, then GitHub environments, once per fold key).
- After a project file import the app opens the first repository at the environment of the first stage (the repository level if none). `MainViewModel.open(repositoryID:scope:)` keeps the scope pending until the sidebar row and the column exist.
- Tests: `stageSuggestionsListDestinationStagesThenEnvironmentsOnce`; `openingAScopeBeforeItsSidebarRowExistsSelectsItWhenTheRowAppears` (seen failing without the pending scope); the import test checks the staging environment opens. 9 test files and the cases for the removed features go (listed in the handoff).
- Gates (verify copy without the 9 files): XcodeGen drift OK; `swift test` all suites green; `xcodebuild test` 557 app tests green; Release build OK; no UI-testing code; UI tests ×2 green; lint OK; check-secrets OK (973 files); re-run in the worktree after Bryan ran the deletion; strings synced (second run: no change).
- Review: by me. Subagents were not available (session cap). Found and fixed: the first version of the pending-scope test passed without the change.
- Docs: README, CHANGELOG (Unreleased 1.0), ARCHITECTURE (decisions 113–114 gone, 112, 117, 124 updated), API (B11 gone), DATABASE, DESIGN, STRUCTURE, SHARING-PROTOCOL, RELEASING (#44 gone).
- Commit: `b9f8062` `refactor(destinations)!: remove the stage Overview and fxvault.yml`.

Review B3d — remove Supabase and Vercel (2026-10-25, automatic):
- Removed: DestinationKit `SupabaseRemote`, `VercelRemote`, both account clients, token credentials and `tokenMissing`; VaultCore `.supabase`/`.vercel`, `VercelEnvironment`, `ConnectionModel`/`ConnectionID`, `connectionID`, `isPublicAllowed`, `maxConnections` and their rules; VaultCrypto `SecretFieldAAD`; VaultData `DestinationAccessRepository`, connections, digests, review warnings, `connectionMissing`; app Preferences › Destinations, the provider and connection fields of Add Destination and Settings…, Mark as Public, the connection banner.
- Migration `v16_drop_runtime_providers`: their destinations, items, journal and every token deleted (connections table emptied, kept for the FK), names kept in `retired_destinations`; WAL checkpointed. Nothing is deleted remotely.
- One-time notice after unlock (`RetiredDestinationsNotice`, `DestinationRepository.retiredDestinationLabels` / `dismissRetiredDestinations`); OK clears it.
- 0.9 files: Supabase/Vercel destinations dropped on decode with their labels; lone link tokens removed; `publicNames` ignored; the import preview shows "Left out: …".
- Tests: `droppingTheRuntimeProvidersLeavesNoTokenBytesOnDisk`, `retiredDestinationsShowOnceThenClear`, v15→v16 seed, `a09FileDropsItsSupabaseAndVercelDestinations`, `theRetiredDestinationsNoticeShowsOnceThenClearsTheVault`, `aFailingReadShowsNoNotice`, `theRepositoryPreviewNamesTheDestinationsLeftOut`. Seen failing under mutations: no `DELETE FROM provider_connections`, no `dropLoneLinkTokens`, no dismiss guard.
- Test functions removed with the features: `publicValuesCanBeMarkedAsMeantToBePublic`, `connectionsSealTheirTokens`, `supabaseDigests…`, `dekRotationReKeysSupabaseMarkers`, `supabaseWritesAreConfirmed…`, `aMissingConnectionBlocks…`, `aSupabaseFill…`, `connectionTokensNeverEnterABundle`, `factoryRequiresAToken…`, `factoryCopiesTheToken`, `personalToken401IsNotRetried`, the `SecretFieldTests` suite, the Vercel/Supabase live tests, validator cases for Supabase refs, reserved prefixes and public names, `vercelPublicNamesCanBeMarkedAsPublic`, `supabaseAndVercelNeedASavedConnection`, `settingsRenamesAndRemovesConnections`, snapshots `settings-destinations` and `main-destination-vercel`. Rewritten to Key Vault: `reviewBlocks…`, the store `journalChecksItsColumns`.
- Test files removed: 26 (DestinationKitTests `VercelTests.swift`, `SupabaseTests.swift`, `Fixtures/vercel/*`, `Fixtures/supabase/*`); Bryan runs the deletion.
- Gates (verify copy without the 26 files): XcodeGen drift OK; `swift test` 1,289 green; `xcodebuild test` 556 app tests green; Release build OK; no UI-testing code; UI tests ×2 green; lint OK; check-secrets OK in the worktree (967 files); strings synced (second run: no change).
- Waiver: the notice is tested through injected closures; the app tests' in-memory vault can't seed `retired_destinations` (only v16 writes it). The SQL is covered by the store test.
- Review: by me (subagent cap). Found and fixed: a double clear when the alert's binding and OK both dismiss.
- Docs: README, CHANGELOG, ARCHITECTURE (decision 115 gone; 106–109, 111, 116–118, 124 updated), API (G.2/G.3 Supabase and Vercel gone), DATABASE (v16, `retired_destinations`), DESIGN, SECURITY-MODEL, SHARING-PROTOCOL, STRUCTURE, RELEASING (#41, #43 gone; #49 upgrade check).
- Commit: `3a90a62` `refactor(destinations)!: remove Supabase and Vercel`.

Review B3b — Share Securely: production behind Touch ID, Send with AirDrop (2026-10-25, automatic):
- Scope: repositories and environments. Exporting an organization waits for organizations in the store (B5/B6).
- Production stages are listed unchecked. Checking one asks for Touch ID; cancelling leaves it unchecked. Without Touch ID it is checked and Create asks for the master password with a production message. A production environment picked in the tree asks at Create too.
- Enforced in VaultData: `ShareAuthorizationPurpose.productionFileExport`; `exportBundle` refuses production without it (`productionNotAuthorized`, renamed from `productionNotShared`) before the authorization is consumed and again on the sealed bundle. The tick's confirmation is reused at Create (one prompt).
- Send with AirDrop: `NSSharingService(named: .sendViaAirDrop)` for the same staged file, gated by "I've saved it", shown only where the Mac offers AirDrop; Share… and Save… stay.
- Tests: VaultData `aProductionStageNeedsTheProductionAuthorization`, `aProductionStageExportsWithTheProductionAuthorization`, `theProductionAuthorizationAlsoExportsWithoutProduction`; app `productionIsListedUncheckedAndTickingItAsksForTouchIDOnce`, `cancellingTouchIDLeavesProductionUnchecked`, `withoutTouchIDProductionIsConfirmedWithThePasswordAtCreate`, `aProductionEnvironmentInTheTreeNeedsTheProductionConfirmation` (replace the two "never shared" tests), `sendWithAirDropNeedsTheSavedConfirmationAndHandsOverTheFile`. Seen failing under mutations: `allows` always true, `activeReauth` always the ordinary model, no cancel guard, no saved gate on AirDrop.
- e2e: `ShareProjectUITests` (import the scripted repository → Share Project → check production → note names it → password → passphrase; AirDrop disabled until "I've saved it" where offered). The scripted gh gained read-only import stubs. It fails when the app sends the ordinary authorization. Onboarding helpers moved to `VaultUITestCase`.
- Gates: XcodeGen drift OK; `swift test` 1,291 green; `xcodebuild test` 559 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (onboarding, share); lint OK; check-secrets OK in the worktree (944 files); strings synced (second run: no change).
- Review: by me (subagent cap).
- Docs: README, CHANGELOG, ARCHITECTURE, DESIGN, SECURITY-MODEL §10.5, SHARING-PROTOCOL, RELEASING #47.
- Commit: `e0cb1a8` `feat(sharing): share production behind its own confirmation, send with AirDrop`.

Review B4 — organization access (2026-10-25, automatic):
- GitHubKit: A6 `GHOrgsCommands.membership(organization:)` (`gh api -X GET user/memberships/orgs/{org}`), `GHOrgMembershipDTO`, `OrgAccessChecker` (role first, then `admin:org`; SAML → SSO with its URL; no scopes → unknown), `ScopeChecker.fixCommands(…, scopes:)`, `GHError.stopsAccountReads` (shared with the catalog, replacing its private `isFatal`).
- VaultData: `GitHubEnvironmentRepository.organizationAccess(accountLogin:)`, `adminOrgFixCommands(for:)`, `OrgAccessModel`.
- App: Preferences › Accounts lists each logged-in account's organizations with a chip (Ready, Needs admin:org, Org secrets need an org admin, Needs SSO authorization with Open SSO Page, Access unknown) and the admin:org commands when one needs them; Re-check reloads; a lock clears them.
- Assumption: FX Vault never runs `gh auth refresh` (needs a browser and the active account, §2); the in-app device-code Approve is B4b, after a real-gh check.
- Tests: GitHubKit `OrgAccessTests` (argv, decode, the rule table, fine-grained, admin:org commands), the A6 builder in `CommandBuilderTests`; VaultData `organizationAccessReadsEachRoleWithTheAccountsScopes`, `withoutAdminOrgTheOrganizationAsksForItOnThatAccount`, `aRevokedTokenStopsTheOrganizationAccessRead`; app `organizationsShowTheirAccessAndTheAdminOrgCommands`, `anAccountWithAdminOrgIsReadyWithNoCommands`, `organizationsThatCantBeReadStayHiddenWithoutAnError`. Seen failing under mutations: no role rule (UI, VaultData, GitHubKit), commands always shown, the lock keeping organizations.
- e2e: `AccountsUITests` (example-org Ready, example-labs Org secrets need an org admin); the scripted gh gained the A6 roles and the member organization.
- Gates: XcodeGen drift OK; `swift test` 1,299 green; `xcodebuild test` 562 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (onboarding, share, accounts); lint OK; check-secrets OK in the worktree (949 files); strings synced (second run: no change).
- Review: by me (subagent cap). Found and fixed: a comment claimed organizations are absent while loading.
- Lesson: a read test on a network failure hangs (reads retry on the manual clock); use a non-transient account error.
- Docs: README, CHANGELOG, API (A6), ARCHITECTURE, DESIGN (Accounts), RELEASING #50.
- Commit: `69281f9` `feat(accounts): show each organization's access and the admin:org commands`.

Review B5a — organization listings in GitHubKit (2026-10-25, automatic):
- B12 `GHSecretsCommands.list(organization:)` and B13 `GHVariablesCommands.list(organization:)` with `--org=` and the `visibility,numSelectedRepos` fields (checked against gh 2.102.0's help); scheduler `listOrganizationSecrets` / `listOrganizationVariables`.
- `OrgVisibility` (VaultCore: `all`, `private`, `selected`); `GHSecretDTO` and the variable DTO/listing gain optional `visibility` and `numSelectedRepos` (nil for repository listings), so the decoders are shared.
- No UI yet: B5b stores them, B5c shows them; no e2e in this part (the UI-test gh gets org stubs in B5c).
- Tests: `OrgListingTests` (argv, invalid org, decoding of each visibility, an unknown visibility is malformed, repository listings carry none); `CommandBuilderTests` registers B12/B13 (seen failing before).
- Gates: `swift test` 1,304 green; app and test targets build; lint OK; check-secrets OK (951 files). Full CI and UI tests run with B5c.
- Docs: API (B12/B13).

Review B5b — organization store and import (2026-10-25, automatic):
- VaultCore `OrganizationModel`, `OrgItemModel`, `OrganizationID`; VaultCrypto `OrgFieldAAD` (table `org_items`, the organization as container), and one `FieldContext` protocol for every field AAD (commit `ba6b649`).
- VaultStore: migration `v17_organizations` (additive: `organizations`, `org_items`), `OrganizationRecord`, `OrgItemRecord`, `OrganizationStore`.
- VaultData: `OrganizationRepository` (import, list, observe, remove), `OrgFieldCipher`, `OrgImportResultModel`; `RepoCatalogError` gains `.organizationAlreadyImported` and `.organizationNotFound` and a shared `perform`; `DEKRotator` re-seals org values, the destination loop now shares the same `rotate` step.
- Assumption: a listed row without visibility fails the import (`.malformedOutput`) instead of guessing who can read the item.
- Not wired into the app yet: B5c adds it to `VaultDataComponents` with the sidebar node.
- Tests: `OrganizationStoreTests` (constraints, case-insensitive login, counts, cascade), `MigrationTests` (v17 in the frozen list and step-by-step), KAT `organizationFieldAADAndBlobs` (new Python vectors; the old ones byte-identical; refused as repository, folder and destination item), `OrganizationRepositoryTests` (import with visibility and selected count, skipped names, already imported, missing visibility, failed list, locked vault, removal, DEK rotation). Seen failing under 6 mutations: no `synced_fp`, rotation skipping orgs, stale `synced_fp` kept, wrong AAD table, a default visibility, `selected_count` kept for non-selected.
- Docs: DATABASE (v17, tables), SECURITY-MODEL (organizations), ARCHITECTURE (OrgFieldAAD, Organizations).
- Gates: `swift test` 1,316 green; `xcodebuild test` app tests green; lint OK; check-secrets OK (958 files); strings up to date. UI tests run with B5c (no UI here).
- Commit: `1e96536` `feat(organizations): store organization secrets and variables in the vault`.

Review B5c — the read-only organization node (2026-10-25, automatic):
- App: `VaultDataComponents.organizations` and `FeatureDependencies.organizations`; each organization group in the sidebar starts with a Secrets and variables row (count once imported, "Import" before; context menu Import or Remove from Vault…); `SidebarViewModel` observes vault organizations, selects a repository, a folder or an organization one at a time, imports through the group's account, removes with confirmation; `SidebarOwnerModel` carries `accountLogin` and its `OrganizationModel`; search keeps an imported organization by its login.
- Column 2 shows an ORGANIZATION note; column 3 the Import prompt or `OrganizationDetailScreen` (counts with "without value", Read only tag, Remove from Vault…, table Name | Kind | Value | Visibility | Updated; `OrgVisibility.title(selectedCount:)`).
- Assumptions: Import is offered whatever the access chip says (a missing `admin:org` fails with gh's error; Settings › Accounts explains it); an organization belongs to the account that imported it, so another account listing the same organization still shows Import and gets "Already in the vault" (revisit with B6 writes); the arrow keys do not step onto the organization row yet.
- Tests: app `OrganizationViewModelTests` (grouping and search, vault-only organization, visibility and count texts, one selection at a time, import needs gh and an unlocked vault, import → detail → rows and counts → removal clears it). Seen failing under 4 mutations: selection not cleared, detail not followed, search dropping the organization, a vault-only organization dropped.
- e2e: `OrganizationUITests` (example-org row → Import → NPM_TOKEN, STRIPE_KEY, REGION with All repositories, Selected · 3 repositories, Private and internal repositories); the scripted gh gained B12/B13 for example-org.
- Docs: README, CHANGELOG, DESIGN (Organizations), ARCHITECTURE (sidebar), RELEASING #51.
- Gates: XcodeGen drift OK; `swift test` 1,316 green; `xcodebuild test` 567 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (onboarding, share, accounts, organization); lint OK; check-secrets OK in the worktree (964 files); strings synced (second run: no change).

Review B11a — macOS 26 minimum (2026-10-25, automatic):
- `project.yml` deployment target 26.0, `Package.swift` `.macOS("26.0")`, the cask `depends_on macos: :tahoe`.
- Availability branches gone: `SecretValueEditor` (Writing Tools off), `BuildCapabilities` (biometry state hash), `SheetChrome.linkPointer`, the main toolbar (one `MainToolbar`, shared glass hidden); `ProcessRunner` uses `posix_spawn_file_actions_addchdir` (the `_np` form is deprecated in 26).
- No new test: the change removes code paths for older systems; the existing suites cover the kept paths (`SecretValueEditorTests` lost its availability guard).
- B11 split: B11a macOS 26; B11b two-column main window with the GitHub › owner › repo › environment tree in a glass sidebar; B11c black-and-white tokens and Liquid Glass; B11d onboarding and start (D1); B11e notch unlock island; B11f allowlisted setup-command runner.
- Docs: README (requirements; 0.9 is the last for macOS 14 and 15), CHANGELOG (Removed), ARCHITECTURE, DESIGN, RELEASING (rows 11 and 14).
- Gates: `swift test` 1,316 green; `xcodebuild test` 567 app tests green; Release build OK; no UI-testing code; UI tests ×2 green; lint OK; check-secrets OK in the worktree (964 files).

Review B6a — organization write commands in GitHubKit (2026-10-25, automatic, built in a parallel worktree):
- §8 C10/C11 org secret set and delete, C12/C13 org variable set and delete (registered as writes), B14/B15 the repositories of a `selected` secret or variable (`gh api`, every page).
- `GHOrgRepositoryAccess` (`all`, `private`, `selected`) means every write sends `--visibility=`; `GHSelectedRepositories` throws for an empty list, an invalid name or a duplicate, so `selected` always sends the complete `--repos` list. Values only on stdin; log templates carry `{repos}`, never names or values.
- B14/B15 decoding fails on a count other than `total_count` or an invalid name: a write built from a partial list would revoke repositories.
- Not confirmed: that gh prefixes the organization to bare `--repos` names, and that org `variable set` upserts (POST then PATCH on 409) like C7. Both get checked with Bryan's real gh before B6 writes ship.
- Open for B6b: a `selected` item with no repositories cannot be written (secrets have `--no-repos-selected`, variables nothing); the §8 rule text should list the org `gh api` reads.
- Tests: `OrgWriteTests` (10) and the six commands in `CommandBuilderTests.allCommands`; 8 mutations caught.
- Docs: API (B14/B15, C10–C13, the `gh api` rule).
- Gates: `swift test` 1,326 green; the app builds; lint OK; check-secrets OK (967 files).

Review B8a — Azure discovery, package layer (2026-10-25, automatic, built in a parallel worktree):
- DestinationKit `AzureCLIRunner`: the trusted `az` run rules, the exact environment and stderr classification moved out of `AzureCLITokenProvider` so discovery shares them; new: ARM `AuthorizationFailed` → `.forbidden`, a truncated stdout → `.responseTooLarge`.
- `AzureCLIDiscovery`: `az account list` (subscriptions, one per id, the default wins; `[]` → `.azNotSignedIn`) and `az keyvault list --resource-type vault --subscription <uuid>` (the id is a `UUID`, so it never becomes a flag; vault names pass `DestinationRules`; `vaultUri` kept only when it is the vault's own allowlisted host). `discover()` keeps one subscription's failure on that entry and runs one `az` at a time (token cache races).
- VaultData `AzureDiscoveryRepository` (no storage, works while locked); `ShellResolvingAzureCLI` shared with `ShellResolvingAzureTokens`.
- Not verified against a real `az`: `[]` with exit 0 when signed out, `properties.vaultUri` in the list, the exact `AuthorizationFailed` stderr. Check with Bryan's `az` before B8b ships.
- Open for B8b: hide tenant-only entries and Disabled or Deleted subscriptions? One malformed entry fails the whole listing (strict on purpose for now).
- Tests: `AzureDiscoveryTests`, `AzureDiscoveryRepositoryTests`, fixtures `Fixtures/az/`; 11 mutations caught.
- Docs: API (G rows), ARCHITECTURE, SECURITY-MODEL (`az` runs more than one read command).
- Gates: `swift test` 1,340 green; app and test targets build; lint OK; check-secrets OK (974 files).

Review B11b — two-column main window, sidebar tree (2026-10-25, automatic):
- `NavigationSplitView` has two columns: the sidebar tree and the selected place. `ScopeColumnView` and `FolderOverviewView` are gone; the folder hint moved into the folder header.
- Sidebar: GITHUB (accounts, owners, repositories), the selected imported repository's environments, New Environment and destinations nested under its row (`ScopeListView`, `sidebarTreeIndent`), FOLDERS after GitHub, no `surface` fill (the window's sidebar glass shows).
- The repository row stands for the repository scope: `MainViewModel.select(repository:)` goes back to it from an environment, `isRowSelected(_:)` highlights it only then; `ScopeListViewModel.environmentScopes`; Up and Down still walk repository scope › environments › destinations.
- Toolbar: the mark and `MainViewModel.breadcrumb` (`GitHub › owner › repo › environment`, `Folders › name`), last two steps when long; the app name with nothing selected. `toolbarTitleWidth` 340, sidebar 240–280.
- Strings: `main.sidebar.github` added; Accounts, Scopes, Build · GitHub Actions, the scopes empty state and the organization column note removed.
- Tests: app `theRepositoryRowIsItsRepositoryScopeAndThePathFollowsTheSelection` (seen failing when re-clicking the row does not return to the repository scope); e2e `MainTreeUITests` (staging and production under api-service, the path follows staging and back).
- Visual check: `main-sidebar` shows the tree; full-window captures still leave the glass sidebar blank (known capture limit, DESIGN.md).
- Docs: README, CHANGELOG, DESIGN (main window), ARCHITECTURE, STRUCTURE.
- Gates: XcodeGen drift OK; `swift test` 1,340 green; `xcodebuild test` 568 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (5 tests); lint OK; check-secrets OK in the worktree; strings synced (second run: no change).

Review B11c — black-and-white tokens and system type (2026-10-25, automatic):
- Color sets (1.0, boards Main2-Home and Main2-Dark): ground white / black, ink black / white, system greys for muted (`#3F3F42` / `#AEAEB2`) and subtle (`#5C5C61` / `#8E8E93`) text, hairlines black 8–16% / white 10–20%, `card` a translucent glass fill (white 80% / `#1C1C1E` 72%), Brand is ink (no brand blue; still the global accent). Warning, success and danger unchanged (small marks only).
- Type: SF Pro and SF Mono (`Font.system`, `NSFont.monospacedSystemFont`); body 13, secondary 12, labels 11, titles 22–24 semibold; no heading tracking.
- Removed: `FontRegistry`, the six Geist faces and `Geist-OFL.txt`, `ATSApplicationFontsPath`, the Geist notice and OFL text in Credits.rtf, the face and license tests.
- Tests: `DesignTokenTests` (1.0 values, seen failing with the old Ink color set; type scale; no bundled fonts), `DesignComponentTests.appKitMonospacedFontIsTheSystemMono`.
- Visual check: snapshots in light and dark are black and white with SF type; links and pending dots are ink.
- Left for later slices: `glassEffect` on floating chrome (progress, footer action bar) lands with the screens that have it (B11d–f, B9).
- Docs: CHANGELOG, DESIGN (1.0 status, principles, Color, Type), ARCHITECTURE, STRUCTURE.
- Gates: XcodeGen drift OK; `swift test` 1,340 green; `xcodebuild test` 564 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (5 tests); lint OK; check-secrets OK in the worktree.

Review B11d — onboarding Secure phase (2026-10-25, automatic):
- Welcome (board Main): centered mark, "FX Vault", the 1.0 line, Create Vault, "Secure · Connect · Import", "Encrypted on this Mac". The gh status row and the steps side panel are gone (gh is checked in the Connect phase, B11d2).
- Secure phase: one column with `OnboardingPhaseHeader` and `StepCounter` over the phase's own steps (01 / 04, 3 without Touch ID); board copy on Password, Recovery key, Confirm (groups named from this run's picks) and Touch ID (two fact lines).
- Password step has Back (`backToWelcome()`, clears what was typed). Recovery key: Continue waits for the "I saved it offline" checkbox (`hasSavedRecoveryKey`, reset with the key); no Back there, the vault already exists (assumption).
- Deferred: the board's "Save…" (write the key to a file) is not built; Copy only. The Done step stays, restyled by the column, until the Connect phase replaces it.
- Removed: `OnboardingStepsPanel`, `Theme.Layout.onboardingSidePanelWidth`, `OnboardingViewModel.ghStatus`, the recovery warning banner.
- Tests: `OnboardingViewModelTests` (gate seen failing with the old guard; `theSecurePhaseCountsItsStepsAndPasswordGoesBack`); UI `onboard()` asserts Continue is disabled before the checkbox; snapshots `onboarding-welcome`, `onboarding-recovery` added and checked in light and dark.
- Docs: CHANGELOG, DESIGN (lock and onboarding).
- Gates: XcodeGen drift OK; `swift test` 1,340 green; `xcodebuild test` 567 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (5 tests); lint OK; check-secrets OK in the worktree; strings synced (second run: no change).

Review B11d2 — Connect GitHub and first import (2026-10-25, automatic):
- Flow: the last Secure step (Touch ID, or Confirm without it) opens `ConnectScreen` (`AppViewModel.isFirstConnectPending`, in memory; a lock clears it). `GHSetupScreen` still comes first when gh needs attention. The onboarding Done step is removed.
- Connect GitHub: per ok account, its organizations with `OrgAccessStatus` and one personal row (repositories neither archived nor imported); ready rows checked. An organization two accounts reach is listed once, under the first account that can read it.
- Continue imports in order: organizations through `OrganizationRepository.importOrganization`, personal repositories one by one through `RepoCatalogRepository.importRepository`; a failure is named in the summary and the rest goes on. Not Now imports nothing.
- Summary (board FirstImport): organizations and repositories (with environments) with secret and variable counts, total, failures, the "never returns secret values" note. Key Vaults join with B8b; the per-environment split of the board is folded into the repository row (the import result has totals only).
- Deferred: Approve on GitHub (B4b, reserved), Open SSO Page and Show Commands in the rows (Settings › Accounts has them); the Connect step counter waits for Connect Azure; the board's Back on Connect is Not Now (nothing to go back to once the vault exists).
- Tests: `ConnectViewModelTests` (sources and default checks, dedupe, import with a failure, counts agree, lock); dedupe and default checks seen failing under a mutation; onboarding tests now end in the Connect phase; UI `ConnectUITests` imports example-org through the summary; `onboard()` takes Not Now; snapshots `connect`, `connect-summary` checked in light and dark.
- Docs: README (first launch), CHANGELOG, DESIGN, ARCHITECTURE, STRUCTURE.
- Gates: XcodeGen drift OK; `swift test` 1,340 green; `xcodebuild test` 574 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (6 tests); lint OK; check-secrets OK in the worktree; strings synced (second run: no change).

Review B11e — notch unlock island (2026-10-25, automatic):
- `NotchIslandController` owns a borderless `NotchIslandPanel` (status-bar level, no shadow, `sharingType = .none`, hidden while another app is active) showing `NotchIslandView` over the shared `AppViewModel.lockScreen`; `NotchGeometry` hangs it from the notch or floats it 6 pt under the menu bar.
- States: Touch ID (system prompt for now) with Use Password; password with the reason or error and Recovery Key…; "Unlocked" for 0.9 s. The island never shows names or values.
- Window: `lock(trigger:)` presents the island and closes the main window; at launch and on Dock reopen the window closes again while locked; `didUnlock()` opens it. Recovery and the Touch ID offer use the window (`showLockWindow()`); cancelling recovery returns to the island. The window lock card stays for tests and previews (no side effects, no island).
- Split: B11e2 embeds Touch ID with `LAAuthenticationView` (needs the island's `LAContext` passed to the keychain read; testable only on a signed build with a sensor).
- Removed: `AppViewModel.makeLockViewModel()` (one shared lock model).
- Tests: `NotchIslandTests` (geometry with and without a notch, states, shared model, no island without side effects); `DesignTokenTests` (Island color sets); UI `NotchIslandUITests` (⌃⌘L closes the window, the island's password unlocks); snapshots `island-touchid`, `island-password` checked. Waiver for the notch hardware and Touch ID checks (tasks/waivers.md).
- Docs: README (Unlocking), CHANGELOG, DESIGN, ARCHITECTURE, STRUCTURE.
- Gates: XcodeGen drift OK; `swift test` 1,340 green; `xcodebuild test` 580 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (7 tests); lint OK (first run flagged a literal symbol size, now `Theme.Typography.title`); check-secrets OK in the worktree; strings synced.

Review D6a — tables as the boards (2026-10-25, automatic):
- Rows 34 pt (`tableRowHeight`, cell 26), column headers 12 pt medium sentence case muted, `TableMetaText` 12 pt sans muted, Status column `StatusDotLabel` (dot + title) in the repository, folder, destination and organization tables. Chips stay for tags and Value missing.
- Checked against Main2 / Org-Visibility renders; `DesignComponentTests` measures the real row height.
- Docs: DESIGN.
- Gates: full CI green (swift test, app tests, Release build, UI tests twice, lint); check-secrets OK in the worktree.

Review D6b — the Sync sheet as Sync-Review (2026-10-25, automatic):
- Summary: no eyebrow, "Review Sync" in `.leadEmphasized` (15 pt semibold) and the board's subtitle; the write limit moved under the cards; 12 pt between cards.
- One hairline card per place (`SyncSummaryRepoModel.cards`): the repository's own scope, each environment (`api-service › production · environment`), each Key Vault, each organization. Header: `Theme.Symbols` symbol (new; the vault's provider symbol), name in `.placeName` (12 pt semibold), muted kind. A created, renamed or deleted environment adds its sentence.
- Blocked, dependent and changed-on-GitHub changes sit in their place's card (`SyncIssueModel.place`); a place with only blocked changes gets its own card; the new repository note and unplaced issues join the repository's card, else the first. Notes carry their place too.
- Lines are a model (`SyncChangeLineModel`: symbol or none, name, detail, text): rename `~ NEW  variable · renamed from OLD`, deletion red with `· deleted on GitHub` / `· deleted in Key Vault`, deployment branches without symbol, muted. Names `.monoMeta`, details muted `.caption`. `text` keeps the old strings for Copy as Text.
- Blocked lines: `!` in ink (only `−` is red), the changed name in mono, the reason below, the fix as an inline link; VoiceOver reads the full title and the reason.
- Counts: the button "Sync N Changes" with N = `pendingCount`, the toolbar's §7.1 count (an environment rename or delete is one change, whatever it copies; GitHub's `summary.pendingCount` + destination and organization changes); the footer "N changes in M places · D deletions · B blocked" with N = that count + what does not run (blocked, waiting, changed on GitHub) and M = cards. Plurals via `inflect`.
- A destination-only repository's card is named from its `RepoModel` (`DestinationSyncPresentation.merge(…, repository:)`), not by splitting the full name.
- `ConfigSheetFooter.metaHelp` removed (unused since the footer lost its meta). Updates read `~` everywhere (destinations, organizations, held shares were `↑`).
- Departures from the board: card order is repositories, Key Vaults, organizations (the board puts the organization first); details show the kind, never values (the board shows `info → debug`, `beta,search`, `selected 3 → 4 repos`); a blocked line keeps its reason sentence below the name (the board: `blocked · no value` inline); with deletions the primary button stays "Review N Deletions…" (§7.5); Copy as Text and the write limit are kept; the fix link is `FXLinkButtonStyle` (the board underlines it).
- Tests: `summaryShowsNamesCountsAndTheWriteLimit` (cards, line parts, a blocked change in its card, footer "4 changes in 2 places · 1 blocked", button "Sync 3 Changes"), `renameAndPolicyLinesKeepTheirParts`, `blockedChangesCarryReasonsAndFixes` (a card for blocked-only production, "7 changes in 2 places · 6 blocked"), `anEnvironmentRenameCountsOnceOnTheButtonAndInTheFooter` (seen red: "Sync 6 Changes", "6 changes in 1 place"), the Key Vault group's card and the destination card's routing and name; snapshot `sync-summary` now has a rename, a deletion, a blocked line, a Key Vault and an organization, compared with the Sync-Review render (light and dark).
- Docs: DESIGN (Sheets, type table, board table), README, CHANGELOG.
- Gates: `FXVAULT_SKIP_UI_TESTS=1 scripts/ci-local.sh` green in the worktree (drift check with XcodeGen 2.45.4, swift build and test, app build and 604 app tests, Release build, no UI-testing code, lint, check-secrets 1002 files); targeted SyncViewModelTests, DestinationViewModelTests and the `sync-summary` snapshot; strings ×2 (second run up to date); UI tests twice: 7/8, AccountsUITests blocked by Orca's local-network prompt (see night.md).

Review D6c1 — the sidebar as Main2 (2026-10-25, automatic):
- Tree: no account level; one node per owner across the gh accounts (`SidebarGrouping.owners`), through the account that imported it, else the first signed-in one that lists it; organizations first, then people, each by login (the boards' order). An organization's node is its place (selecting it opens its secrets and variables or Import) and expands to its repositories; owners start collapsed, a selection opens its owner, a search opens all; "Show N more" holds the repositories not in the vault (the selected one always shows).
- Sublines (`SidebarOwnerProblem`): Not logged in · Settings, Needs repo… · Approve, Needs admin:org · Approve, Org secrets need an org admin, Authorize SSO · Open, Could not be listed. Organization access is read per signed-in account after each reload, in the background (skipped offline). Approve opens Settings › Accounts (`AppViewModel.requestedSettingsTab`); in-app approval stays B4b.
- Rows: `SidebarTreeRow` (28 pt, chevron and symbol columns, 14 pt per level, mono names, sans for folders), `SidebarSubline`, `SidebarSectionHeader` (GitHub, Azure, Folders), `SidebarPendingDot`, `KeyHint`. Environments are level-2 rows; Key Vaults stay flat under Azure until 1g.
- Moved: search into the sidebar (⌘F, `KeyHint`; the toolbar `.searchable` is gone), Lock and Settings to its bottom (toolbar Lock and the auto-lock line gone), Add Repository by Name… to the owner's menu, New Environment… to the repository's (`MainViewModel.newEnvironment(in:)`; the dashed row and `ScopeListViewModel.newEnvironment()` are gone).
- Not yet: counts of secrets without a value on repositories (no per-repository count; the pending dot shows), "Changed on GitHub" under an environment (B7), the recovery-key notice (1c); runtime destinations keep their section as is.
- Tests: `SidebarViewModelTests` (`ownerTwoAccountsSeeShowsOnceThroughItsImporter`, organizations before people, first signed-in account, sublines from access, Show N more, expansion and ⌘F, access after reload), `MainViewModelTests.newEnvironmentFromTheRepositoryMenuNeedsAdmin`, `PreferencesViewModelTests.approveInTheSidebarOpensTheAccountsTab`, `MainScreenPresentationTests.ownerSublinesSayWhatToDo`; snapshots `main-sidebar`, `main-sidebar-home`, `main-sidebar-expanded`, `main-sidebar-folders`; UI tests reveal example-org's repositories (chevron, Show N more), the smoke flow finds api-service with ⌘F, `MainTreeUITests` attaches a window screenshot.
- Places draw with `Theme.Symbols` (D6b) in the sidebar, the scopes, the organization prompt and Sync; a Key Vault with its provider's symbol.
- Docs: README, CHANGELOG, DESIGN, ARCHITECTURE, STRUCTURE.
- Review fixes: Edit › Find (⌘F) is a menu command that brings a hidden sidebar back and focuses the search (`MainViewModel.findInSidebar()`; the `KeyHint` button lost its own shortcut); the owner chevron has `AccessibilityID.Main.ownerToggle` (UI tests use it, not the label); a repository's chevron says "Open name" (it selects, never hides); `SidebarCount` is the one trailing count (environments, destinations, Key Vaults, folders); "Org secrets need an org admin" only on an imported or selected organization (`SidebarGrouping.shownProblem`); `ScopeListViewModel.canCreateEnvironment(in:)` is the one environment rule; Share draws a repository with `Theme.Symbols.repository`; RELEASING steps 19 and 51 rewritten. Tests: `findShowsTheSidebarAndFocusesItsSearch`, `memberOnlySublineShowsOnAnImportedOrSelectedOrganization`, `repositoryChevronSaysItOpens`, the smoke flow's ⌘F with the sidebar hidden (⌃⌘S; `SidebarCommands` added for View › Hide Sidebar). Deferred to the plan: the per-repository "N without value" count (needs a store query).
- Gates: rebased on D6b e373242; `FXVAULT_SKIP_UI_TESTS=1 scripts/ci-local.sh` green in the worktree (drift check with XcodeGen 2.45.4, swift build and test, 612 app tests, Release build, no UI-testing code, lint, check-secrets 1006 files); targeted Sidebar, Organizations, Main window, Preferences, Main screen presentation, Scope list, Accounts settings and Sync sheet suites; snapshots `main`, `main-selection`, `main-sidebar`, `main-sidebar-home`, `main-sidebar-expanded`, `main-sidebar-folders`, `main-keyvault-standalone` compared with Main2-Home, Main2-Expanded, Main2-Repository and Main2-Dark (light and dark); strings ×2 (second run up to date); UI tests twice on 3f3770d: 7/8 each (only AccountsUITests, on Orca's prompt). Review fixes: targeted Sidebar, Main window, Scope list, Main screen presentation, Share and visual snapshot suites (70 tests); ci-local without UI green (615 app tests, lint, check-secrets 1005 files); strings ×2 (2 keys added, second run up to date); the smoke flow's ⌘F with the sidebar hidden runs in the next UI pass.

Review B6b3b — organizations in Sync (2026-10-25, automatic):
- Badge: `AppViewModel.organizationPendingCounts` (observed from `OrganizationItemRepository`) joins the Sync count and the Dock badge.
- Sync sheet: the toolbar Sync reviews each organization with pending changes (`OrganizationSyncRepository.review`), one summary group per organization (`OrgSyncPresentation`, "+ / ↑ / −" lines, blocked rows with Edit… for a missing value or empty list), its deletions in the deletion review, and runs them after GitHub and destinations; result rows per change. A repository's own Sync leaves organizations out.
- `SyncGroupID` (repository, Key Vaults, organization) replaces `RepoID?` as the summary and deletion group id.
- Assumptions: no per-change progress inside an organization (the progress line names the organization); a blocked "changed on GitHub" has no fix until B7 (organization refresh).
- Tests: `SyncViewModelTests.organizationChangesJoinTheBadgeTheSummaryAndTheRun` (lean testing from here on, Bryan 2026-10-25).
- Docs: README, CHANGELOG, ARCHITECTURE.
- Gates: the full CI run passed (package suites, app tests, Debug and Release builds, UI tests twice, lint); check-secrets OK in the worktree.

Review B6b3a — editable organization detail (2026-10-25, automatic):
- Detail: Add Secret / Add Variable, a Status column, the struck-through name of a deletion; the row menu Copy Value, Edit… (also double-click), Revert for adds, deletions and access changes (Revert Access when every row is an access change; `OrgItemModel.isAccessChanged`, a value change alone offers none), Delete… (⌫ too); synced rows confirm with the repository texts (`ConfigDeletionModel.title/confirmTitle/message` now static by count and names), adds go at once. Read only tag removed.
- `OrgItemEditorScreen/ViewModel` (`MainSheet.orgItemEditor`): kind and name on add (taken and pending-deletion notes), value (variables loaded, a secret's empty editor keeps its value, "Already matches GitHub" for a secret without one), Access All / Private / Selected with the sidebar's repositories of the organization. A Selected item whose list GitHub holds keeps it until repositories are picked; an empty Selected list blocks Save. `load()` runs once (the view's task runs again when it reappears).
- Shared with the item editor, no behaviour change there: `ItemValueRules`, `ItemNameField`, `ItemFillChoiceField`, `ItemEditorReadOnlyName`, `CredentialWarningView` (`ItemEditorFields.swift`); `ConfigKind.addTitle`; `FeatureDependencies.copyOrganizationValue`.
- Test ids: `AccessibilityID.ItemEditor.name/value` (the value id set on the `NSTextView`: a SwiftUI id stops at the scroll view), `Main.organizationAdd(kind)`.
- Assumptions: no Reveal (eye) in the organization table yet; Revert never undoes a changed value (no synced copy, B6b1); repositories offered are the ones the sidebar lists for the organization.
- Review (review-code): fixed the "0 repositories" note (no count), Revert Access offered for value-only changes, `save()` returning true without writing, the default `repositoryNames`, STRUCTURE tree. Kept: the value-edit tracking (`value` didSet + programmatic flag, ~10 lines) stays in each editor: SwiftUI binds `$viewModel.value` on each `@Observable` model, and a shared wrapper would change both editors' bindings for little gain.
- Tests: `OrganizationEditingTests` (4), UI `OrganizationUITests.testAddingAVariableAndDeletingASecretWaitForTheNextSync`; snapshots `organization-detail`, `organization-item-editor` checked. Mutations caught: empty Selected allowed, matches-GitHub ignored, access never saved, variable value not loaded, adds confirmed, taken name allowed, load not idempotent.
- Docs: README, CHANGELOG, DESIGN, STRUCTURE, ARCHITECTURE.
- Gates: the full CI run passed (package suites, 601 app tests, Debug and Release builds, UI tests twice, lint); check-secrets OK in the worktree; strings synced.

Review B6b2 — organization Sync in VaultData (2026-10-25, automatic):
- `OrganizationSyncRepository` (actor, through the importing account): `review(organizationID:)` lists B12/B13 and blocks `existsRemotely` (an add), `remoteChanged` (`updatedAt` differs, or gone, for an update or deletion), `valueMissing` (a secret write without its value), `listingFailed`; `run(_:includeDeletions:)` sends writes first, deletions last (only when included), each write with the complete access (edited list, or B14/B15 read just before; `noRepositories` for an empty list); a deletion GitHub no longer has finishes locally; one confirming re-list records `synced_visibility`, `synced_fp`, `remote_updated_at` and the repository count and clears the edited list.
- Models: `OrgChangeModel`, `OrgBlockReason`, `OrgBlockedChangeModel`, `OrgReviewModel`, `OrgChangeOutcome`, `OrgRunResultModel` (names only).
- Assumptions: no journal (an interrupted write is blocked as changed until a refresh); still unconfirmed against real gh: bare `--repos` names and org `variable set` upserting (B6a), checked with Bryan's gh before B6 ships.
- Tests: `OrganizationSyncRepositoryTests` (3). Mutations caught: list never fetched, no remote-change block, no value-missing block, adds not blocked, deletions always run, confirm not recording, empty list written, deletion keeping the row.
- Docs: ARCHITECTURE (decision 140).
- Gates: the full CI run passed (package suites, app tests, Debug and Release builds, 7 UI tests twice, lint); check-secrets OK in the worktree.

Review B6b1 — organization changes in the store (2026-10-25, automatic):
- Migration `v19_org_item_changes` (additive): `org_items.is_deleted`, `synced_visibility` (backfilled from `visibility`), `repositories_edited`; table `org_item_repositories`. Imports set `syncedVisibility`.
- `OrgItemRecord.syncStatus` / `OrgItemModel.syncStatus`: deleted, added (never synced), modified (value fingerprint ≠ `synced_fp`, visibility ≠ synced, or the list edited), synced; a secret without a value is synced.
- `OrganizationItemRepository` (VaultData): `addItem` (revives a pending deletion of the same name; 1,000 per kind, GitHub's limit), `setValue` (`alreadyMatchesRemote` for a secret filled to match GitHub), `setAccess` (`OrgItemAccessModel`; a `selected` list validated whole by `GHSelectedRepositories`), `repositories(of:)`, `deleteItems` (adds disappear), `revertItems` (adds, deletions, access; not a changed value: no synced copy is kept), `reveal`, `pendingCounts` / `observePendingCounts`. `ConfigRepositoryError.organizationNotFound` (app message added).
- Not wired into the app yet (B6b3); not in the Sync badge yet (B6b2/B6b3).
- Tests: `OrganizationItemRepositoryTests` (3), `MigrationTests.organizationItemsKeepTheirVisibilityAsSynced`, the migration list. Mutations caught: imports not synced, no backfill, list edits ignored, deleting an add leaves a tombstone, no revival, revert keeps the list.
- Docs: DATABASE (v19), ARCHITECTURE (decision 139).
- Gates: the full CI run passed (package suites, app tests, Debug and Release builds, 7 UI tests twice, lint); check-secrets OK in the worktree; strings up to date (`error.config.organizationNotFound` added).

Review B8c2a — Remove from FX Vault for a Key Vault of its own (2026-10-25, automatic):
- `KeyVaultContextMenu` (shared by the sidebar row's context menu and the destination detail's Actions button, which now shows for a vault of its own) sets `SidebarViewModel.pendingKeyVaultRemoval`; `SidebarView` confirms with the destination removal copy; `confirmKeyVaultRemoval()` calls `deleteDestination` (nothing in Azure), and the observation clears the selection.
- UI tests: `VaultUITestCase.dialogButton(_:in:)` finds a confirmation dialog's button (the Touch Bar's disabled copy matched first; lesson added).
- Tests: `aKeyVaultOfItsOwnOpensFromTheSidebar` now removes through the sidebar; `ConnectUITests` removes the vault from its context menu. Mutation caught: confirm without deleting.
- Docs: DESIGN, ARCHITECTURE, CHANGELOG, lessons.
- Gates: the full CI run passed (package suites, app tests, Debug and Release builds, 7 UI tests twice, lint); check-secrets OK in the worktree (991 files); strings up to date.

Review B8c1 — Sync of the Key Vaults of their own (2026-10-25, automatic):
- `DestinationStore.pendingCounts` (and `DestinationRepository.pendingCounts` / `observePendingCounts`) now key by `RepoID?`: nil counts the vaults of their own, so they reach the Sync button and the Dock badge (`AppViewModel.destinationPendingCounts`).
- `DestinationSyncRepository.review(repositoryID: RepoID?)`, `DestinationReviewModel.repositoryID: RepoID?`; the run needed no change (it walks the review's sections).
- Sync sheet: a Sync of everything reviews the repositories with destination changes, then nil; `SyncSummaryRepoModel` / `SyncDeletionRepoModel.id` are `RepoID?`, nil titled `MainCopy.azureSection`; `SyncViewModel.fullName(of:)` is the one name lookup (the summary's own copy folded into it). A Sync scoped to repositories leaves the vaults out.
- Assumption: Sync still needs gh (a vault-only user waits for B10's gh-less path); no UI test drives a vault write (the UI-testing transport stubs reads only), covered by the package run test and the app summary test.
- Tests: `aKeyVaultOfItsOwnIsCountedAndSyncedApartFromRepositories` (package, counts, review, run), `keyVaultsOfTheirOwnJoinTheBadgeAndTheSummary` (app, badge and summary group). Mutations caught: counts skipping nil, the review list without nil. B8b1's `keyVaultsOfTheirOwnStandBesideRepositoryDestinations` now expects `[nil: 1]` (it asserted the old rule that left them out).
- Docs: README, DATABASE, ARCHITECTURE (decision 110), CHANGELOG.
- Gates: the full CI run passed (package suites, app tests, Debug and Release builds, 7 UI tests twice, lint) after the B8b1 expectation fix; check-secrets OK in the worktree (991 files); strings up to date.

Review B8b3 — Azure Key Vault in the sidebar (2026-10-25, automatic):
- `SidebarViewModel` observes the Key Vaults of their own (`observeDestinations(repositoryID: nil)`) into `keyVaults`; `selectedKeyVaultID` joins the exclusive selections (`SelectionKind.keyVault`); `visibleKeyVaults` follows the search (shared `matchesSearch` with folders); a removed vault clears its selection; each update calls `onChange`, so a vault selected before it was listed (just imported) gets its detail (found in self-review, test seen failing).
- `SidebarKeyVaultsSection` (AZURE KEY VAULT, after GitHub, hidden when empty) reuses `DestinationRow` (now internal); id `AccessibilityID.Main.keyVault(name)`.
- `MainViewModel`: a selected vault gets a `DestinationDetailViewModel` (live from the sidebar), no scope column, path `Azure Key Vault › name`; a vault's detail closes when anything else or nothing is selected; `open(destinationID:)` selects a vault of its own (Show in Sidebar from a linked copy).
- Toolbar path: `MainToolbarTitle.fallbacks` drops first steps down to the last one; the two-step vault path fell straight back to the app name beside the DEV chip (seen in the snapshot).
- `MainCopy.azureSection` reuses `DestinationProvider.azureKeyVault.title`; the Connect summary row uses it (key `connect.summary.keyVaults` dropped).
- Assumptions: no Actions menu (Remove from Vault, stage) on a vault of its own yet, and its edits wait for B8c's Sync (no badge, not in the Sync review).
- Tests: `aKeyVaultOfItsOwnOpensFromTheSidebar`, `toolbarPathFallsBackStepByStep`, `ConnectUITests` now opens the vault from the sidebar; snapshot `main-keyvault-standalone`. Mutations caught: no observation, selection not exclusive, stale vault detail, open not selecting, no `onChange` on update.
- Docs: README, DESIGN, ARCHITECTURE, STRUCTURE, CHANGELOG.
- Gates: the full CI run passed (package suites, app tests, Debug and Release builds, 7 UI tests twice, lint); check-secrets OK in the worktree (991 files); strings up to date.

Review B8b2 — Connect Azure (2026-10-25, automatic):
- Connect gains a second step (`ConnectViewModel.Step`, `StepCounter` 01 / 02): GitHub's Continue goes to Azure (allowed with nothing checked); Azure has Back, Skip (GitHub only, or straight to the vault when nothing is checked) and Continue (imports both; GitHub first).
- `ConnectAzureModel`: `AzureDiscoveryRepository.discover()` (now in `VaultDataComponents.azureDiscovery`); Disabled and Deleted subscriptions are left out (B8a's open question); every vault checked; a subscription whose vault list fails shows its message. Requirements: `azNotInstalled`/`azUntrusted` offer `brew install azure-cli` (Run) and `az login` (Copy), `azNotSignedIn` only `az login`; other errors show as the step's error.
- Import: each checked vault is created with `createDestination(repositoryID: nil)` (or the vault already there is reused) and read with `importRemote`; failures are named in the summary, which gains the Azure Key Vault row (secrets with values, no variables) and "Secrets" instead of "Secrets (names)".
- Run state extracted from gh setup into `SetupCommandRunState` + `SetupCommandList` (shared, no behaviour change on gh setup); `DestinationSyncCopy.azInstallCommand` reuses `SetupCommand.installAzureCLI`.
- Test doubles: DestinationKit `FakeAzureOutput` (`az account list`, `az keyvault list`, the token, Key Vault list and read) and `FakeHTTPTransport.stubKeyVault`, checked against the real parsers (`FakeAzureOutputTests`); `TestHarness.installFakeAZ()` puts a placeholder `az` first on the probed PATH and exposes `transport`; the UI-testing host gets a placeholder `az`, one subscription with `kv-example-prod` (one secret), and a scripted transport.
- Assumptions: no per-vault secret count or access check before import (the board's "32 secrets · Ready" would need a listing per vault); the tenant-sign-in row ("Sign In to This Tenant") waits for a real multi-tenant `az` check; the `az` version line is not shown.
- Tests: `ConnectAzureTests` (6), `FakeAzureOutputTests` (2), `ConnectUITests` now goes through Azure; snapshots `connect-azure`, `connect-azure-signin`, `connect-summary`. Mutations caught: no vault import, Disabled subscriptions kept, no reuse.
- Docs: README (first launch step 6), DESIGN, ARCHITECTURE, STRUCTURE, CHANGELOG.
- Gates: the full CI run passed every step (package suites, app tests, Debug and Release builds, 7 UI tests twice) except lint, which caught two force unwraps in the UI-testing host; fixed with `FakeAzureOutput.syntheticID`, then lint OK, check-secrets OK (990 files), strings up to date, Connect UI test passed again.

Review B8b1 — Key Vaults of their own, store layer (2026-10-25, automatic):
- Migration `v18_standalone_key_vaults` rebuilds `destinations` with an optional `repository_id` (Key Vault rows only), plus `destinations_standalone_target` (unique `target_key` where the repository is NULL). Items and journal keep their ids (foreign keys are off during migrations).
- `DestinationRecord`/`DestinationModel.repositoryID` are optional; `DestinationStore` and `DestinationRepository` take `repositoryID: nil` for the vaults of their own (`createDestination`, `destinations`, `observeDestinations`, limit `Limits.maxStandaloneKeyVaults` 256). Refresh, import, items, links and DEK rotation needed no change (`DestinationFieldAAD` never bound the repository).
- Callers: a linked copy in a vault of its own names no repository; held shares and the repository Sync badge skip those vaults (share imports only place destinations under repositories; their Sync is B8c); the app's Show in Sidebar skips them until B8b2's node.
- Assumption: 0.9's repository Key Vaults stay under their repository until B8c moves them (several repositories may share one vault, so the move needs a merge rule).
- Tests: `standaloneKeyVaultsAreUniqueAndKeyVaultOnly` (store), `keyVaultsOfTheirOwnStandBesideRepositoryDestinations`, `aKeyVaultOfItsOwnImportsLikeARepositoryDestination`; the step-by-step migration tests carry every earlier seed (destination, items, held rows) through the rebuild. Mutation: dropping the partial index fails the store test.
- Docs: DATABASE (v18, tables), ARCHITECTURE decision 138, CHANGELOG.
- Gates: every package suite green in the CI run; app tests 584; build Debug and Release; 7 UI tests passed twice; lint OK; check-secrets OK (984 files); strings up to date.

Review B11f — allowlisted setup commands (2026-10-25, automatic):
- GitHubKit `SetupCommand` (`brew install gh`, `brew upgrade gh`, `brew install azure-cli`) and `SetupCommandRunner`: fixed argv, `brew` from `/opt/homebrew/bin` then `/usr/local/bin` only when it passes `GHLocator.evaluate`, `ProcessEnvironmentBuilder.homebrew` (identity, Homebrew PATH, NONINTERACTIVE), 600 s, redacted last 40 lines.
- App: the gh setup screen offers Run on allowlisted rows when a trusted Homebrew exists, shows `CommandOutputView` and "Done · … · checked again" or the failure; a success runs Check Again.
- Kept Copy-only: `gh auth login` (interactive; the device flow is B4b, reserved), the `GH_TOKEN` login, `az login` (with Connect Azure). Azure's `brew install azure-cli` row arrives with Connect Azure (B8b).
- Tests: GitHubKit `SetupCommandTests` (allowlist, environment, trusted brew argv, untrusted brew never runs — seen failing with the trust check removed, redacted last lines); app `SetupCommandRunTests` (run and output, failure message, no Run without Homebrew); snapshot `gh-setup-run` checked. No UI test: the UI-testing gh is always ready, so the setup screen never shows there (unit and snapshot cover it).
- Docs: API.md H, README (first launch), CHANGELOG, DESIGN, ARCHITECTURE, STRUCTURE.
- Gates: XcodeGen drift OK; `swift test` 1,345 green; `xcodebuild test` 584 app tests green; Release build OK; no UI-testing code; UI tests ×2 green (7 tests); lint OK; check-secrets OK in the worktree; strings synced.
