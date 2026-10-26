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
- Keep it native macOS: `Table`, the `Settings` scene, system sheets and the window's own
  traffic lights stay; this language restyles them, it does not rebuild their behavior. The main
  window lays out its own glass panels instead of `NavigationSplitView` (D6c2b, "Main window").

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
| `panelShadow` | PanelShadow | black 8% | black 40% | Under the main window's glass panels |
| `mainGround` | MainGround | `#F8F7F6` | `#121214` | The main window's soft ground (`MainWindowGround`) |
| `mainGlowTopLeading` | MainGlowTopLeading | `#FFFFFF` | `#212124` | The ground's glow from the top leading corner |
| `mainGlowTopTrailing` | MainGlowTopTrailing | `#EBE9E6` | `#1B1B1F` | … from the top trailing corner |
| `mainGlowBottomTrailing` | MainGlowBottomTrailing | `#E6E5E3` | `#1B1A1A` | … from the bottom trailing corner |
| `mainGlowBottomLeading` | MainGlowBottomLeading | `#F3EFEB` | `#1B1A1A` | … from the bottom leading corner |

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
  ⌘K palette), `panel` 14 (the main window's sidebar and toolbar panels), `control` 12 (inputs,
  banners, checkbox rows), `row` 10 (scopes, the recovery-key strip), `compactRow` 8 (sidebar).
  Pills (buttons, chips, segmented control, pill inputs, badges) use the `.pill` shape
  (`Capsule(style: .circular)`, Radius.swift). The macOS 27 SDK's `Capsule()` defaults to
  `.continuous` corners, whose flatter ends read as short straight edges at pill sizes;
  `scripts/lint.sh` rejects `Capsule()`.
- **Lines** (`Theme.Stroke.hairline` = 1 pt): `hairline` by default, `hairlineStrong` for
  controls. Dashed rows ("Add Destination") use `Theme.Stroke.dashPattern` (4 / 4). Focus rings are 2 pt `brand`, 2 pt outside the shape (`Theme.Layout.focusRing*`).
