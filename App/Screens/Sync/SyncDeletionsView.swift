import SwiftUI

/// Step 2 (§7.5): every deletion, the live contents of each environment being deleted (names
/// GitHub has that the vault does not are marked "will be lost"), and the acknowledgements.
/// Neither footer button is the default and Return does nothing.
struct SyncDeletionsView: View {
    @Bindable var viewModel: SyncViewModel

    var body: some View {
        Form {
            if viewModel.deletionPreviews == nil {
                Section {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(
                            localized: "sync.deletions.loading",
                            defaultValue: "Fetching what GitHub has in the environments being deleted…"
                        ))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            } else {
                ForEach(viewModel.deletionRows) { repository in
                    Section {
                        ForEach(repository.items) { item in
                            Label(item.title, systemImage: "trash")
                                .foregroundStyle(Theme.Colors.textPrimary)
                        }
                        ForEach(repository.environments) { environment in
                            SyncDeletionEnvironmentRow(environment: environment)
                        }
                    } header: {
                        Text(verbatim: repository.fullName)
                            .font(Theme.Typography.headline)
                    }
                }
                acknowledgementSection
            }
        }
        .formStyle(.grouped)
        .onKeyPress(.return) { .handled }
    }

    private var acknowledgementSection: some View {
        Section {
            if viewModel.hasUnknownContents {
                Toggle(
                    String(
                        localized: "sync.deletions.unknownAck",
                        defaultValue: "Delete even though FX Vault could not see what some environments contain"
                    ),
                    isOn: $viewModel.unknownContentsAcknowledged
                )
            }
            Toggle(
                String(localized: "sync.deletions.ack", defaultValue: "I understand this cannot be undone"),
                isOn: $viewModel.deletionsAcknowledged
            )
        }
    }
}

/// One environment being deleted with its live contents.
private struct SyncDeletionEnvironmentRow: View {
    let environment: SyncDeletionEnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Label(
                String(localized: "sync.deletions.environment", defaultValue: "Delete environment \(environment.name)"),
                systemImage: "trash"
            )
            .font(Theme.Typography.body.weight(.medium))
            .foregroundStyle(Theme.Colors.textPrimary)
            contents
            Text(String(
                localized: "sync.deletions.workflowWarning",
                defaultValue: "Workflows that still reference \(environment.name) will recreate it empty."
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.xxSmall)
    }

    @ViewBuilder
    private var contents: some View {
        switch environment.contents {
        case .loaded(let items, let patterns, let foreignRules):
            ForEach(items) { item in
                HStack(spacing: Theme.Spacing.small) {
                    Text(verbatim: item.title)
                        .font(Theme.Typography.callout.monospaced())
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if item.willBeLost {
                        StatusChip(
                            title: String(
                                localized: "sync.deletions.willBeLost",
                                defaultValue: "not in your vault: will be lost"
                            ),
                            tint: Theme.Colors.danger
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
                    .font(Theme.Typography.caption)
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
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.leading, Theme.Spacing.large)
            .fixedSize(horizontal: false, vertical: true)
    }
}
