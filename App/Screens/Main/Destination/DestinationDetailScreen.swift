import SwiftUI
import VaultCore
import VaultData

/// Column 3 for a runtime destination (v0.8.0, canvas board 3): DESTINATION · RUNTIME and the
/// destination's name with its provider, stage and Experimental tags; Refresh and the actions; a
/// card with the stage, the target and the provider's rules; the Refresh banner; the Secrets
/// label (Key Vault holds secrets only) with the add actions; and the table with the Status column.
struct DestinationDetailScreen: View {
    @Bindable var viewModel: DestinationDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
            if let banner = main.connectivityBanner {
                MainConnectivityBanner(banner: banner, main: main)
            }
            DestinationDetailHeader(viewModel: viewModel, main: main)
            if let destination = viewModel.destination {
                DestinationInfoCard(destination: destination)
            }
            DestinationRefreshBanner(viewModel: viewModel)
            DestinationDetailControls(viewModel: viewModel)
            ConfigTableView(viewModel: viewModel, emptyMessage: DestinationCopy.tableEmpty) { row in
                DestinationRowActions(row: row, viewModel: viewModel)
            } selectionMenu: { rows in
                DestinationSelectionMenu(rows: rows, viewModel: viewModel)
            }
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxLargePlus)
        .padding(.vertical, Theme.Spacing.xLargePlus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            FolderCopy.deleteItemsTitle(count: viewModel.pendingDeletion?.count ?? 0),
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { rows in
            Button(FolderCopy.deleteItemsConfirm(count: rows.count), role: .destructive) {
                viewModel.confirmDeletion()
            }
        } message: { _ in
            Text(DestinationCopy.deleteItemsMessage)
        }
        .modifier(ItemCopyConflictDialog(viewModel: viewModel))
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeletion != nil },
            set: { if !$0 { viewModel.pendingDeletion = nil } }
        )
    }
}

/// The eyebrow, the name in the large title with its tags, then Refresh and the actions menu.
private struct DestinationDetailHeader: View {
    let viewModel: DestinationDetailViewModel
    let main: MainViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
                details
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                details
                actions
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            SectionLabel(DestinationCopy.eyebrow)
            Text(verbatim: viewModel.destination?.title ?? "")
                .fxTextStyle(.largeTitle)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let destination = viewModel.destination {
                HStack(spacing: Theme.Spacing.small) {
                    StatusChip.tag(destination.provider.title)
                    StatusChip.tag(destination.stage ?? DestinationCopy.noStage)
                    StatusChip.tag(DestinationCopy.experimentalTag)
                        .help(DestinationCopy.experimentalHelp)
                    Text(destination.provider.accessDescription)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .lineLimit(1)
                }
                .padding(.top, Theme.Spacing.xSmall)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.large) {
            Button {
                viewModel.refreshNow()
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(DestinationCopy.refresh)
                }
            }
            .fxButtonStyle(.secondary)
            .disabled(viewModel.isRefreshing || !main.isOnline)
            .help(main.networkHelp(DestinationCopy.refreshHelp))
            if let destination = viewModel.destination {
                Menu {
                    if destination.repositoryID == nil {
                        KeyVaultContextMenu(vault: destination, sidebar: main.sidebar)
                    } else if let scopeList = main.scopeList {
                        DestinationContextMenu(destination: destination, viewModel: scopeList)
                    }
                } label: {
                    Label(String(localized: "main.detail.actions", defaultValue: "Actions"), systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fxIconButtonStyle()
                .help(String(localized: "main.detail.actions", defaultValue: "Actions"))
            }
        }
    }
}

