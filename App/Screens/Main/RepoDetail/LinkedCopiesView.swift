import SwiftUI
import VaultCore
import VaultData

/// The Linked chip of a table row (v0.4.1; board Folder-View): a link symbol and "3 places", the
/// places that share the item's link, in an 18 pt outlined tag. A click opens
/// ``LinkedCopiesPopover``; the row menu's Show Linked Copies opens the same popover.
struct LinkedChip<Model: ConfigTableModel>: View {
    let row: ConfigRowModel
    @Bindable var viewModel: Model

    var body: some View {
        Button {
            viewModel.showLinkedCopies(of: row)
        } label: {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
            HStack(spacing: Theme.Spacing.xSmall) {
                Image(systemName: "link")
                    .font(Theme.Typography.monoLabel)
                    .accessibilityHidden(true)
                Text(LinkedChipText.places(row.linkCount))
                    .font(Theme.Typography.label)
            }
            .foregroundStyle(Theme.Colors.mutedText)
            .padding(.horizontal, Theme.Spacing.smallMinus)
            .frame(height: Theme.Layout.dialogTagHeight)
            .overlay(shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(LinkedChipText.help(count: row.linkCount))
        .accessibilityLabel(LinkedChipText.help(count: row.linkCount))
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

}

/// The Linked chip's help text.
enum LinkedChipText {
    /// "3 places" (inflected).
    static func places(_ count: Int) -> String {
        String(inflected: AttributedString(localized: "main.table.linked.places", defaultValue: "^[\(count) place](inflect: true)"))
    }

    static func help(count: Int) -> String {
        String(localized: "main.table.linked.help", defaultValue: "Linked copy: the same item is in \(count) places")
    }
}

/// The other places of a linked item (v0.4.1): account · repository, scope, how the value
/// compares, the sync status, and Open. Footer: Unlink.
struct LinkedCopiesPopover<Model: ConfigTableModel>: View {
    let row: ConfigRowModel
    let viewModel: Model

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
                    Text(verbatim: copy.placeName)
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
        .help(String(localized: "main.linked.open.help", defaultValue: "Show \(copy.name) in \(copy.placeName)"))
    }
}

extension LinkedCopyModel {
    /// "staging · user-a", "Repository · user-a", "Folder" (v0.7.0) or "Key Vault · production ·
    /// owner/name" (v0.8.0), with the copy's name when
    /// it differs from `itemName` (a renamed copy).
    func placeDetail(itemName: String) -> String {
        let parts: [String] = switch place {
        case .scope(_, let accountLogin, _, _, let environmentName):
            [environmentName ?? String(localized: "main.scopes.repository", defaultValue: "Repository"), accountLogin]
        case .folder:
            [String(localized: "main.linked.folder", defaultValue: "Folder")]
        case .destination(_, _, let repositoryFullName, let provider, _, let stage):
            [provider.shortTitle] + [stage, repositoryFullName].compactMap { $0 }
        }
        let named = name == itemName ? parts : [parts[0], name] + parts.dropFirst()
        return named.joined(separator: " · ")
    }
}

extension LinkedCopyModel {
    /// "example-org › api-service › staging", a folder's name, or "example-org › api-service ›
    /// kv-example-prod" (board Folder-LinkedUpdate).
    var placePath: String {
        switch place {
        case .scope(_, _, let fullName, _, let environmentName):
            PlaceCopy.path(fullName.split(separator: "/").map(String.init) + [environmentName].compactMap { $0 })
        case .folder(_, let name):
            name
        case .destination(_, _, let repositoryFullName, _, let displayName, _):
            PlaceCopy.path((repositoryFullName?.split(separator: "/").map(String.init) ?? []) + [displayName])
        }
    }

    /// Why this copy can't take the new value, short: "read only", "environment deleted".
    var blockedNote: String? {
        switch editBlock {
        case nil:
            nil
        case .readOnly?:
            String(localized: "main.linked.blocked.readOnly", defaultValue: "can’t update · read only")
        case .environmentDeleted?:
            String(localized: "main.linked.blocked.environmentDeleted", defaultValue: "can’t update · environment deleted")
        default:
            String(localized: "main.linked.blocked", defaultValue: "can’t update")
        }
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
