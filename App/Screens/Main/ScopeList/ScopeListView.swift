import SwiftUI
import VaultData

/// Column 2 (§10; mockup Main): the mono SCOPES label, "Repository" then each environment with
/// its pending dot, item count and value-missing warning, the row context menu and the dashed
/// "+ New environment" row.
///
/// The rows are drawn with `.fxRowBackground(style: .scope)` (36 pt, `card` with a hairline when
/// selected) instead of a native `List` selection; ``MainColumnSelection`` keeps Up and Down.
struct ScopeListView: View {
    @Bindable var viewModel: ScopeListViewModel
    @FocusState private var isListFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                SectionLabel(String(localized: "main.scopes.title", defaultValue: "Scopes"))
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.bottom, Theme.Spacing.small)
                ForEach(viewModel.scopes) { scope in
                    Button {
                        viewModel.selectedScopeID = scope.id
                        isListFocused = true
                    } label: {
                        ScopeRow(scope: scope, isSelected: viewModel.selectedScopeID == scope.id)
                    }
                    .buttonStyle(.plain)
                    .id(scope.id)
                    .contextMenu {
                        ScopeContextMenu(scope: scope, viewModel: viewModel)
                    }
                }
                NewEnvironmentButton(viewModel: viewModel)
                    .padding(.top, Theme.Spacing.small)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.largePlus)
        }
        .mainColumnKeyboardSelection(
            ids: viewModel.scopes.map(\.id),
            selection: $viewModel.selectedScopeID,
            isFocused: $isListFocused
        )
        .background(Theme.Colors.ground)
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

/// One scope row: title (500 when selected, struck through when deleted), the rename note, the
/// value-missing warning, the brand pending dot and the mono item count.
private struct ScopeRow: View {
    let scope: ConfigScopeSummaryModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: scope.title)
                    .font(isSelected ? Theme.Typography.calloutEmphasized : Theme.Typography.callout)
                    .strikethrough(scope.isDeleted)
                    .foregroundStyle(scope.isDeleted ? Theme.Colors.subtleText : Theme.Colors.ink)
                    .lineLimit(1)
                if let renamedFrom = scope.renamedFrom {
                    Text(String(localized: "main.scopes.renamedFrom", defaultValue: "Renamed from \(renamedFrom)"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Theme.Spacing.xSmall)
            Spacer(minLength: 0)
            if scope.valueMissingCount > 0 {
                let help = String(
                    localized: "main.scopes.valueMissing.help",
                    defaultValue: "\(scope.valueMissingCount) secrets have no value in FX Vault"
                )
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.warning)
                    .help(help)
                    .accessibilityLabel(help)
            }
            if scope.hasPendingChanges {
                Circle()
                    .fill(Theme.Colors.brand)
                    .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                    .help(String(localized: "main.scopes.pending.help", defaultValue: "Pending changes"))
                    .accessibilityLabel(String(localized: "main.scopes.pending.help", defaultValue: "Pending changes"))
            }
            Text(scope.itemCount, format: .number)
                .font(Theme.Typography.monoLabel)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityLabel(String(localized: "main.scopes.itemCount", defaultValue: "\(scope.itemCount) items"))
        }
        .fxRowBackground(isSelected: isSelected, style: .scope)
    }
}

/// "+ New environment" as a dashed hairline-strong row (mockup Main).
private struct NewEnvironmentButton: View {
    let viewModel: ScopeListViewModel

    var body: some View {
        let isEnabled = viewModel.canCreateEnvironment
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        Button {
            viewModel.newEnvironment()
        } label: {
            Label(String(localized: "main.scopes.newEnvironment", defaultValue: "New Environment"), systemImage: "plus")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .padding(.horizontal, Theme.Spacing.mediumMinus)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.sidebarRowHeight, alignment: .leading)
                .overlay(
                    shape.strokeBorder(
                        Theme.Colors.hairlineStrong,
                        style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: Theme.Stroke.dashPattern)
                    )
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
        .help(isEnabled
            ? String(localized: "main.scopes.newEnvironment.help", defaultValue: "Add an environment to this repository")
            : String(localized: "main.scopes.newEnvironment.adminRequired", defaultValue: "Environments need admin rights on the repository"))
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
