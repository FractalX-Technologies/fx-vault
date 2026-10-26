import SwiftUI

/// The ⌘K palette over the main window (board Main2-Search) while ``MainViewModel/jumpPalette``
/// is set: a scrim that closes it on a click, and the palette under the toolbar.
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
                .padding(.top, Theme.Spacing.xLarge)
            }
            .transition(.opacity)
        }
    }
}

/// The field, "Places" with the matches (the selected one with its ↩ key) and the keys in the
/// footer. The field keeps the focus: ↑↓ move the selection, ↩ opens it, esc closes.
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
        .onAppear {
            isFieldFocused = true
        }
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
                .onExitCommand(perform: onClose)
                .accessibilityIdentifier(AccessibilityID.Jump.field)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Theme.Layout.jumpPaletteFieldHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SidebarSectionHeader(JumpPaletteCopy.places)
                        .padding(.bottom, Theme.Spacing.xSmall)
                    if palette.results.isEmpty {
                        Text(JumpPaletteCopy.noMatches)
                            .fxTextStyle(.callout)
                            .foregroundStyle(Theme.Colors.subtleText)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: Theme.Layout.jumpPaletteRowHeight)
                    }
                    ForEach(palette.results) { place in
                        JumpPlaceRow(
                            place: place,
                            highlight: palette.highlight(in: place.name),
                            isSelected: place.id == palette.selectedID
                        ) {
                            palette.open(place)
                        }
                        .id(place.id)
                    }
                }
                .padding(Theme.Spacing.small)
            }
            // As tall as the places, up to the maximum, then it scrolls.
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
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([JumpPaletteCopy.move, JumpPaletteCopy.open, JumpPaletteCopy.close].joined(separator: ", "))
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

/// One place: its symbol, the name with the typed text in bold (mono for names from GitHub and
/// Azure, sans for folders), what and where it is, and ↩ on the selected row.
private struct JumpPlaceRow: View {
    let place: JumpPlaceModel
    let highlight: Range<String.Index>?
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: place.systemImage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .frame(width: Theme.Layout.sidebarSymbolWidth)
                    .accessibilityHidden(true)
                Text(nameText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(place.detail)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                if isSelected {
                    KeyHint("↩")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fxRowBackground(isSelected: isSelected, style: .palette)
        .accessibilityLabel([place.name, place.detail].joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The name with the matched part in the emphasized weight of its style.
    private var nameText: AttributedString {
        let (regular, emphasized) = switch place.titleStyle {
        case .mono: (Theme.Typography.monoMeta, Theme.Typography.monoMetaEmphasized)
        case .sans: (Theme.Typography.callout, Theme.Typography.calloutEmphasized)
        }
        func part(_ text: Substring, _ font: Font) -> AttributedString {
            var part = AttributedString(String(text))
            part.font = font
            part.foregroundColor = Theme.Colors.ink
            return part
        }
        guard let highlight else { return part(place.name[...], regular) }
        return part(place.name[..<highlight.lowerBound], regular)
            + part(place.name[highlight], emphasized)
            + part(place.name[highlight.upperBound...], regular)
    }
}
