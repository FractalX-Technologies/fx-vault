# Changelog

All notable changes to FX Vault are listed here. Versions follow `MAJOR.MINOR.PATCH`
(see [docs/RELEASING.md](docs/RELEASING.md)).

## 0.8.0

### Added

- **Runtime destinations (experimental).** Next to a repository's GitHub scopes, a new RUNTIME
  section lists the places its code reads at runtime: an **Azure Key Vault**, the Edge Function
  secrets of a **Supabase** project, or one environment of a **Vercel** project. Add
  Destination… imports the names already there (and the values the provider returns), then the
  destination works like a scope: the same table, Add, Paste Multiple…, `.env` import and
  export, ⌘C / ⌘V and Copy To › Destinations, with every copy linked, so one rotation in FX
  Vault reaches GitHub and the runtime in the same Sync. Nothing changes in the provider until
  you Sync.
- **Sync sends destination changes after GitHub,** in the same review: what will be pushed (and
  as which name: Key Vault writes `DATABASE-URL` for `DATABASE_URL`), what is blocked and why,
  and deletions, which wait for your confirmation (Key Vault deletes are soft deletes). If the
  destination changed since your last sync, nothing is overwritten: **Refresh** lists the
  changes and lets you keep yours or use theirs.
- **Public names are checked.** Names starting with `NEXT_PUBLIC_`, `VITE_`, `EXPO_PUBLIC_` and
  the like end up in the browser: a value that looks like a credential (a known token prefix, a
  private key, a URL with a password) is not sent to one, and a token-looking value asks you to
  Mark as Public first.
- **Overview.** The first row of the scope column shows one stage (for example production)
  across GitHub and every destination with that stage: one row per name, its cycle (Build,
  Runtime or Public), and what Sync will do in each place, so a key that is in GitHub but missing
  from the runtime stands out. Click a cell to open that place.
- **`fxvault.yml`.** An optional, names-only file at the root of the repository that says which
  names each stage needs and where. When it is on the default branch, the Overview checks the
  stage against it (missing, extra, a secret stored as a variable, a destination not added yet),
  and Show Check copies a `.env.example` per target. Copy fxvault.yml for This Repository writes
  one from what the repository has today.
- **Settings › Destinations.** Checks your Azure CLI sign-in (FX Vault asks `az` for a
  short-lived Key Vault token when it syncs and keeps it in memory until the vault locks), and
  keeps your Supabase and Vercel personal access tokens, encrypted in the vault, with Rename…,
  Replace Token… and Remove….

### Changed

- The scope column is split into BUILD · GITHUB ACTIONS (the repository and its environments)
  and RUNTIME (its destinations).
- The Sync badge and the pending dots count destination changes too.
- FX Vault makes its first HTTPS requests of its own, only to the Azure Key Vault, Supabase and
  Vercel APIs, with no cookies, cache or redirects. GitHub still goes through `gh`.

### Known limits

- Destinations are experimental. The Vercel round trip was checked against a real project; Key
  Vault and Supabase were checked against simulated responses only.
- Supabase never returns secret values: FX Vault compares digests, and a secret imported from
  Supabase has no value in FX Vault until you fill it.
- At the default window width, the Overview scrolls sideways when a stage has three or more
  places.

## 0.7.0

### Added

- **Folders.** Create folders of your own at the top of the sidebar (New Folder…, ⇧⌘N), for
  example "Mobile App", to keep the secrets and variables you use in several repositories. A
  folder belongs to no repository and never reaches GitHub by itself. Copy its items into any
  repository scope with ⌘C / ⌘V, Copy To or Copy To › Another Repository…, or copy items from a
  repository into a folder; every copy stays linked, so a new value in the folder offers to
  update its copies in your repositories (as changes for the next Sync). Folders have the same
  table, Paste Multiple…, `.env` import and export, Rename… and Delete Folder….
- **Send a copy of a folder.** From the folder's ••• menu (Send to Teammate, Share as File…) or a
  teammate's card in the sidebar (Send Folder): a chat with your teammate opens with the folder
  attached after Touch ID or your master password, or an encrypted `.fxvault` file is written.
  The other person saves it as a folder (a new one, or merged into theirs, keeping their own
  values unless they choose Replace) or imports it into one of their repositories through the
  usual import preview. They get their own copy; later changes are not sent.
