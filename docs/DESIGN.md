# FX Vault design language

## 1.0: minimal black and white, Liquid Glass (approved 2026-10-25, building in B11)

Replaces the v0.3.0 language below slice by slice: B11b the two-column window, B11c the colors and
type (the Color and Type sections below are 1.0's, and `DesignTokenTests` checks them). Sections
not yet rebuilt still describe v0.3.0. Brief: [V1-BRIEF.md](design/V1-BRIEF.md). Boards: `docs/design/mockup/v1/`
(`canvas.json` lays them out).

- **Platform:** macOS 26 minimum; native Liquid Glass (`glassEffect`) for floating chrome, one code path.
- **Color:** white ground and black ink (dark: black and white); greys only for secondary text and hairlines, every
  text 4.5:1 or more on glass. No brand blue: the current or interactive state is ink. Muted red and green only for
  small error and success marks.
- **Glass:** windows are frosted glass over the desktop; cards, lists and inputs inside are a more opaque glass so
  text stays crisp; the progress bar and the footer action bar float as glass.
- **Type:** the system font (SF Pro) for prose, a monospace for names, values and commands. Body 13 pt, secondary
  12, labels 11, titles 22–24 semibold.
- **Size:** macOS regular controls (28–32 pt), rows 32, checkboxes 14, forms about 440 wide; few words.
- **Unlock:** after onboarding only the notch island (Touch ID or password), flat black, no shadow; without a notch,
  a dark glass pill under the menu bar.
- **Motion and sound:** short and quiet; the first import draws a check and plays the system "Glass" sound, both off
  with Reduce Motion and the system's interface-sound setting.
- **Setup commands:** an embedded terminal runs only the suggested command (Run), with Copy as a fallback.

## v0.3.0 (being replaced)

FX Vault used the FractalX design language (fractalx.io): pill buttons, 24 pt cards, hairlines
instead of shadows and the 3×3 mark. Since 1.0 (B11c) the ground is white and the ink black, the
fonts are SF Pro and SF Mono, and there is no brand blue.

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
2. **Ink is the accent.** `brand` (ink since 1.0) marks only what is pending or interactive:
   pending dots, links, focus rings, and the Modified / Will push chips.
3. **Names are code.** Secret and variable names, values, counts, timestamps, paths and small
   labels are SF Mono. Prose is SF Pro.
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
| `ground` (`onInk`) | Ground | `#FFFFFF` | `#000000` | Window background; text on an ink fill |
| `surface` | Surface | `#F5F5F7` | `#1C1C1E` | Quiet panels, search field |
| `surface2` | Surface2 | `#E8E8ED` | `#2C2C2E` | Secondary buttons, segmented track, selected sidebar row, offline banner, neutral chip |
| `card` | Card | white 80% | `#1C1C1E` 72% | Cards, tables, sheets, inputs, selected segment: the more opaque glass inside a window |
| `ink` | Ink | `#000000` | `#FFFFFF` | Primary text, primary button fill |
| `mutedText` | MutedText | `#3F3F42` | `#AEAEB2` | Secondary text, paragraphs under headings, masked values |
| `subtleText` | SubtleText | `#5C5C61` | `#8E8E93` | Section labels, timestamps, counts, placeholders |
| `faintText` | FaintText | `#A1A1A6` | `#48484A` | Decorative only: the `/` in `02 / 05` |
| `hairline` | Hairline | black 8% | white 10% | Default borders and dividers |
| `hairlineStrong` | HairlineStrong | black 16% | white 20% | Outline buttons, tags, inputs, banners that need weight |
| `brand` | Brand | `#000000` | `#FFFFFF` | Ink: the current or interactive state (principle 2); the app's global accent color |
| `warning` | Warning | `#8A6316` | `#D9A441` | Drift, value missing, offline (small marks) |
| `success` | Success | `#1F7A55` | `#3FB283` | Verified, strong password (small marks) |
| `danger` | Danger | `#CA2121` | `#EC6A6A` | Destructive actions, failures |
| `inkBadge` | InkBadge | white 20% | black 12% | The count badge inside an ink pill |
| `dotGrid` | DotGrid | black 12% | white 10% | Dots of `DotGridBackground` |
| `shadow` | Shadow | black 12% | black 40% | The one sheet shadow |
| `scrim` | Scrim | black 6% | black 30% | The dimmed window behind the ⌘K jump palette |

`Theme.Colors.windowBackground` is the `NSColor` of Ground for AppKit.
`Theme.Colors.onSelectionSecondary` is the hierarchical `.secondary` style, for secondary text in
native `List` rows that can be selected (it stays legible on the system selection highlight).

**Legacy names** (v0.2 screens; migrate when you touch a screen): `accent` → `brand`,
`background` → `ground`, `textPrimary` → `ink`, `textSecondary` → `mutedText`, `pending` → `brand`.

Contrast: `ink`, `mutedText` and `subtleText` meet WCAG AA for text on `ground`, `surface` and
`card` in both appearances (subtle on white about 6.7:1, on black about 6.4:1). On dark `surface2`,
`subtleText` (about 4.3:1) falls just under AA for small text: use `mutedText` for text there and
`warning` only for symbols. `faintText` does not meet AA anywhere; never use it for
information.

## Type

Fonts are the system faces since 1.0: SF Pro (`Font.system`) and SF Mono (`design: .monospaced`,
`NSFont.monospacedSystemFont`). Nothing is bundled or registered; SF Pro tracks itself by size, so
headings add no tracking.

A SwiftUI `Font` cannot carry tracking or case, so the scale has two layers:
`Theme.Typography.*` (a `Font`) and `Theme.TextStyle.*` (font + tracking + line spacing + case),
applied with `.fxTextStyle(_:)`. **Prefer `.fxTextStyle`**; use the bare font only where a `Font`
is required.

| `TextStyle` / `Typography` | Face | Size | Tracking | Use (mockup) |
|---|---|---|---|---|
| `.display` | SF Pro semibold | 32 | 0 | Lock headline |
| `.largeTitle` | SF Pro semibold | 24 | 0 | Onboarding step title |
| `.title` | SF Pro semibold | 22 | 0 | Sheet title |
| `.placeTitle` / `.monoPlaceTitle` | SF Pro / SF Mono semibold | 20 | 0 | A place's name heading its detail: mono for names from GitHub and Azure, sans for a folder (boards Main2-Repository, Folder-View) |
| `.title2` | SF Pro semibold | 17 | 0 | Card and settings section titles |
| `.headline` | SF Pro semibold | 13 | 0 | The app name with nothing selected, emphasized rows |
| `.lead` | SF Pro | 15 (22 lines) | 0 | Paragraph under a display or large title |
| `.leadEmphasized` | SF Pro semibold | 15 | 0 | Compact sheet title ("Review Sync") |
| `.body` | SF Pro | 13 (18 lines) | 0 | Default; the window default font |
| `.bodyEmphasized` | SF Pro medium | 13 | 0 | Large primary button labels, links in banners |
| `.callout` / `.calloutEmphasized` | SF Pro / semibold | 13 | 0 | Regular buttons, links |
| `.caption` / `.captionEmphasized` | SF Pro / medium | 12 | 0 | Chips, captions under fields, secondary text, folder names in the sidebar |
| `.placeName` | SF Pro semibold | 12 | 0 | A place heading a Sync summary card |
| `.label` / `.labelEmphasized` (`.sidebarSection`) | SF Pro / medium | 11 | 0 | Sidebar sublines and "Show N more"; section headers ("GitHub") |
| `.mono` (`Typography.monospaced`) | SF Mono | 13 | 0 | Names inside prose, recovery keys, commands |
| `.monoName` | SF Mono | 13 | 0 | Names in tables and lists |
| `.monoValue` | SF Mono | 13 | +0.08em | Masked values `••••••••` |
| `.monoMeta` / `.monoMetaEmphasized` | SF Mono / medium | 12 | 0 | Timestamps, counts, repository paths; names in the sidebar tree and the Sync summary |
| `.monoCounter` | SF Mono | 12 | +0.06em | `02 / 05` |
| `.sectionLabel` | SF Mono | 11, UPPERCASE | +0.08em | `ENVIRONMENT`, `MASTER PASSWORD`, column headers |
| `.statusLine` | SF Mono | 11, UPPERCASE | +0.06em | `PASSWORD REQUIRED AFTER RESTART`, `WRITE LIMIT …` |
| `.passphraseWord` | SF Mono medium | 17 | 0 | Words of a generated passphrase (`PassphraseView`) |
| `Typography.emptyStateIcon` | SF Symbols light | 32 | | The symbol above an empty state |
| `Typography.nsMonospaced` (`NSFont`) | SF Mono | 13 | | AppKit text views (secret value and `.env` paste editors) |

Write strings in sentence case; `.sectionLabel` uppercases them (`textCase`), so translations
keep their own case rules.

## Spacing, shape, lines, motion

- **Spacing** (`Theme.Spacing`): 2, 4, 6 `smallMinus`, 8, 10 `mediumMinus`, 12, 16, 20
  `largePlus`, 24, 28 `xLargePlus`, 32, 36 `xxLargePlus`, 48, 56 `huge`, 64 `xHuge`.
- **Radius** (`Theme.Radius`): `card` / `sheet` 24, `container` 16 (tables, grouped lists, the
  ⌘K palette), `control` 12 (inputs, banners, checkbox rows), `row` 10 (scopes), `compactRow` 8
  (sidebar).
  Pills (buttons, chips, segmented control, pill inputs, badges) use the `.pill` shape
  (`Capsule(style: .circular)`, Radius.swift). The macOS 27 SDK's `Capsule()` defaults to
  `.continuous` corners, whose flatter ends read as short straight edges at pill sizes;
  `scripts/lint.sh` rejects `Capsule()`.
- **Lines** (`Theme.Stroke.hairline` = 1 pt): `hairline` by default, `hairlineStrong` for
  controls. Dashed rows ("Add Destination") use `Theme.Stroke.dashPattern` (4 / 4). Focus rings are 2 pt `brand`, 2 pt outside the shape (`Theme.Layout.focusRing*`).
- **Shadow** (`Theme.Shadow`): only `Card(.sheet)` and the ⌘K palette (`.popover`): `shadow`
  color, radius 32, y 24.
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
| `.primary` | ink fill, ground text, 500 | The one action the view exists for (Sync, Unlock, Continue, Import) |
| `.secondary` | `surface2` fill, `hairline` border (keeps the pill's edge on a dark `card`) | Cancel, Touch ID |
| `.outline` | `hairlineStrong` border | Back, a folder's Copy To and Share Securely… |
| `.ghost` | no chrome until hover | Inline and low-priority actions |
| `.destructive` | `danger` fill, ground text | Only the final confirm of a destructive action |

Sizes: `.regular` 34 pt / 13 pt text (inline, sheets), `.large` 42 pt / 14 pt (sheet
footers, onboarding, lock), `.compact` 26 pt / 12 pt with 8 pt corners instead of the capsule (a
place header's buttons). `.fxIconButtonStyle(size: .compact)` is the matching 26 pt square, the
header's ⋯ More. A pill keeps its title's width (never truncates next to flexible
text). `isFullWidth: true` stretches the pill (lock Touch ID). Disabled pills
fade to 40%. Always apply with `.fxButtonStyle` / `.fxIconButtonStyle` (they replace the system
focus ring with the brand ring). Icon-only buttons need an accessibility label.

Do: one primary per view; put Cancel left of the primary. Don't: two primaries side by side,
brand-colored buttons, `.borderedProminent` in new screens.

### `SectionLabel`

```swift
SectionLabel(String(localized: "main.detail.environment", defaultValue: "Environment"))
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
BrandMark()                                                       // 18 pt ink
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
SidebarTreeRow(level: 1, systemImage: Theme.Symbols.repository, title: repo.name, isSelected: isSelected) { select() }
                                                   // 28 pt, surface2 when selected (.fxRowBackground(style: .sidebar))
JumpPlaceRow(…).fxRowBackground(isSelected: isSelected, style: .palette)  // 34 pt, surface2 (⌘K palette)
```

`.fxTableCell()` gives 34 pt rows (boards Main2, Org-Visibility; cell content 26 + the inset table's padding; measured on a real
`NSTableView` by `DesignComponentTests`). Native `Table` keeps its system column header;
hand-built tables use `FXTableHeaderRow` (mono uppercase labels) inside `Card(.container)`.
Column headers are 12 pt medium, sentence case, muted (`ConfigTableFormat.header`);
`TableMetaText` is 12 pt sans muted; a table's Status column is `StatusDotLabel` (the tone's dot
and the title, no chip; D6a).

### Sheet chrome: `SheetHeader`, `SheetCallout`, `FXCheckboxRow`, `InlineErrorView`, `FXLinkButtonStyle`, `.fxSheetContent`

One implementation each, in `SheetChrome.swift`; every sheet and full-window form uses them.

- `SheetHeader(label:title:subtitle:isExperimental:titleStyle:subtitleStyle:subtitleSpacing:alignment:accessory:)`:
  `SectionLabel` eyebrow, `.title`, `mutedText` `.body` subtitle, 6 pt apart (SyncReview). The
  title column has layout priority; an optional trailing accessory (Copy as Text) keeps its size.
  The lock screen centers it with `.display` / `.lead` and 8 pt before the subtitle.
- `.fxCalloutBackground()`: the quiet 12 pt `ground` row with a hairline. `SheetCallout`
  (symbol + message) and `FXCheckboxRow` (a confirmation checkbox) are drawn on it.
- `InlineErrorView(error:)`: the danger `Banner` box with a title and a message line.
- `.fxLinkButtonStyle(isEmphasized:)`: a `brand` text button with the pointing-hand cursor,
  40% when disabled ("Use recovery key", "Edit").
- `.fxSheetContent(width:)`: the content of a system `.sheet`: 32 pt padding on
  `.fxSheetBackground()`, optionally at a fixed width.

`PassphraseView` (App/Components) is the generated passphrase card shared by onboarding and
Share as File; `EmptyStateView` uses the light symbol, a `.headline` ink title and a `mutedText`
`.callout` message.

### `.fxWindowBackground()`

Applied once per scene in `FXVaultApp` (main window, Settings): `ground` behind the
content and as the `NSWindow` background, SF Pro 13 as the default font, `brand` tint. It sets no
foreground color, so `.primary` text still turns white on selected rows.

## Screen patterns

### Main window (boards Main2-Home, Main2-Repository; two columns since 1.0, B11b)

- Toolbar (1.0 D6c2; boards Main2-Home, Main2-Repository, Main2-Search): the system's glass
  toolbar (`MainToolbar.swift`). The title item, shared glass hidden, is the selected place's
  path (`MainViewModel.breadcrumb`) in sans `.callout`: the steps `mutedText`, the separators
  `faintText`, the last step `.calloutEmphasized` ink (`GitHub › owner › repo › environment`,
  `Azure › vault` or `Folders › name`), or "FX Vault" in `mutedText` with nothing selected, then
  the DEV chip in Debug builds. It is a fixed `Theme.Layout.toolbarTitleWidth` item at the
  detail column's leading edge; a long path drops its first steps down to the last one, then
  shows the app name. Then the search button (`magnifyingglass` + `KeyHint("⌘K")`) on its own
  glass, a fixed `ToolbarSpacer`, and `SyncToolbarButton` with its shared glass hidden. New
  Repository, Import .env and Share are menu commands only (⌘N, also on an owner's menu; ⇧⌘I;
  ⌥⌘S).
- Sidebar (1.0, D6c1; boards Main2-Home, Main2-Expanded, Main2-Repository, Main2-Dark): the
  system's split-view sidebar with its own Liquid Glass and no fill of ours (the boards draw it
  floating; whether it floats is the system's call, and macOS 27 draws it full height). On top the search field
  (`surface2`, `compactRow` radius, `sidebarControlHeight`, a `KeyHint("⌘F")`; Edit › Find
  focuses it and brings a hidden sidebar back). Then sections with a `SidebarSectionHeader` (11 pt medium, sentence case,
  `subtleText`): GitHub, Azure, Folders (a quiet `plus` for New Folder…). Every node is a
  `SidebarTreeRow`: 28 pt, a chevron column and a symbol column so names line up,
  `sidebarTreeIndent` (14) per level, names in `.monoMeta` (`.monoMetaEmphasized` selected; the
  user's own names, folders, in `.caption`), `subtleText` for a repository not in the vault and
  for a deleted environment (struck through), marks on the right (a `SidebarCount` in
  `monoLabel` subtle, the 6 pt `brand` `SidebarPendingDot`), `.fxRowBackground(style: .sidebar)` when selected.
- GitHub has no account level: one node per owner (`Theme.Symbols`: `building.2` or `person`) across every gh
  account, organizations first, then people. An organization's node is its place (selecting it opens its secrets and variables, or
  Import); its chevron opens its repositories (`book.closed`), which list the ones in the vault
  and the selected one, the rest behind "Show N more" (`.label` subtle). A `SidebarSubline`
  (`.label` subtle, its action in `.labelEmphasized` ink) says what an owner needs: "Needs
  admin:org · Approve", "Authorize SSO · Open", "Not logged in · Settings". Owners start
  collapsed; a selection opens its owner and a search opens all. New Repository… (the owner
  preselected) and Add Repository by Name… are on the owner's context menu, New Environment… on
  the repository's.
- The selected imported repository's row stands for its repository scope; its environments
  (`ScopeListView`, `smallcircle.filled.circle`, level 2) nest under it with the secrets without
  a value and the pending dot, then the runtime destinations. Clicking the repository row again
  goes back to the repository scope; Up and Down walk the branch once one of its rows was
  clicked.
- Azure lists the Key Vaults of their own flat (`key`, level 0; context menu and the detail's
  Actions: Remove from FX Vault…) until the subscriptions of 1g. The bottom of the sidebar holds
  the listing state or the last notice in `.label`, then Lock and Settings as quiet icons.
- Home (nothing selected; board Main2-Home): `EmptyStateView` with `square.3.layers.3d`, "Choose
  a place", the pending changes ("4 pending changes", or "No pending changes") and
  `KeyHint("⌘K")` + "to jump anywhere".
- Recovery key (never confirmed as saved; board Main2-Home): a `.warning` `Banner` with `key` at
  the top of the detail column, over every place: "Your recovery key wasn't saved" · Create New
  Key… (Settings › Security on the new-key sheet). The key shown at onboarding cannot be shown
  again, so the board's "Show Key" is not offered.
- Jump palette (⌘K, Edit › Jump Anywhere or the toolbar's search button; board Main2-Search):
  over the window on `scrim` (a click outside closes it), `jumpPaletteWidth` wide under the
  toolbar, `.fxCardBackground(.popover)`. The field (`.headline`, `jumpPaletteFieldHeight`), a
  divider, "Places" (`SidebarSectionHeader`) with rows up to `jumpPaletteListMaxHeight`, then it
  scrolls: `.fxRowBackground(style: .palette)` (34 pt), the place's symbol, its name in its
  sidebar style with the first typed word in the emphasized weight, the detail ("Folder",
  "owner › repository") in `.caption` subtle, `KeyHint("↩")` on the selected row. A divider and
  the footer keys: ↑ ↓ to move, ↩ to open, esc to close. Every typed word must be in the name or
  the owner and repository; names that start with a word come first, then names that contain
  one, then path matches. Secrets by name join in 1f.
- Detail (no background of its own: the window's `ground` shows; `.fxPlaceColumn()`: insets
  28 sides / 20 top and bottom, 14 between blocks, `Spacing.mediumPlus`): `Banner`s first; then
  the place header (1.0 D6c3, `PlaceHeader`; boards Main2-Repository, Place-Table): the name in
  `.monoPlaceTitle` (`.placeTitle` for a folder), "kind · parent · counts" in `.caption`
  `subtleText` (`PlaceCopy.subline`: `Environment · api-service · 6 secrets · 2 variables · 1
  without value`; the repository scope adds its visibility and "created by the next Sync"; a Key
  Vault "Key Vault · 32 secrets"; a folder "Folder · never sent anywhere by itself · …"), then a
  status line: the drift line (`DriftBannerView`: a 7 pt ink ring, "2 changed on GitHub" in
  `mutedText` (`warning` when a change also changed in the vault), "·", Review as an
  emphasized link) or why the check failed. On the right, bottom-aligned: the place's own
  `.compact` outline buttons (a folder's Copy To and Share Securely…) and ⋯ More. The
  `SegmentedPill` (Secrets / Variables) with the selection's actions; the table with
  `.fxTable()`.
- ⋯ More (board Main2-Actions), what each place offers, disabled when the account may not:
  New Secret, New Variable | Paste Multiple…, Import .env…, Export .env… | Copy To (the
  selection, or the open tab when nothing is selected), Share Securely… | Deployment Branches…
  (an environment; its help says the policy and the plan note), Clone…, Refresh | Delete
  Selected…. An organization: New Secret, New Variable | Remove from Vault…. A Key Vault: New
  Secret | Paste Multiple…, Import .env… | Copy To, Refresh | Delete Selected… | its own menu. A
  folder: the item actions, then its own menu (Rename…, Share Securely…, Export .env…, Delete
  Folder…). Copy All joins in 1e; the lock beside Touch ID items and Notes | Table wait for 1e
  and B9.
- An environment row's context menu (board Main2-Actions): Rename…, Duplicate Environment…,
  Share Securely…, Refresh, Revert Changes (only when there is a change to undo; not on the
  board), | Delete Environment….
- Dark appearance and offline are the same layout (MainDark): only tokens change; offline adds
  `Banner(.offline)` and disables the Sync pill.
- Columns take the window's height: each column of the split view has
  `.frame(minHeight: 0, maxHeight: .infinity)` (`mainColumnHeight()` in MainScreen.swift).
  AppKit sizes the split view from each column's minimum height, which SwiftUI measures at zero
  width, where a wrapped empty-state message is about 1,000 pt tall; the split view then
  outgrew the window and was centered in it, so the sidebar's first rows sat under the traffic
  lights and its footer fell below the window. A column scrolls or centers its own content.
- With two or more rows selected (v0.4.0), the selection's actions sit right of the pill:
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
- The detail fits its narrowest column (`Theme.Layout.detailMinWidth`): the header's buttons and
  ⋯ move under the name, and the selection's actions under the Secrets / Variables pill when a
  row does not fit (`ViewThatFits`); the table scrolls sideways inside its card. Nothing
  spills under the sidebar or past the window edge. `MainWindowLayoutTests` checks both.
- On macOS 26+ the sidebar's rows scroll under the traffic lights and the sidebar button with the
  system's soft scroll-edge effect, as in Finder; at rest they start below the title bar.

- Folders (v0.7.0): one sidebar row per folder (`folder` / `folder.fill` when selected, the
  name in `.caption`, the item count in `monoLabel` subtle), or a quiet "New Folder…" row when
  there is none. A selected folder fills the detail with the place header (the name in
  `.placeTitle`, "Folder · never sent anywhere by itself · counts", Copy To and Share Securely…
  as `.compact` outline buttons, ⋯ More) above the same Secrets / Variables pill and table as a
  repository, without the Status column.
- Organizations (1.0, B5c; mockup Org-Visibility): the organization's own sidebar node.
  Selected, the detail shows the Import prompt (`EmptyStateView`, primary Import) or
  the place header (the login, "Organization · 14 secrets · 6 variables · 3 without value", ⋯
  More with New Secret, New Variable and Remove from Vault…) above a `.fxTable()`: Name (struck through when deleted), Kind, Value
  (`MaskedValueCell`, no eye), Visibility, Status (`StatusDotLabel`), Updated; the row menu
  Copy Value, Edit…, Revert / Revert Access, Delete… (B6b3a). The item editor is a
  `ConfigEditorSheet` (ORGANIZATION, the name or New Secret/Variable): Kind `SegmentedPill` on
  add, `ItemNameField` (or the read-only name), `SecretValueEditor`, `ItemFillChoiceField` for a
  secret without a value, and ACCESS: a `SegmentedPill` All / Private / Selected, the
  visibility's caption, and for Selected one `FXCheckboxRow` per repository.
- Runtime destinations under the selected repository (v0.8.0, canvas "FX Vault Destinations"):
  after the environments, `SectionLabel` RUNTIME with an Experimental `StatusChip.tag`, then one 2-line
  row per destination: the provider symbol in `monoLabel` `mutedText`
  (`destinationSymbolWidth`, so names line up), the name in `.callout` (`.calloutEmphasized`
  when selected; tail-truncated) over "provider · stage" in `.caption` `mutedText`, then the
  value-missing `exclamationmark.triangle` in `warning`, the 6 pt `brand` pending dot and the
  count in `monoLabel` subtle, on `.fxRowBackground(style: .sidebar)`. "Add Destination" is a dashed
  `hairlineStrong` row. A destination's context menu (and the detail's
  ••• menu): Settings…, Export .env…, Remove from FX Vault… (destructive confirmation).
- Destination detail (v0.8.0; board KV-Place): the place header (the name, "Key Vault · 32
  secrets", a runtime destination "Key Vault · Runtime · stage · …" with its Experimental tag;
  Refresh in ⋯ More, disabled offline). A
  `container` card holds STAGE (`.callout`), TARGET (`.monoMeta`) and NAMES AND VALUES (the
  provider's rules in `.caption` `mutedText`), side by side or stacked. The Refresh banner is
  `.info` with Review ("2 changes in Key Vault since your last sync"), `.info` with a checkmark
  when nothing changed, and a `.warning` for items FX Vault cannot use (their names as help).
  Then the same table as a repository with the Status column: Key Vault holds secrets only, so
  a `SectionLabel` "SECRETS · 4" takes the place of the Secrets / Variables `SegmentedPill`. Add
  actions, multi-selection and the linked chip are unchanged.
- After the first unlock on 1.0, the main window shows a one-time alert, "Supabase and Vercel
  Destinations Removed", listing each destination migration v16 deleted (`owner/name · Supabase
  <ref>`); OK clears the list (`RetiredDestinationsNotice`).
- Held rows (v0.9.0, tasks/todo.md P8): a row imported from a share file and not yet included
  in a Sync shows a `.warning` `StatusChip` "Held" in the Status column instead of Will push /
  Added, in repository scopes and destinations alike; its help names the sender's file and says
  how it gets out (Sync's From Files review, or Push on Next Sync, which releases only the hold).

### Sheets (board SyncReview)

- The Sync summary (1.0, D6b, board Sync-Review): no eyebrow, `.leadEmphasized` (15 pt semibold)
  "Review Sync", `.callout` subtitle "Names only · values go through gh and az, never shown".
- One hairline card per place: a repository, each of its environments, a Key Vault, an
  organization. The header is the place's `Theme.Symbols` symbol (a Key Vault's provider symbol),
  its name in `.placeName` (12 pt semibold: `api-service › production`) and its kind in muted
  `.caption`. An environment created, renamed or deleted adds its sentence.
- Lines: `+ ~ −` in a `syncSymbolWidth` column, the name in `.monoMeta`, the detail in muted
  `.caption` (`variable · renamed from OLD_NAME`); a deletion is red; a deployment-branches line has
  no symbol and reads muted. Blocked lines: `!` in ink, `↯` in warning when GitHub changed it,
  the reason below and the fix as an inline link. A blocked change sits in its place's card.
- Footer: "N changes in M places · D deletions · B blocked" in muted `.caption` (N counts what
  runs and what is blocked; an offline notice takes its place); the button says
  "Sync N Changes" with what runs. The write limit sits under the cards.
- New Folder… and Rename… (v0.7.0) are a `ConfigEditorSheet` with one rounded name field and its
  live note (invalid, or "Another folder already has this name").
- A received folder (v0.7.0), in Import Share: a `container` card with
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
  STAGE as a rounded field with a Stages menu (the repository's environments) and its note;
  then VAULT NAME (with a note that FX Vault reaches it through the user's `az login`) and TENANT
  (OPTIONAL) as mono rounded fields. The primary is "Add and Import". Afterwards the fields give way to the import
  result ("4 items imported from the destination.", the ones without a value, the names left as
  they are) with Open Destination.
- A destination's Settings… (v0.8.0) is a `ConfigEditorSheet` with STAGE.
- Destination drift review (v0.8.0) is a `ConfigEditorSheet` titled with the banner's sentence:
  a `ConfigSheetList` with each name in `.monoName`, what happened in the provider as a caption,
  and Keep Mine (outline) / Use Key Vault (secondary) per row; the footer has Close and "Use Key
  Vault for All" (primary). A value the provider does not return says so in the row.
- The Sync sheet (v0.8.0, canvas board 4) shows each destination as one more scope of its
  repository ("Key Vault · kv-example-prod · via Azure CLI sign-in"), its lines as "DATABASE_URL
  as DATABASE-URL" where the provider stores another name, blocked changes as issues with a fix
  (Show Destination).
  Destination deletions join the deletion review; the result shows "Confirmed in the
  destination", "Sent, but the destination did not list it yet…" or "Not sent" per item.
- Share Project (v0.9.0, `ProjectShareScreen`, `shareSheetWidth`, eyebrow SHARE) replaces the
  Share as File sheet for every entry point: File › Share Project… (⌥⌘S; ⇧⌘S is Sync), Share ›
  File… (Vault menu), and Share Securely… on a repository, an environment or a folder.
  Step 1, what to share: REPOSITORIES as removable chips in a
  `FlowLayout` (`Theme.Symbols.repository`, `.monoName`, an `xmark.circle.fill`) with an Add Repository
  borderless menu; STAGES as checkboxes across those repositories, a production stage with a
  `.warning` "Production" chip and its checkbox unchecked (help: "Unchecked by default. Checking it asks for Touch ID."); "Repository-level secrets and variables" as a
  checkbox beside ADJUST WHAT'S INCLUDED; then the scope tree with one root per repository (and
  folders), destinations as nodes with their provider symbol; the summary ("7 secrets and
  variables in 3 repositories") in `.statusLine` `subtleText` and the value-missing names as a
  warning note. Step 2, SEND TO: one `fxCardBackground(.container)` card, "Anyone, with a passphrase" in
  `.bodyEmphasized` with its explanation in `.caption` and a `warning` note naming the production
  places when the file includes production; EXPIRES AFTER as a `SegmentedPill` (1 day / 7 days / 30 days)
  with the honest note in `.caption` `subtleText`. Then Touch ID or the password (`ShareReauthView`) and
  the result: the six words (`PassphraseView`, a `warning` `SheetCallout` "Send these words
  another way…", "I've saved it") with the expiry; Send with AirDrop (primary, `dot.radiowaves.up.forward`, only where this Mac offers AirDrop), Share… (the system picker; primary without AirDrop) and Save… (secondary), the file name in
  `.monoMeta`. The footer: Back (secondary), Cancel, Continue / Create Share File (primary).
- Import Share for a project file (v0.9.0, `ProjectShareImportView`): a passphrase field; "This share file has
  expired" is a failure with its own title. The sender row: a person symbol, "From Ana" in
  `.bodyEmphasized`, `StatusChip` "Not verified" (`.warning`) with its explanation as help, then created and
  expiry dates in `.monoMeta`. One `Card(.container)` lists the repositories: `checkmark.circle.fill`
  `success` "In your vault", `arrow.down.circle` `brand` "Will be imported from GitHub with
  user-a", `xmark.circle` `warning` "Skipped: none of your GitHub accounts can see it" (the name
  muted), counts in `.monoMeta` and a chevron (`brand` when chosen). The chosen repository shows
  today's merge preview, then DESTINATIONS (provider symbol, "Azure Key Vault · kv-example-staging",
  the stage as a chip, `.warning` for production, and "New. FX Vault reaches it with your az
  login." or "Merges into your destination…" as a caption; a 0.9 file's Supabase and Vercel
  destinations as one "Left out: …" note) and FOLDERS (a picker: New folder, Merge keep mine /
  replace mine, Don't import). A note closes it: "Nothing reaches GitHub or a provider until you
  include it in Sync." The content scrolls past `projectShareContentMaxHeight`. After Import,
  `SheetCallout`s list what changed ("1 change waits for you in Sync › From Files" in `brand`),
  and the main window has already moved to the first repository, at the environment of the
  first stage.
- Sync's From Files (v0.9.0, `SyncHeldSharesView`): a `ConfigSheetField` after the summary, its
  explanation as a caption, then one `ConfigSheetList` row per held file: `doc.badge.ellipsis` in
  `warning`, "From Ana's file" in `.bodyEmphasized` with an "Unverified" tag (a file imported under 0.9
  from a verified teammate keeps its "Verified" `.success` chip), "Imported Jan 15, 2027 at 12:00 PM · 2 items" in `.monoMeta`, "Include in this Sync"
  as a checkbox (off), and Show 2 Items / Hide Items expanding the names per repository, scope
  and destination. A single file starts expanded. When only held rows wait, an `.info` `Banner`
  says so and Sync stays disabled until a file is included.
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

- Notch island (1.0 boards NotchUnlock, NotchPassword, NotchNoNotch, NotchUnlocked): the unlock UI
  while locked, a borderless panel above the menu bar (`NotchIslandPanel`), 340 pt wide,
  `island` black with `islandInk` / `islandMuted` text in both appearances, no shadow, lower
  corners 20 pt (all four without a notch, 6 pt under the menu bar). Touch ID row (symbol 24 pt,
  `.headline` "FX Vault is locked", `.caption` "Touch ID to unlock", "Use Password"), password
  pill with the reason or error line and "Recovery Key…", or "Unlocked" for 0.9 s.
- Setup commands (board GitHubSetup): a `CommandRow` for an allowlisted brew command adds an
  `.outline` Run before Copy; under the rows, `CommandOutputView` (`.monoMeta` `mutedText` lines on
  `surface`, 140 pt before it scrolls, newest at the bottom) and a `.caption` line ("Done · brew
  install gh · checked again", or the failure in `danger`).
- Lock window (recovery and the one-time Touch ID offer only; also the lock screen in tests):
  `DotGridBackground` full window; centered column with `BrandMark(size: .brandMarkLarge)`,
  `.display` headline, `.lead` `mutedText` paragraph, a 360 pt form: `SectionLabel` + pill
  `FXTextField` and `.primary` Unlock on one line, `.secondary` full-width Touch ID, then a
  `.statusLine` and a `brand` link.
- Onboarding (1.0 boards Main, Password, RecoveryKey, RecoveryConfirm, TouchID): Welcome is centered
  (`BrandMark(.brandMarkLarge)`, `.display` "FX Vault", `.lead` paragraph, `.primary` Create Vault,
  then the phases "Secure · Connect · Import" and "Encrypted on this Mac"). The Secure phase is one
  column (insets 56 / 64): `OnboardingPhaseHeader` (`.statusLine`, current phase in `ink`, the
  others `subtleText`) with `StepCounter` (`01 / 04`, 3 steps without Touch ID) at the end,
  `.largeTitle`, `.lead` paragraph, rounded `FXTextField`s (460 pt), a `.caption` note, and footer
  `.outline` Back + `.primary` Continue (`.large`). The recovery key's Continue waits for the
  `FXCheckboxRow` "I saved it offline"; that step has no Back (the vault already exists).
- Connect (boards ConnectGitHub, ConnectAzure, FirstImport), same column, a `StepCounter`
  (01 / 02) beside the phase header: a `SectionLabel` per account
  ("user-a · github.com") over callout rows (checkbox, `.bodyEmphasized` login, `.caption`
  "Organization" or "N personal repositories", the org's `StatusChip` at the end); a `.caption`
  "N selected · Secret names only"; `.outline` Not Now + `.primary` Continue. Azure: while `az`
  is missing or signed out, a "Requirements" `SectionLabel`, one `.body` sentence and the
  `SetupCommandList` (Run on `brew install azure-cli`, `az login` Copy only) with `.outline`
  Check Again; then a `SectionLabel` per subscription over callout rows (checkbox,
  `.bodyEmphasized` vault name, `.caption` location), a `.caption` "N vaults selected · Secrets
  with values"; `.outline` Back + Skip, `.primary` Continue. The summary is a `Grid` (Source /
  Secrets / Variables, counts in `.mono`; rows Organizations, Repositories, Azure Key Vault), a
  `.bodyEmphasized` total, a warning `Banner` naming failures, and the "GitHub never returns
  secret values" note.

### Settings

Native `Settings` + `TabView` + `Form`; the window gets `.fxWindowBackground()`. Use
`SectionLabel` for group titles inside custom sections, `StatusChip` for states, and
`.fxButtonStyle(.secondary)` for row actions. Do not restyle native toggles and pickers.

Accounts (1.0, B4): under each account's Scopes row, ORGANIZATIONS lists each organization in
`.mono` with its `StatusChip`: Ready (`success`), Needs admin:org and Needs SSO authorization
(`warning`, the latter with an Open SSO Page link), Org secrets need an org admin and Access
unknown (`mutedText`); then, when one needs admin:org, the `CommandRow`s to run before
Re-check.

Sharing (v0.9.0, tab symbol `paperplane`) has one section, FILES YOU SENT, with its footnote
("Values are never kept here"): one row per export, newest first: the date in `.monoMeta`, an
"Expired" neutral chip or "Expires …", a ••• menu with Remove from List (a confirmation that the
sent file is not affected), the protection ("Passphrase"; a 0.9 row may say "Teammates: …"), the
repositories and stages, and a disclosure "Names in this file · 4 secrets" with a `warning` note
"Rotate these secrets if the file leaked." over the names per place.

### `.env` and sharing (sheet pattern)

These sheets use the sheet chrome components (`SheetHeader`, `.fxSheetContent()`, `SheetCallout`,
`FXCheckboxRow`). `App/Screens/Sharing/ShareSheetComponents.swift` adds only the
`ShareSheetLabel` eyebrows, `ShareNoteView` (inline icon and callout text) and
`SheetProgressRow`; `.shareListContainer()` draws a native `List` as a hairline `card` container.
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
- Passphrase: a `Card` with the six words numbered (`StepCounter.padded`) in SF Mono medium at
  the `title2` size (`Theme.TextStyle.passphraseWord`; the shared `PassphraseView`), Copy as an
  outline pill; screen capture protected.
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
| Sync-Review | `.fxSheetBackground`, `SyncSummaryCardView` (`.fxCardBackground(.container)`), `.leadEmphasized`, `.placeName`, `.monoMeta`, `FXLinkButtonStyle`, `FXButtonStyle(.large)` |
| FX Vault Destinations 3: Key Vault destination | `DestinationDetailScreen`, the RUNTIME rows of `ScopeListView` |
| FX Vault Destinations 4: multi-provider Sync review | `DestinationSyncPresentation` sections in the Sync sheet |

## Known limits

- System sheets keep the system corner radius and shadow; the 24 pt sheet look applies to
  `Card(.sheet)` dialogs drawn in the window.
- Native `Table` column headers take a styled `Text` (`ConfigTableView.header(_:)`: 12 pt
  medium, sentence case); the header row's own chrome stays native: it draws vertical column separators, and
  its divider spans the card while row separators are inset (the Main board has neither). Hiding
  the native header for an `FXTableHeaderRow` would need fixed column widths (SwiftUI does not
  expose the live, user-resizable widths), which would leave the table short of the column on
  wide windows, so the native header stays.
- The drift line (a banner before 1.0) is `mutedText`, `warning` when a change on GitHub also
  changed in the vault (a decision is needed; nothing failed). `DriftBannerView` is the only
  implementation.
- On macOS 26+ the toolbar draws shared glass behind items unless hidden per item.
- The toolbar proposes no width to its items, so the title is a fixed-width item
  (`toolbarTitleWidth`) and picks the longest path that fits it; a path longer than that keeps its
  last two steps.
- Tracking is not part of `Font`; text styled with a bare `Theme.Typography` font has no tracking.
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
window captures (9 screens × 2 appearances = 18 files; v0.7.0 adds `main-folder`,
`main-folder-variables`, `main-sidebar-folders`, `folder-destination` and
`folder-destination-new`; v0.8.0 adds `main-destination-keyvault` and `add-destination`, over
`MainSnapshotFixture.destinations` (`kv-example-prod` and `kv-example-web`).
v0.9.0 adds two suites gated the same way (pass `-only-testing:AppTests/ProjectShareSnapshotTests`
and `-only-testing:AppTests/HeldShareSnapshotTests`): `project-share-contents`,
`project-share-contents-three`, `project-share-production-blocked`,
`project-share-send-to-passphrase`, `project-share-passphrase`, `project-share-open`,
`project-share-expired` and `settings-sharing`; `sync-held-one`, `sync-held-two`,
`sync-held-only` and `main-held`. 1.0 removed the presence, teammates, pairing, shared-space
and Nearby Chat renders with those screens; D6c2 adds `main-home` (nothing selected, with the
recovery-key banner) and `main-jump` (the ⌘K palette). The toolbar's glass items and the
sidebar draw blank in these captures: `JumpPaletteUITests` (light) and `MainTreeUITests` (dark)
attach screenshots of the running window instead.
The offscreen window capture leaves the repository sidebar blank or black in some captures; the
running app draws it normally. SwiftUI `ImageRenderer` is not used: it
cannot draw AppKit-backed views (`ScrollView`, `List`, `Table`, text fields, toggles, the split
view), which came out blank or as placeholders. A window capture cannot draw the macOS 26+ glass
sidebar, so the sidebar also has its own snapshot (`main-sidebar`).