- **Shadow** (`Theme.Shadow`): `Card(.sheet)` and the ⌘K palette (`.popover`): `shadow` color,
  radius 32, y 24; the main window's glass panels (`.fxGlassPanel()`): `panelShadow`, radius 12
  (the board's CSS blur 24), y 8.
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
| `.outlineDestructive` | `hairlineStrong` border, `danger` text | A deletion confirm in a 1.0 dialog ("Delete 1", board Sync-Delete) |

Sizes: `.regular` 34 pt / 13 pt text (inline, sheets), `.large` 42 pt / 14 pt (sheet
footers, onboarding, lock), `.compact` 26 pt / 12 pt with 8 pt corners instead of the capsule (a
place header's buttons), `.dialog` 32 pt / 13 pt (the 1.0 dialogs, boards Sync-Review,
Sync-Delete, NewRepo, Share-*: the primary stays an ink pill, every other variant has the 8 pt
`compactRow` corners, as the boards draw Cancel). `FXButtonStyle.shape(for:variant:)` is the one
place that picks the shape. `.fxIconButtonStyle(size: .compact)` is the matching 26 pt square, the
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
for forms; `.dialog` is the 1.0 dialog forms' field (boards NewRepo, NewEnvironment): 28 pt, 7 pt
`Radius.field` corners, mono at 12 pt, an `ink` hairline while focused (`DialogFieldChrome`, the
same box as the dialog pop-ups). Names and keys
use `isMonospaced: true`.

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
`size: .small` is the 1.0 dialogs' control (boards NewRepo, NewEnvironment, Share-Pick): 22 pt
segments with 6 pt `Radius.token` corners on an 8 pt track, 12 pt ink text, medium when chosen.

### `Banner`

```swift
Banner(.offline, message: ConnectivityBannerModel.offline.message)
Banner(.info, message: driftText, action: .init(title: reviewTitle) { viewModel.reviewDifferences() })
Banner(.warning, message: text, label: "Experimental")
```

12 pt corners in the content column (not edge to edge). `.info`: `card` + hairline + brand dot;
`.warning`: `card` + `hairlineStrong` + warning symbol (a read-only scope, the recovery-key
notice); `.offline`: `surface2` + `hairlineStrong` + `wifi.slash` + the `OFFLINE` mono label (the
only `surface2` banner, so it reads apart from the others); `.danger`: `card` + `hairlineStrong` + danger
symbol. The action is an emphasized `FXLinkButtonStyle` link (brand on `card` is 5.49:1 light;
pointer cursor, 40% when disabled).

### `BrandMark`, `DotGridBackground`, `StepCounter`

```swift
BrandMark(size: Theme.Layout.brandMarkLarge)                      // 44 pt ink
BrandMark(size: Theme.Layout.brandMarkLarge, center: .outlined)   // 44 pt, brand outlined center
LockContent().background(DotGridBackground())
StepCounter(current: 2, total: 5)                                 // "02 / 05"
```

### `SyncToolbarButton`

```swift
SyncToolbarButton(count: viewModel.pendingChangeCount, isSyncing: viewModel.isSyncing,
                  isEnabled: viewModel.canSync, unavailableReason: offlineHelp) { viewModel.sync() }
```

A `.toolbar` ink pill (28 pt, 12 pt medium; board Main2-Home): the sync symbol, "Sync" and the
count in a 16 pt mono `inkBadge` capsule (`monoLabel`), 12 pt before and 6 pt after it; a spinner
while syncing; 40% when disabled. `SyncToolbarButton.title(count:)` ("Sync 5") stays the menu
title. It sits in the toolbar panel, not in a system toolbar.

### `.fxGlassPanel()`, `MainWindowGround`

```swift
SidebarView(main: main).fxGlassPanel()                 // 14 pt corners
RecoveryKeyStrip(main: main).fxGlassPanel(radius: Theme.Radius.row)
panels.background(MainWindowGround())
```

The main window's floating panels: `glassEffect(.regular)` in a continuous rounded rectangle, a
`hairline` border and the `panelShadow`. `MainWindowGround` is `mainGround` with a radial glow from
each corner (`mainGlow*`, `groundGlowRadius`); only the main window uses it.

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
- `FXCheckboxRow(isBoxed: false)`: the checkbox alone on the sheet (the 1.0 dialogs).

The 1.0 dialogs (D6d, `DialogChrome.swift`): `Theme.Layout.dialogInset` (22 pt) around the
content, no eyebrow, `SheetHeader` with `.leadEmphasized` (15 pt semibold) and a `.callout`
subtitle 4 pt below, cards as `.fxCardBackground(.dialog)` (`card` glass, hairline, 10 pt `row` corners,
10 pt apart), what a confirmation is about in `.fxDialogListBox()` (`surface`, 10 pt corners,
24 pt rows), and the footer row without a rule (`ConfigSheetFooter(inset: SheetFooterInset.dialog)`)
with `.dialog` buttons.

Dialog forms (`DialogForm.swift`, boards NewRepo, NewEnvironment): `DialogSheet(title:footerNote:)`
puts `SheetHeader.dialog` and the rows 14 pt apart over the footer. `DialogFormRow(label)` is the
150 pt column of 11 pt medium muted labels (`.formLabel`, 7 pt down), 14 pt from the controls;
`ConfigEditorNoteView(style: .dialog)` the 11 pt note 5 pt under them (`.formNote`; muted,
warning, or danger with its icon so an error does not rely on color alone; a confirmation stays
muted). Controls share one 28 pt box, `DialogFieldChrome` (`card`, `hairlineStrong`, faded once
when disabled): `.fxInputField(.dialog)`, `DialogPopUp` (a menu with a check beside the chosen
option, drawn by `DialogFieldButtonStyle` with chevrons; `display` can differ from the option
title, ".gitignore: None"), `.dialogFieldChrome()` alone for a value without a menu (the SSH
alias); `DialogSwitch` (a mini switch before its title; the title toggles it unless disabled),
`DialogTokenChip` (`production ×`, 22 pt, 6 pt corners, mono) and the dashed `DialogAddChip`
(its face, `DialogAddChipLabel`, also labels an add menu), laid out in a `FlowLayout`;
`StatusChip.dialogTag` (`production`, 18 pt, 6 pt corners, an ink hairline, 11 pt medium) beside
a name in a dialog list; its `.quiet` tone (muted on `hairlineStrong`, 11 pt regular) with an
optional symbol is a linked row's tag. A dialog's body sentence is `DialogSentence` (13 pt
`mutedText`, wrapped). Small actions in a row are `.compact` buttons (Add Rule, Try Again).

`PassphraseView` (App/Components) is the generated passphrase card of onboarding; `EmptyStateView` uses the light symbol, a `.headline` ink title and a `mutedText`
`.callout` message.

### `.fxWindowBackground()`

Applied once per scene in `FXVaultApp` (main window, Settings): `ground` behind the
content and as the `NSWindow` background, SF Pro 13 as the default font, `brand` tint. It sets no
foreground color, so `.primary` text still turns white on selected rows.

## Screen patterns

### Main window (boards Main2-Home, Main2-Repository; two columns since 1.0, B11b)

- Chrome (1.0 D6c2b; boards Main2-Home, Main2-Dark): no title bar of its own. The scene is
  `.windowStyle(.hiddenTitleBar)`; `MainScreen` lays out `.fxGlassPanel()`s on
  `MainWindowGround`, `mainPanelInset` (8) from the window's edges and from each other, from the
  window's very top: the sidebar panel (`sidebarWidth` 264, its content `sidebarPanelTopInset`
  44 down), and beside it the toolbar panel (`toolbarPanelHeight` 44), the recovery-key strip
  and the detail. Dragging the gutter after the sidebar resizes it between `sidebarMinWidth`
  (240) and `sidebarMaxWidth` (400), saved per Mac user when the drag ends
  (`PreferencesManager.sidebarWidth`); the
  screen's minimum is `mainScreenMinWidth` (the widest sidebar beside `detailMinWidth`) with the
  sidebar hidden too. The other gutters, the sidebar's top band and the toolbar panel's empty
  part are title bar (`WindowDragArea`; not the path text, which keeps its tooltip, nor the
  detail, which takes its own clicks): they move the window, a double-click zooms or
  minimizes as System Settings says, and they take the first click in an inactive window (the
  toolbar's buttons don't). While it shows, `MainWindowTitleBar` hides the title, makes the title bar
  transparent and gives the window an empty unified toolbar, so AppKit itself puts the traffic
  lights 19 pt in, inside the sidebar panel, and keeps them there on resize, in full screen and
  on hover; leaving the main screen (the lock) restores the title bar. View › Hide Sidebar
  (⌃⌘S) is our own command (`MainViewModel.toggleSidebar()`): the sidebar panel slides out and
  the toolbar panel starts `trafficLightsWidth` (80) in, after the lights (not in full screen,
  which hides them); Edit › Find brings it back. Two main screens may overlap while SwiftUI
  swaps them: the title bar is counted per window, and the last one out restores it.
  Why (decision, 2026-10-26): on macOS 27 (26A428) `NavigationSplitView`, and an AppKit sidebar
  split item alike, draw the sidebar's glass full height with square corners, so the boards'
  floating sidebar cannot be had from the split view. Moving the traffic-light buttons by hand
  (the Electron way) lasts only until AppKit's next title-bar layout (every resize) and leaves
  their hover area behind; the empty toolbar gets the boards' place (19 vs 20 pt) natively.
