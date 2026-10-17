import SwiftUI
import VaultCore

/// Sync's From Files review (v0.9.0, P8): one row per share file whose imported rows are held,
/// with the sender (Verified for a teammates file), the import date and count, the held names
/// per scope and destination, and "Include in this Sync", off by default. Like the deletions
/// review, a file is offered again at every Sync until it is included.
struct SyncHeldSharesView: View {
    let rows: [SyncHeldShareRowModel]
    let setIncluded: (SharePackageID, Bool) -> Void

    var body: some View {
        ConfigSheetField(HeldShareCopy.sectionTitle) {
            Text(HeldShareCopy.explanation)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            // One file starts expanded, so its names show without a click.
            ConfigSheetList(rows) { row in
                SyncHeldShareRow(row: row, startsExpanded: rows.count == 1) { setIncluded(row.id, $0) }
            }
        }
    }
}

/// One held share file.
private struct SyncHeldShareRow: View {
    let row: SyncHeldShareRowModel
    let setIncluded: (Bool) -> Void
    @State private var isExpanded: Bool

    init(row: SyncHeldShareRowModel, startsExpanded: Bool, setIncluded: @escaping (Bool) -> Void) {
        self.row = row
        self.setIncluded = setIncluded
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundStyle(Theme.Colors.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(verbatim: row.title)
                            .fxTextStyle(.bodyEmphasized)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        senderChip
                    }
                    Text(verbatim: row.meta)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
                Spacer(minLength: Theme.Spacing.medium)
                Toggle(HeldShareCopy.include, isOn: Binding(get: { row.isIncluded }, set: setIncluded))
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Button(HeldShareCopy.disclosure(isExpanded: isExpanded, itemCount: row.itemCount)) {
                isExpanded.toggle()
            }
            .buttonStyle(.link)
            .font(Theme.Typography.caption)
            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                    ForEach(row.groups) { group in
                        groupView(group)
                    }
                }
                .padding(.leading, Theme.Spacing.large)
            }
        }
    }

    @ViewBuilder
    private var senderChip: some View {
        if row.isVerified {
            StatusChip(title: HeldShareCopy.verified, tone: .success)
                .help(HeldShareCopy.verifiedHelp)
        } else {
            StatusChip.tag(HeldShareCopy.unverified)
                .help(HeldShareCopy.unverifiedHelp)
        }
    }

    private func groupView(_ group: SyncHeldShareGroupModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(verbatim: group.title)
                .textCase(.uppercase)
                .fxTextStyle(.monoCounter)
                .foregroundStyle(Theme.Colors.subtleText)
            Text(verbatim: group.names)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let note = group.note {
                Text(verbatim: note)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
