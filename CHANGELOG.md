# Changelog

All notable changes to FX Vault are listed here. Versions follow `MAJOR.MINOR.PATCH`
(see [docs/RELEASING.md](docs/RELEASING.md)).

## Unreleased (1.0)

### Added

- **Touch ID in the island.** On a signed build with a sensor, the island shows the system's
  Touch ID glyph and one touch unlocks there, with no Touch ID dialog over it. The password,
  the restart and 14-day rules and the window's lock screen are unchanged.
- **Approve in the app.** Approve on a sidebar line (Needs repo… or Needs admin:org) runs
  `gh auth refresh` for that scope and shows GitHub's one-time code with Copy and Open
  github.com/login/device; it closes once the browser approval is done, or with Check Again.
  Another account than gh's active one still opens Settings › Accounts with its commands.
- **Quick vault shortcut.** Settings › General records the global shortcut for the quick vault:
  ⌃⌥V by default, any key with two modifiers, one of them Control, Option or Command. Settings
  says so when another app holds the shortcut.
- **Quick vault.** The shortcut, from any app, or Quick Vault at the top of the menu bar menu,
  opens a search under the notch: the vault's places, recent ones first, and names. ↩ shows a
  place's lines; Copy puts a variable on the clipboard at once and a secret after Touch ID or the
  master password (cleared after 30 s); ⌘↩ opens the place in the main window. It is hidden from
  screen capture and closes when FX Vault loses the focus or locks; esc gives the keys back to
  the app it opened over. While locked, the island asks for the unlock first.
- **Open at login.** Settings › General adds FX Vault to the Login Items, and says when System
  Settings has to allow it first.
- **Copy Diagnostics in Settings.** Settings › Advanced copies the gh report (versions, paths
  and checks; variable names and account names only) and gives the Terminal command for the full
  one, with Copy.
- **Add Account….** Settings › Accounts gives gh's login command for another GitHub account,
  with Check Again.
- **Azure in Settings.** Settings › Accounts has an Azure group: each tenant with its vaults
  in FX Vault, Signed in or the `az login --tenant` command to copy, Choose Vaults… to add more
  of a tenant's vaults after onboarding, and `az logout` to copy.
- **Menu bar item.** FX Vault's dot grid in the menu bar: Quick Vault, Open FX Vault (the island while
  locked), Review Sync · N pending… (opens the Sync review, after the unlock when locked), Lock
  Now, Settings… and Quit. It shows counts only, never names or values.
- **File secrets.** Add a key file as a secret from ⋯ More › Add File Secret… or by dropping a
  `.p8`, `.pem` or `.json` file on a place. Store it as exact text or Base64 (binary files are
  always Base64); the sheet shows the file's size and lines, GitHub's and Key Vault's limits
  after Base64, and the name rules. The table and notes show "AuthKey.p8 · 6 lines" in place of
  the mask, until the value is replaced. Migration v21 adds the `file_detail` column.

### Fixed

- **Deleting what GitHub no longer has.** Sync reads gh's `HTTP nnn (…)` (an error with no
  message) as its status, so deleting a secret or variable already gone from GitHub finishes.

### Changed

- **The table asks first.** In the Table view, revealing a secret or copying its value asks for
  Touch ID or your master password, as Reveal in the notes does, each time; the window stays
  out of screen capture while a value shows. Variables copy and show as before.
- **Settings, second pass.** General shows "Lock when the screen locks" (always on) and "Sound
  effects: Follows system"; Reset vault moved from Advanced to Security, where it stays while
  the vault is locked.

- **Review Sync.** The Sync summary is one card per place: the repository, each environment,
  each Key Vault, each organization. Its lines read `+ ~ −` with the kind (a rename says where
  it came from), blocked changes sit in their place's card with their fix, and the footer counts
  changes, places, deletions and blocked; the button says how many changes will run
  ("Sync 8 Changes").
- **Sync run and finish.** While Sync runs, the sheet keeps the summary's cards and each line
  turns from waiting to writing to done (or failed, or not run), with the deletions in a last
  card; Cancel After Current stops after the write in flight. A run where nothing failed ends on
  a short "Synced 8 changes" with the places and what stays pending. The deletion check reads
  "Delete 1 secret?" and lists each name with its place.
- **Offline and GitHub notices.** Offline, or with GitHub not responding, a glass strip sits under
  the toolbar over every place, folders and organizations included: "Offline · edits stay in the
  vault; Sync, import and drift checks wait", or "GitHub isn't responding" with Retry.
