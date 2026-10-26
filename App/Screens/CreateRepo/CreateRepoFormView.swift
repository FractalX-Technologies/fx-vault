import AppKit
import SwiftUI
import VaultCore
import VaultData

/// The New Repository form as board NewRepo: one row per choice (account, owner, name,
/// description, visibility, contents, environments, secrets and variables, clone) in the dialog
/// form's label column, then "Created on GitHub at the next Sync." with Cancel and Stage
/// Repository.
struct CreateRepoFormView: View {
    @Bindable var viewModel: CreateRepoViewModel
    let onCancel: () -> Void
    let onCreate: () -> Void
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case description
    }

    var body: some View {
        DialogSheet(
            title: String(localized: "createRepo.title", defaultValue: "New Repository"),
            footerNote: SyncCopy.createdAtNextSync,
            isWorking: viewModel.phase == .staging
        ) {
            Group {
                if viewModel.accounts.count > 1 {
                    accountRow
                }
                ownerRow
                nameRow
                descriptionRow
                visibilityRow
                contentsRow
                environmentsRow
                CreateRepoItemsRow(viewModel: viewModel)
                cloneRow
            }
            .disabled(viewModel.phase == .staging)
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                .fxButtonStyle(.outline, size: .dialog)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "createRepo.stage", defaultValue: "Stage Repository"), action: onCreate)
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canCreate)
        }
        .frame(height: Theme.Layout.createRepoSheetHeight)
    }

    // MARK: - Account, owner and name

    private var accountRow: some View {
        let title = String(localized: "createRepo.account.label", defaultValue: "Create with")
        return DialogFormRow(title) {
            DialogPopUp(
                title: title,
                selection: $viewModel.accountLogin,
                options: viewModel.accounts.map { .init(value: Optional($0), title: $0) },
                isMonospaced: true
            )
        }
    }

    private var ownerRow: some View {
        let title = String(localized: "createRepo.owner", defaultValue: "Owner")
        return DialogFormRow(title) {
            DialogPopUp(
                title: title,
                selection: $viewModel.ownerID,
                options: viewModel.owners.map { .init(value: Optional($0.id), title: CreateRepoText.ownerTitle($0)) },
                display: viewModel.selectedOwner?.login,
                isMonospaced: true
            )
            .disabled(viewModel.owners.isEmpty)
            if viewModel.isLoadingAccountData {
                HStack(spacing: Theme.Spacing.xSmall) {
                    ProgressView()
                        .controlSize(.mini)
                    DialogFormNote(String(localized: "createRepo.owners.loading", defaultValue: "Loading organizations…"))
                }
            }
            if let warning = viewModel.ownersWarning {
                DialogFormNote("\(warning.title). \(warning.message)", tone: .warning)
            }
        }
    }

    private var nameRow: some View {
        let title = String(localized: "createRepo.name", defaultValue: "Name")
        return DialogFormRow(title) {
            TextField(
                title,
                text: $viewModel.name,
                prompt: Text(verbatim: "my-service").foregroundStyle(Theme.Colors.subtleText)
            )
            .focused($focusedField, equals: .name)
            .autocorrectionDisabled()
            .labelsHidden()
            .fxInputField(.dialog, isFocused: focusedField == .name, isInvalid: viewModel.availability.blocksCreate, isMonospaced: true)
            CreateRepoAvailabilityView(
                availability: viewModel.availability,
                fullName: "\(viewModel.selectedOwner?.login ?? "")/\(viewModel.name)",
                suggestedName: viewModel.suggestedName,
                onUseSuggestion: viewModel.applySuggestedName
            )
        }
    }

    private var descriptionRow: some View {
        let title = String(localized: "createRepo.description", defaultValue: "Description")
        return DialogFormRow(title) {
            TextField(
                title,
                text: $viewModel.repoDescription,
                prompt: Text(String(localized: "createRepo.description.prompt", defaultValue: "Optional"))
                    .foregroundStyle(Theme.Colors.subtleText)
            )
            .focused($focusedField, equals: .description)
            .labelsHidden()
            .fxInputField(.dialog, isFocused: focusedField == .description)
        }
    }

    // MARK: - Visibility and contents

    private var visibilityRow: some View {
        let title = String(localized: "createRepo.visibility", defaultValue: "Visibility")
        return DialogFormRow(title) {
            SegmentedPill(
                selection: $viewModel.visibility,
                segments: CreateRepoViewModel.visibilityOptions.map { .init(value: $0, title: $0.localizedTitle) },
                accessibilityLabel: title,
                size: .small
            )
            .fixedSize()
        }
    }

    private var contentsRow: some View {
        DialogFormRow(String(localized: "createRepo.contents", defaultValue: "Contents")) {
            DialogSwitch(
                title: String(localized: "createRepo.readme.switch", defaultValue: "Add README"),
                isOn: $viewModel.addsReadme
            )
            HStack(spacing: Theme.Spacing.smallMinus) {
                DialogPopUp(
                    title: String(localized: "createRepo.gitignore", defaultValue: ".gitignore template"),
                    selection: $viewModel.gitignoreTemplate,
                    options: [.init(value: nil, title: CreateRepoText.none)]
                        + viewModel.gitignoreTemplates.map { .init(value: Optional($0), title: $0) },
                    display: CreateRepoText.gitignoreDisplay(viewModel.gitignoreTemplate)
                )
                .disabled(viewModel.gitignoreTemplates.isEmpty)
                DialogPopUp(
                    title: String(localized: "createRepo.license", defaultValue: "License"),
                    selection: $viewModel.licenseKey,
                    options: [.init(value: nil, title: CreateRepoText.none)]
                        + viewModel.licenseTemplates.map { .init(value: Optional($0.key), title: $0.name) },
                    display: CreateRepoText.licenseDisplay(viewModel.licenseTemplates.first { $0.key == viewModel.licenseKey }?.name)
                )
                .disabled(viewModel.licenseTemplates.isEmpty)
            }
            if let error = viewModel.templatesError {
                HStack(spacing: Theme.Spacing.small) {
                    DialogFormNote(
                        String(localized: "createRepo.templates.failedLine", defaultValue: "Templates could not be loaded. \(error.message)"),
                        tone: .warning
                    )
                    Spacer(minLength: 0)
                    Button(String(localized: "createRepo.retry", defaultValue: "Try Again")) {
                        Task { await viewModel.retryTemplates() }
                    }
                    .fxButtonStyle(.outline, size: .compact)
                }
            }
        }
    }

    // MARK: - Environments

    private var environmentsRow: some View {
        DialogFormRow(String(localized: "createRepo.environments.label", defaultValue: "Environments to create")) {
            FlowLayout(spacing: Theme.Spacing.smallMinus) {
                ForEach(viewModel.environments) { environment in
                    DialogTokenChip(
                        title: environment.name,
                        removeLabel: String(localized: "createRepo.environment.removeNamed", defaultValue: "Remove \(environment.name)"),
                        onSelect: { viewModel.editEnvironment(environment.id) },
                        onRemove: { viewModel.removeEnvironment(environment.id) }
                    )
                    .help(CreateRepoText.policySummary(environment.policy))
                }
                DialogAddChip(title: String(localized: "createRepo.environment.addChip", defaultValue: "Add")) {
                    viewModel.addEnvironment()
                }
            }
            if viewModel.showsPlanNote {
                EnvironmentPlanNoteView(isPlanGated: false)
            }
        }
    }

    // MARK: - Clone

    private var cloneRow: some View {
        DialogFormRow(String(localized: "createRepo.section.clone", defaultValue: "Clone")) {
            DialogSwitch(
                title: String(localized: "createRepo.clone", defaultValue: "Clone to my Mac"),
                isOn: $viewModel.clonesAfterCreate
            )
            HStack(spacing: Theme.Spacing.smallMinus) {
                Text(verbatim: viewModel.cloneSSHAlias ?? CreateRepoText.noAlias)
                    .font(Theme.Typography.monoMeta)
                    .foregroundStyle(viewModel.cloneSSHAlias == nil ? Theme.Colors.mutedText : Theme.Colors.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dialogFieldChrome()
                    .accessibilityLabel(Text(String(localized: "createRepo.clone.alias", defaultValue: "SSH alias")))
                    .accessibilityValue(Text(verbatim: viewModel.cloneSSHAlias ?? CreateRepoText.noAlias))
                Button(action: chooseFolder) {
                    Text(verbatim: folderText)
                }
                .buttonStyle(DialogFieldButtonStyle(isMonospaced: true))
                .accessibilityLabel(Text(String(localized: "createRepo.clone.destination", defaultValue: "Destination")))
                .accessibilityValue(Text(verbatim: folderText))
            }
            .opacity(viewModel.clonesAfterCreate ? 1 : Theme.Opacity.disabled)
            .disabled(!viewModel.clonesAfterCreate)
            DialogFormNote(String(localized: "createRepo.clone.note", defaultValue: "Optional · SSH alias and folder"))
            if viewModel.needsCloneFolder {
                DialogFormNote(String(localized: "createRepo.clone.noFolder", defaultValue: "Choose a folder"), tone: .warning)
            }
            if viewModel.cloneNeedsSSHAlias {
                DialogFormNote(
                    String(
                        localized: "createRepo.clone.noAliasLine",
                        defaultValue: "No SSH alias mapped. Map one for this account in Settings › Accounts before you sync, or the clone is skipped."
                    ),
                    tone: .warning
                )
            }
        }
    }

    /// The clone folder with `~` for the home folder ("~/Code"), or the prompt to choose one.
    private var folderText: String {
        guard let folder = viewModel.cloneFolderURL else {
            return String(localized: "createRepo.clone.chooseFolder", defaultValue: "Choose…")
        }
        return (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.cloneFolderURL
        panel.prompt = String(localized: "createRepo.clone.panel.prompt", defaultValue: "Choose")
        panel.message = String(
            localized: "main.clone.message",
            defaultValue: "Choose the folder FX Vault clones repositories into. You can change it in Settings › General."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.setCloneFolder(url)
    }
}

/// The note under the Name field: checking, probably available, taken, invalid or unknown.
struct CreateRepoAvailabilityView: View {
    let availability: CreateRepoAvailabilityModel
    let fullName: String
    let suggestedName: String?
    let onUseSuggestion: () -> Void

    var body: some View {
        switch availability {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: Theme.Spacing.xSmall) {
                ProgressView()
                    .controlSize(.mini)
                DialogFormNote(String(localized: "createRepo.availability.checking", defaultValue: "Checking the name…"))
            }
        case .probablyAvailable:
            DialogFormNote(String(
                localized: "createRepo.availability.probablyAvailableLine",
                defaultValue: "Probably available · GitHub confirms it at Sync"
            ))
        case .taken:
            DialogFormNote(
                String(localized: "createRepo.availability.taken", defaultValue: "\(fullName) already exists"),
                tone: .danger
            )
        case .invalid(let rule):
            HStack(spacing: Theme.Spacing.small) {
                DialogFormNote(rule.localizedMessage, tone: .danger)
                if let suggestedName {
                    Spacer(minLength: 0)
                    Button(String(localized: "createRepo.name.useSuggestion", defaultValue: "Use \(suggestedName)"), action: onUseSuggestion)
                        .fxButtonStyle(.outline, size: .compact)
                }
            }
        case .unknown(let error):
            DialogFormNote(
                String(localized: "createRepo.availability.unknownLine", defaultValue: "Could not check the name. \(error.message)"),
                tone: .warning
            )
        }
    }
}

/// A small icon, text and optional detail line in a form (the nested item editor).
struct CreateRepoNoteView: View {
    let text: String
    let detail: String?
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(text)
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .fxTextStyle(.caption)
        .accessibilityElement(children: .combine)
    }
}
