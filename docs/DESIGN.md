# FX Vault design language (v0.3.0)

FX Vault uses the FractalX design language (fractalx.io): a warm off-white ground, near-black
ink, Geist Sans and Geist Mono, pill buttons, 24 pt cards, hairlines instead of shadows and the
3×3 mark. Brand blue is an accent, never a surface.

- **Approved mockup:** `docs/design/mockup/*.dc.html` (boards: Main, MainDark, Lock, Onboarding,
  SyncReview, Brand) and tasks/todo.md, "v0.3.0: FractalX design language".
- **Tokens:** `App/Helpers/Theme` (`Theme.*`). **Components:** `App/Components/Design`.
- **Rule:** screens use tokens and components only. `scripts/lint.sh` fails on literal colors
  (`Color(red:…)`, `NSColor(srgbRed:…)`, hex helpers, `#colorLiteral`, `.red`, `Color.blue`, …)
  and literal fonts (`.system(size:)`, `Font.custom`, `NSFont(name:)`, …) anywhere in `App/`
  outside those two folders.
- Keep it native macOS: `NavigationSplitView`, `Table`, the `Settings` scene and system sheets
  stay; this language restyles them, it does not rebuild their behavior.

## Principles

1. **Quiet ground, ink type.** Most of the window is `ground`, `surface` and `card`. Contrast
   comes from ink text and hairlines.
2. **One accent.** `brand` marks only what is pending or interactive: pending dots, links, focus
   rings, and the Modified / Will push chips. It is never a fill behind text.
3. **Names are code.** Secret and variable names, values, counts, timestamps, paths and small
   labels are Geist Mono. Prose is Geist Sans.
4. **Hairlines, not shadows.** Every border is a 1 pt `hairline` or `hairlineStrong`. The only
   shadow is under a sheet drawn inside the window.
5. **Short, quiet motion.** 140 ms ease-out for state changes, one critically damped spring for
   things that move. Nothing bounces.
6. **No gradients, no emoji.** SF Symbols are fine for icons (outline weights, sized by the text
   style).

## Color

Every color is an asset-catalog color set with a light and a dark variant
(`App/Resources/Assets.xcassets`), exposed as `Theme.Colors.*`. `DesignTokenTests` checks every
value below and fails if a color set has no dark variant or no test.

| Token (`Theme.Colors.`) | Color set | Light | Dark | Use |
|---|---|---|---|---|
| `ground` (`onInk`) | Ground | `#F6F5F3` | `#0B0C0E` | Window background; text on an ink fill |
| `surface` | Surface | `#EDEBE7` | `#111820` | Sidebar, quiet panels, search field |
| `surface2` | Surface2 | `#E4E1DB` | `#18212A` | Secondary buttons, segmented track, selected sidebar row, offline banner, neutral chip |
| `card` | Card | `#FFFFFF` | `#111820` | Cards, tables, sheets, inputs, selected segment and scope |
| `ink` | Ink | `#0B0C0E` | `#F6F5F3` | Primary text, primary button fill |
| `mutedText` | MutedText | `#454D56` | `#A6B0BC` | Secondary text, paragraphs under headings, masked values |
| `subtleText` | SubtleText | `#5F6874` | `#808B97` | Section labels, timestamps, counts, placeholders |
| `faintText` | FaintText | `#A1A7AF` | `#4A5460` | Decorative only: the `/` in `02 / 05` |
| `hairline` | Hairline | ink 10% | white 8% | Default borders and dividers |
| `hairlineStrong` | HairlineStrong | ink 18% | white 16% | Outline buttons, tags, inputs, banners that need weight |
| `brand` | Brand | `#0B6FA4` | `#3BA3DD` | Accent (see principle 2); the app's global accent color |
| `warning` | Warning | `#8A6316` | `#D9A441` | Drift, value missing, offline |
| `success` | Success | `#1F7A55` | `#3FB283` | Verified, strong password |
| `danger` | Danger | `#CA2121` | `#EC6A6A` | Destructive actions, failures |
| `inkBadge` | InkBadge | ground 16% | ink 12% | The count badge inside an ink pill |
| `dotGrid` | DotGrid | ink 14% | white 10% | Dots of `DotGridBackground` |
| `shadow` | Shadow | ink 16% | black 48% | The one sheet shadow |

`Theme.Colors.windowBackground` is the `NSColor` of Ground for AppKit.
`Theme.Colors.onSelectionSecondary` is the hierarchical `.secondary` style, for secondary text in
native `List` rows that can be selected (it stays legible on the system selection highlight).

**Legacy names** (v0.2 screens; migrate when you touch a screen): `accent` → `brand`,
`background` → `ground`, `textPrimary` → `ink`, `textSecondary` → `mutedText`, `pending` → `brand`.

Contrast: `ink`, `mutedText` and `subtleText` meet WCAG AA for text on `ground`, `surface` and
`card` in both appearances (subtle on surface: 4.7:1 light, 5.2:1 dark). On `surface2`, light
`subtleText` (4.3:1) and `warning` (4.2:1) fall just under AA for small text: use `mutedText` for
text there and `warning` only for symbols. `faintText` does not meet AA anywhere; never use it for
information.

## Type

Fonts are Geist Sans and Geist Mono 1.7.2 (SIL OFL 1.1), static faces 400 / 500 / 600 in
`App/Resources/Fonts`, registered by `ATSApplicationFontsPath = .` in Info.plist (project.yml).
`FontRegistry` checks every face once; a missing face is registered from the bundle, and if that
fails too the matching system font (SF Pro / SF Mono, same weight) is used and logged.

A SwiftUI `Font` cannot carry tracking or case, so the scale has two layers:
`Theme.Typography.*` (a `Font`) and `Theme.TextStyle.*` (font + tracking + line spacing + case),
applied with `.fxTextStyle(_:)`. **Prefer `.fxTextStyle`**; use the bare font only where a `Font`
is required.