- **New Repository and New Environment as the boards.** Both are compact forms with their
  labels in a column: New Repository shows environments as chips, the account's SSH alias beside
  the clone folder, and the button says Stage Repository; New Environment is titled with its
  repository, says when a name is free ("Not used in api-service yet"), shows branch rules as
  chips, and the button says Stage Environment. Both end on "Created on GitHub at the next Sync."
- **Share Securely as the boards.** Choosing what to share is one dialog: the repositories,
  the repository level and stages, the tree with each row's counts, the production note and
  Expires after, with Create File (with Touch ID where it can) in the footer; the Send to step
  is gone. The passphrase is shown on one line with Copy, the time the clipboard clears, and
  when FX Vault stops opening the file. Opening a file asks the six words in one field, lists
  what it adds with a dot per repository, and imports as held ("Import as Held"); an expired
  file says "This file expired" in a small dialog of its own.
- **Settings as the boards.** The tabs are wider, with sentence-case group titles over rounded
  cards and small outline buttons. General holds Lock after inactivity, the 30 s clipboard
  clear and the clone folder; Security holds Touch ID, the master password and a new recovery
  key; Advanced shows the gh in use beside the path override, and the vault folder and Reset
  vault, whose dialog is smaller with Erase Vault in red. Accounts lists each account with its
  SSH alias, token, scopes and organizations as dotted lines, and the accounts FX Vault can't
  use in the same card; the gh path and version moved to Advanced. Sharing lists "Files you
  shared" as Active or Expired with their counts and expiry time, and Show names.
- **Delete and Export .env as the boards.** Deleting secrets or variables opens a small
  dialog titled with the count and the place ("Delete 2 secrets from api-service ›
  production?"), lists the names (with their kind when a secret and a variable are both
  listed; a long list scrolls), says the next Sync deletes them on GitHub or in Key Vault and
  asks again, and has a red Delete; Return no longer deletes. Export .env is titled with its
  place, keeps its steps, shows the warnings in one box with "Add /.env to .gitignore" beside
  its note, and ends each step on "Saved readable only by you."
