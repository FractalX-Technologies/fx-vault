import SwiftUI

/// Step 2 (§7.5, board Sync-Delete): every deletion in the grey list box, `STRIPE_KEY  api-service ›
/// production`, an environment with what GitHub holds in it (names the vault does not have are
/// marked "will be lost"), then the acknowledgements as plain checkboxes. Neither footer button
/// is the default and Return does nothing.
struct SyncDeletionsView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if viewModel.deletionPreviews == nil {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(
                            localized: "sync.deletions.loading",
                            defaultValue: "Fetching what GitHub has in the environments being deleted…"
                        ))
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        ForEach(viewModel.deletionRows) { group in
                            ForEach(group.items) { item in
                                SyncDeletionItemRow(item: item, groupName: group.fullName)
                            }
                            ForEach(group.environments) { environment in
                                SyncDeletionEnvironmentRow(environment: environment, groupName: group.fullName)
                            }
                        }
                    }
                    .fxDialogListBox()
                    ForEach(viewModel.deletionRows.flatMap(\.environments)) { environment in
                        DialogSentence(String(
                            localized: "sync.deletions.workflowWarning",
                            defaultValue: "Workflows that still reference \(environment.name) will recreate it empty."
                        ))
                    }
                    acknowledgements
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.dialogInset)
        }
        .onKeyPress(.return) { .handled }
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if viewModel.hasUnknownContents {
                FXCheckboxRow(
                    title: String(
                        localized: "sync.deletions.unknownAck",
                        defaultValue: "Delete even though FX Vault could not see what some environments contain"
                    ),
                    isOn: $viewModel.unknownContentsAcknowledged,
                    isBoxed: false
                )
            }
            FXCheckboxRow(
                title: String(localized: "sync.deletions.ack", defaultValue: "I understand this cannot be undone"),
                isOn: $viewModel.deletionsAcknowledged,
                isBoxed: false
            )
        }
    }
}

/// `STRIPE_KEY  api-service › production`: the mono name and its place, muted.
private struct SyncDeletionItemRow: View {
    let item: SyncIssueModel
    let groupName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            if let name = item.name {
                Text(verbatim: name)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                Text(verbatim: item.place?.name ?? groupName)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(verbatim: item.title)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.ink)
            }
        }
        .frame(minHeight: Theme.Layout.dialogListRowHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.title))
    }
}

/// `production  api-service` with the environment symbol, as an item's place (board
/// Sync-Delete), then what GitHub holds in it, the branch rules and the other rules deleted
/// with it.
private struct SyncDeletionEnvironmentRow: View {
    let environment: SyncDeletionEnvironmentModel
    let groupName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: Theme.Symbols.environment)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .accessibilityHidden(true)
                Text(verbatim: environment.name)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.ink)
                Text(verbatim: environment.place ?? groupName)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minHeight: Theme.Layout.dialogListRowHeight, alignment: .leading)
            .accessibilityElement(children: .combine)
            contents
                .padding(.leading, Theme.Spacing.large)
        }
    }

    @ViewBuilder
    private var contents: some View {
        switch environment.contents {
        case .loaded(let items, let patterns, let foreignRules):
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(verbatim: item.title)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .textSelection(.enabled)
                    if item.willBeLost {
                        Text(String(
                            localized: "sync.deletions.willBeLost",
                            defaultValue: "not in your vault: will be lost"
                        ))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.danger)
                    }
                }
            }
            if let patterns {
                caption(String(localized: "sync.deletions.patterns", defaultValue: "Deployment branch rules: \(patterns)"))
            }
            if !foreignRules.isEmpty {
                caption(String(
                    localized: "sync.deletions.foreignRules",
                    defaultValue: "Also deleted with it: \(foreignRules.joined(separator: ", "))."
                ))
            }
        case .alreadyDeleted:
            caption(String(
                localized: "sync.deletions.alreadyDeleted",
                defaultValue: "GitHub no longer has this environment; the deletion only confirms it."
            ))
        case .unknown(let reason):
            Text(String(localized: "sync.deletions.unknown", defaultValue: "Contents unknown. \(reason)"))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