| `TextStyle` / `Typography` | Face | Size | Tracking | Use (mockup) |
|---|---|---|---|---|
| `.display` | Sans 500 | 44 | −0.04em | Lock headline "FX Vault is locked." |
| `.largeTitle` | Sans 500 | 34 | −0.03em | Environment heading, onboarding step title |
| `.title` | Sans 500 | 28 | −0.03em | Sheet title (SyncReview) |
| `.title2` | Sans 500 | 20 | −0.02em | Card and settings section titles |
| `.headline` | Sans 500 | 15 | −0.013em | Window title next to the mark, emphasized rows |
| `.lead` | Sans 400 | 16 (25 lines) | 0 | Paragraph under a display or large title |
| `.body` | Sans 400 | 14 (20 lines) | 0 | Default; the window default font |
| `.bodyEmphasized` | Sans 500 | 14 | 0 | Large primary button labels, links in banners |
| `.callout` / `.calloutEmphasized` | Sans 400 / 500 | 13 | 0 | Sidebar and scope rows, regular buttons, links |
| `.caption` | Sans 400 | 12 | 0 | Chips, captions under fields |
| `.mono` (`Typography.monospaced`) | Mono 400 | 14 | 0 | Names inside prose, recovery keys, commands |
| `.monoName` | Mono 400 | 13 | 0 | Names in tables and lists |
| `.monoValue` | Mono 400 | 13 | +0.08em | Masked values `••••••••` |
| `.monoMeta` | Mono 400 | 12 | 0 | Timestamps, counts, repository paths |
| `.monoCounter` | Mono 400 | 12 | +0.06em | `02 / 05` |
| `.sectionLabel` | Mono 400 | 11, UPPERCASE | +0.08em | `ENVIRONMENT`, `MASTER PASSWORD`, column headers |
| `.statusLine` | Mono 400 | 11, UPPERCASE | +0.06em | `PASSWORD REQUIRED AFTER RESTART`, `WRITE LIMIT …` |
| `.sasCode` (`Typography.sasCode`) | Mono 600 | 44 | +0.08em | The nearby `ddd ddd` code |
| `.passphraseWord` | Mono 500 | 20 | 0 | Words of a generated passphrase (`PassphraseView`) |
| `Typography.emptyStateIcon` | SF Symbols light | 32 | | The symbol above an empty state |
| `Typography.nsMonospaced` (`NSFont`) | Mono 400 | 14 | | AppKit text views (secret value and `.env` paste editors) |

Write strings in sentence case; `.sectionLabel` uppercases them (`textCase`), so translations
keep their own case rules.

## Spacing, shape, lines, motion

- **Spacing** (`Theme.Spacing`): 2, 4, 6 `smallMinus`, 8, 10 `mediumMinus`, 12, 16, 20
  `largePlus`, 24, 28 `xLargePlus`, 32, 36 `xxLargePlus`, 48, 56 `huge`, 64 `xHuge`.
- **Radius** (`Theme.Radius`): `card` / `sheet` 24, `container` 16 (tables, grouped lists),
  `control` 12 (inputs, banners, checkbox rows), `row` 10 (scopes), `compactRow` 8 (sidebar).
  Pills (buttons, chips, segmented control, pill inputs, badges) use the `.pill` shape
  (`Capsule(style: .circular)`, Radius.swift). The macOS 27 SDK's `Capsule()` defaults to
  `.continuous` corners, whose flatter ends read as short straight edges at pill sizes;
  `scripts/lint.sh` rejects `Capsule()`.
- **Lines** (`Theme.Stroke.hairline` = 1 pt): `hairline` by default, `hairlineStrong` for
  controls. Dashed rows ("New Environment") use `Theme.Stroke.dashPattern` (4 / 4). Focus rings are 2 pt `brand`, 2 pt outside the shape (`Theme.Layout.focusRing*`).
- **Shadow** (`Theme.Shadow`): only `Card(.sheet)`: `shadow` color, radius 32, y 24.
- **Motion** (`Theme.Durations`): `interaction` 0.14 s / `interactionAnimation` (ease-out) for
  hover, press, focus, selection, chips; `spring` (0.28 s, no bounce) for the selected segment,
  expanding rows and banners sliding in. Legacy `standardAnimation` = `interactionAnimation`.
- **Opacity** (`Theme.Opacity`): `disabled` 0.4, `pressed` 0.82, `hovered` 0.9.
- **Component metrics** live in `Theme.Layout` ("Design components" section): button heights
  34 / 42, input 44, chip 24, tag 22, segment 30, rows 52 / 36 / 32, mark 18 / 44, dot grid 22.

## Components (`App/Components/Design`)

### Buttons: `FXButtonStyle`, `FXIconButtonStyle`

```swift
Button(String(localized: "sync.confirm", defaultValue: "Sync \(count) changes")) { … }
    .fxButtonStyle(.primary, size: .large)
Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) { … }
    .fxButtonStyle(.secondary, size: .large)
Button { … } label: { Label(lockTitle, systemImage: "lock") }
    .fxIconButtonStyle()                       // 32 pt hairline circle
```

| Variant | Look | Use |
|---|---|---|
| `.primary` | ink fill, ground text, 500 | The one action the view exists for (Sync, Unlock, Continue, Add secret) |
| `.secondary` | `surface2` fill, `hairline` border (keeps the pill's edge on a dark `card`) | Cancel, Refresh, Touch ID |
| `.outline` | `hairlineStrong` border | Clone, Paste multiple, Back |
| `.ghost` | no chrome until hover | Inline and low-priority actions |
| `.destructive` | `danger` fill, ground text | Only the final confirm of a destructive action |

Sizes: `.regular` 34 pt / 13 pt text (toolbar, inline, headers), `.large` 42 pt / 14 pt (sheet
footers, onboarding, lock). A pill keeps its title's width (never truncates next to flexible
text). `isFullWidth: true` stretches the pill (lock Touch ID). Disabled pills
fade to 40%. Always apply with `.fxButtonStyle` / `.fxIconButtonStyle` (they replace the system
focus ring with the brand ring). Icon-only buttons need an accessibility label.

Do: one primary per view; put Cancel left of the primary. Don't: two primaries side by side,
brand-colored buttons, `.borderedProminent` in new screens.

### `SectionLabel`

```swift
SectionLabel(String(localized: "main.detail.environment", defaultValue: "Environment"))
SectionLabel(step.title, color: Theme.Colors.brand)    // the current onboarding step
```

Mono 11 uppercase, +0.08em, `subtleText`. Above sections, fields, table columns and sidebar
groups. Not a heading for long content (use `.title2`).

### `StatusChip`

```swift
StatusChip(status: row.status)                       // Synced = neutral filled; Modified, Will push = brand outlined
StatusChip(title: missingTitle, tone: .warning)      // outlined warning
StatusChip.valueMissing
StatusChip.tag(String(localized: "repo.private", defaultValue: "Private"))   // 22 pt, outline, no dot
```

Tones: `.neutral` (filled `surface2`, muted text), `.brand`, `.warning`, `.danger`, `.success`
(outlined in their color). `fill:` overrides the default; `showsDot: false` hides the dot. The
v0.2 `StatusChip(title:tint:)` still works: theme colors map to their tone.

### `Card`, `HairlineDivider`, `.fxCardBackground`, `.fxSheetBackground`

```swift
Card { SectionLabel(…); Text(title).fxTextStyle(.title) }    // 24 pt, padding 32
Card(.container) { FXTableHeaderRow(titles: …); rows… }       // 16 pt, no padding
Card(.sheet) { … }                                            // in-window dialog with the one shadow
SomeView().fxCardBackground(.container)
SheetContent().fxSheetBackground()                            // system .sheet content
```

### Inputs: `FXTextField`, `.fxInputField`

```swift
FXTextField(label: nameLabel, text: $name, prompt: "my-service", isMonospaced: true)
FXTextField(label: passwordLabel, text: $password, isSecure: true, shape: .pill)

@FocusState private var focused: Bool
SecureField(passwordLabel, text: $password).focused($focused).fxInputField(.pill, isFocused: focused)
```

