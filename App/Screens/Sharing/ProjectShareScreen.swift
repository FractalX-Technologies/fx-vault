import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// Share Project (v0.9.0): what to share → send to → Touch ID or password → share or save. See
/// ``ProjectShareViewModel`` for the rules.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.shareExport`, from Share › File…, the File menu's Share Project…, a repository's or
/// folder's Share as File… and the Overview's Share Stage….
struct ProjectShareScreen: View {
    @State private var viewModel: ProjectShareViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ShareExportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: ProjectShareViewModel(context: context, dependencies: dependencies))
    }

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(viewModel: ProjectShareViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.share,
                title: ProjectShareCopy.title,
                subtitle: ProjectShareCopy.subtitle
            )
            content
            Spacer(minLength: 0)
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.shareSheetWidth)
        .frame(minHeight: Theme.Layout.shareSheetMinHeight)
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            ProjectShareCopy.includeProductionTitle,
            isPresented: Binding(
                get: { viewModel.pendingProductionStage != nil },
                set: { if !$0 { viewModel.cancelProductionStage() } }
            ),
            titleVisibility: .visible
        ) {
            Button(ProjectShareCopy.includeProduction) {
                viewModel.confirmProductionStage()
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.cancelProductionStage()
            }
        } message: {
            Text(ProjectShareCopy.includeProductionMessage(viewModel.pendingProductionStage?.name ?? ""))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .contents:
            ProjectShareContentsStep(viewModel: viewModel)
        case .sendTo:
            ProjectShareSendToStep(viewModel: viewModel)
        case .authenticate:
            ShareReauthView(
                model: viewModel.reauth,
                message: ProjectShareCopy.reauthMessage,
                onTouchID: { await viewModel.authenticateWithTouchID() },
                onPassword: { await viewModel.authenticateWithPassword() }
            )
        case .creating:
            NearbyProgressRow(text: ProjectShareCopy.creating)
        case .done:
            ProjectShareDoneStep(viewModel: viewModel)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            if viewModel.step == .sendTo || viewModel.step == .authenticate {
                Button(ProjectShareCopy.back) {
                    viewModel.back()
                }
                .fxButtonStyle(.secondary, size: .large)
            }
            Spacer()
            if viewModel.step == .done {
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                switch viewModel.step {
                case .contents:
                    Button(ProjectShareCopy.continueTitle) {
                        viewModel.continueToSendTo()
                    }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canContinue)
                case .sendTo, .creating:
                    Button(ProjectShareCopy.create) {
                        Task { await viewModel.requestCreate() }
                    }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCreate)
                case .authenticate, .done:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Step 1: what to share

private struct ProjectShareContentsStep: View {
    let viewModel: ProjectShareViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            repositories
            stages
            if let tree = viewModel.tree, !tree.roots.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    HStack {
                        SectionLabel(ProjectShareCopy.adjust)
                        Spacer()
                        if !viewModel.chosenRepositoryIDs.isEmpty {
                            Toggle(
                                ProjectShareCopy.repositoryLevel,
                                isOn: Binding(
                                    get: { viewModel.includesRepositoryLevel },
                                    set: { viewModel.setIncludesRepositoryLevel($0) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                        }
                    }
                    ShareScopeTreeView(tree: tree, expandsRoots: viewModel.chosenRepositoryIDs.count == 1) { checked, node in
                        viewModel.setChecked(checked, for: node)
                    }
                    .id(viewModel.chosenRepositoryIDs)
                }
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.shareListMinHeight)
            }
            if let preview = viewModel.preview {
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    Text(ProjectShareCopy.summary(preview))
                        .fxTextStyle(.statusLine)
                        .foregroundStyle(Theme.Colors.subtleText)
                    if !preview.valueMissingNames.isEmpty {
                        ShareNoteView(
                            systemImage: "key.slash",
                            text: ProjectShareCopy.valueMissing(preview.valueMissingNames.count),
                            tint: Theme.Colors.warning
                        )
                        .help(preview.valueMissingNames.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(ProjectShareCopy.repositories)
            FlowLayout(spacing: Theme.Spacing.small) {
                ForEach(viewModel.chosenRepositories) { repository in
                    ProjectShareRepositoryChip(title: repository.fullName) {
                        Task { await viewModel.removeRepository(repository.id) }
                    }
                }
                if !viewModel.addableRepositories.isEmpty {
                    Menu {
                        ForEach(viewModel.addableRepositories) { repository in
                            Button(repository.fullName) {
                                Task { await viewModel.addRepository(repository.id) }
                            }
                        }
                    } label: {
                        Label(ProjectShareCopy.addRepository, systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .fxTextStyle(.callout)
                }
            }
            if viewModel.chosenRepositoryIDs.isEmpty, !viewModel.isLoading {
                Text(ProjectShareCopy.noRepositories)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
        }
    }

    @ViewBuilder
    private var stages: some View {
        if !viewModel.chosenRepositoryIDs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(ProjectShareCopy.stages)
                if viewModel.stageOptions.isEmpty {
                    Text(ProjectShareCopy.noStages)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                } else {
                    FlowLayout(spacing: Theme.Spacing.medium) {
                        ForEach(viewModel.stageOptions) { option in
                            HStack(spacing: Theme.Spacing.xSmall) {
                                Toggle(
                                    option.name,
                                    isOn: Binding(
                                        get: { viewModel.isStageChosen(option) },
                                        set: { viewModel.setStage(option, chosen: $0) }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .fxTextStyle(.monoName)
                                .foregroundStyle(Theme.Colors.ink)
                                if option.isProduction {
                                    StatusChip(title: ProjectShareCopy.productionChip, tone: .warning)
                                        .help(ProjectShareCopy.productionHelp)
                                }
                            }
                            .frame(minHeight: Theme.Layout.scopeRowHeight)
                        }
                    }
                    Text(ProjectShareCopy.stagesHelp)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A chosen repository with its remove button.
private struct ProjectShareRepositoryChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Image(systemName: "shippingbox")
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            .buttonStyle(.plain)
            .help(ProjectShareCopy.removeRepository)
            .accessibilityLabel(ProjectShareCopy.removeRepository)
        }
        .padding(.vertical, Theme.Spacing.xSmall)
        .padding(.horizontal, Theme.Spacing.small)
        .fxCardBackground(.container)
    }
}

// MARK: - Step 2: send to

private struct ProjectShareSendToStep: View {
    let viewModel: ProjectShareViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let preview = viewModel.preview {
                Text(ProjectShareCopy.summary(preview))
                    .fxTextStyle(.statusLine)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            ProjectShareOption(
                title: ProjectShareCopy.teammatesOption,
                message: ProjectShareCopy.teammatesHelp,
                isSelected: viewModel.protection == .teammates,
                isEnabled: !viewModel.teammates.isEmpty
            ) {
                viewModel.setProtection(.teammates)
            } content: {
                teammates
            }
            ProjectShareOption(
                title: ProjectShareCopy.passphraseOption,
                message: viewModel.isPassphraseAllowed
                    ? ProjectShareCopy.passphraseHelp
                    : ProjectShareCopy.passphraseBlocked(viewModel.productionPlaces),
                isSelected: viewModel.protection == .passphrase,
                isEnabled: viewModel.isPassphraseAllowed
            ) {
                viewModel.setProtection(.passphrase)
            } content: {
                EmptyView()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.medium) {
                    SectionLabel(ProjectShareCopy.expiry)
                    SegmentedPill(
                        selection: $viewModel.expiry,
                        segments: ShareExpiryChoice.allCases.map {
                            SegmentedPill.Segment(value: $0, title: ProjectShareCopy.expiryChoice($0))
                        },
                        accessibilityLabel: ProjectShareCopy.expiry
                    )
                    .fixedSize()
                }
                Text(viewModel.protection == .passphrase ? ProjectShareCopy.expiryPassphraseNote : ProjectShareCopy.expiryTeammatesNote)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var teammates: some View {
        if viewModel.teammates.isEmpty {
            Text(ProjectShareCopy.noTeammates)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        } else if viewModel.protection == .teammates {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                if viewModel.teammates.count > Self.unscrolledTeammates {
                    ScrollView {
                        teammateRows
                    }
                    .frame(height: Theme.Layout.shareListMinHeight)
                } else {
                    teammateRows
                }
                Text(ProjectShareCopy.teammateLimit(chosen: viewModel.chosenTeammateIDs.count))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
        }
    }

    /// Up to this many teammates are listed without a scroll view.
    private static let unscrolledTeammates = 6

    private var teammateRows: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        ForEach(viewModel.teammates) { teammate in
                            HStack(spacing: Theme.Spacing.small) {
                                Toggle(
                                    teammate.name,
                                    isOn: Binding(
                                        get: { viewModel.isTeammateChosen(teammate) },
                                        set: { viewModel.setTeammate(teammate, chosen: $0) }
                                    )
                                )
                                .toggleStyle(.checkbox)
                                .fxTextStyle(.callout)
                                .foregroundStyle(Theme.Colors.ink)
                                .disabled(!viewModel.isTeammateChosen(teammate) && !viewModel.canChooseMoreTeammates)
                                if teammate.pairedVia == .remote {
                                    Text(ProjectShareCopy.pairedRemotely)
                                        .fxTextStyle(.caption)
                                        .foregroundStyle(Theme.Colors.subtleText)
                                }
                                Spacer(minLength: 0)
                            }
                        }
        }
    }
}

/// One way to protect the file: a radio row with its explanation and, when selected, its options.
private struct ProjectShareOption<Content: View>: View {
    let title: String
    let message: String
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button(action: onSelect) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.Colors.brand : Theme.Colors.subtleText)
                        .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(title)
                            .fxTextStyle(.bodyEmphasized)
                            .foregroundStyle(Theme.Colors.ink)
                            .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
                        // A disabled option says why at full strength.
                        Text(message)
                            .fxTextStyle(.caption)
                            .foregroundStyle(isEnabled ? Theme.Colors.mutedText : Theme.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            content()
                .padding(.leading, Theme.Spacing.xLarge)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCardBackground(.container)
    }
}

// MARK: - Step 4: deliver

private struct ProjectShareDoneStep: View {
    let viewModel: ProjectShareViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let passphrase = viewModel.passphrase {
                PassphraseView(passphrase: passphrase) {
                    viewModel.copyPassphrase()
                }
                SheetCallout(
                    systemImage: "exclamationmark.bubble",
                    tint: Theme.Colors.warning,
                    text: ProjectShareCopy.passphraseHint
                )
                FXCheckboxRow(
                    title: String(localized: "shareExport.passphrase.saved", defaultValue: "I've saved it"),
                    isOn: Binding(
                        get: { viewModel.hasSavedPassphrase },
                        set: { viewModel.hasSavedPassphrase = $0 }
                    )
                )
            } else {
                SheetCallout(
                    systemImage: "lock.shield",
                    tint: Theme.Colors.success,
                    text: ProjectShareCopy.sealedFor(viewModel.sealedForNames)
                )
                if let expiresAt = viewModel.expiresAt {
                    Text(ProjectShareCopy.teammatesDelivery(expiresAt: expiresAt))
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if viewModel.isPassphraseFile, let expiresAt = viewModel.expiresAt {
                Text(ProjectShareCopy.expires(expiresAt))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    viewModel.shareFile()
                } label: {
                    Label(ProjectShareCopy.share, systemImage: "square.and.arrow.up")
                }
                .fxButtonStyle(.primary)
                .background(ShareDeliveryAnchor(delivery: viewModel.delivery))
                Button {
                    Task { await viewModel.saveToFile() }
                } label: {
                    Label(ProjectShareCopy.save, systemImage: "square.and.arrow.down")
                }
                .fxButtonStyle(.secondary)
                if viewModel.isDelivering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(!viewModel.canDeliver)
            Text(verbatim: viewModel.fileName)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.subtleText)
            if let notice = viewModel.notice {
                ShareNoteView(systemImage: "checkmark.circle", text: notice, tint: Theme.Colors.success)
            }
        }
    }
}
