import AppKit
import SwiftUI
import VaultCore
import VaultData

/// The New Repository form: owner and name, visibility and templates, staged items and
/// environments, Clone to my Mac, and the footer that explains Create stages and Sync creates.
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    SheetHeader(
                        label: CreateRepoText.eyebrow,
                        title: String(localized: "createRepo.title", defaultValue: "New Repository"),
                        subtitle: String(
                            localized: "createRepo.footer.stagingNote",
                            defaultValue: "Nothing is created on GitHub until you sync. Create saves the repository in your vault; Sync then creates it with its environments, secrets and variables in one run."
                        )
                    )
                    ownerSection
                    optionsSection
                    CreateRepoItemsSection(viewModel: viewModel, target: .repository)
                    ForEach(viewModel.environments) { environment in
                        CreateRepoEnvironmentSection(viewModel: viewModel, environment: environment)
                    }
                    environmentsSection
                    cloneSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xxLarge)
            }
            .disabled(viewModel.phase == .staging)
            HairlineDivider()
            footer
        }
        .frame(height: Theme.Layout.createRepoSheetHeight)
    }

    // MARK: - Owner and name

    private var ownerSection: some View {
        ConfigSheetField(String(localized: "createRepo.section.repository", defaultValue: "Repository")) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                if viewModel.accounts.count > 1 {
                    labelled(String(localized: "createRepo.account", defaultValue: "Account")) {
                        Picker(String(localized: "createRepo.account", defaultValue: "Account"), selection: $viewModel.accountLogin) {
                            ForEach(viewModel.accounts, id: \.self) { login in
                                Text(verbatim: login).tag(Optional(login))
                            }
                        }
                    }
                }
                labelled(String(localized: "createRepo.owner", defaultValue: "Owner")) {
                    Picker(String(localized: "createRepo.owner", defaultValue: "Owner"), selection: $viewModel.ownerID) {
                        ForEach(viewModel.owners) { owner in
                            Text(CreateRepoText.ownerTitle(owner)).tag(Optional(owner.id))
                        }
                    }
                    .disabled(viewModel.owners.isEmpty)
                }
            }
            if let warning = viewModel.ownersWarning {
                CreateRepoNoteView(text: warning.title, detail: warning.message, systemImage: "exclamationmark.triangle", tint: Theme.Colors.warning)
            }
            labelled(String(localized: "createRepo.name", defaultValue: "Name")) {
                TextField(
                    String(localized: "createRepo.name", defaultValue: "Name"),
                    text: $viewModel.name,
                    prompt: Text(verbatim: "my-service").foregroundStyle(Theme.Colors.subtleText)
                )
                .focused($focusedField, equals: .name)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(.rounded, isFocused: focusedField == .name, isInvalid: viewModel.availability.blocksCreate, isMonospaced: true)
                CreateRepoAvailabilityView(
                    availability: viewModel.availability,
                    fullName: "\(viewModel.selectedOwner?.login ?? "")/\(viewModel.name)",
                    suggestedName: viewModel.suggestedName,
                    onUseSuggestion: viewModel.applySuggestedName
                )
            }
            labelled(String(localized: "createRepo.description", defaultValue: "Description")) {
                TextField(
                    String(localized: "createRepo.description", defaultValue: "Description"),
                    text: $viewModel.repoDescription,
                    prompt: Text(String(localized: "createRepo.description.prompt", defaultValue: "Optional"))
                        .foregroundStyle(Theme.Colors.subtleText)
                )
                .focused($focusedField, equals: .description)
                .labelsHidden()
                .fxInputField(.rounded, isFocused: focusedField == .description)
            }
        } labelAccessory: {
            if viewModel.isLoadingAccountData {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    /// A caption above one control of a block (Account, Owner, Name, templates). The control keeps
    /// its own accessibility label.
    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            Text(title)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            content()
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Visibility and templates

    private var optionsSection: some View {
        ConfigSheetField(String(localized: "createRepo.section.options", defaultValue: "Visibility and Contents")) {
            SegmentedPill(
                selection: $viewModel.visibility,
                segments: CreateRepoViewModel.visibilityOptions.map { .init(value: $0, title: $0.localizedTitle) },
                accessibilityLabel: String(localized: "createRepo.visibility", defaultValue: "Visibility")
            )
            Toggle(String(localized: "createRepo.readme", defaultValue: "Add a README"), isOn: $viewModel.addsReadme)
                .toggleStyle(.checkbox)
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                labelled(String(localized: "createRepo.gitignore", defaultValue: ".gitignore template")) {
                    Picker(String(localized: "createRepo.gitignore", defaultValue: ".gitignore template"), selection: $viewModel.gitignoreTemplate) {
                        Text(String(localized: "createRepo.none", defaultValue: "None")).tag(String?.none)
                        ForEach(viewModel.gitignoreTemplates, id: \.self) { template in
                            Text(verbatim: template).tag(Optional(template))
                        }
                    }
                    .disabled(viewModel.gitignoreTemplates.isEmpty)
                }
                labelled(String(localized: "createRepo.license", defaultValue: "License")) {
                    Picker(String(localized: "createRepo.license", defaultValue: "License"), selection: $viewModel.licenseKey) {
                        Text(String(localized: "createRepo.none", defaultValue: "None")).tag(String?.none)
                        ForEach(viewModel.licenseTemplates) { license in
                            Text(verbatim: license.name).tag(Optional(license.key))
                        }
                    }
                    .disabled(viewModel.licenseTemplates.isEmpty)
                }
            }
            if let error = viewModel.templatesError {
                HStack(spacing: Theme.Spacing.small) {
                    CreateRepoNoteView(
                        text: String(localized: "createRepo.templates.failed", defaultValue: "Templates could not be loaded"),
                        detail: error.message,
                        systemImage: "exclamationmark.triangle",
                        tint: Theme.Colors.warning
                    )
                    Spacer()
                    Button(String(localized: "createRepo.retry", defaultValue: "Try Again")) {
                        Task { await viewModel.retryTemplates() }
                    }
                    .fxButtonStyle(.outline)
                }
            }
        }
    }

    // MARK: - Environments

    private var environmentsSection: some View {
        ConfigSheetField(String(localized: "createRepo.section.environments", defaultValue: "Environments")) {
            Button {
                viewModel.addEnvironment()
            } label: {
                Label(String(localized: "createRepo.environment.add", defaultValue: "Add Environment…"), systemImage: "plus")
            }
            .fxButtonStyle(.outline)
            if viewModel.environments.isEmpty {
                CreateRepoHint(String(
                    localized: "createRepo.environments.empty",
                    defaultValue: "Optional. For example production with its own secrets and a branch rule."
                ))
            }
            if viewModel.showsPlanNote {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(String(
                        localized: "main.detail.planNote",
                        defaultValue: "Some environment features on private repositories depend on your GitHub plan."
                    ))
                    .foregroundStyle(Theme.Colors.subtleText)
                    if let url = ExternalLinks.environmentPlans {
                        Link(String(localized: "main.detail.planNote.learnMore", defaultValue: "Learn more"), destination: url)
                            .foregroundStyle(Theme.Colors.brand)
                    }
                }
                .fxTextStyle(.caption)
            }
        }
    }

    // MARK: - Clone

    private var cloneSection: some View {
        ConfigSheetField(String(localized: "createRepo.section.clone", defaultValue: "Clone")) {
            Toggle(String(localized: "createRepo.clone", defaultValue: "Clone to my Mac"), isOn: $viewModel.clonesAfterCreate)
                .toggleStyle(.checkbox)
            if viewModel.clonesAfterCreate {
                HStack(spacing: Theme.Spacing.small) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(String(localized: "createRepo.clone.destination", defaultValue: "Destination"))
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                        Text(verbatim: destinationText)
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(viewModel.needsCloneFolder ? Theme.Colors.warning : Theme.Colors.ink)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Button(String(localized: "createRepo.clone.change", defaultValue: "Change…"), action: chooseFolder)
                        .fxButtonStyle(.outline)
                }
                .configSheetRowPadding()
                .fxCardBackground(.container)
                if viewModel.cloneNeedsSSHAlias {
                    CreateRepoNoteView(
                        text: String(localized: "createRepo.clone.noAlias", defaultValue: "No SSH alias mapped"),
                        detail: String(
                            localized: "createRepo.clone.noAlias.detail",
                            defaultValue: "Map one for this account in Settings › Accounts before you sync, or the clone is skipped."
                        ),
                        systemImage: "exclamationmark.triangle",
                        tint: Theme.Colors.warning
                    )
                }
            }
        }
    }

    private var destinationText: String {
        guard let folder = viewModel.cloneFolderURL else {
            return String(localized: "createRepo.clone.noFolder", defaultValue: "Choose a folder")
        }
        let base = folder.path(percentEncoded: false)
        guard !viewModel.name.isEmpty else { return base }
        return folder.appending(path: viewModel.name, directoryHint: .isDirectory).path(percentEncoded: false)
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

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.mediumMinus) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                ForEach(viewModel.reviewSummary, id: \.self) { line in
                    Text(verbatim: line)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if viewModel.phase == .staging {
                ProgressView()
                    .controlSize(.small)
            }
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .fxButtonStyle(.secondary, size: .large)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "createRepo.create", defaultValue: "Create"), action: onCreate)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCreate)
            }
            .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.xxLarge)
        .padding(.vertical, Theme.Spacing.largePlus)
    }
}

