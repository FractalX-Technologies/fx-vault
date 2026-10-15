import SwiftUI
import VaultData

/// Column 2 (§10): "Repository" then each environment with its pending dot and value-missing
/// count, the row context menu and "+ New Environment".
struct ScopeListView: View {
    @Bindable var viewModel: ScopeListViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedScopeID) {
                ForEach(viewModel.scopes) { scope in
                    ScopeRow(scope: scope)
                        .tag(scope.id)
                        .contextMenu {
                            ScopeContextMenu(scope: scope, viewModel: viewModel)
                        }
                }
            }
            Divider()
            HStack {
                Button {
                    viewModel.newEnvironment()
                } label: {
                    Label(String(localized: "main.scopes.newEnvironment", defaultValue: "New Environment"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.canCreateEnvironment)
                .help(viewModel.canCreateEnvironment
                    ? String(localized: "main.scopes.newEnvironment.help", defaultValue: "Add an environment to this repository")
                    : String(localized: "main.scopes.newEnvironment.adminRequired", defaultValue: "Environments need admin rights on the repository"))
                Spacer()
            }
            .padding(Theme.Spacing.small)
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            String(localized: "main.scopes.delete.title", defaultValue: "Delete this environment?"),
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { _ in
            Button(String(localized: "main.scopes.delete.confirm", defaultValue: "Delete Environment"), role: .destructive) {
                viewModel.confirmDeletion()
            }
        } message: { scope in
            Text(String(
                localized: "main.scopes.delete.message",
                defaultValue: "\(scope.title) and its secrets and variables are removed. If it is on GitHub, the next Sync deletes it there after you confirm."
            ))
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeletion != nil },
            set: { if !$0 { viewModel.pendingDeletion = nil } }
        )
    }
}

/// One scope row: title (struck through when deleted), the rename note, the value-missing count
/// and the pending dot.
private struct ScopeRow: View {
    let scope: ConfigScopeSummaryModel

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: scope.title)
                        .strikethrough(scope.isDeleted)
                        .foregroundStyle(scope.isDeleted ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
                        .lineLimit(1)
                    if let renamedFrom = scope.renamedFrom {
                        Text(String(localized: "main.scopes.renamedFrom", defaultValue: "Renamed from \(renamedFrom)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            } icon: {
                Image(systemName: scope.environment == nil ? "shippingbox" : "server.rack")
            }
            Spacer(minLength: 0)
            if scope.valueMissingCount > 0 {
                Text(verbatim: scope.valueMissingCount.formatted())
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.warning)
                    .help(String(
                        localized: "main.scopes.valueMissing.help",
                        defaultValue: "\(scope.valueMissingCount) secrets have no value in FX Vault"
                    ))
            }
            if scope.hasPendingChanges {
                Circle()
                    .fill(Theme.Colors.pending)
                    .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                    .help(String(localized: "main.scopes.pending.help", defaultValue: "Pending changes"))
                    .accessibilityLabel(String(localized: "main.scopes.pending.help", defaultValue: "Pending changes"))
            }
        }
    }
}

/// Settings… / Rename / Duplicate… / Export .env… / Share… / Delete (or Restore).
private struct ScopeContextMenu: View {
    let scope: ConfigScopeSummaryModel
    let viewModel: ScopeListViewModel

    var body: some View {
        if scope.environment != nil {
            Button(String(localized: "main.scopes.settings", defaultValue: "Settings…")) {
                viewModel.openSettings(scope)
            }
            .disabled(!viewModel.canEdit(scope))
            Button(String(localized: "main.scopes.rename", defaultValue: "Rename…")) {
                viewModel.rename(scope)
            }
            .disabled(!viewModel.canEdit(scope))
            Button(String(localized: "main.scopes.duplicate", defaultValue: "Duplicate…")) {
                viewModel.duplicate(scope)
            }
            .disabled(!viewModel.canEdit(scope))
            Divider()
        }
        Button(String(localized: "main.scopes.exportEnv", defaultValue: "Export .env…")) {
            viewModel.exportEnv(scope)
        }
        .disabled(!viewModel.canExport(scope))
        Button(String(localized: "main.scopes.share", defaultValue: "Share…")) {
            viewModel.share(scope)
        }
        .disabled(!viewModel.canExport(scope))
        if scope.environment != nil {
            Divider()
            if viewModel.canRevert(scope) {
                Button(String(localized: "main.scopes.revert", defaultValue: "Revert Changes")) {
                    viewModel.revert(scope)
                }
            }
            Button(String(localized: "main.scopes.delete", defaultValue: "Delete…"), role: .destructive) {
                viewModel.requestDeletion(scope)
            }
            .disabled(!viewModel.canEdit(scope))
        }
    }
}