- **Teammates in the sidebar.** Every paired teammate is listed at the bottom of the sidebar:
  nearby first with a green dot, otherwise when they were last seen; Ping, Chat and Send Folder
  from their card; who can see this Mac from the eye menu; Add Teammate… when you have none.

### Changed

- The bubbles next to Sync became one people button with the number of people nearby; its
  popover lists them with Ping and Chat.
- Nearby Chat speaks chat version 4 (folders). Chats with 0.6 and older still work; their Folder
  tab explains the update.
- A `.fxvault` file of a folder needs FX Vault 0.7 or later to open.

## 0.6.0

### Added

- **Copy secrets and variables to any repository.** ⌘C on the table, then ⌘V in any other scope
  of any repository in your vault, whatever account it belongs to. Copy To › **Another
  Repository…** lists every repository by account, with a search field, and the chosen
  repository's scopes (the ones your account cannot change are disabled with the reason). As
  before, the copies are changes for the next Sync, names the target already has ask Replace or
  Keep Existing, and values never reach the clipboard.
- **Linked copies.** Every copy stays linked to the item it came from. A link chip with the number
  of places shows next to the name; click it (or choose Show Linked Copies) to see every place
  with **Same value**, **Differs** or **Value missing**, open one, or Unlink. When you give a
  linked item a new value, the editor lists its copies (the ones that still had the old value
  are checked), and Save updates them too, so rotating a shared key is one edit and one Sync.

- **Teammates nearby.** Settings › Teammates › Add Teammate… pairs two Macs once, after both
  people compare a 6-digit code. Teammates who are nearby then appear as bubbles next to Sync while
  FX Vault is open; click one to Ping (their Mac plays a sound, or shows a notification when FX
  Vault is in the background) or Chat, which opens Nearby Chat already connected and verified,
  with no code to compare. Your Mac is visible to your teammates only, under a name that changes
  every 15 minutes; choose Nobody or Everyone nearby instead, mute a teammate's pings or all of
  them, and remove a teammate (your Mac then uses a new name nearby). Teammates' Macs need 0.6.
- **Shared scopes (experimental).** Right-click a scope › **Share with Teammates…** keeps it in
  sync between you and the teammates you choose, with no server. Every push becomes a version
  your teammates get Mac to Mac (nearby, or at an address you allow), with its values, author,
  time and an optional "What changed?" note, so a teammate's rotated secret arrives with its
  value. Before anyone pushes, FX Vault checks a small signed version marker on GitHub: if a
  teammate published something you do not have yet, that scope is not pushed until you **Get
  Updates from Teammates**, so nobody overwrites anyone. A push that a teammate left unfinished
  can be taken over after you confirm. **Shared with Teammates…** shows every version, the
  versions of each item with a short fingerprint, reveals an older value after Touch ID or your
  password, and restores it as your next change; add or remove members there (a removed member
  gets no new versions, and FX Vault lists the secrets they received so you can rotate them).
  Drift review shows a teammate's change as such, and offers Get Updates instead of Keep Local.
- **Shared scopes outside the local network.** Settings › Teammates › Outside this network: turn
  a teammate on (on both Macs) and type their address (for example a Tailscale name) to sync
  shared scopes when you are not nearby. Off by default, used only for shared scopes, never
  advertised, and only teammates you turned on are answered.

### Changed

- Nearby Chat speaks chat version 3: chats with 0.4 or older still work and compare the code.
- Copied items are kept by the app instead of the repository you copied from, so a paste works
  after you open another repository. They are still forgotten when FX Vault locks.
- `FXVAULT_SPACE` is reserved: FX Vault uses it for the shared scope marker, never lists it with
  your variables, and refuses it as a name.

## 0.4.0

### Added

