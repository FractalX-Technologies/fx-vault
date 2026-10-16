import SwiftUI
import VaultData

/// SpaceScreen (v0.6.0): a shared scope's History (versions, an item's versions with
/// fingerprints, Reveal after re-authentication, Restore This Value) and Members (add, remove
/// with the secrets to rotate).
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.space`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct SpaceScreen: View {
    @State private var viewModel: SpaceViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: SpaceContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: SpaceViewModel(context: context, dependencies: dependencies))
    }

    /// A screen over an existing view model (previews and snapshots).
    init(viewModel: SpaceViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    SheetHeader(label: SpaceCopy.spaceEyebrow, title: viewModel.scopeName, subtitle: viewModel.subtitle)
                    if let detail = viewModel.detail, !detail.isMember {
                        Banner(.warning, message: SpaceCopy.removedNotice)
                    }
                    if let notice = viewModel.notice {
                        Banner(.info, message: notice)
                    }
                    Picker(selection: $viewModel.tab) {
                        Text(SpaceCopy.historyTab).tag(SpaceViewModel.Tab.history)
                        Text(SpaceCopy.membersTab).tag(SpaceViewModel.Tab.members)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch viewModel.tab {
                    case .history:
                        SpaceHistoryView(viewModel: viewModel)
                    case .members:
                        SpaceMembersView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xxLarge)
            }
            HairlineDivider()
            ConfigSheetFooter(isWorking: viewModel.isWorking) {
                Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: Theme.Layout.editorSheetWidth)
        .fxSheetBackground()
        .task {
            viewModel.load()
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            viewModel.pendingRemoval.map { SpaceCopy.removeTitle($0.name) } ?? "",
            isPresented: Binding(
                get: { viewModel.pendingRemoval != nil },
                set: { if !$0 { viewModel.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(SpaceCopy.remove, role: .destructive) {
                Task { await viewModel.confirmRemoval() }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.pendingRemoval = nil
            }
        } message: {
            Text(SpaceCopy.removeMessage)
        }
    }
}

/// Every version, newest first; the chosen item's versions underneath.
private struct SpaceHistoryView: View {
    let viewModel: SpaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let item = viewModel.selectedItem {
                SpaceItemHistoryView(item: item, viewModel: viewModel)
            }
            ConfigSheetList(viewModel.history) { version in
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    Text(verbatim: SpaceCopy.versionTitle(version))
                        .fxTextStyle(.bodyEmphasized)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(verbatim: [version.authorMacName, version.createdAt.formatted(date: .abbreviated, time: .shortened)]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.mutedText)
                    if !version.reason.isEmpty {
                        Text(verbatim: version.reason)
                            .fxTextStyle(.body)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !version.changedItems.isEmpty {
                        FlowLayout(spacing: Theme.Spacing.xSmall) {
                            ForEach(version.changedItems) { item in
                                Button(item.name) { viewModel.select(item) }
                                    .fxButtonStyle(.ghost)
                                    .help(String(localized: "spaces.history.item.help", defaultValue: "Show the versions of \(item.name)"))
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One item through the versions that changed it: fingerprint, Reveal (re-authentication) and
/// Restore This Value.
private struct SpaceItemHistoryView: View {
    let item: SpaceChangedItemModel
    let viewModel: SpaceViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigSheetField(item.name) {
            ConfigSheetList(viewModel.itemHistory) { entry in
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    HStack(spacing: Theme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                            Text(verbatim: SpaceCopy.itemVersionTitle(entry))
                                .fxTextStyle(.body)
                                .foregroundStyle(Theme.Colors.ink)
                            if let fingerprint = entry.fingerprint {
                                Text(verbatim: fingerprint)
                                    .fxTextStyle(.monoMeta)
                                    .foregroundStyle(Theme.Colors.mutedText)
                                    .help(String(
                                        localized: "spaces.item.fingerprint.help",
                                        defaultValue: "The same on every member's Mac for the same value"
                                    ))
                            }
                        }
                        Spacer(minLength: 0)
                        if !entry.isRemoved {
                            if viewModel.revealed[entry.version] == nil {
                                Button(SpaceCopy.reveal) { Task { await viewModel.reveal(entry.version) } }
                                    .fxButtonStyle(.ghost)
                            } else {
                                Button(SpaceCopy.hide) { viewModel.hide(entry.version) }
                                    .fxButtonStyle(.ghost)
                            }
                            Button(SpaceCopy.restore) { viewModel.restore(entry.version) }
                                .fxButtonStyle(.secondary)
                        }
                    }
                    if let value = viewModel.revealed[entry.version] {
                        Text(verbatim: value)
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if viewModel.pendingReveal == entry.version {
                        HStack(spacing: Theme.Spacing.medium) {
                            FXTextField(
                                label: nil,
                                text: $viewModel.revealPassword,
                                prompt: SpaceCopy.revealPasswordPrompt,
                                isSecure: true
                            )
                            Button(SpaceCopy.reveal) { Task { await viewModel.revealWithPassword() } }
                                .fxButtonStyle(.primary)
                                .disabled(viewModel.revealPassword.isEmpty)
                            Button(String(localized: "common.cancel", defaultValue: "Cancel")) { viewModel.cancelPasswordReveal() }
                                .fxButtonStyle(.ghost)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(String(localized: "spaces.item.close", defaultValue: "Close")) { viewModel.closeItem() }
                .fxButtonStyle(.ghost)
        }
    }
}

/// The members, with Add Teammates and Remove….
private struct SpaceMembersView: View {
    let viewModel: SpaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let detail = viewModel.detail {
                ConfigSheetList(detail.members) { member in
                    HStack(spacing: Theme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                            Text(verbatim: member.name)
                                .fxTextStyle(.bodyEmphasized)
                                .foregroundStyle(Theme.Colors.ink)
                            Text(verbatim: [member.login, member.macName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .fxTextStyle(.monoMeta)
                                .foregroundStyle(Theme.Colors.mutedText)
                            if member.isThisMac {
                                Text(SpaceCopy.thisMac)
                                    .fxTextStyle(.caption)
                                    .foregroundStyle(Theme.Colors.brand)
                            } else if !member.isPaired {
                                Text(SpaceCopy.notPaired)
                                    .fxTextStyle(.caption)
                                    .foregroundStyle(Theme.Colors.warning)
                            }
                        }
                        Spacer(minLength: 0)
                        if !member.isThisMac {
                            Button(SpaceCopy.remove) { viewModel.pendingRemoval = member }
                                .fxButtonStyle(.ghost)
                                .disabled(!viewModel.canChangeMembers)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.medium)
                }
            }
            if !viewModel.addableTeammates.isEmpty {
                Menu(SpaceCopy.addMembers) {
                    ForEach(viewModel.addableTeammates) { teammate in
                        Button(teammate.name) { Task { await viewModel.add([teammate.id]) } }
                    }
                }
                .fixedSize()
                .disabled(!viewModel.canChangeMembers)
            }
        }
    }
}
