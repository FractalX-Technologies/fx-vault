import SwiftUI
import VaultCore
import VaultData

/// The selected repository's branch of the sidebar tree (1.0; board Main2-Expanded): its
/// environments, then the RUNTIME destinations (experimental). New Environment… is on the
/// repository's context menu; the repository scope is the repository's own row.
struct ScopeListView: View {
    @Bindable var viewModel: ScopeListViewModel
    /// The open repository's detail, for Refresh on a row's menu.
    let detail: RepoDetailViewModel?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            ForEach(viewModel.environmentScopes) { scope in
                ScopeRow(scope: scope, isSelected: viewModel.selectedScopeID == scope.id) {
                    viewModel.selectedScopeID = scope.id
                    isListFocused = true
                }
                .id(scope.id)
                .contextMenu {
                    ScopeContextMenu(scope: scope, viewModel: viewModel, detail: detail)
                }
            }
            DestinationsSection(viewModel: viewModel, isListFocused: $isListFocused)
                .padding(.leading, Theme.Layout.sidebarTreeIndent * 2)
                .padding(.top, Theme.Spacing.small)
        }
        .mainColumnKeyboardSelection(
            ids: viewModel.rowIDs,
            selection: $viewModel.selectedScopeID,
            isFocused: $isListFocused
        )
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

/// RUNTIME (experimental): the repository's destinations and "+ Add Destination" (v0.8.0, R7).
private struct DestinationsSection: View {
    @Bindable var viewModel: ScopeListViewModel
    var isListFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                SectionLabel(DestinationCopy.runtimeSection)
                StatusChip.tag(DestinationCopy.experimentalTag)
                    .help(DestinationCopy.experimentalHelp)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.xSmall)
            ForEach(viewModel.destinations) { destination in
                let id = ScopeListViewModel.selectionID(of: destination.id)
                Button {
                    viewModel.selectedScopeID = id
                    isListFocused.wrappedValue = true
                } label: {
                    DestinationRow(destination: destination, isSelected: viewModel.selectedScopeID == id)
                }
                .buttonStyle(.plain)
                .id(id)
                .contextMenu {
                    DestinationContextMenu(destination: destination, viewModel: viewModel)
                }
            }
            AddDestinationButton(viewModel: viewModel)
                .padding(.top, Theme.Spacing.small)
        }
        .confirmationDialog(
            DestinationCopy.removeTitle,
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingDestinationRemoval
        ) { _ in
            Button(DestinationCopy.removeConfirm, role: .destructive) {
                viewModel.confirmRemoval()
            }
        } message: { destination in
            Text(DestinationCopy.removeMessage(destination.copyTargetTitle))
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDestinationRemoval != nil },
            set: { if !$0 { viewModel.pendingDestinationRemoval = nil } }
        )
    }
}

/// One destination row: provider symbol, name, stage, value-missing warning, pending dot and the
/// mono item count.
private struct DestinationRow: View {
    let destination: DestinationModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Image(systemName: destination.provider.symbolName)
                .font(Theme.Typography.monoLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(width: Theme.Layout.destinationSymbolWidth)
                .accessibilityLabel(destination.provider.title)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: destination.title)
                    .font(isSelected ? Theme.Typography.calloutEmphasized : Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(verbatim: destination.subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
            }
            .padding(.vertical, Theme.Spacing.xSmall)
            Spacer(minLength: 0)
            if destination.valueMissingCount > 0 {
                let help = DestinationCopy.valueMissingHelp(destination.valueMissingCount)
                Image(systemName: "exclamationmark.triangle")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.warning)
                    .help(help)
                    .accessibilityLabel(help)
            }
            if destination.pendingCount > 0 {
                SidebarPendingDot()
            }
            SidebarCount(
                value: destination.itemCount,
                help: String(localized: "main.scopes.itemCount", defaultValue: "\(destination.itemCount) items")
            )
        }
        .fxRowBackground(isSelected: isSelected, style: .sidebar)
    }
}