- **Act on several secrets or variables at once.** Select rows with ⌘-click or ⇧-click, or all
  of them with ⌘A. With two or more selected, the bar above the table shows how many and offers
  Push on Next Sync and Revert (for the rows they apply to) and Delete…; the context menu offers
  the same, and ⌫ deletes the selection. One confirmation covers them all: rows on GitHub are
  deleted there by the next Sync, after you confirm them in its deletion review, and rows never
  synced are removed at once. A scope your account can only read offers none of these.
- **Copy and paste between the repository level and environments.** Select secrets or variables
  and press ⌘C, open another scope of the same repository and press ⌘V, or choose **Copy To ›**
  in the context menu or the selection bar. The copies are changes for the next Sync. When the
  target already has a name, FX Vault asks whether to replace its value or keep it. Values never
  leave the vault: the clipboard gets only the names. Secrets that have no value in FX Vault
  (GitHub never returns secret values) are not copied, and FX Vault names them.
- **Environment actions next to Clone and Refresh.** The ••• button in the header offers the
  open environment's Settings, Rename, Duplicate, Export .env, Share, Revert and Delete (and
  Export .env and Share for the repository level), as the right-click menu of the scope list
  does. **New Environment** stays at the bottom of the scope list. Actions that need admin
  access on the repository are shown disabled for other accounts.
- **Send a whole repository in Nearby Chat.** Attach… › Whole Repository sends a repository's
  configuration (the repository level and every environment with its branch rules) as one card,
  after Touch ID or your master password. Your teammate sees its name and counts; the values
  travel only if they choose **Import Into…**, which lets them pick any of their repositories
  and review everything in the usual import preview (environments it lacks are created, and
  nothing reaches GitHub before their next Sync), or **Save as File…**, which writes an
  encrypted `.fxvault` file with a new six-word passphrase that they can still import
  afterwards. Repositories their account cannot change are listed with the reason. If anything
  in the repository changes after you attach it, nothing is sent. Both Macs need FX Vault 0.4
  or later; chatting and sending one secret or variable with 0.2 or 0.3 work as before.

## 0.3.2

### Fixed

- **The sidebar no longer starts under the window buttons.** With no repository selected, the
  first account sat behind the close, minimize and zoom buttons, the ACCOUNTS label was hidden
  and the status line at the bottom of the sidebar was missing: the empty "No repository
  selected" message made the three columns taller than the window, so they were cut off at the
  top and the bottom. Each column now takes the window's height.
- **Nothing overlaps in a narrow window.** When the window, or the space left by the sidebar and
  scope columns, is narrow, Clone and Refresh move under the title, the tags stack, and Paste
  Multiple and Add move under the Secrets / Variables switch; the table scrolls sideways. Before,
  the header and the buttons were drawn under the scope column and cut off at the window edge.
- **SSH aliases of accounts that are not logged in to the GitHub CLI are shown.** FX Vault lists
  only the accounts gh knows, so the alias of a second GitHub identity (`Host github-work` in
  `~/.ssh/config`) only appeared as a choice in the other accounts' menus, with nothing saying
  why its account was missing. Settings › Accounts now lists **SSH aliases without an account**
  with the `gh auth login` command and **Check Again**, which also updates the sidebar, so the
  new account appears without relaunching. The aliases are listed even while gh is not found,
  and the alias Test explains how to add the account it authenticates as.

## 0.3.1

### Fixed

- **Accounts from GitHub Enterprise Managed Users (logins with an underscore) were ignored.**
  EMU logins are your handle, an underscore and the enterprise short code (`mona-cat_acme`). FX
  Vault rejected the underscore, dropped those accounts without a word and showed "Log in to
  GitHub" although `gh auth status` listed them. They now work everywhere: accounts, tokens,
  personal repositories of managed users, import, Sync (`--repo=mona-cat_acme/app`), sharing and
  the SSH alias Test.
- **Never drops an account silently again.** An account gh lists that FX Vault cannot use is
  shown with the reason on the setup screen and in Settings › Accounts, and in the diagnostics.