- Toolbar panel (1.0 D6c2, D6c2b; boards Main2-Home, Main2-Repository, Main2-Search):
  `MainToolbarPanel` (`MainToolbar.swift`), no native toolbar items. The selected place's path
  (`MainViewModel.breadcrumb`) in sans `.callout`: the steps `mutedText`, the separators
  `faintText`, the last step `.calloutEmphasized` ink (`GitHub › owner › repo › environment`,
  `Azure › subscription › vault` or `Folders › name`), or "FX Vault" in `mutedText` with nothing selected, then
  the DEV chip in Debug builds. It takes the panel's free width; a long path drops its first
  steps down to the last one, then shows the app name. Then the search button (`magnifyingglass`
  + `KeyHint("⌘K")`, `.ghost` `.compact`) and `SyncToolbarButton`. 16 pt before the path, 8 pt
  after Sync. The panel's empty part is title bar (`WindowDragArea`, above). New
  Repository, Import .env and Share are menu commands only (⌘N, also on an owner's menu; ⇧⌘I;
  ⌥⌘S).
- Sidebar (1.0, D6c1; boards Main2-Home, Main2-Expanded, Main2-Repository, Main2-Dark): the
  sidebar panel (above). On top the search field
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
- Azure › subscription › vault (1.0 D6c6, board Main2-Repository): the vaults without a saved
  subscription first, directly under Azure (`key`, level 0), then one row per subscription by
  name (`cloud`, sans title, chevron; open by default, while searching and when one of its vaults
  is selected) with its vaults at level 1 (context menu and the detail's Actions: Remove from FX
  Vault…). Departures: a vault saved before 1.0 stays directly under Azure until its Refresh
  finds the subscription; no "Needs Key Vault Secrets User" subline under a vault row (a vault FX
  Vault can't read says so when it is read). The bottom of the sidebar holds
  the listing state or the last notice in `.label`, then Lock and Settings as quiet icons.
- Home (nothing selected; board Main2-Home): `EmptyStateView` with `square.3.layers.3d`, "Choose
  a place", the pending changes ("4 pending changes", or "No pending changes") and
  `KeyHint("⌘K")` + "to jump anywhere".
- Recovery key (never confirmed as saved; board Main2-Home): a glass strip under the toolbar
  panel, over every place (`bannerStripHeight` 36, `row` corners, 14 / 6 pt sides): `key`, "Your
  recovery key wasn't saved" in `.calloutEmphasized` ink, then Create New Key… (`.secondary`
  `.compact`; Settings › Security on the new-key sheet). The key shown at onboarding cannot be
  shown again, so the board's "Show Key" is not offered.
