import SwiftUI
import VaultCore
import VaultData

/// Column 3 for a Key Vault (v0.8.0; board KV-Place): the header (name, "Key Vault · counts",
/// Refresh's findings as its status line, Copy All, Notes | Table, ⋯ More); the notes, or the
/// Secrets label (Key Vault holds secrets only) with the selection's actions and the table with
/// the Status column; then the footnotes: what Refresh left hidden and how Key Vault names and
/// deletes.
struct DestinationDetailScreen: View {
    @Bindable var viewModel: DestinationDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            DestinationDetailHeader(viewModel: viewModel, main: main)
            switch main.placeViewMode {
            case .notes:
                PlaceNotesView(model: viewModel)
            case .table:
                DestinationDetailControls(viewModel: viewModel)
                ConfigTableView(viewModel: viewModel, emptyMessage: DestinationCopy.tableEmpty) { row in
                    DestinationRowActions(row: row, viewModel: viewModel)
                } selectionMenu: { rows in
                    DestinationSelectionMenu(rows: rows, viewModel: viewModel)
                }
            }
            DestinationFootnotes(viewModel: viewModel)
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .fxPlaceColumn()
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .errorAlert($viewModel.alert)
        .deleteItemsSheet(viewModel.deletionSheet) {
            viewModel.pendingDeletion = nil
        } confirm: {
            viewModel.confirmDeletion()
        }
        .modifier(ItemCopyConflictDialog(viewModel: viewModel))
    }
}

/// The vault's name, its subline, Refreshing… while `az` reads it, the Experimental tag of a
/// runtime destination, Copy All, and ⋯ More: New Secret (a Key Vault holds secrets only), Paste
/// Multiple…, Import .env…, Copy All, Copy To, Refresh, Delete Selected…, then the vault's own menu.
private struct DestinationDetailHeader: View {
    let viewModel: DestinationDetailViewModel
    let main: MainViewModel

    var body: some View {
        let destination = viewModel.destination
        PlaceHeader(title: destination?.title ?? "", subline: viewModel.subline) {
            if viewModel.isRefreshing {
                PlaceRefreshingLine()
            } else if let refresh = viewModel.refresh, let destination {
                DestinationRefreshLine(refresh: refresh, provider: destination.provider, onReview: viewModel.reviewDifferences)
            }
        } accessories: {
            if destination?.repositoryID != nil {
                StatusChip.tag(DestinationCopy.experimentalTag)
                    .help(DestinationCopy.experimentalHelp)
            }
            CopyAllButton(isEnabled: viewModel.canCopyAll) {
                viewModel.copyAll()
            }
            PlaceViewModePicker(main: main)
        } moreItems: {
            PlaceItemMoreItems(viewModel: viewModel, kinds: [.secret]) {
                CopyAllMenuItem(isEnabled: viewModel.canCopyAll) {
                    viewModel.copyAll()
                }
                Divider()
                CopyToMenu(title: PlaceCopy.copyTo, rows: viewModel.placeCopyRows, viewModel: viewModel)
                Button(PlaceCopy.refresh) {
                    viewModel.refreshNow()
                }
                .disabled(viewModel.isRefreshing || !main.isOnline)
                .help(main.networkHelp(DestinationCopy.refreshHelp))
            }
            if let destination {
                Divider()
                if destination.repositoryID == nil {
                    KeyVaultContextMenu(vault: destination, sidebar: main.sidebar)
                } else if let scopeList = main.scopeList {
                    DestinationContextMenu(destination: destination, viewModel: scopeList)
                }
            }
        }
    }
}

/// Refresh's findings in the header (board KV-Place): "2 changed in Key Vault · Review" as a
/// repository's drift line, or that nothing changed.
private struct DestinationRefreshLine: View {
    let refresh: DestinationRefreshPresentationModel
    let provider: DestinationProvider
    let onReview: () -> Void

    var body: some View {
        if refresh.findings.isEmpty {
            Text(DestinationCopy.noDrift)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
        } else {
            DriftBannerView(
                message: DestinationCopy.changed(refresh.findings.count, provider: provider),
                reviewHelp: DestinationCopy.reviewHelp(provider: provider),
                onReview: onReview
            )
        }
    }
}

/// Under the table (board KV-Place): the secrets Refresh found but FX Vault can't use, one line
/// per reason with their names as help, then how Key Vault names and deletes.
private struct DestinationFootnotes: View {
    let viewModel: DestinationDetailViewModel

    var body: some View {
        if let destination = viewModel.destination {
            VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                ForEach(viewModel.refresh?.hiddenNotes ?? []) { note in
                    Label {
                        Text(note.text)
                    } icon: {
                        // A name FX Vault can't use never syncs: a warning, not a quiet lock.
                        Image(systemName: note.isWarning ? "exclamationmark.triangle" : "lock")
                            .foregroundStyle(note.isWarning ? Theme.Colors.warning : Theme.Colors.subtleText)
                    }
                    .labelStyle(.titleAndIcon)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .help(note.names.joined(separator: ", "))
                }
                Text(DestinationCopy.rules(for: destination.provider))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.large)
        }
    }
}

/// SECRETS · n (the provider holds secrets only), with the selection's actions while several
/// rows are selected.
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
        if viewModel.showsSelectionActions {
            let rows = viewModel.selectedRows
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Text(String(localized: "main.detail.selection.count", defaultValue: "\(rows.count) selected"))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                CopyToMenu(
                    title: PlaceCopy.copyTo,
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
            CopyToMenu(title: PlaceCopy.copyTo, rows: [row], viewModel: viewModel)
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
