import SwiftUI
import VaultCore
import VaultData

/// The Linked chip of a table row (v0.4.1, tasks/todo.md L3): a link symbol and the number of
/// places that share the item's link. A click opens ``LinkedCopiesPopover``; the row menu's Show
/// Linked Copies opens the same popover.
struct LinkedChip: View {
    let row: ConfigRowModel
    @Bindable var viewModel: RepoDetailViewModel

    var body: some View {
        Button {
            viewModel.showLinkedCopies(of: row)
        } label: {
            HStack(spacing: Theme.Spacing.xSmall) {
                Image(systemName: "link")
                    .font(Theme.Typography.monoLabel)
                    .accessibilityHidden(true)
                Text(verbatim: "\(row.linkCount)")
                    .font(Theme.Typography.monoMeta)
            }
            .foregroundStyle(Theme.Colors.brand)
            .padding(.horizontal, Theme.Spacing.smallMinus)
            .frame(height: Theme.Layout.tagHeight)
            .overlay(Capsule.pill.strokeBorder(Theme.Colors.brand, lineWidth: Theme.Stroke.hairline))
            .contentShape(Capsule.pill)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Self.help(count: row.linkCount))
        .accessibilityLabel(Self.help(count: row.linkCount))
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            LinkedCopiesPopover(row: row, viewModel: viewModel)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { viewModel.linkedPopoverRowID == row.id },
            set: { if !$0, viewModel.linkedPopoverRowID == row.id { viewModel.linkedPopoverRowID = nil } }
        )
    }

    static func help(count: Int) -> String {
        String(localized: "main.table.linked.help", defaultValue: "Linked copy: the same item is in \(count) places")
    }
}

/// The other places of a linked item (v0.4.1): account · repository, scope, how the value
/// compares, the sync status, and Open. Footer: Unlink.
struct LinkedCopiesPopover: View {
    let row: ConfigRowModel
    let viewModel: RepoDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                SectionLabel(String(localized: "main.linked.eyebrow", defaultValue: "Linked copies"))
                Text(verbatim: row.name)
                    .fxTextStyle(.monoName)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if viewModel.linkedCopies.isEmpty {
                Text(String(localized: "main.linked.none", defaultValue: "No other place has this item any more."))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        ForEach(viewModel.linkedCopies) { copy in
                            LinkedCopyRow(copy: copy, itemName: row.name) {
                                viewModel.openLinkedCopy(copy)
                            }
                        }
                    }
                }
                .frame(maxHeight: Theme.Layout.linkedListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(String(
                    localized: "main.linked.footer",
                    defaultValue: "Editing the value offers to update the copies too."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.small)
                Button(String(localized: "main.linked.unlink", defaultValue: "Unlink")) {
                    viewModel.unlink(row)
                }
                .fxButtonStyle(.outline)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: Theme.Layout.linkedPopoverWidth)
    }
}

/// One place of a linked item; a click opens it in the main window.
private struct LinkedCopyRow: View {
    let copy: LinkedCopyModel
    /// The name of the item the popover belongs to: repeated only when the copy's differs.
    let itemName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: Theme.Spacing.mediumMinus) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: copy.repositoryFullName)
                        .fxTextStyle(.monoName)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(copy.placeDetail(itemName: itemName))
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Theme.Spacing.small)
                StatusChip(title: copy.comparison.title, tone: copy.comparison.tone)
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.smallMinus)
            .padding(.horizontal, Theme.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "main.linked.open.help", defaultValue: "Show \(copy.name) in \(copy.repositoryFullName)"))
    }
}

extension LinkedCopyModel {
    /// "staging · user-a" or "Repository · user-a", with the copy's name when it differs from
    /// `itemName` (a renamed copy).
    func placeDetail(itemName: String) -> String {
        let scope = environmentName ?? String(localized: "main.scopes.repository", defaultValue: "Repository")
        let parts = name == itemName ? [scope, accountLogin] : [scope, name, accountLogin]
        return parts.joined(separator: " · ")
    }
}

extension LinkedValueComparison {
    var title: String {
        switch self {
        case .same: String(localized: "main.linked.same", defaultValue: "Same value")
        case .differs: String(localized: "main.linked.differs", defaultValue: "Differs")
        case .valueMissing: String(localized: "main.linked.missing", defaultValue: "Value missing")
        case .unknown: String(localized: "main.linked.unknown", defaultValue: "Not compared")
        }
    }

    var tone: StatusChip.Tone {
        switch self {
        case .same: .success
        case .differs: .brand
        case .valueMissing: .warning
        case .unknown: .neutral
        }
    }
}
