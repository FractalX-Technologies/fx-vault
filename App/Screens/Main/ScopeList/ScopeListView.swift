import SwiftUI
import VaultCore
import VaultData

/// Column 2 (§10; mockup Main): the mono SCOPES label, "Repository" then each environment with
/// its pending dot, item count and value-missing warning, the row context menu and the dashed
/// "+ New environment" row. Since v0.8.0: Overview first, the GitHub scopes under BUILD · GITHUB
/// ACTIONS, and the RUNTIME destinations with "+ Add Destination" (experimental).
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
                Button {
                    viewModel.selectOverview()
                    isListFocused = true
                } label: {
                    OverviewRow(isSelected: viewModel.isOverviewSelected)
                }
                .buttonStyle(.plain)
                .id(ScopeListViewModel.overviewID)
                SectionLabel(String(localized: "main.scopes.build", defaultValue: "Build · GitHub Actions"))
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.top, Theme.Spacing.medium)
                    .padding(.bottom, Theme.Spacing.xSmall)
                ForEach(viewModel.scopes) { scope in
                    Button {
                        viewModel.selectedScopeID = scope.id
                        isListFocused = true
                    } label: {
                        ScopeRow(
                            scope: scope,
                            isSelected: viewModel.selectedScopeID == scope.id,
                            isShared: viewModel.space(of: scope) != nil
                        )
                    }
                    .buttonStyle(.plain)
                    .id(scope.id)
                    .contextMenu {
                        ScopeContextMenu(scope: scope, viewModel: viewModel)
                    }
                }
                NewEnvironmentButton(viewModel: viewModel)
                    .padding(.top, Theme.Spacing.small)
                DestinationsSection(viewModel: viewModel, isListFocused: $isListFocused)
                    .padding(.top, Theme.Spacing.medium)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.largePlus)
        }
        .mainColumnKeyboardSelection(
            ids: viewModel.rowIDs,
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

/// "Overview": every name of a stage across GitHub and the destinations (v0.8.0, R8).
private struct OverviewRow: View {
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Image(systemName: "square.grid.2x2")
                .font(Theme.Typography.monoLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            Text(DestinationCopy.overviewTitle)
                .font(isSelected ? Theme.Typography.calloutEmphasized : Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .padding(.vertical, Theme.Spacing.xSmall)
            Spacer(minLength: 0)
        }
        .fxRowBackground(isSelected: isSelected, style: .scope)
        .help(DestinationCopy.overviewHelp)
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
                Circle()
                    .fill(Theme.Colors.brand)
                    .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
                    .help(String(localized: "main.scopes.pending.help", defaultValue: "Pending changes"))
                    .accessibilityLabel(String(localized: "main.scopes.pending.help", defaultValue: "Pending changes"))
            }
            Text(destination.itemCount, format: .number)
                .font(Theme.Typography.monoLabel)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityLabel(String(localized: "main.scopes.itemCount", defaultValue: "\(destination.itemCount) items"))
        }
        .fxRowBackground(isSelected: isSelected, style: .scope)
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

/// One scope row: title (500 when selected, struck through when deleted), the rename note, the
/// value-missing warning, the brand pending dot and the mono item count.
private struct ScopeRow: View {
    let scope: ConfigScopeSummaryModel
    let isSelected: Bool
    /// Shared with teammates (v0.6.0).
    var isShared = false

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
            if isShared {
                Image(systemName: "person.2")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.brand)
                    .help(SpaceCopy.chipHelp)
                    .accessibilityLabel(SpaceCopy.spaceEyebrow)
            }
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

/// Settings… / Rename / Duplicate… / Export .env… / Share… / Delete (or Restore): the row's
/// context menu, and since v0.4.0 the detail header's actions menu for the selected scope.
struct ScopeContextMenu: View {
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
        if viewModel.space(of: scope) != nil {
            Button(SpaceCopy.showMenu) {
                viewModel.showSpace(scope)
            }
        } else {
            Button(SpaceCopy.shareMenu) {
                viewModel.shareWithTeammates(scope)
            }
            .disabled(!viewModel.canShareWithTeammates(scope))
        }
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