/// The line under the Name field: checking, probably available, taken, invalid or unknown.
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
                Text(String(localized: "createRepo.availability.checking", defaultValue: "Checking the name…"))
            }
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
        case .probablyAvailable:
            CreateRepoNoteView(
                text: String(localized: "createRepo.availability.probablyAvailable", defaultValue: "Probably available"),
                detail: String(
                    localized: "createRepo.availability.probablyAvailable.detail",
                    defaultValue: "GitHub confirms the name when Sync creates the repository."
                ),
                systemImage: "checkmark.circle",
                tint: Theme.Colors.success
            )
        case .taken:
            CreateRepoNoteView(
                text: String(localized: "createRepo.availability.taken", defaultValue: "\(fullName) already exists"),
                detail: nil,
                systemImage: "xmark.octagon",
                tint: Theme.Colors.danger
            )
        case .invalid(let rule):
            HStack(spacing: Theme.Spacing.small) {
                CreateRepoNoteView(text: rule.localizedMessage, detail: nil, systemImage: "exclamationmark.circle", tint: Theme.Colors.danger)
                if let suggestedName {
                    Spacer()
                    Button(String(localized: "createRepo.name.useSuggestion", defaultValue: "Use \(suggestedName)"), action: onUseSuggestion)
                        .fxButtonStyle(.outline)
                }
            }
        case .unknown(let error):
            CreateRepoNoteView(
                text: String(localized: "createRepo.availability.unknown", defaultValue: "Could not check the name"),
                detail: error.message,
                systemImage: "questionmark.circle",
                tint: Theme.Colors.warning
            )
        }
    }
}

/// A small icon, text and optional detail line in a form.
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

/// A quiet caption under a block of the New Repository form ("Optional. …").
struct CreateRepoHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.subtleText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
