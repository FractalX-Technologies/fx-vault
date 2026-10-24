# FX Vault 1.0 brief

Draft for approval (2026-10-25). The design boards and build slices in `tasks/todo.md` follow from it.

## Goal

- One simple, secure Mac app for FractalX's secrets, replacing the notes file the team keeps them in today.
- Two sources, side by side: **GitHub** (organization, repository and environment secrets and variables) and
  **Azure Key Vault** (secrets).
- Every place reads as a note: see everything, copy everything, edit it as text, review before anything is sent.

## How the team works today

- Secrets live in a notes file, and are copied by hand into GitHub and the Azure portal.
- GitHub holds organization-level secrets and variables used by Actions; repositories and environments add their own.
- Azure Key Vaults hold what services read at runtime; deployed services read them with managed identity.
- Locally, developers read Key Vault with their own Azure sign-in. Managed identity exists only inside Azure, so on a
  Mac FX Vault uses `az login` (what `DefaultAzureCredential` falls back to there).

## Decisions taken (Bryan, 2026-10-25)

- Organization secrets and variables are the first priority.
- The experimental features are removed, not hidden: nearby sharing, Nearby Chat, teammates (presence, Ping, local
  and remote pairing), shared scopes, teammate-sealed share files and sending a folder to a teammate.
- Kept and simplified (Bryan, 2026-10-25): **Share Securely** exports an organization, repository or environment
  (or a subset) as a passphrase `.fxvault` file (format 2: Argon2id + six words sent another way, expiry 1/7/30
  days, production unchecked by default; ticking production asks for Touch ID; Bryan, 2026-10-25, relaxes 0.9's
  refusal of production in passphrase files, since 1.0 has no paired teammates). The receiver previews the merge and imports as held until Sync. Settings ›
  Sharing lists what was sent, names only.
- Azure Key Vault becomes a source at the same level as GitHub in the sidebar, no longer a destination hung on a
  repository.
- The notes view is editable: on save, FX Vault lists what is added, changed and removed before applying it.

## Look and platform (Bryan, 2026-10-25)

- Minimal: black and white, small macOS-sized controls (28–32 pt), few words, narrow forms.
- Apple Liquid Glass for floating chrome (toolbar, progress, action bar, cards over content).
- macOS 26 is the minimum for 1.0 (native `glassEffect`, one code path); users on 14–15 stay on 0.9.
- `docs/DESIGN.md` is rewritten for this language when D1 is approved.

## Unlock from the notch (Bryan, 2026-10-25)

- After onboarding, activating a locked FX Vault shows a small black island grown out of the notch (a borderless
  panel at the top center of the screen) instead of the unlock window; without a notch, the same pill floats under
  the menu bar.
- Touch ID inside the island with `LAAuthenticationView` (LocalAuthenticationEmbeddedUI); the password state asks
  for the master password in one small secure field. The island never shows names or values.
- Welcome and onboarding show only while this Mac has no vault (first launch after install, or after the vault is
  reset). An interrupted onboarding resumes where it stopped.
- After that the island is the only unlock UI: FX Vault starts locked, every window closes on lock, and the main
  window opens after unlock. No fallback unlock window.
- "Recovery Key…" in the island opens the one window it needs: recovery key, new master password, new recovery key.

## Quick vault from the notch (Bryan, 2026-10-25)

- A global shortcut (default ⌃⌥V, configurable; a registered hot key needs no Accessibility permission) grows the
  island into a quick vault: search places and names, recent places, a place's notes (secrets masked, variables
  plain) with Copy per line. Reveal asks for Touch ID; copied values clear after 30 s.
- Locked: the island asks for Touch ID first. Expand (⌘↩) morphs the island into the main window on that place.
- The panel closes when it loses focus and is excluded from screen capture.

## Place actions (Bryan, 2026-10-25)

- Each place has a More menu: New Secret, New Variable, Paste Multiple…, Import .env…, Export .env… (Touch ID),
  Copy All (Touch ID), Copy To…, Delete Selected…. Sidebar rows: Rename…, Duplicate Environment…, Refresh,
  Delete Environment….
- Deleting shows names only and removes them from GitHub or Key Vault at the next Sync, which asks again.

## Setup commands run inside FX Vault (Bryan, 2026-10-25)

- Setup problems (gh missing or old, no account, scopes, SSO, az missing or signed out) offer **Run** in a small
  embedded terminal with the command pre-filled; Copy stays as a fallback.
