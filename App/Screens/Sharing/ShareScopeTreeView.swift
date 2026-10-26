import SwiftUI

/// The share tree (board Share-Pick): a card of 28 pt rows with tri-state checkboxes, the
/// repository, its repository level, environments and destinations, their items, then folders;
/// each row with its counts. See ``ShareScopeTreeModel`` for the rules.
///
/// The box grows with its rows up to `shareListHeight`, then scrolls.
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
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(visibleRows.enumerated()), id: \.element.node.id) { index, row in
                    if index > 0 {
                        HairlineDivider()
                    }
                    ShareScopeTreeRow(
                        node: row.node,
                        depth: row.depth,
                        state: tree.state(of: row.node),
                        isExpanded: row.node.children == nil ? nil : expanded.contains(row.node.id),
                        onExpand: { toggleExpanded(row.node.id) },
                        onToggle: { onCheck(tree.state(of: row.node) != .checked, row.node) }
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Theme.Layout.shareListHeight)
        .fxCardBackground(.dialog)
    }

    /// The rows in tree order, each open row followed by its children.
    private var visibleRows: [(node: ShareScopeNodeModel, depth: Int)] {
        var rows: [(node: ShareScopeNodeModel, depth: Int)] = []
        func add(_ node: ShareScopeNodeModel, depth: Int) {
            rows.append((node, depth))
            guard expanded.contains(node.id) else { return }
            node.children?.forEach { add($0, depth: depth + 1) }
        }
        tree.roots.forEach { add($0, depth: 0) }
        return rows
    }

    private func toggleExpanded(_ id: ShareScopeNodeID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
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

/// One row: the disclosure chevron, a tri-state checkbox, the symbol, the name (mono for names
/// from GitHub and Azure), a production environment's tag and lock, then the counts.
private struct ShareScopeTreeRow: View {
    let node: ShareScopeNodeModel
    let depth: Int
    let state: ShareCheckState
    /// nil for a row without children.
    let isExpanded: Bool?
    let onExpand: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            chevron
            Button(action: onToggle) {
                HStack(spacing: Theme.Spacing.smallMinus) {
                    Image(systemName: checkboxSymbol)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(state == .unchecked ? Theme.Colors.subtleText : Theme.Colors.ink)
                    Image(systemName: icon)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                    Text(verbatim: node.title)
                        .fxTextStyle(isPlainTitle ? .caption : .monoMeta)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if node.isProduction {
                        DialogTag(title: ProjectShareCopy.productionTag)
                        Image(systemName: "lock")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .help(ProjectShareCopy.productionTreeHelp)
                    }
                    notes
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(accessibilityState)
            Spacer(minLength: Theme.Spacing.small)
            Text(verbatim: ProjectShareCopy.counts(node.itemCounts))
                .font(Theme.Typography.monoLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, Theme.Spacing.mediumMinus + CGFloat(depth) * Theme.Layout.shareTreeIndent)
        .padding(.trailing, Theme.Spacing.mediumMinus)
        .frame(height: Theme.Layout.shareTreeRowHeight)
    }

    @ViewBuilder
    private var chevron: some View {
        if let isExpanded {
            Button(action: onExpand) {
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    .frame(width: Theme.Layout.shareTreeChevronWidth, height: Theme.Layout.shareTreeRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: node.title))
            .accessibilityValue(isExpanded ? Self.expandedTitle : Self.collapsedTitle)
        } else {
            Color.clear
                .frame(width: Theme.Layout.shareTreeChevronWidth)
        }
    }

    /// A secret without a value here travels by name only; an environment checked in part
    /// leaves its branch policy behind.
    @ViewBuilder
    private var notes: some View {
        switch node.kind {
        case .secret(hasValue: false):
            note(
                String(localized: "share.tree.byNameOnly", defaultValue: "Name only"),
                help: String(
                    localized: "share.tree.byNameOnly.help",
                    defaultValue: "The value is missing in your vault, so only the name is shared."
                )
            )
        case .environment where state == .mixed:
            note(
                String(localized: "share.tree.itemsOnly", defaultValue: "Selected items only"),
                help: String(
                    localized: "share.tree.itemsOnly.help",
                    defaultValue: "Only the checked items are shared. The deployment branch policy is shared only when the whole environment is checked."
                )
            )
        default:
            EmptyView()
        }
    }

    private func note(_ text: String, help: String) -> some View {
        Text(verbatim: text)
            .fxTextStyle(.formNote)
            .foregroundStyle(Theme.Colors.mutedText)
            .lineLimit(1)
            .help(help)
    }

    /// The repository level reads as a place ("Repository"); names come from GitHub and Azure.
    private var isPlainTitle: Bool {
        node.kind == .repositoryLevel
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

    private static let expandedTitle = String(localized: "share.tree.expanded", defaultValue: "Expanded")
    private static let collapsedTitle = String(localized: "share.tree.collapsed", defaultValue: "Collapsed")

    private var icon: String {
        switch node.kind {
        case .repository, .repositoryLevel: Theme.Symbols.repository
        case .environment: Theme.Symbols.environment
        case .destination(let symbolName): symbolName
        case .folder: "folder"
        case .secret: "key"
        case .variable: "textformat"
        }
    }
}
