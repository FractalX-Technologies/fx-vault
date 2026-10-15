import SwiftUI
import VaultCore
import VaultData

/// The staged secrets and variables of one scope (the repository or one environment). Values are
/// never shown: each row shows its name, its kind and a fixed mask.
struct CreateRepoItemsSection: View {
    let viewModel: CreateRepoViewModel
    let target: CreateRepoItemTargetModel

    var body: some View {
        Section {
            CreateRepoItemRows(viewModel: viewModel, target: target)
        } header: {
            Text(String(localized: "createRepo.section.repositoryItems", defaultValue: "Repository Secrets and Variables"))
        } footer: {
            if viewModel.repositoryItems.isEmpty {
                Text(String(
                    localized: "createRepo.items.empty",
                    defaultValue: "Optional. Values stay encrypted in your vault until Sync sends them to GitHub."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

/// The rows and the Add Secret / Add Variable buttons of one scope.
struct CreateRepoItemRows: View {
    let viewModel: CreateRepoViewModel
    let target: CreateRepoItemTargetModel

    var body: some View {
        ForEach(viewModel.items(in: target)) { item in
            CreateRepoItemRow(item: item) {
                viewModel.editItem(item.id, in: target)
            } onRemove: {
                viewModel.removeItem(item.id, from: target)
            }
        }
        HStack(spacing: Theme.Spacing.medium) {
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
        .buttonStyle(.borderless)
    }
}

/// One staged item: kind icon, name, kind, mask, Edit and Remove.
struct CreateRepoItemRow: View {
    let item: CreateRepoItemDraftModel
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: item.kind == .secret ? "key" : "textformat")
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityHidden(true)
            Text(verbatim: item.name)
                .font(Theme.Typography.monospaced)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Text(CreateRepoText.kindTitle(item.kind))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Text(verbatim: CreateRepoConstants.maskedValue)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityLabel(String(localized: "createRepo.item.valueSet", defaultValue: "Value entered"))
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "createRepo.item.edit", defaultValue: "Edit"))
            .accessibilityLabel(String(localized: "createRepo.item.edit", defaultValue: "Edit"))
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "createRepo.item.remove", defaultValue: "Remove"))
            .accessibilityLabel(String(localized: "createRepo.item.remove", defaultValue: "Remove"))
        }
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
        Section {
            LabeledContent(String(localized: "createRepo.environment.branches", defaultValue: "Deployment branches")) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(CreateRepoText.policySummary(environment.policy))
                    Button(String(localized: "createRepo.environment.edit", defaultValue: "Edit…")) {
                        viewModel.editEnvironment(environment.id)
                    }
                    .buttonStyle(.link)
                }
            }
            CreateRepoItemRows(viewModel: viewModel, target: .environment(environment.id))
        } header: {
            HStack {
                Label {
                    Text(verbatim: environment.name)
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                Spacer()
                Button(String(localized: "createRepo.environment.remove", defaultValue: "Remove Environment"), role: .destructive) {
                    viewModel.removeEnvironment(environment.id)
                }
                .buttonStyle(.borderless)
                .font(Theme.Typography.caption)
            }
        }
    }
}
