import SwiftUI

/// The scope tree with tri-state checkboxes (`ProjectShareScreen`, v0.2.0): repository,
/// repository level, environments, items. See ``ShareScopeTreeModel`` for the rules.
///
/// The repository row starts expanded, so its scopes fill the box; the box grows up to
/// `shareListHeight` and gives way down to `shareListMinHeight` when the sheet is short.
struct ShareScopeTreeView<Tree: ShareCheckTree>: View {
    let tree: Tree
    /// `true` checks everything under the row, `false` unchecks it.
    let onCheck: (Bool, ShareScopeNodeModel) -> Void
    @State private var expanded: Set<ShareScopeNodeID>

    /// - Parameter expandsRoots: start with every root open (one repository) or closed (a
    ///   project share's several repositories, v0.9.0).
    init(tree: Tree, expandsRoots: Bool = true, onCheck: @escaping (Bool, ShareScopeNodeModel) -> Void) {
        self.tree = tree
        self.onCheck = onCheck
        _expanded = State(initialValue: expandsRoots ? Set(tree.roots.map(\.id)) : [])
    }

    var body: some View {
        List {
            ForEach(tree.roots) { root in
                ShareScopeTreeNode(node: root, tree: tree, expanded: $expanded, onCheck: onCheck)
            }
        }
        .shareListContainer()
        .frame(minHeight: Theme.Layout.shareListMinHeight, maxHeight: Theme.Layout.shareListHeight)
    }
}

/// One node and, when expanded, its children (a disclosure group per node with children).
private struct ShareScopeTreeNode<Tree: ShareCheckTree>: View {
    let node: ShareScopeNodeModel
    let tree: Tree
    @Binding var expanded: Set<ShareScopeNodeID>
    let onCheck: (Bool, ShareScopeNodeModel) -> Void

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { child in
                    ShareScopeTreeNode(node: child, tree: tree, expanded: $expanded, onCheck: onCheck)
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        ShareScopeTreeRow(node: node, state: tree.state(of: node)) {
            onCheck(tree.state(of: node) != .checked, node)
        }
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Theme.Colors.hairline)
    }

    private var isExpanded: Binding<Bool> {
        Binding {
            expanded.contains(node.id)
        } set: { isExpanded in
            if isExpanded {
                expanded.insert(node.id)
            } else {
                expanded.remove(node.id)
            }
        }
    }
}

extension View {
    /// A native `List` inside the sharing sheets as a hairline container (16 pt corners, `card`
    /// fill, no stripes), like the tables of the main window.
    func shareListContainer() -> some View {
        listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .fxCardBackground(.container)
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
                    .font(Theme.Typography.body)
                    .foregroundStyle(state == .unchecked ? Theme.Colors.subtleText : Theme.Colors.ink)
                    .accessibilityHidden(true)
                Image(systemName: icon)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
                Text(verbatim: node.title)
                    .fxTextStyle(isGroup ? .calloutEmphasized : .monoName)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.small)
                notes
            }
            .frame(minHeight: Theme.Layout.scopeRowHeight)
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
                tone: .warning
            )
            .help(String(
                localized: "share.tree.byNameOnly.help",
                defaultValue: "The value is missing in your vault, so only the name is shared."
            ))
        case .environment where state == .mixed:
            StatusChip(
                title: String(localized: "share.tree.itemsOnly", defaultValue: "Selected items only"),
                tone: .neutral
            )
            .help(String(
                localized: "share.tree.itemsOnly.help",
                defaultValue: "Only the checked items are shared. The deployment branch policy is shared only when the whole environment is checked."
            ))
        case .environment where state == .checked:
            StatusChip(
                title: String(localized: "share.tree.withPolicy", defaultValue: "With branch policy"),
                tone: .brand
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
        case .repository, .repositoryLevel, .environment, .destination, .folder: true
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
        case .destination(let symbolName): symbolName
        case .folder: "folder.fill"
        case .secret: "key"
        case .variable: "textformat"
        }
    }
}
