import SwiftUI

/// The scope tree with checkboxes (§10 `ShareExportScreen`): repository, environments, items.
/// Exactly one node is checked; what it encloses is shown checked and dimmed.
struct ShareScopeTreeView: View {
    let tree: ShareScopeTreeModel
    let onCheck: (Bool, ShareScopeNodeModel) -> Void

    var body: some View {
        List {
            OutlineGroup(tree.root, children: \.children) { node in
                row(node)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .frame(height: Theme.Layout.shareListHeight)
    }

    private func row(_ node: ShareScopeNodeModel) -> some View {
        let inherited = tree.isIncludedByAncestor(node)
        return Toggle(isOn: Binding(
            get: { tree.isIncluded(node) },
            set: { onCheck($0, node) }
        )) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: icon(node.kind))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: node.title)
                    .font(node.kind == .repository || node.kind == .environment
                        ? Theme.Typography.body
                        : Theme.Typography.monospaced)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                if case .secret(hasValue: false) = node.kind {
                    StatusChip(
                        title: String(localized: "share.tree.byNameOnly", defaultValue: "Name only"),
                        tint: Theme.Colors.warning
                    )
                    .help(String(
                        localized: "share.tree.byNameOnly.help",
                        defaultValue: "The value is missing in your vault, so only the name is shared."
                    ))
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(inherited)
        .opacity(inherited ? Theme.Opacity.disabled : 1)
        .help(inherited
            ? String(
                localized: "share.tree.inherited.help",
                defaultValue: "Included with the checked row above. Uncheck that row first to share a smaller part."
            )
            : "")
        .accessibilityHint(inherited
            ? String(localized: "share.tree.inherited.hint", defaultValue: "Included with the checked item above")
            : "")
    }

    private func icon(_ kind: ShareScopeNodeModel.Kind) -> String {
        switch kind {
        case .repository: "shippingbox"
        case .environment: "square.stack.3d.up"
        case .secret: "key"
        case .variable: "textformat"
        }
    }
}
