import SwiftUI

/// The ⌘K palette over the main window (board Main2-Search) while ``MainViewModel/jumpPalette``
/// is set: a scrim that closes it on a click, and the palette centered under the toolbar panel.
struct JumpPaletteOverlay: View {
    let main: MainViewModel

    var body: some View {
        if let palette = main.jumpPalette {
            ZStack(alignment: .top) {
                Theme.Colors.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { main.closeJumpPalette() }
                    .accessibilityHidden(true)
                JumpPaletteView(palette: palette) {
                    main.closeJumpPalette()
                }
                .padding(.top, Theme.Layout.mainPanelInset + Theme.Layout.toolbarPanelHeight + Theme.Spacing.largePlus)
            }
            // Measured from the window's top, as the panels are (the title bar is hidden).
            .ignoresSafeArea()
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { main.closeJumpPalette() }
            .transition(.opacity)
        }
    }
}

/// The field, "Places" and "Secrets by name" with the matches (the selected one with its ↩ key)
/// and the keys in the footer, "Names only" at its end. The field keeps the focus: ↑↓ move the
/// selection, ↩ opens it, esc closes.
struct JumpPaletteView: View {
    @Bindable var palette: JumpPaletteViewModel
    let onClose: () -> Void
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: Theme.Layout.jumpPaletteWidth)
        .fxCardBackground(.popover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Jump.palette)
        // A focus set while the overlay is being inserted is dropped and typing goes to the
        // window behind (JumpPaletteUITests), so it is asked for until it lands.
        .task {
            await FocusRetry.take(isFocused: { isFieldFocused }) {
                isFieldFocused = true
            }
        }
        // The one esc path, ahead of the field's editor (``View/onEscapeKey(perform:)``).
        .onEscapeKey(perform: onClose)
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            TextField(JumpPaletteCopy.title, text: $palette.query, prompt: Text(JumpPaletteCopy.prompt))
                .textFieldStyle(.plain)
                .font(Theme.Typography.headline)
                .labelsHidden()
                .focused($isFieldFocused)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    palette.moveSelection(press.key == .upArrow ? .up : .down)
                    return .handled
                }
                .onSubmit {
                    palette.open()
                }
                .accessibilityIdentifier(AccessibilityID.Jump.field)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Theme.Layout.jumpPaletteFieldHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !palette.results.isEmpty || palette.items.isEmpty {
                        SidebarSectionHeader(JumpPaletteCopy.places)
                            .padding(.bottom, Theme.Spacing.xSmall)
                    }
                    if palette.results.isEmpty && palette.items.isEmpty {
                        Text(JumpPaletteCopy.noMatches)
                            .fxTextStyle(.callout)
                            .foregroundStyle(Theme.Colors.subtleText)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: Theme.Layout.jumpPaletteRowHeight)
                    }
                    ForEach(palette.results) { place in
                        let id = JumpResultID.place(place.id)
                        JumpRow(
                            systemImage: place.systemImage,
                            name: place.name,
                            titleStyle: place.titleStyle,
                            detail: place.detail,
                            highlight: palette.highlight(in: place.name),
                            isSelected: id == palette.selectedID
                        ) {
                            palette.open(place)
                        }
                        .id(id)
                    }
                    if !palette.items.isEmpty {
                        SidebarSectionHeader(JumpPaletteCopy.secretsByName)
                            .padding(.top, palette.results.isEmpty ? 0 : Theme.Spacing.small)
                            .padding(.bottom, Theme.Spacing.xSmall)
                        ForEach(palette.items) { item in
                            let id = JumpResultID.item(item.id)
                            JumpRow(
                                systemImage: item.match.kind.symbolName,
                                name: item.name,
                                titleStyle: .mono,
                                detail: item.detail,
                                highlight: palette.highlight(in: item.name),
                                isSelected: id == palette.selectedID
                            ) {
                                palette.open(item)
                            }
                            .id(id)
                        }
                    }
                }
                .padding(Theme.Spacing.small)
            }
            // As tall as the rows, up to the maximum, then it scrolls.
            .frame(maxHeight: Theme.Layout.jumpPaletteListMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: palette.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.large) {
            footerHint(["↑", "↓"], JumpPaletteCopy.move)
            footerHint(["↩"], JumpPaletteCopy.open)
            footerHint(["esc"], JumpPaletteCopy.close)
            Spacer(minLength: 0)
            Text(JumpPaletteCopy.namesOnly)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [JumpPaletteCopy.move, JumpPaletteCopy.open, JumpPaletteCopy.close, JumpPaletteCopy.namesOnly].joined(separator: ", ")
        )
    }

    private func footerHint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            ForEach(keys, id: \.self) { key in
                KeyHint(key)
            }
            Text(text)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        }
    }
}

/// One row, a place or a name: its symbol, the name with the typed text in bold (mono for names
/// from GitHub and Azure and for secrets, sans for folders), what and where it is, and ↩ on the
/// selected row. The quick vault's rows trade the ↩ for the pending dot (board QuickVault-Search).
struct JumpRow: View {
    let systemImage: String
    let name: String
    let titleStyle: SidebarTitleStyle
    let detail: String
    let highlight: Range<String.Index>?
    let isSelected: Bool
    var showsReturnKey = true
    var hasPendingChanges = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: systemImage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .frame(width: Theme.Layout.sidebarSymbolWidth)
                    .accessibilityHidden(true)
                Text(nameText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(detail)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                if hasPendingChanges {
                    Circle()
                        .fill(Theme.Colors.ink)
                        .frame(width: Theme.Layout.changedDotSize, height: Theme.Layout.changedDotSize)
                        .help(NotesCopy.pendingMark)
                }
                if isSelected, showsReturnKey {
                    KeyHint("↩")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fxRowBackground(isSelected: isSelected, style: .palette)
        .accessibilityLabel([name, detail].joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The name at 13 pt in either style (the detail beside it is 12), the matched part in the
    /// emphasized weight.
    private var nameText: AttributedString {
        let (regular, emphasized) = switch titleStyle {
        case .mono: (Theme.Typography.monoName, Theme.Typography.monoNameEmphasized)
        case .sans: (Theme.Typography.callout, Theme.Typography.calloutEmphasized)
        }
        func part(_ text: Substring, _ font: Font) -> AttributedString {
            var part = AttributedString(String(text))
            part.font = font
            part.foregroundColor = Theme.Colors.ink
            return part
        }
        guard let highlight else { return part(name[...], regular) }
        return part(name[..<highlight.lowerBound], regular)
            + part(name[highlight], emphasized)
            + part(name[highlight.upperBound...], regular)
    }
}