- Only an allowlist of fixed commands runs (`brew install gh`, `brew upgrade gh`, `brew install azure-cli`,
  `gh auth login`, the `gh auth switch/refresh` sequence, `az login [--tenant]`); the user never types a command.
  Commands that change the user's shell environment stay Copy-only.
- GitHub approvals use gh's device flow: FX Vault shows the one-time code and opens `github.com/login/device`.
- After the first import: a short check animation and the system "Glass" sound, off with Reduce Motion and the
  system's interface-sound setting.

## Onboarding adds "Fill values from your notes"

- GitHub never returns secret values, so imported GitHub secrets have names only.
- Last onboarding step (optional): paste the team's notes; each `KEY=value` is matched to imported names, shown in a
  review, and stays pending until Sync. A name that matches several places waits for the user to pick one.

## Information architecture

```
Sidebar
├── GitHub
│   └── <organization or personal account>     org secrets and variables (visibility: all / private / selected repos)
│       └── <repository>                       repository secrets and variables
│           └── <environment>                  environment secrets and variables
├── Azure
│   └── <subscription>
│       └── <key vault>                        secrets
└── Folders                                    personal notes; never sent anywhere by themselves
```

- Every node with values opens the same place view: **Notes** (default) or **Table**.
- **Notes**: `KEY=value` lines, `#` comments, secret values masked until revealed. Copy All and Reveal ask for Touch
  ID or the master password. Editing the text and saving shows the change review; changes stay pending until Sync.
- **File secrets**: `.p8`, `.pem`, `.json` (service accounts, Apple keys, certificates) are one value with many lines.
  Added by dropping or choosing the file; stored as its exact bytes, or base64 when the workflow decodes it. In
  Notes a file secret is one collapsed line (`APNS_KEY = file AuthKey.p8 · 6 lines`), never inlined into the text.
  Limits: GitHub 48 KB per secret, Key Vault 25 KB per secret.
- **Variables are shown in plain text** in Notes (GitHub returns them; they are configuration); only secrets are
  masked. Both stay encrypted on disk, and Copy All still asks for Touch ID because the text includes secrets.
- A repository's Notes lists the organization secrets that reach it, read-only (`# From <org>`), and marks a
  repository secret that overrides one.
- **Table**: today's table, for kinds, visibility and per-row actions.
- **Sync**: one review for everything pending, GitHub and Azure, names and counts only.

## Window by window (design order)

1. **Start**: welcome for a new vault, unlock for an existing one.
2. **Onboarding**: master password → recovery key (confirm) → Touch ID → connect GitHub (`gh` accounts, pick the
   organizations) → connect Azure (optional: `az login`, pick subscriptions and vaults) → first import.
3. **Main window**: sidebar with the sources above, an empty state per source.
4. **Place view**: Notes and Table, Copy All, Reveal, the edit review.
5. **Sync review**.
6. **Settings**: only what remains after the removals.

## Security rules that do not change

- Values encrypted field by field in the local vault; nothing in the notes view is written to disk in plain text.
- Reveal, Copy All and `.env` export need a fresh Touch ID or master-password check; the clipboard clears after 30 s.
- GitHub through `gh` with values on stdin; Azure through `az`-issued tokens held in memory until lock.
- Organization secrets need the `admin:org` scope; FX Vault asks for it (`gh auth refresh -s admin:org`) and never
  works around it.

## Corrections from anton's review (2026-10-25)

- Organization secrets need `admin:org` and the org-admin role; today `ScopeChecker` accepts `read:org` and asks
  for `repo,read:org`. The check becomes per organization.
- Values are not kept byte-exact: `ValueNormalizer` strips trailing CR/LF (D32, gh does it on stdin). The review
  says so for file secrets.
- `Limits.maxValueBytes` is 48,000, below GitHub's 49,152; Key Vault needs its own 25,600.
- Onboarding's passphrase generator lives in SharingKit; it moves to VaultCrypto before SharingKit goes.
- Binary files go in as base64 (values are UTF-8). Key Vault certificates stay out of 1.0.
- Notes never holds secret values in its editable text: masked values are placeholders, spliced back at save.
- A repository secret with the same name shadows the organization one; the repository shows inherited names.

## Scope decisions (Bryan, 2026-10-25, on anton's recommendation)

- Removed from 1.0: Supabase and Vercel destinations, Overview and `fxvault.yml`.
- Kept: drift detection (needed for organization visibility); `.env` import and export behind reauth; New
  Repository with clone, out of the main flow.
- Data of removed features: dropped in a migration (its tables still hold encrypted teammate and space keys);
  that migration is reserved for Bryan's OK.