- **Folder, Key Vault and organization views as the boards.** A linked item's tag shows a link
  and "3 places". Typing a new value for a linked item lists each copy by its path
  ("api-service › production", with its own name when it was renamed) with a checkbox and
  whether its value is the same or differs; copies that can't take it say why. A Key Vault's
  header says "No changes since your last sync" or "2 changed in Key Vault" with Review, and
  the secrets FX Vault leaves alone (disabled, managed by Key Vault, or with a name FX Vault
  can't use, marked as a warning) and the naming rules are footnotes under the table instead
  of a card and banners. An organization's Visibility column says what each item reaches:
  "all repos", "private and internal" or "selected · 3 repos".
- **Refresh an organization.** ⋯ More › Refresh reads the organization from GitHub again and
  marks what changed there since FX Vault last read it ("Changed on GitHub": a new date,
  visibility or repository list, an item GitHub added or deleted). Review offers Keep Local or
  Accept GitHub for each, as for a repository; taking GitHub's version of a secret GitHub
  changed leaves it without a value, since GitHub never returns one (one whose only change is
  who can use it keeps its value). Taking GitHub's deletion, or GitHub's item over one you
  added here too, asks first. A deletion GitHub already made is finished on Refresh, and what
  your own Sync just deleted is not reported as added while GitHub catches up. For a name
  added on both sides, a repository's review now says the same: Keep Local sends yours at the
  next Sync (it said the name would be deleted on GitHub), and taking GitHub's asks first. With nothing to review, the
  organization's status line still names what GitHub lists that FX Vault can't store.
- **Inherited organization secrets and variables.** When a repository's organization is in
  the vault, its Secrets and Variables tabs also list, muted and read only, what the
  organization gives it ("example-org · all repos", "· private and internal", "· selected"),
  marked Inherited. An item of the repository or environment with the same name says
  "Overrides example-org" beside its status. A `selected` item shows on the repositories
  GitHub lists for it, read at import, on Refresh and after Sync. On GitHub Free, private repositories can't use
  organization items, but FX Vault doesn't know the plan and still lists them there.
- **Edit organization secrets and variables.** The organization view gains Add Secret, Add
  Variable and a Status column; its editor sets the value and Access (All, Private, or Selected
  with the organization's repositories). A Selected item opens with GitHub's repositories
  checked; one whose list FX Vault couldn't read keeps GitHub's until you pick repositories. The row menu offers Copy Value, Edit…, Revert (Revert Access for a
  changed item) and Delete…. The changes count on the Sync button, and the toolbar Sync
  sends them as one group per organization, after the repositories; deletions go through the
  deletion review.
- **Connect Azure.** After GitHub, the first launch lists your Azure subscriptions and their Key
  Vaults through `az`, every vault checked; Continue imports each vault with its secret values
  as a Key Vault of its own (no repository), and the summary counts them. Without `az`, Run
  installs it with Homebrew; `az login` stays Copy. The vaults are listed under **Azure** in the
  sidebar, after GitHub, and open with their secrets; their edits count on the
  Sync button and Sync sends them, shown as an "Azure Key Vault" group after the repositories.
  **Remove from FX Vault…** (the vault's context menu or Actions) drops one locally; nothing
  changes in Azure.
  Existing Key Vault destinations stay where they are.

- **First launch in three phases.** Welcome names them (Secure · Connect · Import); the Secure
  phase counts its steps (01 / 04), the password step has Back, and the recovery key's Continue
  waits until you check "I saved it offline".
- **Connect and first import.** After Touch ID, Connect GitHub lists each account's
  organizations (with their access) and personal repositories, the ready ones checked;
  Continue imports them and shows the totals by source, naming anything that failed. The
  "Your vault is ready" step is gone.
- **Run setup commands.** The gh setup screen runs `brew install gh` and `brew upgrade gh` with
  Run, shows their output, and checks again. Only these fixed commands run, and only with a
  Homebrew nobody else can change; `gh auth login` stays Copy.
- **Unlock from the notch.** A locked FX Vault has no window: a black island grows out of the
  notch (or floats under the menu bar) with Touch ID and the master password, says Unlocked,
  and the main window opens. Locking closes the window; Recovery Key… opens the recovery window.
- **Black and white.** A white window with black type (black and white in dark mode), system
  greys for secondary text, translucent cards and no brand blue: pending dots and links are ink.
  The interface uses SF Pro and SF Mono; FX Vault no longer ships its own fonts.
- **Two-column main window.** The sidebar is one tree: GitHub, each owner, the repositories,
  and the selected repository's environments and destinations under it; Azure and Folders
  follow GitHub. The middle scopes column is gone: the repository row stands for the repository
  itself, and the toolbar shows where you are (GitHub › owner › repository › environment).
- **One node per owner.** The sidebar has no account level: each organization or person shows
  once, whichever accounts see it, and goes through the account that imported it (else the
  first signed-in one). Owners start collapsed and list the repositories in your vault; the
  rest wait behind **Show N more**. An owner that needs something says so under its name
  (Needs admin:org · Approve, Authorize SSO · Open, Not logged in · Settings); Approve opens
  Settings › Accounts. Search moved into the sidebar: Edit › Find (⌘F) focuses it, and brings
  the sidebar back when it is hidden. "Org secrets need an org admin" shows only on an
  organization you imported or selected. Lock and Settings sit at the bottom
  of the sidebar; Add Repository by Name… is on an owner's menu and New Environment… on a
  repository's.
- **Secrets without a value in the sidebar.** A repository row shows how many of its secrets
  have no value in FX Vault (its repository level and environments), like its environments and
  Key Vaults.
- **Azure by subscription.** The sidebar and the toolbar's path read Azure › subscription ›
  vault; each subscription opens and closes, and searching a subscription's name finds its vaults. Connect Azure keeps
  each vault's subscription; a vault connected before shows directly under Azure until its first
  Refresh.
- **Jump anywhere (⌘K).** The toolbar's search button, Edit › Jump Anywhere or ⌘K opens a
  palette of every place in the sidebar (organizations, repositories, environments, Key Vaults,
  folders): type part of a name or of its owner and repository, ↑↓ to move, ↩ to open, esc to
  close. Under **Secrets by name** it also lists up to 50 secrets and variables whose name holds
  what you typed, with where each one is; ↩ opens that place with the row selected. Values are
  never searched.
- **A quieter toolbar.** The toolbar shows the path of the selected place (`GitHub › owner ›
  repository › environment`, `Azure › subscription › vault`, `Folders › name`), the ⌘K search button and Sync.
  New Repository (⌘N, and now on an owner's menu with the owner preselected), Import .env
  (⇧⌘I) and Share Project (⌥⌘S) stay in the File menu. With nothing selected, the window says
  "Choose a place" with the pending changes and the ⌘K hint. "Your recovery key wasn't saved"
  moved from the sidebar to a strip under the toolbar, with Create New Key….
- **Floating panels.** The main window has no title bar of its own: the sidebar and the toolbar
  float as rounded glass panels on a soft ground, with the window's close, minimize and zoom
  buttons inside the sidebar's top corner. View › Hide Sidebar (⌃⌘S) slides the sidebar out and
  the toolbar starts after the window buttons; Edit › Find brings it back. Drag the gap after
  the sidebar to resize it (240 to 400 pt; FX Vault remembers it); drag the toolbar's empty
  part, the gaps or the band above the sidebar's search to move the window, and double-click
  them to zoom. The Sync button is a smaller pill with the sync symbol and the pending count.
- **A place's header and its ⋯ menu.** Every place opens with its name and one line saying what
  it is, where and how many (`Environment · api-service · 6 secrets · 2 variables · 1 without
  value`), then "N changed on GitHub · Review" when GitHub changed something. Its ⋯ menu holds
  New Secret, New Variable, Paste Multiple…, Import .env…, Export .env…, Copy To, Share
  Securely…, Deployment Branches…, Clone…, Refresh and Delete Selected… (what the place offers);
  Copy To takes the selected rows, or the open tab when none is selected. An environment's menu
  in the sidebar has Rename…, Duplicate Environment…, Share Securely…, Refresh and Delete
  Environment…. A folder keeps Copy To and Share Securely… beside its ⋯. Refresh shows
  "Refreshing…" under the title until GitHub or Azure answers, and Delete Selected… waits for a
  selected row that is not already deleted. The Add buttons, the tags under the title and the
  drift banner are gone.
- **Copy All.** A repository's scopes, Key Vaults and organizations have a Copy All button in
  their header, and every place has Copy All in its ⋯ menu. It asks for Touch ID (or your master
  password), then copies every value of the place as `.env` text: `# Secrets · N`, the secrets,
  a blank line, `# Variables · N`, the variables, a secret without a value as `KEY=`. The
  clipboard is marked concealed and clears after 30 seconds, when FX Vault locks and when it
  quits.
- **Sharing production.** Share Project lists production stages unchecked; checking one asks
  for Touch ID (or, without Touch ID, your master password at Create), and the send step names
  the production places. The file is refused unless that confirmation was given.
- **Organization access.** Settings › Accounts lists each account's organizations with whether
  it can manage their secrets: Ready, Needs admin:org (copy the commands, approve in the browser,
  Re-check), Org secrets need an org admin, or Needs SSO authorization.
- **Organization secrets and variables.** Selecting an organization in the sidebar opens its
  own secrets and variables: Import reads its secrets (names only) and variables, and
  the organization view lists them with who can use each one (all repositories, private and
  internal, or the selected ones) and when GitHub last changed it. Remove from Vault deletes
  them from this Mac only.
- **Send with AirDrop.** After the passphrase is saved, Send with AirDrop opens the AirDrop
  window for the file; Share… and Save… stay.
- **Notes.** Every place with values opens on its notes: numbered `# Secrets · N` and
  `# Variables · N` sections, secrets masked and variables in plain text, "no value" and
  "overrides example-org" at the end of a line, what a repository gets from its organization as
  a read-only section with who gets each item, and ○ / ● for changed on GitHub (or in Key Vault)
  and waiting for the next Sync. Notes | Table in the header switches to the table; a name
  opened from ⌘K opens the table. A click on a masked value reveals it after Touch ID or your
  master password, for 30 s, with the window kept out of screen capture.
- **Notes editing.** Click a line, or choose ⋯ More › Edit Notes, to edit a place's notes as
  text: type `KEY=value` lines under `# Secrets` or `# Variables`, rename, delete and move lines.
  A secret's value is never typed into the text: the key after `=` opens Set value… with it
  (type, paste or Generate), and a click on a value's token opens it again. A paste after a
  secret's `=` is its value; pasted `KEY=value` lines become masked tokens and the clipboard is
  cleared, and key material (Base64, hex, a known token, a connection string) never becomes a
  name. A copy from the
  notes writes `••••`. Each line says what it does or why it can't be saved, with Key Vault's
  name rules in a Key Vault. Review ⌘S lists what is added, changed and removed; Save turns it
  into pending changes, and nothing reaches GitHub or Key Vault until Sync. With unsaved
  changes, another place, scope or Table asks "Discard N unsaved changes?" first; locking drops
  the edit. Paste and Import .env… wait for the edit to end. An organization's notes stay read
  only.

### Removed

- **macOS 14 and 15.** FX Vault 1.0 needs macOS 26 Tahoe; 0.9 stays the version for older Macs.
- **Nearby, chat, teammates and shared spaces.** Pairing, presence, Nearby Chat, sending to a
  nearby Mac and shared spaces are gone, with their tables (migration `v15_drop_teammates`).
  Share a project as a passphrase `.fxvault` file instead; Share… still offers AirDrop. A 0.9
  file sealed for teammates no longer opens.
- **Overview and `fxvault.yml`.** The stage matrix, the manifest check and Share Stage… are
  gone. After you open a project file, FX Vault shows the first repository at the environment of
  the file's first stage.
- **Supabase and Vercel destinations.** Azure Key Vault is the only runtime destination. Your
  first unlock lists the Supabase and Vercel destinations removed from the vault, with their
  saved tokens (migration `v16_drop_runtime_providers`); nothing is deleted in Supabase or Vercel,
  so revoke those tokens there. Preferences › Destinations and Mark as Public are gone. A 0.9
  project file imports without its Supabase and Vercel destinations, and the preview names them.

## 0.9.0

### Added

- **Share a project as one file.** File › Share Project… (⌥⌘S), a repository's Share…, a
  folder's Share as File… or the Overview's **Share Stage…** writes one encrypted `.fxvault` file
  with one or more repositories: their repository level, the GitHub environment of each stage you
  pick and the runtime destinations of that stage (target, stage and values), plus folders if you
  add them. A tree per repository adjusts the selection down to single secrets, linked copies stay
  linked, and Mark as Public travels with the value. Send it with the system share picker
  (WhatsApp, Mail, Messages, AirDrop) or save it; the file name carries no repository or stage.
- **Two ways to protect it.** **Teammates**: sealed for up to 10 paired teammates' Macs and
  signed by yours, so it opens without a passphrase, only in FX Vault on their Macs, and shows
  "Verified teammate". **Anyone, with a passphrase**: six words you send another way, as before.
- **Expiry and a sent log.** A file expires after 1, 7 (default) or 30 days. Settings › Sharing
  lists every file this Mac wrote (date, expiry, recipients, repositories, stages and the names
  inside, never values) with "Rotate these secrets if the file leaked."
- **Open a project file.** The import sheet lists each repository as in your vault, to be
  imported from GitHub with your account, or skipped when none of your accounts can see it (open
  the same file again later). It previews the merge per scope, destinations (new ones arrive
  without a connection: connect your own account in Settings › Destinations) and folders, imports
  everything at once and opens the first repository's Overview at the shared stage.
- **From Files in Sync.** Rows a file brought that GitHub or the provider does not have yet are
  **Held**: a chip in the table and a cell in the Overview. Sync lists each file (sender, verified
  or not, date, names) with "Include in this Sync", off by default; Push on Next Sync on a held
  row releases just that row. A value you type yourself releases its row.
- **Pair at a distance (experimental).** Settings › Teammates › **Not Nearby…**: send an
  invitation card by chat or mail, the other person sends back a reply card, and you both compare
  six words on a call before confirming. Cards carry public keys and names only.

### Changed

- Share as File… is the new Share Project sheet everywhere; nearby sharing and Nearby Chat keep
  their 0.8 packages.
- Nearby Chat's Save as File… writes the new format too: a project file under a passphrase that
  expires after 7 days. A repository with a production environment can't be saved that way
  (import it, then share it with teammates).
- A teammate paired at a distance shows "Paired remotely" and, until you meet on the same
  network or they send you a file, "Seen nearby once you meet on the same network".

### Security

- A production stage (a name with `prod`, `production`, `prd` or `live` as a word) starts
  unchecked, needs a confirmation, and can only be sent to teammates, never with a passphrase.
- Connection tokens (Supabase, Vercel), `az` sessions, GitHub accounts and SSH aliases never go
  into a file.
- Nothing from a file reaches GitHub or a provider until you include it in a Sync.
- The six pairing words come from both cards and a fresh random value drawn by the replier, so a
  relay swapping cards cannot make the words match (about 2^77 work).

### Compatibility

- A `.fxvault` file from 0.9 needs FX Vault 0.9 or later (0.8 shows "Wrong passphrase or damaged
  file"); 0.9 still opens files from every earlier version.
- Remote pairing and teammate files are experimental.

### Known limits

- The import sheet previews one repository at a time; changing the stages in Share Project resets
  boxes you adjusted by hand.
- Environments and branch policies a file creates are not held: they appear in Sync's normal
  review.

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
