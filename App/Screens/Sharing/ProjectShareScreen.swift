import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// Share Securely (boards Share-Pick, Share-Passphrase): what to share, Touch ID or the password,
/// then the passphrase and the file (``ProjectShareViewModel``). UI feature contract entry view
/// (ARCHITECTURE.md): `MainScreen` presents it for `MainSheet.shareExport` (Share › File…, the File
/// menu's Share Project…, a place's or a row menu's Share Securely…).
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
        DialogSheet(
            title: isDone ? ProjectShareCopy.doneTitle : ProjectShareCopy.title(viewModel.subjectName),
            subtitle: isDone ? nil : ProjectShareCopy.subtitle,
            footerNote: footerNote,
            isWorking: viewModel.isDelivering
        ) {
            content
        } actions: {
            actions
        }
        .frame(width: isDone ? Theme.Layout.sharePassphraseWidth : Theme.Layout.sharePickWidth)
        .frame(maxHeight: Theme.Layout.shareSheetMaxHeight)
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .errorAlert($viewModel.alert)
    }

    private var isDone: Bool {
        viewModel.step == .done
    }

    /// The file's counts while choosing (board Share-Pick); when FX Vault refuses the file once
    /// it is made (board Share-Passphrase).
    private var footerNote: String? {
        if isDone {
            return viewModel.expiresAt.map(ProjectShareCopy.refusedAfter)
        }
        return viewModel.counts.map(ProjectShareCopy.counts).flatMap { $0.isEmpty ? nil : $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .contents:
            ProjectShareContentsStep(viewModel: viewModel)
        case .authenticate:
            ReauthView(
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

    @ViewBuilder
    private var actions: some View {
        switch viewModel.step {
        case .contents, .creating:
            cancelButton
            Button {
                Task { await viewModel.requestCreate() }
            } label: {
                if viewModel.activeReauth.canUseTouchID {
                    Label(ProjectShareCopy.createFileWithTouchID, systemImage: "touchid")
                } else {
                    Text(ProjectShareCopy.createFile)
                }
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canCreate)
            .accessibilityIdentifier(AccessibilityID.Share.create)
        case .authenticate:
            Button(ProjectShareCopy.back) {
                viewModel.back()
            }
            .fxButtonStyle(.outline, size: .dialog)
            cancelButton
        case .done:
            ProjectShareDeliveryButtons(viewModel: viewModel)
            Button(String(localized: "common.done", defaultValue: "Done")) {
                dismiss()
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
            dismiss()
        }
        .fxButtonStyle(.outline, size: .dialog)
        .keyboardShortcut(.cancelAction)
    }
}

// MARK: - What to share (board Share-Pick)

/// The repositories, the repository level and stages across them, the tree, the notes and the
/// expiry.
private struct ProjectShareContentsStep: View {
    let viewModel: ProjectShareViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        DialogFormRow(ProjectShareCopy.repositories) {
            FlowLayout(spacing: Theme.Spacing.smallMinus) {
                ForEach(viewModel.chosenRepositories) { repository in
                    DialogTokenChip(title: repository.fullName, removeLabel: ProjectShareCopy.removeRepository) {
                        Task { await viewModel.removeRepository(repository.id) }
                    }
                }
                if !viewModel.addableRepositories.isEmpty {
                    addRepositoryMenu
                }
            }
            if viewModel.chosenRepositoryIDs.isEmpty, !viewModel.isLoading {
                ConfigEditorNoteView(note: .info(ProjectShareCopy.noRepositories), style: .dialog)
            }
        }
        if !viewModel.chosenRepositoryIDs.isEmpty {
            DialogFormRow(ProjectShareCopy.stages) {
                stages
            }
        }
        if let tree = viewModel.tree, !tree.roots.isEmpty {
            ShareScopeTreeView(tree: tree, expandsRoots: viewModel.chosenRepositoryIDs.count == 1) { checked, node in
                viewModel.setChecked(checked, for: node)
            }
            .id(viewModel.chosenRepositoryIDs)
        } else if viewModel.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
        notes
        HStack(spacing: Theme.Spacing.medium) {
            Text(ProjectShareCopy.expiry)
                .fxTextStyle(.formLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            SegmentedPill(
                selection: $viewModel.expiry,
                segments: ShareExpiryChoice.allCases.map {
                    SegmentedPill.Segment(value: $0, title: ProjectShareCopy.expiryChoice($0))
                },
                accessibilityLabel: ProjectShareCopy.expiry,
                size: .small
            )
            .fixedSize()
        }
    }

    /// The repositories that can still be added, as the dashed add chip of a dialog form.
    private var addRepositoryMenu: some View {
        Menu {
            ForEach(viewModel.addableRepositories) { repository in
                Button(repository.fullName) {
                    Task { await viewModel.addRepository(repository.id) }
                }
            }
        } label: {
            DialogAddChipLabel(title: ProjectShareCopy.addRepository)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// The repository level and each stage, for every chosen repository; production carries its
    /// tag and asks for Touch ID when ticked.
    @ViewBuilder
    private var stages: some View {
        FlowLayout(spacing: Theme.Spacing.medium) {
            Toggle(
                ProjectShareCopy.repositoryLevelPlace,
                isOn: Binding(
                    get: { viewModel.includesRepositoryLevel },
                    set: { viewModel.setIncludesRepositoryLevel($0) }
                )
            )
            .toggleStyle(.checkbox)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.ink)
            .frame(minHeight: Theme.Layout.dialogFieldHeight)
            ForEach(viewModel.stageOptions) { option in
                HStack(spacing: Theme.Spacing.smallMinus) {
                    Toggle(
                        option.name,
                        isOn: Binding(
                            get: { viewModel.isStageChosen(option) },
                            set: { viewModel.setStage(option, chosen: $0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityIdentifier(AccessibilityID.Share.stage(option.name))
                    if option.isProduction {
                        StatusChip.dialogTag(ProjectShareCopy.productionTag)
                            .accessibilityHidden(true)
                        Image(systemName: "lock")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .help(ProjectShareCopy.productionHelp)
                            .accessibilityLabel(Text(ProjectShareCopy.productionHelp))
                    }
                }
                .frame(minHeight: Theme.Layout.dialogFieldHeight)
            }
        }
        ConfigEditorNoteView(
            note: .info(viewModel.stageOptions.isEmpty ? ProjectShareCopy.noStages : ProjectShareCopy.stagesHelp),
            style: .dialog
        )
    }

    /// Production leaving the Mac and secrets that travel by name only.
    @ViewBuilder
    private var notes: some View {
        if viewModel.includesProduction {
            ConfigEditorNoteView(note: .info(ProjectShareCopy.productionIncluded(viewModel.productionPlaces)), style: .dialog)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Share.productionNote)
        }
        if let missing = viewModel.preview?.valueMissingNames, !missing.isEmpty {
            ConfigEditorNoteView(note: .warning(ProjectShareCopy.valueMissing(missing.count)), style: .dialog)
                .help(missing.joined(separator: "\n"))
        }
    }
}

// MARK: - The passphrase (board Share-Passphrase)

/// The file, the passphrase shown once with Copy, the clipboard line, how to send both, and
/// "I've saved it", which unlocks the delivery buttons.
private struct ProjectShareDoneStep: View {
    let viewModel: ProjectShareViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: "doc")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            Text(verbatim: viewModel.fileName)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let counts = viewModel.counts.map(ProjectShareCopy.counts), !counts.isEmpty {
                Text(verbatim: "· \(counts)")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        if let passphrase = viewModel.passphrase {
            ProjectSharePassphraseBox(passphrase: passphrase) {
                viewModel.copyPassphrase()
            }
            Text(verbatim: viewModel.passphraseNote)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            Text(ProjectShareCopy.sendApart)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            FXCheckboxRow(
                title: String(localized: "shareExport.passphrase.saved", defaultValue: "I've saved it"),
                isOn: Binding(
                    get: { viewModel.hasSavedPassphrase },
                    set: { viewModel.hasSavedPassphrase = $0 }
                ),
                isBoxed: false
            )
            .accessibilityIdentifier(AccessibilityID.Share.passphraseSaved)
        }
    }
}

/// The six words on one line in the grey box, 17 pt mono, with Copy. Hidden from screen
/// capture.
private struct ProjectSharePassphraseBox: View {
    let passphrase: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Text(verbatim: passphrase.components(separatedBy: PassphraseGenerator.separator).joined(separator: " "))
                .fxTextStyle(.passphraseWord)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Label(String(localized: "passphrase.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
            }
            .fxButtonStyle(.outline, size: .compact)
        }
        .padding(.vertical, Theme.Spacing.mediumPlus)
        .padding(.leading, Theme.Spacing.large)
        .padding(.trailing, Theme.Spacing.mediumPlus)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Share.passphrase)
        .screenCaptureProtected()
    }
}

/// Save File…, Send with AirDrop where this Mac offers it, and Share…: enabled once the
/// passphrase is saved.
private struct ProjectShareDeliveryButtons: View {
    let viewModel: ProjectShareViewModel

    var body: some View {
        Group {
            Button(ProjectShareCopy.saveFile) {
                Task { await viewModel.saveToFile() }
            }
            .fxButtonStyle(.outline, size: .dialog)
            if viewModel.canSendWithAirDrop {
                Button {
                    viewModel.sendWithAirDrop()
                } label: {
                    Label(ProjectShareCopy.airDrop, systemImage: "dot.radiowaves.up.forward")
                }
                .fxButtonStyle(.outline, size: .dialog)
                .accessibilityIdentifier(AccessibilityID.Share.airDrop)
            }
            Button {
                viewModel.shareFile()
            } label: {
                Label(ProjectShareCopy.share, systemImage: "square.and.arrow.up")
            }
            .fxButtonStyle(.outline, size: .dialog)
            .background(ShareDeliveryAnchor(delivery: viewModel.delivery))
        }
        .disabled(!viewModel.canDeliver)
    }
}
