import SwiftUI
import VaultCore

/// The quick vault on the island (boards QuickVault-Search, -Place): the search with its
/// places and names, or one place's lines. Esc goes back, then away.
struct QuickVaultView: View {
    @Bindable var model: QuickVaultViewModel

    var body: some View {
        Group {
            if let place = model.place {
                QuickVaultPlaceView(place: place, onExpand: model.expand)
            } else {
                QuickVaultSearchView(model: model)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, model.notchHeight > 0 ? Theme.Spacing.small : Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
        .notchIsland(notchHeight: model.notchHeight, width: Theme.Layout.quickVaultWidth)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            model.onSizeChange?(size)
        }
        .onEscapeKey(perform: model.escape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QuickVaultCopy.title)
        .accessibilityIdentifier(AccessibilityID.QuickVault.panel)
    }
}

/// The field, "Recent" or "Places" and "Secrets by name", and the keys (board QuickVault-Search).
/// The field keeps the focus: ↑↓ move, ↩ opens, ⌘↩ expands.
private struct QuickVaultSearchView: View {
    @Bindable var model: QuickVaultViewModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            QuickVaultSearchField {
                TextField(QuickVaultCopy.title, text: $model.query, prompt: Text(QuickVaultCopy.prompt))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
                        switch press.key {
                        case .upArrow: model.moveSelection(.up)
                        case .downArrow: model.moveSelection(.down)
                        default:
                            if press.modifiers.contains(.command) {
                                model.expand()
                            } else {
                                model.openSelected()
                            }
                        }
                        return .handled
                    }
                    .accessibilityIdentifier(AccessibilityID.QuickVault.field)
            }
            results
            Divider()
            QuickVaultFooter {
                KeyHintLabel(["↩"], QuickVaultCopy.open)
                KeyHintLabel(["⌘↩"], QuickVaultCopy.expand)
                KeyHintLabel(["esc"], QuickVaultCopy.close)
            }
        }
        // A focus set while the panel is being shown is dropped (as in ⌘K), so it is asked for
        // until it lands, on each open and after Esc from a place.
        .task(id: model.focusRequest) {
            await FocusRetry.take(isFocused: { isFieldFocused }) {
                isFieldFocused = true
            }
        }
    }

    private var results: some View {
        JumpResultsList(
            placesTitle: model.showsRecents ? QuickVaultCopy.recent : JumpPaletteCopy.places,
            places: model.results.map { place in
                JumpResultRowModel(
                    place: place.row,
                    id: QuickVaultResultID.place(place.holder),
                    hasPendingChanges: place.hasPendingChanges
                ) { model.show(place.holder) }
            },
            items: model.items.map { item in
                JumpResultRowModel(item: item, id: QuickVaultResultID.item(item.id)) { model.show(item.match.holder) }
            },
            selectedID: model.selectedID,
            highlight: model.highlight(in:),
            showsReturnKey: false,
            height: .fixed(Theme.Layout.quickVaultListHeight)
        )
    }
}

/// A place's path with its name in bold, Expand, and its own lines with Copy (board
/// QuickVault-Place). "Confirm it's you" takes the lines' room while it asks.
private struct QuickVaultPlaceView: View {
    let place: QuickVaultPlaceViewModel
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            header
            Group {
                if let request = place.reveal.request, let reauth = place.reveal.reauth {
                    QuickVaultConfirmView(
                        title: NotesCopy.reveal(request.name),
                        message: NotesCopy.revealMessage,
                        flow: place.reveal,
                        reauth: reauth,
                        onCancel: place.reveal.cancel
                    )
                } else if let request = place.copyRequest, let reauth = place.copyReauth {
                    QuickVaultConfirmView(
                        title: NotesCopy.copy(request.name),
                        message: NotesCopy.copyMessage,
                        flow: place,
                        reauth: reauth,
                        onCancel: place.cancelCopy
                    )
                } else {
                    lines
                }
            }
            .frame(height: Theme.Layout.quickVaultListHeight, alignment: .top)
            Divider()
            QuickVaultFooter {
                Label(QuickVaultCopy.footer, systemImage: "eye.slash")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        // A Reveal asked over a Copy's confirmation replaces it: one question at a time.
        .onChange(of: place.reveal.request) { _, request in
            if request != nil {
                place.cancelCopy()
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(path)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: Theme.Spacing.small)
            Button(action: onExpand) {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(QuickVaultCopy.expandButton)
                    Image(systemName: "arrow.up.right")
                        .accessibilityHidden(true)
                }
            }
            .fxButtonStyle(.outline, size: .compact)
            .keyboardShortcut(.return, modifiers: .command)
            .help(QuickVaultCopy.expandHelp)
            .accessibilityIdentifier(AccessibilityID.QuickVault.expand)
        }
        .frame(height: Theme.Layout.quickVaultFieldHeight)
    }

    /// "example-org › api-service › **production**".
    private var path: AttributedString {
        let row = place.place.row
        var steps = AttributedString(row.path.map { $0 + PlaceCopy.pathSeparator }.joined())
        steps.font = Theme.Typography.callout
        steps.foregroundColor = Theme.Colors.mutedText
        var name = AttributedString(row.name)
        name.font = row.titleStyle == .mono ? Theme.Typography.monoNameEmphasized : Theme.Typography.calloutEmphasized
        name.foregroundColor = Theme.Colors.ink
        return steps + name
    }

    private var lines: some View {
        let lines = place.lines
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty {
                    Text(QuickVaultCopy.noLines)
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .frame(height: Theme.Layout.quickVaultLineHeight)
                }
                ForEach(lines, id: \.id) { line in
                    QuickVaultLineView(line: line, place: place)
                }
            }
            if let error = place.error {
                InlineErrorView(error: error)
                    .padding(.top, Theme.Spacing.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.QuickVault.lines)
    }
}

