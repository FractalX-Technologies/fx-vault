import SwiftUI
import VaultCore

/// Settings › Accounts › Azure (1.0 S1b; board Settings-Accounts): a row per tenant with its
/// saved vaults, then Sign out of Azure. Lists on its own task, so `az` never waits for gh.
struct AzureAccountsSection: View {
    let viewModel: AzureAccountsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            PreferencesSection(AzureAccountsCopy.section) {
                ForEach(Array(viewModel.tenants.enumerated()), id: \.element.id) { index, tenant in
                    if index > 0 {
                        HairlineDivider()
                    }
                    AzureTenantRow(tenant: tenant, viewModel: viewModel)
                }
                if showsSetup {
                    if !viewModel.tenants.isEmpty {
                        HairlineDivider()
                    }
                    PreferencesBlock {
                        AzureSetupContent(viewModel: viewModel)
                    }
                }
                if viewModel.showsSignOut {
                    HairlineDivider()
                    PreferencesRow(AzureAccountsCopy.signOut) {
                        AzureCommandControl(command: AzureAccountsCopy.logoutCommand, viewModel: viewModel)
                    }
                    .accessibilityIdentifier(AccessibilityID.Accounts.azureSignOut)
                }
            }
            if let copied = viewModel.copiedCommand {
                HStack(spacing: Theme.Spacing.small) {
                    PreferencesFootnote(AzureAccountsCopy.copied(copied))
                    Spacer(minLength: 0)
                    Button(AzureAccountsCopy.checkAgain) {
                        Task { await viewModel.checkAgain() }
                    }
                    .fxButtonStyle(.outline, size: .compact)
                    .disabled(viewModel.isLoading)
                    .accessibilityIdentifier(AccessibilityID.Accounts.azureCheckAgain)
                }
            }
            if let result = viewModel.importResult {
                PreferencesFootnote(Self.resultText(result))
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: chooserBinding) {
            if let chooser = viewModel.chooser {
                ChooseVaultsSheet(azure: chooser, viewModel: viewModel)
            }
        }
    }

    /// A block for what no tenant row says: a failure, the commands that install or sign in
    /// to `az`, or that there is nothing yet.
    private var showsSetup: Bool {
        viewModel.tenants.isEmpty || !viewModel.setupCommands.isEmpty || viewModel.requirement?.failure != nil
    }

    private var chooserBinding: Binding<Bool> {
        Binding(
            get: { viewModel.chooser != nil },
            set: { isPresented in
                if !isPresented { viewModel.closeChooser() }
            }
        )
    }

    static func resultText(_ result: ConnectAzureModel.ImportResult) -> String {
        var parts: [String] = []
        if result.vaultCount > 0 {
            parts.append(AzureAccountsCopy.added(vaults: result.vaultCount, secrets: result.secretCount))
        }
        if !result.failedNames.isEmpty {
            parts.append(AzureAccountsCopy.notRead(result.failedNames))
        }
        return parts.joined(separator: " ")
    }
}

/// What stands between FX Vault and `az`, or that no vault is in FX Vault yet.
private struct AzureSetupContent: View {
    let viewModel: AzureAccountsViewModel

    var body: some View {
        if let error = viewModel.requirement?.failure {
            InlineErrorView(error: error)
        } else if let requirement = viewModel.requirement, !viewModel.setupCommands.isEmpty {
            Text(AzureVaultChoicesView.requirementText(requirement))
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(viewModel.setupCommands, id: \.self) { command in
                CommandRow(command: command) { viewModel.copy($0) }
            }
        } else if viewModel.isLoading || viewModel.requirement == nil {
            ProgressView()
                .controlSize(.small)
        } else {
            Text(AzureAccountsCopy.noVaults)
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.mutedText)
        }
    }
}

/// One tenant (board Settings-Accounts): its name and saved vaults, then "● Signed in" with
/// Choose Vaults…, or the `az login --tenant` to copy.
private struct AzureTenantRow: View {
    let tenant: AzureTenantRowModel
    let viewModel: AzureAccountsViewModel

    var body: some View {
        PreferencesRow(tenant.title, detail: tenant.subline) {
            switch tenant.signIn {
            case .signedIn:
                PreferencesStatus(title: AzureAccountsCopy.signedIn, mark: .fine)
                    .fixedSize()
                Button(AzureAccountsCopy.chooseVaults) {
                    viewModel.chooseVaults(tenant)
                }
                .fxButtonStyle(.outline, size: .compact)
                .disabled(viewModel.isImporting)
                .accessibilityIdentifier(AccessibilityID.Accounts.azureChooseVaults(tenant.id))
            case .notSignedIn:
                AzureCommandControl(command: tenant.loginCommand, viewModel: viewModel)
            case .unknown:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Accounts.azureTenant(tenant.id))
    }
}

/// A command to run in Terminal, in mono, and Copy (Copied once it is on the clipboard). The
/// command can be long (a tenant id): it truncates in the middle and its help shows it whole.
private struct AzureCommandControl: View {
    let command: String
    let viewModel: AzureAccountsViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            Text(verbatim: command)
                .fxTextStyle(.monoLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(command)
                .accessibilityIdentifier(AccessibilityID.Setup.command(command))
            Button {
                viewModel.copy(command)
            } label: {
                if viewModel.copiedCommand == command {
                    Label(String(localized: "settings.advanced.diagnostics.copied", defaultValue: "Copied"), systemImage: "checkmark")
                } else {
                    Label(String(localized: "command.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
                }
            }
            .fxButtonStyle(.outline, size: .compact)
            .fixedSize()
            .help(String(localized: "command.copy.help", defaultValue: "Copy the command"))
        }
    }
}

/// Choose Vaults… (board ConnectAzure as a sheet): Connect Azure's list for one tenant, where
/// the vaults already in FX Vault stay checked and disabled, then Add Vaults.
private struct ChooseVaultsSheet: View {
    let azure: ConnectAzureModel
    let viewModel: AzureAccountsViewModel

    var body: some View {
        DialogSheet(
            title: AzureAccountsCopy.chooseTitle,
            subtitle: subtitle,
            footerNote: footerNote,
            isWorking: azure.isLoading || viewModel.isImporting
        ) {
            if let failure = azure.failure {
                Banner(.danger, message: failure.message)
            }
            AzureVaultChoicesView(azure: azure, isDisabled: viewModel.isImporting)
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.closeChooser()
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.isImporting)
            Button(AzureAccountsCopy.add) {
                Task { await viewModel.addChosenVaults() }
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
            .disabled(azure.selectedVaults.isEmpty || azure.isLoading || viewModel.isImporting)
            .accessibilityIdentifier(AccessibilityID.Accounts.azureAddVaults)
        }
        .frame(width: Theme.Layout.sheetWidth)
        .frame(maxHeight: Theme.Layout.chooseVaultsSheetMaxHeight)
        .task {
            if !azure.hasLoaded {
                await azure.load()
            }
        }
    }

    private var subtitle: String? {
        guard case .tenant(let tenantID) = azure.scope else { return nil }
        return viewModel.tenants.first { $0.tenantID == tenantID }?.title
    }

    /// "1 vault selected · Secrets with values", or the vault being read.
    private var footerNote: String? {
        if let name = viewModel.importingName {
            return String(localized: "connect.importing", defaultValue: "Importing \(name)…")
        }
        return azure.requirement == .ready ? ConnectCopy.vaultsSelected(azure.selectedVaults.count) : nil
    }
}