- Jump palette (⌘K, Edit › Jump Anywhere or the toolbar's search button; board Main2-Search):
  over the window on `scrim` (a click outside closes it), `jumpPaletteWidth` wide under the
  toolbar, `.fxCardBackground(.popover)` (the `card` fill over `.regularMaterial`, so the text
  under it blurs instead of showing through). The field (`.headline`, `jumpPaletteFieldHeight`,
  focused through `FocusRetry`: a focus set while the overlay is inserted is dropped), a
  divider, "Places" (`SidebarSectionHeader`) with rows up to `jumpPaletteListMaxHeight`, then it
  scrolls: `.fxRowBackground(style: .palette)` (34 pt), the place's symbol, its name in its
  sidebar style with the first typed word in the emphasized weight, the detail ("Folder",
  "owner › repository") in `.caption` subtle, `KeyHint("↩")` on the selected row. A divider and
  the footer keys: ↑ ↓ to move, ↩ to open, esc to close (`onEscapeKey`, a key-down monitor on
  the window: the field's editor eats esc before SwiftUI sees it). Every typed word must be in the name or
  the owner and repository; names that start with a word come first, then names that contain
  one, then path matches. Then "Secrets by name" (1.0 D6c5) once something is typed: secrets and
  variables whose name holds every word (a repository's own destinations left out before the
  limit), up to 50, a name that starts with one first; the kind's
  symbol (key, text), the mono name, where it is ("owner › repository › environment",
  "Folder · name", "Azure Key Vault · vault", "example-org · Organization"). ↑↓ cross both
  sections; ↩ opens the place with the row selected. "Names only" closes the footer.
  Departures: variables join the section (the board shows secrets); an organization name has no
  "· 3 repos".
- Detail (no background of its own: the window's `ground` shows; `.fxPlaceColumn()`: insets
  28 sides / 20 top and bottom, 14 between blocks, `Spacing.mediumPlus`): `Banner`s first; then
  the place header (1.0 D6c3, `PlaceHeader`; boards Main2-Repository, Place-Table): the name in
  `.monoPlaceTitle` (`.placeTitle` for a folder), "kind · parent · counts" in `.caption`
  `subtleText` (`PlaceCopy.subline`: `Environment · api-service · 6 secrets · 2 variables · 1
  without value`; the repository scope adds its visibility and "created by the next Sync"; a Key
  Vault "Key Vault · 32 secrets"; a folder "Folder · never sent anywhere by itself · …"), then a
  status line: Refreshing… with a mini spinner while Refresh runs (`PlaceRefreshingLine`), the
  drift line (`DriftBannerView`: a 7 pt ink ring, "2 changed on GitHub" in `mutedText` (with
  "· 1 also changed in your vault" on a conflict, still muted), "·", Review in `ink`
  `captionEmphasized` with a `hairlineStrong` underline) or why the check failed. On the right, bottom-aligned: the place's own
  `.compact` outline buttons (a folder's Copy To and Share Securely…; Copy All with the `touchid`
  glyph on a repository scope, a Key Vault and an organization, `CopyAllButton`) and ⋯ More. The
  `SegmentedPill` (Secrets / Variables) with the selection's actions; the table with
  `.fxTable()`.
- Inherited organization items (1.0, B7a; board Place-Table): when the repository's
  organization is in the vault, each tab lists after its own rows the organization's items that
  reach the repository (all → every repository, private → private and internal ones, selected →
  the ones in the list FX Vault knows) and nothing here overrides: the name in `mutedText` over
  "example-org · all repos" (`OrgVisibility.reachTitle`) in `.caption`, the value masked (a
  variable's in plaintext), Updated from GitHub, and Status "Inherited" in `mutedText`. They
  have no menu, no edit and no actions. The repository's (or the environment's) own item of the
  same name shows "· Overrides example-org" in `mutedText` after its status; in an environment
  the repository level's names also keep the organization's out.
- ⋯ More (board Main2-Actions), what each place offers, disabled when the account may not:
  New Secret, New Variable | Paste Multiple…, Import .env…, Export .env…, Copy All | Copy To
  (the selection, or the open tab when nothing is selected), Share Securely… | Deployment
  Branches… (an environment; its help says the policy and the plan note), Clone…, Refresh |
  Delete Selected…. An organization: New Secret, New Variable | Copy All | Remove from Vault….
  A Key Vault: New Secret | Paste Multiple…, Import .env…, Copy All | Copy To, Refresh | Delete
  Selected… | its own menu. A folder: the item actions with Copy All, then its own menu
  (Rename…, Share Securely…, Export .env…, Delete Folder…). The item actions are one section
  (`PlaceItemMoreItems`); Delete Selected… needs a selected row that is not already a pending
  deletion (`canDeleteSelection`); Copy All needs a live item (`canCopyAll`). A SwiftUI menu
  item has no trailing lock glyph, so Copy All's help says it asks for Touch ID or your master password; Notes | Table
  waits for B9.
- Copy All (1.0 D6c4, `CopyAllScreen`): "Confirm it's you" (`ReauthView`, Touch ID tried at once,
  then the master password), then "Copied" with the count and the clipboard's clear delay. The
  text is the board's notes: `# Secrets · N`, `KEY=value` lines by name, a blank line,
  `# Variables · N`; a secret without a value is `KEY=`, a pending deletion is left out, an empty
  kind has no section.
- Delete… and Delete Selected… (boards Main2-Delete, Main2-DeleteKeyVault): `DeleteItemsSheet`,
  a 440 pt `DialogSheet` titled "Delete 2 secrets from api-service › production?" (secrets,
  variables or items; the place as the toolbar names it), the names in `.fxDialogListBox()`
  (`.monoMeta`; each says "secret" or "variable" when both are listed; it scrolls past
  `dialogListMaxHeight`), then `DialogSentence` notes: what the next Sync does on GitHub or in Key Vault
  ("which asks again"), the ones never synced removed now, and "GitHub can’t undo this" when one is
  on GitHub (with "FX Vault has no copy of secrets without a value" when such a secret is there) or "Key Vault
  keeps deleted secrets recoverable for up to 90 days" (and "Their linked copies elsewhere stay"
  when one is linked); a folder says its items go now. Cancel
  outlined (Esc) and the red `.destructive` Delete; Return does nothing.
- An environment row's context menu (board Main2-Actions): Rename…, Duplicate Environment…,
  Share Securely…, Refresh, Revert Changes (only when there is a change to undo; not on the
  board), | Delete Environment….
- Dark appearance and offline are the same layout (MainDark): only tokens change; offline adds
  `Banner(.offline)` and disables the Sync pill.
- Columns take the window's height: the sidebar panel and the detail have
  `.frame(minHeight: 0, maxHeight: .infinity)` (`mainColumnHeight()` in MainScreen.swift).
  SwiftUI measures a column's minimum height at zero width, where a wrapped empty-state message
  is about 1,000 pt tall; as a minimum it grew the window (the split view before D6c2b outgrew
  it and was centered, the sidebar's first rows under the traffic lights). A column scrolls or
  centers its own content.
- With two or more rows selected (v0.4.0), the selection's actions sit right of the pill:
  "N selected" in `.monoMeta` `mutedText`, Copy To (an outline pill menu with a chevron), Push on
  Next Sync and Revert as outline pills when some rows allow them, Delete… as an outline pill
  (the destructive style stays for the dialog's final confirm), and Deselect as an outline
  circle.
- Linked copies (v0.4.1; 1.0 board Folder-View): a linked row shows `LinkedChip` after its
  name, a `StatusChip.dialogTag(_:systemImage:tone: .quiet)`: the `link` symbol and "3 places"
  in `mutedText` on a `hairlineStrong` outline. Its
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
  More with New Secret, New Variable, Copy All, Refresh and Remove from Vault…) above a `.fxTable()`: Name (struck through when deleted), Kind, Value
  (`MaskedValueCell`, no eye), Visibility as its reach ("all repos", "private and internal",
  "selected · 3 repos"; board Org-UsedBy), Status (`StatusDotLabel`), Updated; the row menu
  Copy Value, Edit…, Revert / Revert Access, Delete… (B6b3a). The item editor is a
  `ConfigEditorSheet` (ORGANIZATION, the name or New Secret/Variable): Kind `SegmentedPill` on
  add, `ItemNameField` (or the read-only name), `SecretValueEditor`, `ItemFillChoiceField` for a
  secret without a value, and ACCESS: a `SegmentedPill` All / Private / Selected, the
  visibility's caption, and for Selected one `FXCheckboxRow` per repository.
- Organization Refresh (1.0, B7b; no board, the repository's and Key Vault's pattern): Refresh
  in ⋯ More (after Copy All) lists the organization again. The status line says Refreshing…,
  then "Nothing changed on GitHub" in `mutedText` or the drift line ("2 changed on GitHub · 1
  also changed in your vault · Review", `DriftBannerView`). A row whose date, visibility or
  repository count differs on GitHub, or that GitHub deleted or also added, says "○ Changed on
  GitHub" (`RingDot`, `ink`) in Status, its own status as help. Review opens `OrgDriftScreen`:
  the drift review's size and `DriftFindingRow`s (ORGANIZATION, "Secret NPM_TOKEN was changed
  on GitHub on Oct 20", Keep Local / Accept GitHub with what each does), Done in the footer,
  and the "Delete … from your vault?" confirmation before taking GitHub's deletion. Accept GitHub
  of a changed secret leaves it without a value (no fill step, unlike a repository's).
- Runtime destinations under the selected repository (v0.8.0, canvas "FX Vault Destinations"):
  after the environments, `SectionLabel` RUNTIME with an Experimental `StatusChip.tag`, then one 2-line
  row per destination: the provider symbol in `monoLabel` `mutedText`
  (`destinationSymbolWidth`, so names line up), the name in `.callout` (`.calloutEmphasized`
  when selected; tail-truncated) over "provider · stage" in `.caption` `mutedText`, then the
  value-missing `exclamationmark.triangle` in `warning`, the 6 pt `brand` pending dot and the
  count in `monoLabel` subtle, on `.fxRowBackground(style: .sidebar)`. "Add Destination" is a dashed
  `hairlineStrong` row. A destination's context menu (and the detail's
  ••• menu): Settings…, Export .env…, Remove from FX Vault… (destructive confirmation).
- Destination detail (v0.8.0; 1.0 boards KV-Place, KV-NameRules): the place header (the name,
  "Key Vault · 32 secrets", a runtime destination "Key Vault · Runtime · stage · …" with its
  Experimental tag; Refresh in ⋯ More, disabled offline). After a Refresh the header's status
  line says "No changes since your last sync" in `mutedText`, or "2 changed in Key Vault" with
  Review (`DriftBannerView`). There is no info card: the stage is in the subline and the target
  in Settings. Under the table, `DestinationFootnotes` in `.caption` `subtleText`: one `lock` line
  per kind of secret FX Vault leaves alone ("1 disabled secret is hidden · not editable", their
  names as help; a name FX Vault can't use gets a `warning` triangle, since it never syncs), then
  the provider's rules ("Key Vault names use dashes: …").
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
- Every step is a 1.0 dialog (D6d): 600 pt, 22 pt inset, no eyebrow, `.fxCardBackground(.dialog)` cards,
  `.dialog` footer buttons (Cancel and Back outlined, the default an ink pill, the deletion
  confirm `.outlineDestructive`).
- The deletion check (board Sync-Delete): "Delete 1 secret?" (secrets, variables or items),
  "Confirm before Sync starts. Deletions run after every write.", the deletions in
  `.fxDialogListBox()` (`STRIPE_KEY` in `.monoMeta`, its place muted; an environment with its
  symbol, its repository muted, and what GitHub holds in it below, "not in your vault: will be lost" in `danger`), the
  workflow notes, then "I understand this cannot be undone" as a plain checkbox. Buttons: Back,
  Sync Without Deleting, "Delete N".
- The run (board Sync-Progress): "Syncing" / "Keep FX Vault open until it finishes", a 4 pt ink
  bar on a `hairline` track across the sheet, "Writing 5 of 8 · FX Vault writes 60 a minute ·
  Locking stops after the current write." in muted `.caption`, then the summary's cards
  (`SyncProgressPresentation`) whose symbol column shows each line's state: a 7 pt
  `hairlineStrong` `RingDot` waiting, a mini spinner writing, a `success` check done, a `danger` cross
  failed, a dash not run (blocked lines read `blocked · reason`, muted). The deletions leave
  their cards for a last "Deletions · after every write" card with each place as the
  detail. The footer has Cancel After Current.
- The finish (board Sync-Done) when nothing failed, stopped or waits for a clone
  (`SyncViewModel.done`): 420 pt, centered, a 44 pt `success` `RingDot` with a check, "Synced 8
  changes" in `.leadEmphasized`, "in A, B and C" in subtle `.caption`, up to three pending lines
  (an ink `RingDot`, the change and its reason, "and N more pending"), warnings, and Done as the `.dialog` ink pill.
  Anything else keeps the full result (sections, fixes, clones).
- New Repository (D6d, board NewRepo, 620 × 640, `CreateRepoFormView`): a dialog form. Create
  with (only with two accounts) and Owner as mono pop-ups (the menu says Personal or
  Organization), Name (mono field; "Probably available · GitHub confirms it at Sync", taken or
  invalid in `danger`, Use name… as a `.compact` button), Description, Visibility as a `.small`
  segmented control, Contents (Add README switch, ".gitignore: None" and "License: None"
  pop-ups side by side), Environments to create as chips (the name opens its editor, the help
  says its branch policy) with a dashed Add, Secrets and variables (not on the board: the staged
  items in the grey list box, "secret · production" and the mask, Add Secret… / Add Variable…
  ask for the scope once there are environments), Clone (switch, the account's SSH alias and
  the folder as two boxes, "Optional · SSH alias and folder"). Footer: "Created on GitHub at the
  next Sync.", Cancel, Stage Repository. After it, the staged dialog (title "billing-service is
  ready to sync", a card with the counts, Sync Now… and Done).
- New Environment (D6d, board NewEnvironment, 580 pt): "New Environment in api-service", Name
  (mono field, "Not used in api-service yet"), Deployment branches (`BranchPolicyEditorView`:
  the radio group; for selected branches and tags a grey box with each rule as a chip
  `release/* · branch ×`, the type as a `.small` segmented control, the pattern field and Add
  Rule, the fnmatch note), the plan note with Learn more. Footer as New Repository with Stage
  Environment. Environment Settings and the New Repository's nested environment editor show the
  same editor under their "Deployment Branches and Tags" label.
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
- The item editor's "Linked copies" field (v0.4.1; 1.0 board Folder-LinkedUpdate) appears under
  the value once a new value is typed: `LinkedUpdateList`, a hairline box of 34 pt rows (a
  checkbox, the place's path "owner › repo › environment" in `.monoMeta`, then " · NAME" for a
  renamed copy, and "● Same value" /
  "○ Differs" / "Value missing"; a copy that can't take the value has no checkbox, a subtle path
  and "can’t update · read only"), then an info note.
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
- Share Securely (v0.9.0; D6d, boards Share-Pick and Share-Passphrase, `ProjectShareScreen`) is
  one `DialogSheet` for every entry point: File › Share Project… (⌥⌘S; ⇧⌘S is Sync), Share ›
  File… (Vault menu), and Share Securely… on a repository, an environment or a folder.
  Share-Pick (600 pt): "Share api-service securely" ("Share Securely" for several places), "An
  encrypted file, opened with a passphrase you send another way."; Repositories as
  `DialogTokenChip`s with an Add Repository menu on the dashed chip; Stages as checkboxes across
  those repositories (Repository level first; a production stage unchecked with its
  `StatusChip.dialogTag` and a lock whose help says ticking asks for Touch ID) over the stages
  note; then the tree: a `.dialog` card of 28 pt rows with hairlines between them, 18 pt a
  level, a 10 pt chevron column, a tri-state checkbox, the symbol, the name in `.monoMeta`
  ("Repository" in `.caption`), the tag and lock of a production environment or of a
  destination at a production stage (the lock reads its help to VoiceOver), "Name only" or
  "Selected items only" as a note, and the counts in 11 pt mono ("2 secrets · 1 variable"; a
  kind with none is left out; a folder row counts the folder); up to `shareListHeight`, then it
  scrolls. Under it, dialog notes: "Production values leave this Mac
  in a file (api-service · production). Rotate them if it leaks." and the value-missing names;
  "Expires after" as a `.formLabel` with the `.small` `SegmentedPill` at the trailing edge. The
  footer: the file's counts, Cancel (outline) and "Create File with Touch ID" (primary, `touchid`;
  "Create File" without Touch ID). Touch ID or the password (`ReauthView`: "Confirm it's
  you" in `.headline`, the password as a dialog form row with Continue, Use Touch ID outline)
  keeps the title; its footer is Back and Cancel. Share-Passphrase (680 pt): "Send the
  passphrase another way"; the file (`doc`, the name in `.monoMeta`, "· 18 secrets · 7
  variables"); the six words on one line in 17 pt mono in a `surface` box with 10 pt corners and
  a `.compact` Copy (hidden from screen capture); "The clipboard clears in 30 s." (or the last
  notice: copied, saved, sent); "Send the file by chat or AirDrop, and the words by call or
  another app."; "I've saved it". The footer: "FX Vault refuses it after 1 Nov, 14:02. Rotate anything
  in it if it leaks.", Save File…, Send with AirDrop (only where this Mac offers it), Share…
  (outline, enabled once saved) and Done (primary).
- Opening a file (D6d, boards Share-Open, Share-OpenPreview, Share-Expired, `ShareImportScreen`)
  is a `DialogSheet` titled "Open FX Vault share 25 Oct.fxvault". Share-Open (440 pt): "6-word
  passphrase" as a `.formLabel` over one `.dialog` mono secure field ("six words separated by
  spaces"), the word count and a wrong passphrase as dialog notes; Cancel and Open. A file that
  cannot be opened (Share-Expired, 360 pt) is its own small dialog: a 26 pt symbol (a clock when
  it expired), "This file expired", "FX Vault won't import it. Ask the sender for a new file.",
  the file name in `.monoMeta`, a centred OK. Share-OpenPreview (620 pt, `ProjectShareImportView`):
  "Unlocked · created 25 Oct, 14:02 · expires 1 Nov, 14:02" under the title; "From Ana" with a
  "Not verified" `StatusChip.dialogTag` (its explanation as help); "What it adds · nothing is deleted" over a `.dialog` card
  of 32 pt rows: the repository symbol, the name in `.monoMeta` and its owner muted, then a
  `success` dot "Already in your vault · 3 secrets", an ink `RingDot` "New repository · import
  from GitHub with user-a" or a `hairlineStrong` dot "Skipped · no access" (muted); a row is
  selected (`surface`) to show today's merge preview of that repository, then DESTINATIONS
  (provider symbol, "Azure Key Vault · kv-example-staging", the stage in `.monoMeta` with the
  production tag when it is one, and "New. FX Vault reaches it with your az login." or "Merges into your
  destination…" as a caption; a 0.9 file's Supabase and Vercel destinations as one "Left out: …"
  note) and Folders (a `.dialog` card of rows with a `DialogPopUp`: New folder, Merge keep mine /
  replace mine, Don't import). The footer: "Nothing reaches GitHub or Azure until you include it
  in Sync.", Cancel and Import as Held. The dialogs grow with their content up to
  `shareSheetMaxHeight`, then scroll. After Import,
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

Boards Settings-*: the native `Settings` scene and `TabView` (toolbar tabs: `gearshape`, `lock`,
`person`, `square.and.arrow.up`, `slider.horizontal.3`), 640 pt wide, at least 430 pt of content;
the window gets `.fxWindowBackground()`. `PreferencesLayout.swift` draws the tabs:

- `PreferencesPage`: 16/22 pt inset, groups 14 pt apart.
- `PreferencesSection`: an optional `.groupTitle` (11 pt semibold, `subtleText`, sentence case:
  "Lock", "GitHub CLI"), the rows in a `.fxCardBackground(.dialog)` card split by hairlines, an
  optional `PreferencesFootnote` (11 pt `subtleText`).
- `PreferencesRow`: 7/12 pt inset, a 13 pt label with an optional 11 pt detail, then its controls:
  `.compact` outline buttons (`.outlineDestructive` for Reset Vault…), a mini switch, a
  `DialogPopUp` 96 pt wide, a `PreferencesValue` (12 pt `mutedText`, mono for paths).
- `PreferencesStatus`: a state's mark and 12 pt title: a `success` dot (Ready, Active, Token
  valid), an ink `RingDot` where the user must act (Needs admin:org, Can't use), a
  `hairlineStrong` dot otherwise (Expired, Org secrets need an org admin).

General: Lock (Lock after inactivity, with the footnote that FX Vault always locks on sleep,
screen lock and window close), then Clipboard clears after (the fixed 30 s; also on lock) and Clone folder
(`~/…` with Choose…). Security: Unlock with Touch ID with its footnote, then Master password and
Recovery key; its password sheets keep the older sheet chrome. Advanced: GitHub CLI (the gh path
override field with Choose…, In use with the gh version and path and Check Again, any other gh
state but checking and unknown as a `GHStatusRow` under it, a trusted gh with Revoke, the telemetry footnote), then Vault
(Vault folder, Reset vault). Reset vault stays in Advanced, unlike the board, because it works
while the vault is locked; its dialog (board Reset-Confirm) is a 380 pt `DialogSheet` with two
11 pt labels over 28 pt mono fields and a danger-filled Erase Vault.

Accounts (1.0, B4): one GitHub card. Each account is a block: the person symbol, the login in
12 pt mono medium, its SSH alias as a quiet 11 pt mono menu, Re-check and Test; then 22 pt lines
for Token, Scopes and each organization (`building.2`, mono login, `PreferencesStatus`, an
underlined Open SSO Page link when GitHub gave one), each followed by its `CommandRow`s when a fix
is needed, and the Test result. Accounts FX Vault can't use follow in the same card ("Can't use ·
reason"). The `GH_TOKEN` note and its command sit under the card; SSH aliases without an account
are their own group. The gh path and version are in Advanced.

Sharing (v0.9.0) has one group, "Files you shared", with the footnote "Names only; FX Vault keeps
no copy of the file. If one leaks, rotate what's in it.": one row per export, newest first: the
`doc` symbol, the date and time in 12 pt medium, Active or Expired, a ••• menu with Remove from
List (a confirmation that the sent file is not affected); under it, the repositories, stages,
counts and "expires 1 Nov, 14:02" (a 0.9 row adds "Teammates: …"), and Show names, which lists
the names per place in two mono columns, secrets in ink (the ones to rotate), variables muted.

### `.env` and sharing (sheet pattern)

These sheets use the sheet chrome components (`SheetHeader`, `.fxSheetContent()`, `SheetCallout`,
`FXCheckboxRow`). `App/Screens/Sharing/ShareSheetComponents.swift` adds only the
`ShareSheetLabel` eyebrows, `ShareNoteView` (inline icon and callout text) and
`SheetProgressRow`; `.shareListContainer()` draws a native `List` as a hairline `card` container.
Failures use `Banner(.danger)`.

- `.env` export (board Main2-Export): `EnvExportDialog`, a 580 pt `DialogSheet` titled "Export
  api-service › production as .env", "Saved readable only by you. Delete it when you’re done."
  as every step's footer note, Cancel outlined and the step's default an ink pill. Warnings sit
  in a `DialogNoteBox` (hairline, 10 pt corners, no fill) of `DialogNote` rows (a 13 pt ink
  symbol, the 12 pt ink sentence; a committed file's octagon in `danger`); "Save to" and
  "Saved to" are a `DialogStackedField` over the mono path in `dialogFieldChrome`; "Add /.env
  to .gitignore" (the line it writes) is a `.compact` outline beside its note. Not built: the Include secrets / Include
  variables checkboxes and the one-step flow (path, warnings, Export with Touch ID): the steps
  stay ReauthGate, warnings, save panel, iCloud check, written.
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
| Hairline borders | Shadows (except `Card(.sheet)`, the palette and the main window's panels), gradients (except `MainWindowGround`) |
| Brand for pending, links, focus | Brand fills, brand body text |
| One primary pill per view | `.borderedProminent`, two primaries |
| Sentence-case strings, uppercase via `.sectionLabel` | Uppercase literals in String Catalogs |
| Pill buttons and menu items in Title Case (macOS HIG: "Add Secret", "Paste Multiple…"); text links ("Use recovery key", "Learn more"), headings, body and labels in sentence case | Sentence-case buttons copied from the web boards ("Add secret") |
| Native table, settings, sheets; the window's own traffic lights | Fake or hand-moved traffic lights, native toolbar items in the main window |
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
| Sync-Delete, Sync-Progress, Sync-Done | `SyncDeletionsView` (`.fxDialogListBox`), `SyncRunView` (`SyncProgressPresentation`), `SyncDoneView`, `FXButtonStyle(.dialog)` |
| NewRepo, NewEnvironment | `CreateRepoFormView`, `NewEnvironmentScreen`, `BranchPolicyEditorView`, `DialogForm.swift` |
| Main2-Delete, Main2-DeleteKeyVault, Main2-Export | `DeleteItemsSheet`, `EnvExportDialog`, `DialogNoteBox`, `DialogStackedField` |
| Folder-View, Folder-LinkedUpdate, KV-Place, KV-NameRules, Org-UsedBy | `LinkedChip`, `LinkedUpdateList`, `DestinationDetailScreen` (`DestinationFootnotes`), `OrgVisibility.reachTitle` |
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
- The traffic lights sit 19 pt in, the boards' 20: the place AppKit gives them under an empty
  unified toolbar (`MainWindowTitleBar`).
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
`project-share-contents-three`, `project-share-passphrase`, `project-share-open`, `project-share-expired` and
`settings-sharing` (D6d: `project-share-send-to-passphrase` is gone with its step;
`project-share-contents-production`, `project-share-authenticate` and
`project-share-open-passphrase` are added); `sync-held-one`, `sync-held-two`,
`sync-held-only` and `main-held`. 1.0 removed the presence, teammates, pairing, shared-space
and Nearby Chat renders with those screens; D6c2 adds `main-home` (nothing selected, with the
recovery-key banner) and `main-jump` (the ⌘K palette); D6d adds `preferences-general`,
`preferences-accounts`, `preferences-advanced` and `preferences-reset` beside
`preferences-security`. The toolbar's glass items and the
sidebar draw blank in these captures: `JumpPaletteUITests` (light) and `MainTreeUITests` (dark)
attach screenshots of the running window instead.
The offscreen window capture leaves the repository sidebar blank or black in some captures; the
running app draws it normally. SwiftUI `ImageRenderer` is not used: it
cannot draw AppKit-backed views (`ScrollView`, `List`, `Table`, text fields, toggles, the split
view), which came out blank or as placeholders. A window capture cannot draw the macOS 26+ glass
sidebar, so the sidebar also has its own snapshot (`main-sidebar`).