44 pt, `card` fill, `hairlineStrong` border; 2 pt `brand` border while focused, `danger` while
`isInvalid`. `.pill` pairs with a pill button on one line (lock, search); `.rounded` (12 pt) is
for forms. Names and keys use `isMonospaced: true`.

### `SegmentedPill`

```swift
SegmentedPill(selection: $viewModel.kind, segments: [
    .init(value: .secret, title: secretsTitle, count: secretCount),
    .init(value: .variable, title: variablesTitle, count: variableCount),
], accessibilityLabel: kindTitle)
```

`surface2` track, selected segment `card` with a hairline, mono counts, spring motion. For 2 to 4
peer views of the same content and for the Secret / Variable, visibility and branch-rule type
choices of the editor sheets; settings keep native pickers. `.disabled` dims the whole control to
40%; `Segment(isEnabled: false)` dims and locks one segment (Convert or Move to the same kind).

### `Banner`

```swift
Banner(.offline, message: ConnectivityBannerModel.offline.message)
Banner(.info, message: driftText, action: .init(title: reviewTitle) { viewModel.reviewDrift() })
Banner(.warning, message: text, label: "Experimental")
```

12 pt corners in the content column (not edge to edge). `.info`: `card` + hairline + brand dot;
`.warning`: `card` + `hairlineStrong` + warning symbol (the drift banner with conflicts);
`.offline`: `surface2` + `hairlineStrong` + `wifi.slash` + the `OFFLINE` mono label (the only
`surface2` banner, so it reads apart from drift); `.danger`: `card` + `hairlineStrong` + danger
symbol. The action is an emphasized `FXLinkButtonStyle` link (brand on `card` is 5.49:1 light;
pointer cursor, 40% when disabled).

### `BrandMark`, `DotGridBackground`, `StepCounter`

```swift
BrandMark()                                                       // 18 pt ink, toolbar/sidebar
BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined)   // 44 pt, brand outlined center
LockContent().background(DotGridBackground())
StepCounter(current: 2, total: 5)                                 // "02 / 05"
```

### `SyncToolbarButton`

```swift
SyncToolbarButton(count: viewModel.pendingChangeCount, isSyncing: viewModel.isSyncing,
                  isEnabled: viewModel.canSync, unavailableReason: offlineHelp) { viewModel.sync() }
```

Ink pill "Sync" with the count in a mono `inkBadge` capsule; a spinner while syncing; 40% when
disabled. `SyncToolbarButton.title(count:)` ("Sync 5") stays the menu title. On macOS 26+, hide the
toolbar's shared glass behind it: `ToolbarItem { … }.sharedBackgroundVisibility(.hidden)` inside
`if #available(macOS 26, *)`.

### Tables and rows: `.fxTable`, `.fxTableCell`, `TableNameText`, `TableMetaText`, `FXTableHeaderRow`, `.fxRowBackground`

```swift
Table(rows, selection: $selection) {
    TableColumn(nameTitle) { row in TableNameText(name: row.name, isDeleted: row.isDeleted).fxTableCell() }
    TableColumn(updatedTitle) { row in TableMetaText(row.updatedText).fxTableCell() }
}
.fxTable()                                         // card container, 16 pt, hairline, no stripes

ScopeRow(scope).fxRowBackground(isSelected: isSelected, style: .scope)    // 36 pt, card + hairline
RepoRow(repo).fxRowBackground(isSelected: isSelected, style: .sidebar)    // 32 pt, surface2
```

`.fxTableCell()` gives 52 pt rows (cell content 44 + the inset table's padding; measured on a real
`NSTableView` by `DesignComponentTests`). Native `Table` keeps its system column header;
hand-built tables use `FXTableHeaderRow` (mono uppercase labels) inside `Card(.container)`.

### Sheet chrome: `SheetHeader`, `SheetCallout`, `FXCheckboxRow`, `InlineErrorView`, `FXLinkButtonStyle`, `.fxSheetContent`

One implementation each, in `SheetChrome.swift`; every sheet and full-window form uses them.

- `SheetHeader(label:title:subtitle:isExperimental:titleStyle:subtitleStyle:subtitleSpacing:alignment:accessory:)`:
  `SectionLabel` eyebrow, `.title`, `mutedText` `.body` subtitle, 6 pt apart (SyncReview). The
  title column has layout priority; an optional trailing accessory (Copy as Text) keeps its size.
  The lock screen centers it with `.display` / `.lead` and 8 pt before the subtitle.
- `.fxCalloutBackground()`: the quiet 12 pt `ground` row with a hairline. `SheetCallout`
  (symbol + message) and `FXCheckboxRow` (a confirmation checkbox) are drawn on it.
- `InlineErrorView(error:)`: the danger `Banner` box with a title and a message line.
- `.fxLinkButtonStyle(isEmphasized:)`: a `brand` text button with the pointing-hand cursor
  (macOS 15+), 40% when disabled ("Use recovery key", "Edit").
- `.fxSheetContent(width:)`: the content of a system `.sheet`: 32 pt padding on
  `.fxSheetBackground()`, optionally at a fixed width.

`PassphraseView` (App/Components) is the generated passphrase card shared by onboarding and
Share as File; `EmptyStateView` uses the light symbol, a `.headline` ink title and a `mutedText`
`.callout` message.

### `.fxWindowBackground()`

Applied once per scene in `FXVaultApp` (main window, Nearby Chat, Settings): `ground` behind the
content and as the `NSWindow` background, Geist 14 as the default font, `brand` tint. It sets no
foreground color, so `.primary` text still turns white on selected rows.

## Screen patterns

### Main window (boards Main, MainDark)

- Toolbar: `BrandMark()` + window title (`.headline`) + repository path (`.monoMeta`,
  `subtleText`) in a `Theme.Layout.toolbarTitleWidth` item over the scope column, which drops the
  path, then the name, when they do not fit; icon actions as `.fxIconButtonStyle()`;
  `SyncToolbarButton` last.
- Sidebar (`surface`, hairline on the right): `SectionLabel` group headers (ACCOUNTS, PERSONAL,
  org names), 32 pt rows with `.fxRowBackground(style: .sidebar)`, counts in `.monoMeta`,
  "Import" in `brand`; footer status in `.statusLine`.
- Scope column (`ground`): `SectionLabel("Scopes")`, 36 pt rows with `.fxRowBackground(style:
  .scope)`, a 6 pt `brand` dot for pending scopes, counts in `.monoMeta`; "New environment" as a
  dashed `hairlineStrong` row.
