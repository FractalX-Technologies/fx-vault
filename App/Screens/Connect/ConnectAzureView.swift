import SwiftUI
import VaultCore

/// Board ConnectAzure: the `az` requirements, then each subscription's Key Vaults to read.
struct ConnectAzureView: View {
    let viewModel: ConnectViewModel

    private var azure: ConnectAzureModel {
        viewModel.azure
    }

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "connect.azure.title", defaultValue: "Connect Azure Key Vault."),
            subtitle: String(localized: "connect.azure.subtitle", defaultValue: "Choose the vaults to read."),
            error: failure,
            isWorking: azure.isLoading || viewModel.isImporting
        ) {
            requirements
            ForEach(azure.subscriptions) { subscription in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionLabel(subscription.name)
                    if let failure = subscription.failure {
                        OnboardingNote(failure)
                    }
                    ForEach(subscription.vaults) { vault in
                        ConnectVaultRow(vault: vault, isSelected: azure.selection.contains(vault.id), isDisabled: viewModel.isImporting) {
                            azure.toggle(vault)
                        }
                    }
                }
            }
            if azure.requirement == .ready, azure.subscriptions.allSatisfy(\.vaults.isEmpty) {
                OnboardingNote(String(
                    localized: "connect.azure.empty",
                    defaultValue: "This Azure account lists no Key Vault FX Vault can read."
                ))
            }
            if azure.requirement == .ready || viewModel.importingName != nil {
                OnboardingNote(statusLine)
            }
        } footer: {
            Button(String(localized: "onboarding.back", defaultValue: "Back")) {
                viewModel.backToGitHub()
            }
            .fxButtonStyle(.outline, size: .large)
            .accessibilityIdentifier(AccessibilityID.Connect.back)
            .disabled(viewModel.isImporting)
            Button(String(localized: "connect.azure.skip", defaultValue: "Skip")) {
                Task { await viewModel.skipAzure() }
            }
            .fxButtonStyle(.outline, size: .large)
            .accessibilityIdentifier(AccessibilityID.Connect.skipAzure)
            .disabled(viewModel.isImporting)
            Button {
                Task { await viewModel.importSelected() }
            } label: {
                ShellForwardLabel(title: String(localized: "connect.continue", defaultValue: "Continue"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Connect.importSelected)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canContinue)
        }
        .task {
            if !azure.hasLoaded {
                await azure.load()
            }
        }
    }

    private var failure: ErrorPresentationModel? {
        if case .failed(let presentation) = azure.requirement { return presentation }
        return nil
    }

    /// Azure CLI installed and signed in, with the commands that fix what is missing.
    @ViewBuilder
    private var requirements: some View {
        if let requirement = azure.requirement, requirement != .ready, failure == nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(String(localized: "connect.azure.requirements", defaultValue: "Requirements"))
                Text(Self.requirementText(requirement))
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Connect.azureRequirement)
                SetupCommandList(
                    commands: azure.commands,
                    runs: azure.runs,
                    copiedCommand: azure.copiedCommand,
                    copiedMessage: { String(localized: "connect.azure.copied", defaultValue: "Copied \($0). Run it in Terminal, then check again.") },
                    onRun: { command in Task { await azure.run(command) } },
                    onCopy: { azure.copy($0) }
                )
                Button(String(localized: "connect.azure.checkAgain", defaultValue: "Check Again")) {
                    Task { await azure.load() }
                }
                .fxButtonStyle(.outline)
                .disabled(azure.isLoading)
                .accessibilityIdentifier(AccessibilityID.Connect.azureCheckAgain)
            }
        }
    }

    static func requirementText(_ requirement: ConnectAzureModel.Requirement) -> String {
        switch requirement {
        case .notInstalled:
            String(localized: "connect.azure.notInstalled", defaultValue: "Install the Azure CLI, then sign in with az login.")
        case .untrusted(let path):
            String(localized: "connect.azure.untrusted", defaultValue: "FX Vault does not run \(path): another user can change it. Reinstall the Azure CLI.")
        case .notSignedIn:
            String(localized: "connect.azure.notSignedIn", defaultValue: "Sign in with az login in Terminal. Reading a vault needs the Key Vault Secrets User role.")
        case .ready, .failed:
            ""
        }
    }

    /// "2 vaults selected · Secrets with values", or the vault being imported.
    private var statusLine: String {
        if let name = viewModel.importingName {
            return String(localized: "connect.importing", defaultValue: "Importing \(name)…")
        }
        return ConnectCopy.vaultsSelected(azure.selectedVaults.count)
    }
}

/// One Key Vault, checked when it will be imported.
private struct ConnectVaultRow: View {
    let vault: ConnectAzureModel.Vault
    let isSelected: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggle() })) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: vault.name)
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                Text(verbatim: vault.location)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isDisabled)
        .accessibilityIdentifier(AccessibilityID.Connect.vault(vault.id))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
    }
}