/// "+ Add Destination" as a dashed hairline-strong row.
private struct AddDestinationButton: View {
    let viewModel: ScopeListViewModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        Button {
            viewModel.addDestination()
        } label: {
            Label(DestinationCopy.addDestination, systemImage: "plus")
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
        .help(DestinationCopy.addDestinationHelp)
    }
}

/// Settings… / Export .env… / Remove from FX Vault…: a destination row's context menu, and the
/// destination detail header's actions menu.
struct DestinationContextMenu: View {
    let destination: DestinationModel
    let viewModel: ScopeListViewModel

    var body: some View {
        Button(DestinationCopy.settingsMenu) {
            viewModel.openSettings(destination)
        }
        Button(String(localized: "main.scopes.exportEnv", defaultValue: "Export .env…")) {
            viewModel.exportEnv(destination)
        }
        .disabled(destination.itemCount == 0)
        Divider()
        Button(DestinationCopy.removeMenu, role: .destructive) {
            viewModel.requestRemoval(destination)
        }
    }
}

/// One environment under the selected repository (level 2): struck through when deleted, the
/// rename note under it, and on the right the secrets without a value and the pending dot.
private struct ScopeRow: View {
    let scope: ConfigScopeSummaryModel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if let renamedFrom = scope.renamedFrom {
                SidebarSubline(
                    level: 2,
                    text: String(localized: "main.scopes.renamedFrom", defaultValue: "Renamed from \(renamedFrom)")
                )
            }
        }
    }

    private var row: some View {
        SidebarTreeRow(
            level: 2,
            systemImage: Theme.Symbols.environment,
            title: scope.title,
            isSelected: isSelected,
            isDimmed: scope.isDeleted,
            isStruckThrough: scope.isDeleted,
            accessibilityID: AccessibilityID.Main.environment(scope.title),
            action: action
        ) {
            if scope.valueMissingCount > 0 {
                SidebarCount(
                    value: scope.valueMissingCount,
                    help: String(
                        localized: "main.scopes.valueMissing.help",
                        defaultValue: "\(scope.valueMissingCount) secrets have no value in FX Vault"
                    )
                )
            }
            if scope.hasPendingChanges {
                SidebarPendingDot()
            }
        }
    }
}

/// An environment row's context menu (board Main2-Actions): Rename…, Duplicate Environment…,
/// Share Securely…, Refresh, Revert Changes when there is a change to undo, then Delete
/// Environment…. Export .env… and Deployment Branches… are in the detail's ⋯ More (1.0).
struct ScopeContextMenu: View {
    let scope: ConfigScopeSummaryModel
    let viewModel: ScopeListViewModel
    let detail: RepoDetailViewModel?

    var body: some View {
        Button(String(localized: "main.scopes.rename", defaultValue: "Rename…")) {
            viewModel.rename(scope)
        }
        .disabled(!viewModel.canEdit(scope))
        Button(String(localized: "main.scopes.duplicateEnvironment", defaultValue: "Duplicate Environment…")) {
            viewModel.duplicate(scope)
        }
        .disabled(!viewModel.canEdit(scope))
        Button(PlaceCopy.shareSecurely) {
            viewModel.share(scope)
        }
        .disabled(!viewModel.canExport(scope))
        Button(PlaceCopy.refresh) {
            Task { await detail?.refresh() }
        }
        .disabled(detail?.canRefresh != true)
        if viewModel.canRevert(scope) {
            Button(String(localized: "main.scopes.revert", defaultValue: "Revert Changes")) {
                viewModel.revert(scope)
            }
        }
        Divider()
        Button(String(localized: "main.scopes.deleteEnvironment", defaultValue: "Delete Environment…"), role: .destructive) {
            viewModel.requestDeletion(scope)
        }
        .disabled(!viewModel.canEdit(scope))
    }
}
