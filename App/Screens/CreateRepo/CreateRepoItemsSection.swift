import SwiftUI
import VaultCore
import VaultData

/// The staged secrets and variables of one scope (the repository or one environment). Values are
/// never shown: each row shows its name, its kind and a fixed mask.
struct CreateRepoItemsSection: View {
    let viewModel: CreateRepoViewModel
    let target: CreateRepoItemTargetModel

    var body: some View {
        ConfigSheetField(String(localized: "createRepo.section.repositoryItems", defaultValue: "Repository Secrets and Variables")) {
            CreateRepoItemRows(viewModel: viewModel, target: target)
            if viewModel.repositoryItems.isEmpty {
                CreateRepoHint(String(
                    localized: "createRepo.items.empty",
                    defaultValue: "Optional. Values stay encrypted in your vault until Sync sends them to GitHub."
                ))
            }
        }
    }
}

/// The rows of one scope in a hairline card, then the Add Secret / Add Variable pills.
struct CreateRepoItemRows: View {
    let viewModel: CreateRepoViewModel
    let target: CreateRepoItemTargetModel

    var body: some View {
        let items = viewModel.items(in: target)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        HairlineDivider()
                    }
                    CreateRepoItemRow(item: item) {
                        viewModel.editItem(item.id, in: target)
                    } onRemove: {
                        viewModel.removeItem(item.id, from: target)
                    }
                }
            }
            .fxCardBackground(.container)
        }
        HStack(spacing: Theme.Spacing.small) {
            Button {
                viewModel.addItem(kind: .secret, to: target)
            } label: {
                Label(String(localized: "createRepo.item.addSecret", defaultValue: "Add Secret…"), systemImage: "plus")
            }
            Button {
                viewModel.addItem(kind: .variable, to: target)
            } label: {
                Label(String(localized: "createRepo.item.addVariable", defaultValue: "Add Variable…"), systemImage: "plus")
            }
        }
        .fxButtonStyle(.outline)
    }
}

/// One staged item: mono name, kind tag, mask, Edit and Remove.
struct CreateRepoItemRow: View {
    let item: CreateRepoItemDraftModel
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: item.kind == .secret ? "key" : "textformat")
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            Text(verbatim: item.name)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            StatusChip.tag(CreateRepoText.kindTitle(item.kind))
            Spacer()
            Text(verbatim: CreateRepoConstants.maskedValue)
                .fxTextStyle(.monoValue)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityLabel(String(localized: "createRepo.item.valueSet", defaultValue: "Value entered"))
            Button(action: onEdit) {
                Label(String(localized: "createRepo.item.edit", defaultValue: "Edit"), systemImage: "pencil")
            }
            .fxIconButtonStyle(.ghost)
            .help(String(localized: "createRepo.item.edit", defaultValue: "Edit"))
            Button(action: onRemove) {
                Label(String(localized: "createRepo.item.remove", defaultValue: "Remove"), systemImage: "minus.circle")
            }
            .fxIconButtonStyle(.ghost)
            .help(String(localized: "createRepo.item.remove", defaultValue: "Remove"))
        }
        .padding(.leading, Theme.Spacing.large)
        .padding(.trailing, Theme.Spacing.xSmall)
        .padding(.vertical, Theme.Spacing.xSmall)
        .contextMenu {
            Button(String(localized: "createRepo.item.edit", defaultValue: "Edit"), action: onEdit)
            Button(String(localized: "createRepo.item.remove", defaultValue: "Remove"), role: .destructive, action: onRemove)
        }
    }
}

/// One staged environment: its branch policy with Edit, its items and Remove.
struct CreateRepoEnvironmentSection: View {
    let viewModel: CreateRepoViewModel
    let environment: CreateRepoEnvironmentDraftModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
                Text(verbatim: environment.name)
                    .fxTextStyle(.monoName)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(String(localized: "createRepo.environment.remove", defaultValue: "Remove Environment"), role: .destructive) {
                    viewModel.removeEnvironment(environment.id)
                }
                .fxButtonStyle(.ghost)
            }
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(String(localized: "createRepo.environment.branches", defaultValue: "Deployment branches"))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                    Text(CreateRepoText.policySummary(environment.policy))
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(String(localized: "createRepo.environment.edit", defaultValue: "Edit…")) {
                    viewModel.editEnvironment(environment.id)
                }
                .fxButtonStyle(.outline)
            }
            .configSheetRowPadding()
            .fxCardBackground(.container)
            CreateRepoItemRows(viewModel: viewModel, target: .environment(environment.id))
        }
    }
}