- Detail (`ground`, insets 28 top / 36 sides, 20 between blocks): `Banner`s first; then
  `SectionLabel("Environment")` + `.largeTitle` name + `StatusChip.tag`s + branch patterns in
  `.monoMeta`, with outline/secondary actions on the right (Clone, Refresh, and since v0.4.0
  the scope's actions menu as an outline `ellipsis` circle); the `SegmentedPill`
  (Secrets / Variables) with outline + primary actions; the table with `.fxTable()`.
- Dark appearance and offline are the same layout (MainDark): only tokens change; offline adds
  `Banner(.offline)` and disables the Sync pill.
- Columns take the window's height: each column of the split view has
  `.frame(minHeight: 0, maxHeight: .infinity)` (`mainColumnHeight()` in MainScreen.swift).
  AppKit sizes the split view from each column's minimum height, which SwiftUI measures at zero
  width, where a wrapped empty-state message is about 1,000 pt tall; the split view then
  outgrew the window and was centered in it, so the sidebar's first rows sat under the traffic
  lights and its footer fell below the window. A column scrolls or centers its own content.
- With two or more rows selected (v0.4.0), the add actions give their place to the selection's:
  "N selected" in `.monoMeta` `mutedText`, Copy To (an outline pill menu with a chevron), Push on
  Next Sync and Revert as outline pills when some rows allow them, Delete… as an outline pill
  (the destructive style stays for the dialog's final confirm), and Deselect as an outline
  circle.
- Linked copies (v0.4.1): a linked row shows `LinkedChip` after its name, a `brand` outlined
  capsule (`tagHeight`) with the `link` symbol (`monoLabel`) and the count (`monoMeta`). Its
  popover (`LinkedCopiesPopover`, `Theme.Layout.linkedPopoverWidth`) has a `SectionLabel`, the
  name in `.monoName`, one row per place (repository in `.monoName`, "scope · account" in
  `.monoMeta`, the copy's own name only when it differs, a `StatusChip`: Same value `.success`,
  Differs `.brand`, Value missing `.warning`, Not compared `.neutral`, and a chevron), a
  hairline, a caption and an outline Unlink.
- The detail fits its narrowest column (`Theme.Layout.detailMinWidth`): Clone and Refresh move
  under the title, the tags stack, and the add actions move under the Secrets / Variables pill
  when a row does not fit (`ViewThatFits`); the table scrolls sideways inside its card. Nothing
  spills under the scope column or past the window edge. `MainWindowLayoutTests` checks both.
- On macOS 26+ the sidebar's rows scroll under the traffic lights and the sidebar button with the
  system's soft scroll-edge effect, as in Finder; at rest they start below the title bar.

- Folders (v0.7.0): the sidebar starts with FOLDERS (`SectionLabel` and a quiet `plus` for New
  Folder…), one 32 pt row per folder (`folder` / `folder.fill` when selected, the name in
  `.callout` ink, the item count in `monoLabel` subtle, `.fxRowBackground(style: .sidebar)`), or
  a quiet "New Folder…" row when there is none. A selected folder fills column 2 with
  `FolderOverviewView` (FOLDER, the folder as a selected scope row with its counts in
  `.monoMeta`, then how its items reach repositories as a caption) and column 3 with the folder
  header (FOLDER, the name in `.largeTitle`, a "Never on GitHub" tag, Share as File… outline and a
  ••• menu) above the same Secrets / Variables pill, add actions and table as a repository, without
  the Status column.
- Teammates in the sidebar (v0.7.0): TEAMMATES is pinned above the footer behind a hairline:
  the label with a visibility menu (an `eye`, `eye.slash` or waves symbol in `mutedText`), then one
  row per paired teammate (`NearbyAvatar` with the `success` dot only while nearby, the name in
  `.callout`, "Nearby" in `success` or "Seen 2 hr. ago" in `monoLabel` subtle, a `bell.slash` when
  muted); nearby first. "Others nearby · N" lists people who are not teammates. With no teammate:
  one caption and "Add Teammate…". The section scrolls past `sidebarTeammatesMaxHeight`.
- The toolbar's people button (v0.7.0) replaced the avatar stack: `person.2` and the count in
  `monoLabel` inside a hairline capsule (`avatarSize` high), ink when someone is nearby; its
  popover lists the people nearby with Ping and Chat. A ping bounces it.
- Teammates nearby (v0.5.0, the bubbles until v0.7.0): `NearbyPresenceView` sat before the Sync
  pill: `avatarSize` circles with initials (`monoLabel`, `surface2` fill, a 2 pt `ground` ring so overlapping
  bubbles stay apart, `presenceOverlap`), a `success` dot for teammates, "+N" after
  `presenceMaxBubbles` (an outlined `surface` circle with its own list). A person scales in with
  the spring; a ping bounces the bubble (`phaseAnimator`). The ping outcome shows as a caption
  before the bubbles for 4 s. The popover (`presencePopoverWidth`): avatar, name in `.headline`,
  Mac name in `.monoMeta`, a Teammate (`.success`) or Nearby (`.neutral`) chip, a caption for
  strangers, Ping (outline, "Ping (8 s)" while cooling down) and Chat (primary); since v0.7.0
  a "Send Folder ▾" outline menu lists the folders that hold something.
- Shared spaces (v0.6.0): a shared scope's row in the scopes column shows a `brand`
  `person.2` symbol (help: what it means); the detail header adds a `brand` `StatusChip`
  "Shared · v7" ("· publishing" while a claim is open) that opens the space sheet. When a
  teammate's version arrives, "Got v7 from Ana" shows as a caption before the bubbles for 8 s
  (the ping outcome wins while it shows).
- Runtime destinations in the scope column (v0.8.0, canvas "FX Vault Destinations"): an
  **Overview** row first (`square.grid.2x2` in `mutedText`, `.callout`, the scope row
  background); `SectionLabel` BUILD · GITHUB ACTIONS over the GitHub scopes; after "New
  Environment", `SectionLabel` RUNTIME with an Experimental `StatusChip.tag`, then one 2-line
  row per destination: the provider symbol in `monoLabel` `mutedText`
  (`destinationSymbolWidth`, so names line up), the name in `.callout` (`.calloutEmphasized`
  when selected; tail-truncated) over "provider · stage" in `.caption` `mutedText`, then the
  value-missing `exclamationmark.triangle` in `warning`, the 6 pt `brand` pending dot and the
  count in `monoLabel` subtle, on `.fxRowBackground(style: .scope)`. "Add Destination" is a dashed
  `hairlineStrong` row like "New Environment". A destination's context menu (and the detail's
  ••• menu): Settings…, Export .env…, Remove from FX Vault… (destructive confirmation).
- Destination detail (v0.8.0, canvas board 3): `SectionLabel` DESTINATION · RUNTIME, the name in
  `.largeTitle` (middle-truncated), `StatusChip.tag`s for the provider, the stage (or "No stage")
  and Experimental, then how it is reached ("via Azure CLI sign-in", "via Vercel API token") in
  `.monoMeta` `subtleText`; Refresh (secondary, a small `ProgressView` while listing, disabled
  offline) and the ••• outline circle, beside the title or under it (`ViewThatFits`). A
  `container` card holds STAGE (`.callout`), TARGET (`.monoMeta`) and NAMES AND VALUES (the
  provider's rules in `.caption` `mutedText`), side by side or stacked. The Refresh banner is
  `.info` with Review ("2 changes in Key Vault since your last sync"), `.info` with a checkmark
  when nothing changed, and a `.warning` for items FX Vault cannot use (their names as help).
  Then the same table as a repository with the Status column: Vercel keeps the Secrets /
  Variables `SegmentedPill`; Key Vault and Supabase hold secrets only, so the pill gives way to a
  `SectionLabel` "SECRETS · 4". Add actions, multi-selection and the linked chip are unchanged.
- Stage Overview (v0.8.0, canvas boards 1, 2 and 5): `SectionLabel` STAGE · ALL DESTINATIONS
  with an Experimental tag, the stage in `.largeTitle`, tags for "2 destinations" and the
  `fxvault.yml` state ("No fxvault.yml in the repository", "fxvault.yml could not be read", …).
  The header's actions hold the stage picker (a native menu `Picker`, only with two or more
  stages; it replaced the canvas' stage switcher), Show Check / Hide Check (outline) and Read
  Again (secondary). The findings banner is `.warning` ("1 thing to fix in production", "…, by
  fxvault.yml" when a manifest was applied) or `.info` "This stage matches fxvault.yml." and has
  no action of its own: Show Check sits in the header. The matrix is a `Grid` in a `container`
  card: NAME (`.monoName`, linked count as a neutral chip), CYCLE (a `StatusChip.tag`: Build,
  Runtime, Public; the canvas' "who reads what"), then one column per place with a
  `SectionLabel` title and the environment or destination in `.monoMeta`; each cell is a
  `StatusChip` (Synced `.neutral`, Will push `.brand`, Missing / Extra / Differs / Value
  missing `.warning`, Blocked / Will delete `.danger`) that opens the place, or "—" in
  `subtleText` where the place does not use the name. The matrix scrolls sideways inside its
  card when the stage has more places than fit. A legend in `.caption` `subtleText` follows; Show
  Check opens the manifest panel (a `container` card: parse issues with their line as a chip,
  findings with Add Destination where a destination is missing, Copy .env.example (a menu per
  target) and Copy fxvault.yml for This Repository, both outline).
- Held rows (v0.9.0, tasks/todo.md P8): a row imported from a share file and not yet included
  in a Sync shows a `.warning` `StatusChip` "Held" in the Status column instead of Will push /
  Added, in repository scopes and destinations alike; its help names the sender's file and says
  how it gets out (Sync's From Files review, or Push on Next Sync, which releases only the hold).
  The Overview has the same "Held" cell (`.warning`, legend included), and its header gains
  "Share Stage…" (secondary) after Read Again: the Share Project sheet with this repository and
  stage checked.

### Sheets (board SyncReview)

- Add Teammate (v0.5.0): `SheetHeader`, "Visible to people nearby as …" caption, the people list
  in a `container` card (`addTeammateListHeight`), then `SASCodeView`, then an info `Banner`
  ("… is now your teammate") or a warning `Banner` with Try Again. Preferences › Teammates uses
  the Settings sections: Nearby (visibility picker with its explanation as the footnote, Mute all
  pings) and Teammates (avatar, name, login · Mac, last seen, Mute checkbox, Remove…, Add
  Teammate…).
- Share with Teammates (v0.6.0) is a `ConfigEditorSheet`: what sharing does in `mutedText`
  `.body`, then either warning `Banner`s naming what to sync or fill first, or the paired
  teammates as checkbox rows in a `ConfigSheetList` (name in `.body`, login · Mac in `.monoMeta`)
  and an optional Note `FXTextField`; after sharing, an info `Banner` with "Show Shared Scope".
- The space sheet (v0.6.0): `SheetHeader` (SHARED WITH TEAMMATES, the scope's name, "v7 ·
  3 members"), a native segmented picker (History / Members). History is a `ConfigSheetList` of
  versions (title `.bodyEmphasized`, Mac and time in `.monoMeta`, the note in `.body`, the items
  it changed as ghost buttons in a `FlowLayout`); choosing an item shows its versions above
  (fingerprint in `.monoMeta`, Reveal / Hide ghost, Restore This Value secondary, the revealed
  value in `.monoMeta` with text selection, the password row inline when Touch ID is not used).
  Members: name, login · Mac, "This Mac" (`brand`) or "Not paired on this Mac" (`warning`),
  Remove… (ghost, with a destructive confirmation), Add Teammates as a menu. The footer has only
  Done.
- The Sync sheet (v0.6.0) shows a blocked shared scope as one issue ("Shared with teammates ·
  production", the reason, how many changes wait) with Get Updates from Teammates or Take Over…
  (destructive confirmation); a run that publishes asks "What changed?" in an `FXTextField`
  under the summary. Drift review shows an info `Banner` with Get Updates from Teammates, and a
  teammate's finding has both choices unavailable with the reason.
- Preferences › Teammates › Outside this network (v0.6.0): the port as a narrow text field
  (`portFieldWidth`), then one row per teammate (name, "Sync shared scopes outside this network"
  or the last sync time, a switch) and, when on, a mono "Their address" `FXTextField`; the rules
  are the section footnote.
- New Folder… and Rename… (v0.7.0) are a `ConfigEditorSheet` with one rounded name field and its
  live note (invalid, or "Another folder already has this name").
- A received folder (v0.7.0), in Import Share and in chat's Save a Folder: a `container` card with
  the folder symbol, its name and counts, a `SegmentedPill` (Save as Folder / Import Into a
  Repository), then the folder picker (New folder or one of the vault's) with the name field, or
  "Names the folder already has" as a radio group (Keep mine / Replace with the received values);
  or the repository and scope pickers (read-only scopes disabled with the reason). An info
  `SheetCallout` says what happens next. After saving, a `success` callout ("Saved 2 items in
  Mobile App.").
- Copy to Another Repository (v0.4.1) is a `ConfigEditorSheet`: a rounded search field, then a
  `container` card (`Theme.Layout.copyTargetListHeight`) with `SectionLabel` account headers,
  repository rows (`.monoName`, chevron, `.fxRowBackground(style: .sidebar)` when chosen) and
  the chosen repository's scopes indented as radio rows (`.fxRowBackground(style: .scope)` when
  chosen; a `lock` symbol with the reason as help when read-only). After the copy the list gives
  way to an info `Banner` with the outcome and "Show …".
- The item editor's "Linked copies" field (v0.4.1) appears under the value once a new value is
  typed: one `FXCheckboxRow` per place ("owner/name · scope · account (Same value)") and an info
  note.
- Add Destination (v0.8.0) is a `ConfigEditorSheet` (`destinationSheetWidth`, eyebrow RUNTIME):
  PROVIDER as a `SegmentedPill` (Azure Key Vault / Supabase / Vercel) with a one-line note under
  it; STAGE as a rounded field with a Stages menu (the repository's environments) and its note;
  then the target: VAULT NAME and TENANT (OPTIONAL) as mono rounded fields for Key Vault, or a
  CONNECTION picker (an existing connection or New Token…, which shows NAME and ACCESS TOKEN
  fields and how to create a token) and the project, team and environment pickers for Supabase
  and Vercel. The primary is "Add and Import". Afterwards the fields give way to the import
  result ("4 items imported from the destination.", the ones without a value, the names left as
  they are) with Open Destination.
- A destination's Settings… (v0.8.0) is a `ConfigEditorSheet` with STAGE and, for Supabase and
  Vercel, the CONNECTION picker and a note pointing to Settings › Destinations.
- Destination drift review (v0.8.0) is a `ConfigEditorSheet` titled with the banner's sentence:
  a `ConfigSheetList` with each name in `.monoName`, what happened in the provider as a caption,
  and Keep Mine (outline) / Use Key Vault (secondary) per row; the footer has Close and "Use Key
  Vault for All" (primary). A value the provider does not return says so in the row.
- The Sync sheet (v0.8.0, canvas board 4) shows each destination as one more scope of its
  repository ("Key Vault · kv-example-prod · via Azure CLI sign-in"), its lines as "DATABASE_URL
  as DATABASE-URL" where the provider stores another name, blocked changes as issues with a fix
  (Show Destination), public-value warnings and Vercel variables shared with other environments.
  Destination deletions join the deletion review; the result shows "Confirmed in the
  destination", "Sent, but the destination did not list it yet…" or "Not sent" per item.
- Share Project (v0.9.0, `ProjectShareScreen`, `shareSheetWidth`, eyebrow SHARE) replaces the
  Share as File sheet for every entry point: File › Share Project… (⌥⌘S; ⇧⌘S is Sync), Share ›
  File… (toolbar and Vault menu), a repository's or scope's Share…, a folder's Share as File… and
  the Overview's Share Stage…. Step 1, what to share: REPOSITORIES as removable chips in a
  `FlowLayout` (`shippingbox`, `.monoName`, an `xmark.circle.fill`) with an Add Repository
  borderless menu; STAGES as checkboxes across those repositories, a production stage with a
  `.warning` "Production" chip, unchecked at first and checked only through a confirmation dialog
  ("Include production?", Include Production); "Repository-level secrets and variables" as a
  checkbox beside ADJUST WHAT'S INCLUDED; then the scope tree with one root per repository (and
  folders), destinations as nodes with their provider symbol; the summary ("7 secrets and
  variables in 3 repositories") in `.statusLine` `subtleText` and the value-missing names as a
  warning note. Step 2, SEND TO: two radio cards (`fxCardBackground(.container)`, a `brand`
  `largecircle.fill.circle` when chosen): Teammates (checkboxes, "Paired remotely" as a caption,
  "2 of up to 10 teammates" in `.monoMeta`; scrolls past 6) and "Anyone, with a passphrase",
  whose explanation turns `warning` and names the production places when it is not available;
  EXPIRES AFTER as a `SegmentedPill` (1 day / 7 days / 30 days) with the honest note for the
  chosen mode in `.caption` `subtleText`. Then Touch ID or the password (`ShareReauthView`) and
  the result: the six words (`PassphraseView`, a `warning` `SheetCallout` "Send these words
  another way…", "I've saved it") or a `success` `SheetCallout` "Sealed for Ana and Omar" with
  the expiry; Share… (primary, the system picker) and Save… (secondary), the file name in
  `.monoMeta`. The footer: Back (secondary), Cancel, Continue / Create Share File (primary).
- Import Share for a project file (v0.9.0, `ProjectShareImportView`): a passphrase field only for
  passphrase files; a teammates file opens directly, and "Not sent to this Mac", "Sender isn't
  your teammate" and "This share file has expired" are failures with their own title. The
  sender row: a person symbol, "From Ana" in `.bodyEmphasized`, `StatusChip` "Verified teammate"
  (`.success`) or "Not verified" (`.warning`) with its explanation as help, then created and
  expiry dates in `.monoMeta`. One `Card(.container)` lists the repositories: `checkmark.circle.fill`
  `success` "In your vault", `arrow.down.circle` `brand` "Will be imported from GitHub with
  user-a", `xmark.circle` `warning` "Skipped: none of your GitHub accounts can see it" (the name
  muted), counts in `.monoMeta` and a chevron (`brand` when chosen). The chosen repository shows
  today's merge preview, then DESTINATIONS (provider symbol, "Azure Key Vault · kv-example-staging",
  the stage as a chip, `.warning` for production, and "New, without a connection…" or "Merges
  into your destination…" as a caption) and FOLDERS (a picker: New folder, Merge keep mine /
  replace mine, Don't import). A note closes it: "Nothing reaches GitHub or a provider until you
  include it in Sync." The content scrolls past `projectShareContentMaxHeight`. After Import,
  `SheetCallout`s list what changed ("1 change waits for you in Sync › From Files" in `brand`),
  and the main window has already moved to the first repository's Overview at the first stage.
- Sync's From Files (v0.9.0, `SyncHeldSharesView`): a `ConfigSheetField` after the summary, its
  explanation as a caption, then one `ConfigSheetList` row per held file: `doc.badge.ellipsis` in
  `warning`, "From Ana's file" in `.bodyEmphasized` with a "Verified" `.success` chip or an
  "Unverified" tag, "Imported Jan 15, 2027 at 12:00 PM · 2 items" in `.monoMeta`, "Include in this Sync"
  as a checkbox (off), and Show 2 Items / Hide Items expanding the names per repository, scope
  and destination. A single file starts expanded. When only held rows wait, an `.info` `Banner`
  says so and Sync stays disabled until a file is included.
- Not Nearby… (v0.9.0, `RemotePairingSheet`, `addTeammateSheetWidth`, eyebrow TEAMMATES, an
  Experimental tag): the four steps as a numbered list and Create Invitation (primary); "Send
  Your Invitation" with Share… / Save…; an opened invitation ("Invitation from Ana", the person
  card, Create Reply); "Send Your Reply" and "Reply from Omar" with the person card and
  `PairingCodeView`: a `Card` with COMPARE THESE WORDS and the six words numbered in two columns
  (`StepCounter.padded`, `.passphraseWord`, selectable), then the warning caption. The footer is
  Cancel (the cancel action) and The Words Match, the same secondary pill as the nearby code's
  answers (`SASDecision`) and never the default button; afterwards "Omar is now your teammate…"
  and Done.

- Content on `card` (`.fxSheetBackground()`), padding 32, gap 22–24.
- Header: `SectionLabel` (REVIEW BEFORE SYNC) + `.title` + `mutedText` `.body` line.
- Lists in `Card(.container)` with hairline rows; scope labels mono.
- Confirmations as a 12 pt `surface`/`ground` row with a checkbox; names inside in `.mono`.
- Footer: `.statusLine` on the left, then `.secondary` Cancel and `.primary` confirm, both
  `.large`. A destructive confirm uses `.destructive`.
- Building blocks: `SheetHeader` and `FXCheckboxRow` (design components, above), plus
  `ConfigSheetFooter`, `ConfigSheetField` (a `SectionLabel` above a field) and `ConfigSheetList`
  (hairline rows in `Card(.container)` style) in `App/Components/ConfigEditorSheet.swift`; editor sheets wrap them in
  `ConfigEditorSheet` (scrolling fields, pinned footer under a hairline). Names in fields are
  `.fxInputField(.rounded, isMonospaced: true)`; `SecretValueEditor` is framed the same way.

### Lock and onboarding (boards Lock, Onboarding)

- Lock: `DotGridBackground` full window; centered column with `BrandMark(size: .brandMarkLarge)`,
  `.display` headline, `.lead` `mutedText` paragraph, a 360 pt form: `SectionLabel` + pill
  `FXTextField` and `.primary` Unlock on one line, `.secondary` full-width Touch ID, then a
  `.statusLine` and a `brand` link.
- Onboarding: left column (insets 56 / 64) with `StepCounter`, `.largeTitle`, `.lead` paragraph,
  rounded `FXTextField`s (460 pt), footer `.outline` Back + `.primary` Continue (`.large`); a 300 pt
  side panel (`surface`, hairline left) listing steps as `SectionLabel` (current in `brand`, done and
  upcoming in `subtleText`) over a value line (done and current in `ink`, upcoming in `subtleText`).

### Settings

Native `Settings` + `TabView` + `Form`; the window gets `.fxWindowBackground()`. Use
`SectionLabel` for group titles inside custom sections, `StatusChip` for states, and
`.fxButtonStyle(.secondary)` for row actions. Do not restyle native toggles and pickers.

Destinations (v0.8.0, tab symbol `server.rack`) uses the Preferences sections: AZURE KEY VAULT
(one row "Azure CLI" with its state, Check (secondary) and, when something is wrong, Copy az
login (outline); the footnote says the token stays in memory) and SUPABASE AND VERCEL (one row per
connection: its name, "provider · account" as the detail, a ••• menu with Rename…, Replace
Token… and Remove…; then Add Connection… (outline); the footnote says tokens are encrypted in the
vault). Add Connection… and Replace Token… are a `ConfigEditorSheet` (provider pill and name when
adding, the token in a mono `SecureField`, "Check and Save" as the primary; a failed check shows
under the field in `danger`).

Sharing (v0.9.0, tab symbol `paperplane`) has one section, FILES YOU SENT, with its footnote
("Values are never kept here"): one row per export, newest first: the date in `.monoMeta`, an
"Expired" neutral chip or "Expires …", a ••• menu with Remove from List (a confirmation that the
sent file is not affected), the recipients ("Passphrase" or "Teammates: Ana, Omar"), the
repositories and stages, and a disclosure "Names in this file · 4 secrets" with a `warning` note
"Rotate these secrets if the file leaked." over the names per place.

Teammates (v0.9.0): a remotely paired row adds "Paired remotely" as a caption and, until its
announce key arrives, "Seen nearby once you meet on the same network" instead of the last-seen
time; Not Nearby… (outline) and an Experimental tag sit beside Add Teammate….

### `.env`, sharing, nearby and chat (sheet pattern)

These sheets use the sheet chrome components (`SheetHeader` with `isExperimental` for nearby,
`.fxSheetContent()`, `SheetCallout`, `FXCheckboxRow`). `App/Screens/Sharing/ShareSheetComponents.swift`
adds only the `ShareSheetLabel` eyebrows, `ShareNoteView` (inline icon and callout text) and
`NearbyProgressRow`; `.shareListContainer()` draws a native `List` as a hairline `card` container.
Failures use `Banner(.danger)`.

- `.env` import: File / Paste as a `SegmentedPill`; the preview `Table` uses `.fxTable()` and
  `.fxTableCell()`, mono names (`.monoName`), the line number as `TableMetaText`, the kind as a
  neutral chip that toggles Secret / Variable (filled = secret, outlined = variable), "Make
  Secret" as a warning chip and "New" as a brand chip.
- Scope tree: native `List` + nested `DisclosureGroup`s in `.shareListContainer()` (the
  repository starts expanded; 140 to 260 pt tall), hairline separators,
  36 pt rows, ink tri-state checkbox symbols, chips for "Name only" (warning), "Selected items
  only" (neutral) and "With branch policy" (brand). The content summary starts with a
  `.sectionLabel` ("From owner/repo") over a `Card(.container)` grid: scope as `.statusLine`,
  counts `.calloutEmphasized`.
- Passphrase: a `Card` with the six words numbered (`StepCounter.padded`) in Geist Mono 500 at
  the `title2` size (`Theme.TextStyle.passphraseWord`; the shared `PassphraseView`), Copy as an
  outline pill; screen capture protected.
- Code comparison (`SASCodeView`): the code in a `Card(.container)` under a `CODE` label, Geist
  Mono 44/600 with +0.08em tracking (`Theme.TextStyle.sasCode`).
  "Codes match" and "Don't match" are **both `.secondary` large pills** (`SASDecision.buttonVariant`)
  with no default button: equal weight is a security rule, never make one primary.
- Nearby Chat window: `ground`, a `surface` people column with a hairline; header `.title2` +
  Experimental tag and a visibility pill with a `brand` dot (hollow when not visible). Own
  bubbles are `ink` with `onInk` text, the peer's `surface2`, 16 pt corners, times in `.monoMeta`.
  The composer is an `.fxInputField(.rounded)` editor with a ghost Attach and a primary Send.
  Attachment cards are `Card`s with the kind as a `SectionLabel`, the name in `.mono`, and Save
  (primary) / Dismiss (ghost).
- Repositories in chat (v0.4.0): the attachment picker switches Secret or Variable / Whole
  Repository with a `SegmentedPill`; repository rows show the `book.closed` symbol, the
  `owner/name` in `.monoName` and "1 environment · 4 items" as a caption (automatic grammar
  agreement, `inflect: true`). With an older peer the tab shows a `SheetCallout` instead. A
  repository card uses the `REPOSITORY` label, `book.closed`, the counts line in `.monoMeta`, and
  Import Into… (primary), Save as File… (secondary) and Dismiss (ghost). Import Into… first lists
  the receiver's repositories in `.shareListContainer()`; a repository that cannot be chosen is
  `.selectionDisabled` with the capability chip text ("Read-only: admin required") as a caption
  and its explanation as help, and the sender's own `owner/name` says "Same as the sender's".
  Save as File… is the `ShareExportScreen` sheet titled "Save as File" with "Received in Nearby
  Chat" as its label (v0.9.0: the only use of that sheet; a repository with a production
  environment shows the "Production goes to teammates only" alert).

## Do and don't

| Do | Don't |
|---|---|
| `Theme.Colors.*`, `.fxTextStyle`, `Theme.Spacing/Radius/Layout` | Literal colors, `.system(size:)`, numbers in screens |
| Mono for names, values, counts, dates, paths | Mono for sentences |
| Hairline borders | Shadows (except `Card(.sheet)`), gradients |
| Brand for pending, links, focus | Brand fills, brand body text |
| One primary pill per view | `.borderedProminent`, two primaries |
| Sentence-case strings, uppercase via `.sectionLabel` | Uppercase literals in String Catalogs |
| Pill buttons and menu items in Title Case (macOS HIG: "Add Secret", "Paste Multiple…"); text links ("Use recovery key", "Learn more"), headings, body and labels in sentence case | Sentence-case buttons copied from the web boards ("Add secret") |
| Native split view, table, settings, sheets | Custom window chrome or fake traffic lights |
| 140 ms ease-out, spring without bounce | Long or bouncy animations, emoji |

## App icon (board Brand)

A dark `#0B0C0E` squircle on Apple's 1024 pt macOS grid (824 pt tile, standard padding and drop
shadow), the off-white `#F6F5F3` 3×3 mark at 84/160 of the tile, and the center cell as a
`#3BA3DD` outlined square (stroke 0.09 of a cell pitch). `swift scripts/make-icon.swift
App/Resources/Assets.xcassets/AppIcon.appiconset` renders every size from the vector;
`DesignTokenTests.appIconSetIsComplete` checks the set. The geometry matches `BrandMark.Geometry`.

## Mockup board map

| Board | Implemented by |
|---|---|
| Brand: icon | `scripts/make-icon.swift`, `BrandMark` |
| Brand: color | `Theme.Colors`, the color sets |
| Brand: type, buttons | `Theme.Typography`, `Theme.TextStyle`, `FXButtonStyle` |
| Main / MainDark | `.fxWindowBackground`, `SectionLabel`, `.fxRowBackground`, `StatusChip`, `SegmentedPill`, `Banner`, `.fxTable`, `TableNameText`, `SyncToolbarButton`, `FXIconButtonStyle` |
| Lock | `DotGridBackground`, `BrandMark`, `.display`, `FXTextField(.pill)`, `FXButtonStyle` |
| Onboarding | `StepCounter`, `.largeTitle`, `.lead`, `FXTextField(.rounded)`, `SectionLabel` |
| SyncReview | `.fxSheetBackground`, `Card(.container)`, `.title`, `.statusLine`, `FXButtonStyle(.large)` |
| FX Vault Destinations 1: stage matrix (v0.8.0) | `StageOverviewScreen` (`OverviewHeader`, `OverviewMatrix`, `OverviewCell`); the stage switcher moved into the header's picker |
| FX Vault Destinations 2: who reads what | The CYCLE column (`StageOverviewCycle`: Build, Runtime, Public) and the legend |
| FX Vault Destinations 3: Key Vault destination | `DestinationDetailScreen`, the RUNTIME rows of `ScopeListView` |
| FX Vault Destinations 4: multi-provider Sync review | `DestinationSyncPresentation` sections in the Sync sheet |
| FX Vault Destinations 5: manifest | `OverviewManifestPanel`, the findings banner |

## Known limits

- System sheets keep the system corner radius and shadow; the 24 pt sheet look applies to
  `Card(.sheet)` dialogs drawn in the window.
- Native `Table` column headers take a styled `Text` (`ConfigTableView.header(_:)`: mono 11
  uppercase); the header row's own chrome stays native: it draws vertical column separators, and
  its divider spans the card while row separators are inset (the Main board has neither). Hiding
  the native header for an `FXTableHeaderRow` would need fixed column widths (SwiftUI does not
  expose the live, user-resizable widths), which would leave the table short of the column on
  wide windows, so the native header stays.
- The drift banner is `.info`, or `.warning` when a change on GitHub also changed in the vault
  (a decision is needed; nothing failed). `DriftBannerView` is the only implementation.
- On macOS 26+ the toolbar draws shared glass behind items unless hidden per item.
- The native split view runs the scope/detail divider through the toolbar, and a `.navigation`
  item lands at the scope column's leading edge even when attached to the detail column. So the
  toolbar title is a fixed-width item sized to the default scope column: at that width the path
  does not fit and is dropped (the board's one-row header with `owner / repo` has no column
  dividers). With the sidebar collapsed, or the scope column narrowed below its default, a long
  title can still reach the divider.
- Tracking is not part of `Font`; text styled with a bare `Theme.Typography` font has no tracking.
- The Overview matrix (v0.8.0) takes each column's ideal width inside a horizontal `ScrollView`,
  so at the default window width (1,120 pt, sidebar shown) a stage with three or more places
  scrolls sideways and the last column starts clipped at the card's edge. Collapsing the sidebar
  or widening the window shows it whole.
- Import Share for a project file (v0.9.0) previews one repository at a time: the list chooses
  which; the others are not expanded together.
- In Share Project (v0.9.0), changing the stages rebuilds the tree, so boxes adjusted by hand in
  it are reset (checked folders are kept).

## Visual snapshots

`AppTests/VisualSnapshotTests.swift` renders the main screens in light and dark at 2x for review.
It runs only when `FXV_SNAPSHOTS_DIR` is set (through xcodebuild, also pass it as
`TEST_RUNNER_FXV_SNAPSHOTS_DIR`):

```sh
FXV_SNAPSHOTS_DIR=$PWD/.build-snapshots TEST_RUNNER_FXV_SNAPSHOTS_DIR=$PWD/.build-snapshots \
  xcodebuild -project FXVault.xcodeproj -scheme FXVault -destination platform=macOS \
  -derivedDataPath .build-dd CODE_SIGN_IDENTITY=- test -only-testing:AppTests/VisualSnapshotTests
```

Each screen gives `<name>-<light|dark>.window.png` (an offscreen window): the review set is these
window captures (9 screens × 2 appearances = 18 files; v0.6.0 adds `space-share`,
`space-history`, `space-members`, `sync-summary-space` and `settings-teammates-remote`; v0.7.0
adds `main-folder`, `main-folder-variables`, `main-sidebar-teammates`, `presence-popover-folder`,
`folder-destination` and `folder-destination-new`; v0.8.0 adds `main-destination-keyvault`,
`main-destination-vercel`, `main-overview`, `add-destination` and `settings-destinations`, over
`MainSnapshotFixture.destinations` (`kv-example-prod` and `example-web · Production`)).
v0.9.0 adds two suites gated the same way (pass `-only-testing:AppTests/ProjectShareSnapshotTests`
and `-only-testing:AppTests/ProjectShareTeamSnapshotTests`): `project-share-contents`,
`project-share-contents-three`, `project-share-send-to`, `project-share-send-to-passphrase`,
`project-share-passphrase`, `project-share-teammates-done`, `project-share-open`,
`project-share-expired` and `settings-sharing`; `sync-held-one`, `sync-held-two`,
`sync-held-only`, `main-held`, `pairing-start`, `pairing-invitation-ready`, `pairing-invitation`,
`pairing-reply-ready`, `pairing-reply`, `pairing-paired` and `settings-teammates-paired-remotely`.
The offscreen window capture leaves the repository sidebar blank or black in some captures; the
running app draws it normally. SwiftUI `ImageRenderer` is not used: it
cannot draw AppKit-backed views (`ScrollView`, `List`, `Table`, text fields, toggles, the split
view), which came out blank or as placeholders. A window capture cannot draw the macOS 26+ glass
sidebar, so the sidebar also has its own snapshot (`main-sidebar`).
