import SwiftUI
import VaultCore
import VaultData

/// The staged secrets and variables of the new repository and its environments, in one grey
/// list (board NewRepo has no such row: it lists what New Repository already stages). Values are
/// never shown: each line shows the name, its kind and scope, and a fixed mask.
struct CreateRepoItemsRow: View {
    let viewModel: CreateRepoViewModel

    var body: some View {
        DialogFormRow(String(localized: "createRepo.items.label", defaultValue: "Secrets and variables")) {
            let lines = self.lines
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.item.id) { line in
                        CreateRepoItemRow(item: line.item, scope: viewModel.scopeTitle(for: line.target)) {
                            viewModel.editItem(line.item.id, in: line.target)
                        } onRemove: {
                            viewModel.removeItem(line.item.id, from: line.target)
                        }
                    }
                }
                .fxDialogListBox()
            }
            HStack(spacing: Theme.Spacing.smallMinus) {
                addButton(.secret)
                addButton(.variable)
            }
            if lines.isEmpty {
                DialogFormNote(String(
                    localized: "createRepo.items.empty",
                    defaultValue: "Optional. Values stay encrypted in your vault until Sync sends them to GitHub."
                ))
            }
        }
    }

    private var targets: [CreateRepoItemTargetModel] {
        [.repository] + viewModel.environments.map { .environment($0.id) }
    }

    private var lines: [(target: CreateRepoItemTargetModel, item: CreateRepoItemDraftModel)] {
        targets.flatMap { target in viewModel.items(in: target).map { (target, $0) } }
    }

    /// Adds to the repository, or asks where once there are environments.
    @ViewBuilder
    private func addButton(_ kind: ConfigKind) -> some View {
        let title = kind == .secret
            ? String(localized: "createRepo.item.addSecret", defaultValue: "Add Secret…")
            : String(localized: "createRepo.item.addVariable", defaultValue: "Add Variable…")
        if viewModel.environments.isEmpty {
            Button(title) {
                viewModel.addItem(kind: kind, to: .repository)
            }
            .fxButtonStyle(.outline, size: .compact)
        } else {
            Menu(title) {
                ForEach(targets, id: \.self) { target in
                    Button(viewModel.scopeTitle(for: target)) {
                        viewModel.addItem(kind: kind, to: target)
                    }
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fxButtonStyle(.outline, size: .compact)
            .fixedSize()
        }
    }
}

/// One staged item: mono name, "secret · production", the mask, Edit and Remove.
struct CreateRepoItemRow: View {
    let item: CreateRepoItemDraftModel
    let scope: String
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: item.name)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: SyncCopy.lineDetail(SyncCopy.kindTitle(item.kind), scope))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.small)
            Text(verbatim: CreateRepoConstants.maskedValue)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityLabel(String(localized: "createRepo.item.valueSet", defaultValue: "Value entered"))
            Button(action: onEdit) {
                Label(String(localized: "createRepo.item.edit", defaultValue: "Edit"), systemImage: "pencil")
            }
            .fxIconButtonStyle(.ghost, size: .compact)
            .help(String(localized: "createRepo.item.edit", defaultValue: "Edit"))
            Button(action: onRemove) {
                Label(String(localized: "createRepo.item.remove", defaultValue: "Remove"), systemImage: "minus.circle")
            }
            .fxIconButtonStyle(.ghost, size: .compact)
            .help(String(localized: "createRepo.item.remove", defaultValue: "Remove"))
        }
        .frame(minHeight: Theme.Layout.dialogListRowHeight)
        .contextMenu {
            Button(String(localized: "createRepo.item.edit", defaultValue: "Edit"), action: onEdit)
            Button(String(localized: "createRepo.item.remove", defaultValue: "Remove"), role: .destructive, action: onRemove)
        }
    }
}