/// STAGE, TARGET and the provider's rules in one card.
private struct DestinationInfoCard: View {
    let destination: DestinationModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                fields
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                fields
            }
        }
        .padding(Theme.Spacing.largePlus)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCardBackground(.container)
    }

    @ViewBuilder
    private var fields: some View {
        field(DestinationCopy.stageLabel, value: destination.stage ?? DestinationCopy.noStage, isMono: false)
        field(DestinationCopy.targetLabel, value: destination.targetDescription, isMono: true)
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            SectionLabel(DestinationCopy.rulesLabel)
            Text(DestinationCopy.rules(for: destination.provider))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, value: String, isMono: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            SectionLabel(label)
            Text(verbatim: value)
                .font(isMono ? Theme.Typography.monoMeta : Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// What the last Refresh found: changes to review, items FX Vault cannot use, or nothing.
private struct DestinationRefreshBanner: View {
    let viewModel: DestinationDetailViewModel

    var body: some View {
        if let refresh = viewModel.refresh, let destination = viewModel.destination {
            if !refresh.findings.isEmpty {
                Banner(
                    .info,
                    message: DestinationCopy.driftBanner(refresh.findings.count, provider: destination.provider),
                    action: .init(title: DestinationCopy.review) { viewModel.reviewDifferences() }
                )
            } else {
                Banner(.info, message: DestinationCopy.noDrift, systemImage: "checkmark.circle")
            }
            if !refresh.unusable.isEmpty {
                Banner(.warning, message: DestinationCopy.unusableBanner(refresh.unusable.count), systemImage: "exclamationmark.triangle")
                    .help(refresh.unusable.map(\.remoteName).joined(separator: ", "))
            }
        }
    }
}

/// The pill (or SECRETS · n where the provider holds secrets only) with the add actions, or the
/// selection's actions while several rows are selected.
private struct DestinationDetailControls: View {
    @Bindable var viewModel: DestinationDetailViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.medium) {
                kinds
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                kinds
                actions
            }
        }
    }

    private var kinds: some View {
        SectionLabel(String(
            localized: "destination.detail.secretsOnly",
            defaultValue: "Secrets · \(viewModel.count(of: .secret))"
        ))
    }

    @ViewBuilder
    private var actions: some View {
        if viewModel.selection.count > 1 {
            let rows = viewModel.selectedRows
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Text(String(localized: "main.detail.selection.count", defaultValue: "\(rows.count) selected"))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                CopyToMenu(
                    title: String(localized: "main.detail.selection.copyTo", defaultValue: "Copy To"),
                    rows: rows,
                    viewModel: viewModel,
                    showsChevron: true
                )
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fxButtonStyle(.outline)
                Button(String(localized: "main.table.delete", defaultValue: "Delete…")) {
                    viewModel.requestDeletion(of: rows)
                }
                .fxButtonStyle(.outline)
                Button {
                    viewModel.clearSelection()
                } label: {
                    Label(String(localized: "main.detail.selection.clear", defaultValue: "Deselect"), systemImage: "xmark")
                }
                .fxIconButtonStyle()
                .help(String(localized: "main.detail.selection.clear", defaultValue: "Deselect"))
            }
            .fixedSize()
        } else {
            ConfigAddActions(viewModel: viewModel)
        }
    }
}

/// Reveal, Copy Value, Edit… (or Fill Value…), Copy To, the linked copies, Push on Next Sync,
/// Mark as Public, Revert and Delete… for one destination row.
private struct DestinationRowActions: View {
    let row: ConfigRowModel
    let viewModel: DestinationDetailViewModel

    var body: some View {
        if row.hasValue {
            if row.kind == .secret {
                Button(viewModel.isRevealed(row.id) ? MaskedValueCell.hideTitle : MaskedValueCell.revealTitle) {
                    viewModel.toggleReveal(row.id)
                }
            }
            Button(String(localized: "main.table.copy", defaultValue: "Copy Value")) {
                viewModel.copy(row.id)
            }
            Divider()
        }
        if !row.isDeleted {
            if row.hasValue {
                Button(String(localized: "main.table.edit", defaultValue: "Edit…")) {
                    viewModel.edit(row)
                }
            } else {
                Button(DestinationCopy.fillValue) {
                    viewModel.fill(row)
                }
            }
            CopyToMenu(title: String(localized: "main.table.copyTo", defaultValue: "Copy To"), rows: [row], viewModel: viewModel)
        }
        if row.isLinked {
            Button(String(localized: "main.table.linked.show", defaultValue: "Show Linked Copies")) {
                viewModel.showLinkedCopies(of: row)
            }
            Button(String(localized: "main.table.linked.unlink", defaultValue: "Unlink")) {
                viewModel.unlink(row)
            }
        }
        if row.canPushOnNextSync {
            Button(String(localized: "main.table.pushOnNextSync", defaultValue: "Push on Next Sync")) {
                viewModel.pushOnNextSync([row])
            }
        }
        if viewModel.canRevert(row) {
            Button(String(localized: "main.table.revert", defaultValue: "Revert")) {
                viewModel.revert([row])
            }
        }
        if !row.isDeleted {
            Divider()
            Button(String(localized: "main.table.delete", defaultValue: "Delete…"), role: .destructive) {
                viewModel.requestDeletion(of: [row])
            }
        }
    }
}

/// Copy To, Push on Next Sync, Revert and Delete… for several destination rows.
private struct DestinationSelectionMenu: View {
    let rows: [ConfigRowModel]
    let viewModel: DestinationDetailViewModel

    var body: some View {
        CopyToMenu(
            title: String(localized: "main.table.several.copyTo", defaultValue: "Copy \(rows.count) Items To"),
            rows: rows,
            viewModel: viewModel
        )
        let pushable = rows.filter(\.canPushOnNextSync)
        if !pushable.isEmpty {
            Button(String(localized: "main.table.several.push", defaultValue: "Push \(pushable.count) on Next Sync")) {
                viewModel.pushOnNextSync(pushable)
            }
        }
        let revertable = rows.filter(viewModel.canRevert)
        if !revertable.isEmpty {
            Button(String(localized: "main.table.several.revert", defaultValue: "Revert \(revertable.count)")) {
                viewModel.revert(revertable)
            }
        }
        Divider()
        Button(String(localized: "main.table.several.delete", defaultValue: "Delete \(rows.count)…"), role: .destructive) {
            viewModel.requestDeletion(of: rows)
        }
    }
}

extension DestinationModel {
    /// The target as the info card shows it: the vault, and its tenant when one is set.
    var targetDescription: String {
        switch target {
        case .azureKeyVault(let vaultName, let tenantID):
            [vaultName, tenantID].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
