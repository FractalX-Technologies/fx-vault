import SwiftUI

/// Step 2 (§7.5): every deletion, the live contents of each environment being deleted (names
/// GitHub has that the vault does not are marked "will be lost"), and the acknowledgements.
/// Neither footer button is the default and Return does nothing.
struct SyncDeletionsView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
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
                    ForEach(viewModel.deletionRows) { repository in
                        repositoryBlock(repository)
                    }
                    acknowledgements
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.bottom, Theme.Spacing.xLarge)
        }
        .onKeyPress(.return) { .handled }
    }

    private func repositoryBlock(_ repository: SyncDeletionRepoModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            Text(verbatim: repository.fullName)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(repository.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        HairlineDivider()
                    }
                    Label {
                        Text(verbatim: item.title)
                            .fxTextStyle(.body)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.Colors.danger)
                    }
                    .configSheetRowPadding()
                }
                ForEach(Array(repository.environments.enumerated()), id: \.element.id) { index, environment in
                    if index > 0 || !repository.items.isEmpty {
                        HairlineDivider()
                    }
                    SyncDeletionEnvironmentRow(environment: environment)
                        .configSheetRowPadding()
                }
            }
            .fxCardBackground(.container)
        }
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if viewModel.hasUnknownContents {
                FXCheckboxRow(
                    title: String(
                        localized: "sync.deletions.unknownAck",
                        defaultValue: "Delete even though FX Vault could not see what some environments contain"
                    ),
                    isOn: $viewModel.unknownContentsAcknowledged
                )
            }
            FXCheckboxRow(
                title: String(localized: "sync.deletions.ack", defaultValue: "I understand this cannot be undone"),
                isOn: $viewModel.deletionsAcknowledged
            )
        }
    }
}

/// One environment being deleted with its live contents.
private struct SyncDeletionEnvironmentRow: View {
    let environment: SyncDeletionEnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            Label {
                Text(String(localized: "sync.deletions.environment", defaultValue: "Delete environment \(environment.name)"))
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
            } icon: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.Colors.danger)
            }
            contents
            Text(String(
                localized: "sync.deletions.workflowWarning",
                defaultValue: "Workflows that still reference \(environment.name) will recreate it empty."
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var contents: some View {
        switch environment.contents {
        case .loaded(let items, let patterns, let foreignRules):
            ForEach(items) { item in
                HStack(spacing: Theme.Spacing.small) {
                    Text(verbatim: item.title)
                        .fxTextStyle(.monoName)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                    if item.willBeLost {
                        StatusChip(
                            title: String(
                                localized: "sync.deletions.willBeLost",
                                defaultValue: "not in your vault: will be lost"
                            ),
                            tone: .danger
                        )
                    }
                }
                .padding(.leading, Theme.Spacing.large)
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
            Label {
                Text(String(localized: "sync.deletions.unknown", defaultValue: "Contents unknown. \(reason)"))
                    .fxTextStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.diamond")
            }
            .foregroundStyle(Theme.Colors.danger)
            .padding(.leading, Theme.Spacing.large)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .padding(.leading, Theme.Spacing.large)
            .fixedSize(horizontal: false, vertical: true)
    }
}
