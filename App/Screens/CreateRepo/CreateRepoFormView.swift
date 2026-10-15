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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ownerSection
                optionsSection
                CreateRepoItemsSection(viewModel: viewModel, target: .repository)
                ForEach(viewModel.environments) { environment in
                    CreateRepoEnvironmentSection(viewModel: viewModel, environment: environment)
                }
                environmentsSection
                cloneSection
            }
            .formStyle(.grouped)
            .disabled(viewModel.phase == .staging)
            Divider()
            footer
        }
        .frame(height: Theme.Layout.createRepoSheetHeight)
    }

    // MARK: - Owner and name

    private var ownerSection: some View {
        Section {
            if viewModel.accounts.count > 1 {
                Picker(String(localized: "createRepo.account", defaultValue: "Account"), selection: $viewModel.accountLogin) {
                    ForEach(viewModel.accounts, id: \.self) { login in
                        Text(verbatim: login).tag(Optional(login))
                    }
                }
            }
            Picker(String(localized: "createRepo.owner", defaultValue: "Owner"), selection: $viewModel.ownerID) {
                ForEach(viewModel.owners) { owner in
                    Text(CreateRepoText.ownerTitle(owner)).tag(Optional(owner.id))
                }
            }
            .disabled(viewModel.owners.isEmpty)
            if let warning = viewModel.ownersWarning {
                CreateRepoNoteView(text: warning.title, detail: warning.message, systemImage: "exclamationmark.triangle", tint: Theme.Colors.warning)
            }
            TextField(String(localized: "createRepo.name", defaultValue: "Name"), text: $viewModel.name)
                .font(Theme.Typography.monospaced)
                .autocorrectionDisabled()
            CreateRepoAvailabilityView(
                availability: viewModel.availability,
                fullName: "\(viewModel.selectedOwner?.login ?? "")/\(viewModel.name)",
                suggestedName: viewModel.suggestedName,
                onUseSuggestion: viewModel.applySuggestedName
            )
            TextField(
                String(localized: "createRepo.description", defaultValue: "Description"),
                text: $viewModel.repoDescription,
                prompt: Text(String(localized: "createRepo.description.prompt", defaultValue: "Optional"))
            )
        } header: {
            HStack(spacing: Theme.Spacing.small) {
                Text(String(localized: "createRepo.section.repository", defaultValue: "Repository"))
                if viewModel.isLoadingAccountData {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Visibility and templates

    private var optionsSection: some View {
        Section(String(localized: "createRepo.section.options", defaultValue: "Visibility and Contents")) {
            Picker(String(localized: "createRepo.visibility", defaultValue: "Visibility"), selection: $viewModel.visibility) {
                ForEach(CreateRepoViewModel.visibilityOptions, id: \.self) { visibility in
                    Text(visibility.localizedTitle).tag(visibility)
                }
            }
            .pickerStyle(.segmented)
            Toggle(String(localized: "createRepo.readme", defaultValue: "Add a README"), isOn: $viewModel.addsReadme)
            Picker(String(localized: "createRepo.gitignore", defaultValue: ".gitignore template"), selection: $viewModel.gitignoreTemplate) {
                Text(String(localized: "createRepo.none", defaultValue: "None")).tag(String?.none)
                ForEach(viewModel.gitignoreTemplates, id: \.self) { template in
                    Text(verbatim: template).tag(Optional(template))
                }
            }
            .disabled(viewModel.gitignoreTemplates.isEmpty)
            Picker(String(localized: "createRepo.license", defaultValue: "License"), selection: $viewModel.licenseKey) {
                Text(String(localized: "createRepo.none", defaultValue: "None")).tag(String?.none)
                ForEach(viewModel.licenseTemplates) { license in
                    Text(verbatim: license.name).tag(Optional(license.key))
                }
            }
            .disabled(viewModel.licenseTemplates.isEmpty)
            if let error = viewModel.templatesError {
                HStack {
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
                }
            }
        }
    }

    // MARK: - Environments

    private var environmentsSection: some View {
        Section {
            Button {
                viewModel.addEnvironment()
            } label: {
                Label(String(localized: "createRepo.environment.add", defaultValue: "Add Environment…"), systemImage: "plus")
            }
            if viewModel.showsPlanNote {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(String(
                        localized: "main.detail.planNote",
                        defaultValue: "Some environment features on private repositories depend on your GitHub plan."
                    ))
                    if let url = ExternalLinks.environmentPlans {
                        Link(String(localized: "main.detail.planNote.learnMore", defaultValue: "Learn more"), destination: url)
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        } header: {
            Text(String(localized: "createRepo.section.environments", defaultValue: "Environments"))
        } footer: {
            if viewModel.environments.isEmpty {
                Text(String(
                    localized: "createRepo.environments.empty",
                    defaultValue: "Optional. For example production with its own secrets and a branch rule."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Clone

    private var cloneSection: some View {
        Section(String(localized: "createRepo.section.clone", defaultValue: "Clone")) {
            Toggle(String(localized: "createRepo.clone", defaultValue: "Clone to my Mac"), isOn: $viewModel.clonesAfterCreate)
            if viewModel.clonesAfterCreate {
                LabeledContent(String(localized: "createRepo.clone.destination", defaultValue: "Destination")) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(verbatim: destinationText)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(viewModel.needsCloneFolder ? Theme.Colors.warning : Theme.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button(String(localized: "createRepo.clone.change", defaultValue: "Change…"), action: chooseFolder)
                    }
                }
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
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label(
                String(
                    localized: "createRepo.footer.stagingNote",
                    defaultValue: "Nothing is created on GitHub until you sync. Create saves the repository in your vault; Sync then creates it with its environments, secrets and variables in one run."
                ),
                systemImage: "info.circle"
            )
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(viewModel.reviewSummary, id: \.self) { line in
                        Text(verbatim: line)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if viewModel.phase == .staging {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "createRepo.create", defaultValue: "Create"), action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCreate)
            }
        }
        .padding(Theme.Spacing.large)
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
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
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
                        .buttonStyle(.link)
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
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let detail {
                    Text(detail)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(Theme.Typography.caption)
        .accessibilityElement(children: .combine)
    }
}