/// `KEY = value`, its note ("no value") and Copy: a lock on it when it asks first.
private struct QuickVaultLineView: View {
    let line: NotesItemLineModel
    let place: QuickVaultPlaceViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            Text(verbatim: line.name)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Text(verbatim: "=")
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            NotesValueView(item: line, reveal: place.reveal)
            Spacer(minLength: Theme.Spacing.medium)
            if let note = line.note {
                Text(note)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .help(note)
            }
            if place.canCopy(line) {
                copyButton
            }
        }
        .frame(height: Theme.Layout.quickVaultLineHeight)
        .accessibilityElement(children: .contain)
    }

    private var copyButton: some View {
        let isCopied = place.copiedID == line.id
        let asks = place.asksBeforeCopy(line)
        return Button {
            place.copy(line)
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .overlay(alignment: .bottomTrailing) {
                    if asks, !isCopied {
                        Image(systemName: "lock.fill")
                            .font(Theme.Typography.lockBadge)
                            .offset(x: Theme.Spacing.xxSmall, y: Theme.Spacing.xxSmall)
                    }
                }
        }
        .fxIconButtonStyle(.ghost)
        .help(asks ? QuickVaultCopy.copySecretHelp : QuickVaultCopy.copyHelp)
        .accessibilityLabel(isCopied ? QuickVaultCopy.copied(line.name) : NotesCopy.copy(line.name))
        .accessibilityIdentifier(AccessibilityID.QuickVault.copy)
    }
}

/// "Confirm it's you" for a Reveal or a Copy, in the lines' room: Touch ID at once, then the
/// master password (N1's ``ReauthView``).
private struct QuickVaultConfirmView<Flow: ReauthFlow>: View {
    let title: String
    let message: String
    let flow: Flow
    let reauth: ReauthModel<Flow.Authorization>
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(verbatim: title)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.mutedText)
            ReauthView(
                model: reauth,
                message: message,
                onTouchID: { await flow.authenticateWithTouchID() },
                onPassword: { await flow.authenticateWithPassword() }
            )
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                .fxButtonStyle(.outline, size: .compact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.QuickVault.confirm)
        .task(id: title) {
            await flow.start()
        }
    }
}

/// The island's rounded search field (boards QuickVault-Search, -Locked).
struct QuickVaultSearchField<Input: View>: View {
    @ViewBuilder let input: Input

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            input
                .fxTextStyle(.body)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(height: Theme.Layout.quickVaultFieldHeight)
        .background(Theme.Colors.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline))
    }
}

extension QuickVaultSearchField where Input == Text {
    /// Under "FX Vault is locked": the field to come, dimmed, with nothing in it.
    static var locked: some View {
        QuickVaultSearchField {
            Text(QuickVaultCopy.prompt)
                .foregroundStyle(Theme.Colors.subtleText)
        }
        .frame(maxWidth: .infinity)
        .opacity(Theme.Opacity.disabled)
        .accessibilityHidden(true)
    }
}

/// The bottom row under a hairline: the keys, or the place's note.
private struct QuickVaultFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            content
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Spacing.xSmall)
    }
}