- **Settings from `~/.zshrc` are seen.** FX Vault now asks your shell the way Terminal does
  (an interactive login shell first, the login shell only as a fallback), so PATH additions,
  `GH_CONFIG_DIR` and `XDG_CONFIG_HOME` set only in `~/.zshrc` reach gh. **Check Again** asks
  the shell again, so a changed start-up file counts without a relaunch.
- **The same gh as Terminal.** FX Vault uses the gh your shell finds (`command -v gh`) before
  looking in Homebrew, MacPorts and Nix folders, and the first gh it finds decides: it never falls
  back to another (possibly older) gh behind a rejected one. "Update the GitHub CLI" now names
  the gh it checked.

### Added

- **Explains `GH_TOKEN`.** When gh stores no account and your shell exports `GH_TOKEN` or
  `GITHUB_TOKEN` (Terminal's gh then uses the token, and `gh auth login` refuses to save an
  account), the setup screen says so and offers `env -u GH_TOKEN -u GITHUB_TOKEN gh auth login`,
  then Check Again. Settings › Accounts shows a note while such a variable is set. FX Vault reads
  only whether the variables are set, never their values.
- **Trust This gh.** When another user owns the gh FX Vault would run (typically another
  administrator installed Homebrew), the setup screen names that user, explains that anyone who
  can sign in as them could replace gh and see the values FX Vault sends to it, and offers Trust
  This gh. FX Vault then accepts that exact path while that user still owns it and no one else can
  write to it. Settings › Advanced lists it with Revoke. A gh that others can write to is never
  trusted.
- **Copy Diagnostics** on the GitHub CLI setup screen, and a `gh` section in `--diagnose`: the gh
  candidates with their versions and why each was used or rejected (with the owner's name), your
  shell and how it answered, the names of `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`,
  `XDG_CONFIG_HOME` and `GH_HOST` if set, and each account's login, state, token source and
  scopes. Never a token, a secret or a variable's value.
- README: "Troubleshooting: FX Vault doesn't see my gh login".

## 0.3.0

### Changed

- **New look: the FractalX design language.** Every window, sheet and setting is restyled, with
  no change to what they do. Warm off-white ground and ink text in light mode, near-black in dark
  mode, hairline borders instead of shadows, pill buttons (one black primary per view), 24 pt
  cards, 12 pt inputs and banners, and brand blue only for accents: pending dots, links, focus
  rings and the Modified / Will push chips.
- **Geist type.** The interface uses Geist Sans; names of secrets and variables, values,
  counts, timestamps and small section labels use Geist Mono. Both fonts ship inside the app
  (SIL Open Font License 1.1, see Credits and THIRD_PARTY_NOTICES.md); if one is missing, the
  app falls back to the system font.
- **New app icon:** the FractalX 3×3 mark with a blue outlined center on a dark tile.
- **Main window.** The toolbar shows the mark, the app name and the open repository's
  `owner / repo` path, round icon buttons, the black Sync pill with its count, and search. The
  sidebar and the scope column use their own rows (Up and Down still move the selection), the
  detail shows the environment as a large heading with its tags and branch rules, a Secrets /
  Variables switch with counts, and the table in a card with mono names, dates and status chips.
  The offline and "GitHub isn't responding" banners now sit at the top of the detail column.
- **Drift banner.** "N changes on GitHub · Review" is blue, and amber when some of those items
  also changed in your vault.
- **Lock screen and onboarding** follow the new boards: a dotted background with the mark and
  "FX Vault is locked.", and onboarding with a step counter (02 / 06) and a side panel listing
  every step.
- **Sheets** (Sync, drift review, editors, environments, New Repository, `.env` import and
  export, sharing, nearby and chat) share one layout: a small uppercase label, a large title, a
  muted line, confirmations as checkbox rows, and Cancel next to one primary button. Both
  "Codes match" and "Don't match" stay equal grey buttons, with no default.
- **`.env` import:** the kind of each row is a chip that switches between Secret and Variable
  when clicked (it was a menu).
- **Settings** tabs are grouped cards with mono labels; toggles and pickers stay native.

### Known limits

- On macOS 14 the window keeps the system title, so the toolbar shows the mark, the path and
  the DEV badge without the app name.
- System sheets keep the system corner radius and shadow.

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
