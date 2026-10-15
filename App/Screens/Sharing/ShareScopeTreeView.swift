import SwiftUI

/// The scope tree with tri-state checkboxes (§10 `ShareExportScreen`, v0.2.0): repository,
/// repository level, environments, items. See ``ShareScopeTreeModel`` for the rules.
struct ShareScopeTreeView: View {
    let tree: ShareScopeTreeModel
    /// `true` checks everything under the row, `false` unchecks it.
    let onCheck: (Bool, ShareScopeNodeModel) -> Void

    var body: some View {
        List {
            OutlineGroup(tree.root, children: \.children) { node in
                ShareScopeTreeRow(node: node, state: tree.state(of: node)) {
                    onCheck(tree.state(of: node) != .checked, node)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .frame(height: Theme.Layout.shareListHeight)
    }
}

/// One row: a tri-state checkbox, the icon, the name and its notes.
private struct ShareScopeTreeRow: View {
    let node: ShareScopeNodeModel
    let state: ShareCheckState
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: checkboxSymbol)
                    .foregroundStyle(state == .unchecked ? Theme.Colors.textSecondary : Theme.Colors.accent)
                    .accessibilityHidden(true)
                Image(systemName: icon)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: node.title)
                    .font(isGroup ? Theme.Typography.body : Theme.Typography.monospaced)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                notes
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder
    private var notes: some View {
        switch node.kind {
        case .secret(hasValue: false):
            StatusChip(
                title: String(localized: "share.tree.byNameOnly", defaultValue: "Name only"),
                tint: Theme.Colors.warning
            )
            .help(String(
                localized: "share.tree.byNameOnly.help",
                defaultValue: "The value is missing in your vault, so only the name is shared."
            ))
        case .environment where state == .mixed:
            StatusChip(
                title: String(localized: "share.tree.itemsOnly", defaultValue: "Selected items only"),
                tint: Theme.Colors.textSecondary
            )
            .help(String(
                localized: "share.tree.itemsOnly.help",
                defaultValue: "Only the checked items are shared. The deployment branch policy is shared only when the whole environment is checked."
            ))
        case .environment where state == .checked:
            StatusChip(
                title: String(localized: "share.tree.withPolicy", defaultValue: "With branch policy"),
                tint: Theme.Colors.accent
            )
            .help(String(
                localized: "share.tree.withPolicy.help",
                defaultValue: "The whole environment is checked, so its deployment branch policy is shared too."
            ))
        default:
            EmptyView()
        }
    }

    private var isGroup: Bool {
        switch node.kind {
        case .repository, .repositoryLevel, .environment: true
        case .secret, .variable: false
        }
    }

    private var checkboxSymbol: String {
        switch state {
        case .unchecked: "square"
        case .mixed: "minus.square.fill"
        case .checked: "checkmark.square.fill"
        }
    }

    private var accessibilityState: String {
        switch state {
        case .unchecked: String(localized: "share.tree.state.unchecked", defaultValue: "Not shared")
        case .mixed: String(localized: "share.tree.state.mixed", defaultValue: "Partly shared")
        case .checked: String(localized: "share.tree.state.checked", defaultValue: "Shared")
        }
    }

    private var icon: String {
        switch node.kind {
        case .repository: "shippingbox"
        case .repositoryLevel: "folder"
        case .environment: "square.stack.3d.up"
        case .secret: "key"
        case .variable: "textformat"
        }
    }
}
