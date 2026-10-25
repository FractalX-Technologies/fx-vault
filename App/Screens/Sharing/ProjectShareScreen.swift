import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// Share Project (v0.9.0): what to share → send to → Touch ID or password → share or save. See
/// ``ProjectShareViewModel`` for the rules.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.shareExport`, from Share › File…, the File menu's Share Project…, a repository's or
/// folder's Share as File….
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
                model: viewModel.activeReauth,
                message: viewModel.includesProduction ? ProjectShareCopy.productionReauthMessage : ProjectShareCopy.reauthMessage,
                onTouchID: { await viewModel.authenticateWithTouchID() },
                onPassword: { await viewModel.authenticateWithPassword() }
            )
        case .creating:
            SheetProgressRow(text: ProjectShareCopy.creating)
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
                    .accessibilityIdentifier(AccessibilityID.Share.continueToSendTo)
                case .sendTo, .creating:
                    Button(ProjectShareCopy.create) {
                        Task { await viewModel.requestCreate() }
                    }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCreate)
                    .accessibilityIdentifier(AccessibilityID.Share.create)
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
                                .accessibilityIdentifier(AccessibilityID.Share.stage(option.name))
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
            Image(systemName: Theme.Symbols.repository)
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(ProjectShareCopy.passphraseOption)
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                Text(ProjectShareCopy.passphraseHelp)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.includesProduction {
                    ShareNoteView(
                        systemImage: "exclamationmark.triangle",
                        text: ProjectShareCopy.productionIncluded(viewModel.productionPlaces),
                        tint: Theme.Colors.warning
                    )
                    .accessibilityIdentifier(AccessibilityID.Share.productionNote)
                }
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCardBackground(.container)
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
                Text(ProjectShareCopy.expiryPassphraseNote)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .accessibilityIdentifier(AccessibilityID.Share.passphrase)
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
                .accessibilityIdentifier(AccessibilityID.Share.passphraseSaved)
            }
            if let expiresAt = viewModel.expiresAt {
                Text(ProjectShareCopy.expires(expiresAt))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            HStack(spacing: Theme.Spacing.small) {
                if viewModel.canSendWithAirDrop {
                    Button {
                        viewModel.sendWithAirDrop()
                    } label: {
                        Label(ProjectShareCopy.airDrop, systemImage: "dot.radiowaves.up.forward")
                    }
                    .fxButtonStyle(.primary)
                    .accessibilityIdentifier(AccessibilityID.Share.airDrop)
                }
                Button {
                    viewModel.shareFile()
                } label: {
                    Label(ProjectShareCopy.share, systemImage: "square.and.arrow.up")
                }
                .fxButtonStyle(viewModel.canSendWithAirDrop ? .secondary : .primary)
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
