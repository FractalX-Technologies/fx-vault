import SwiftUI
import VaultCore

/// The `az` requirements with the commands that fix them, then each subscription's Key Vaults
/// with a checkbox (board ConnectAzure). Connect Azure's step and Settings › Accounts › Choose
/// Vaults… (1.0 S1b) both show it over a ``ConnectAzureModel``.
struct AzureVaultChoicesView: View {
    @Bindable var azure: ConnectAzureModel
    let isDisabled: Bool

    var body: some View {
        requirements
        if azure.isSearchable {
            ChooserSearchField(
                prompt: ConnectCopy.searchVaults,
                accessibilityID: AccessibilityID.Connect.vaultSearch,
                text: $azure.query
            )
        }
        let subscriptions = azure.visibleSubscriptions
        if subscriptions.isEmpty, azure.isSearching {
            OnboardingNote(ConnectCopy.noMatchingVaults)
        }
        ForEach(subscriptions) { subscription in
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(subscription.name)
                if let failure = subscription.failure {
                    OnboardingNote(failure)
                }
                ForEach(subscription.vaults) { vault in
                    let isSaved = azure.isSaved(vault)
                    ConnectVaultRow(
                        vault: vault,
                        isSelected: isSaved || azure.selection.contains(vault.id),
                        isSaved: isSaved,
                        isDisabled: isDisabled || isSaved
                    ) {
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
    }

    /// Azure CLI installed and signed in, with the commands that fix what is missing.
    @ViewBuilder
    private var requirements: some View {
        if let requirement = azure.requirement, requirement != .ready, azure.failure == nil {
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
}

/// One Key Vault, checked when it will be imported; one already in FX Vault stays checked and
/// disabled, and says so.
private struct ConnectVaultRow: View {
    let vault: ConnectAzureModel.Vault
    let isSelected: Bool
    let isSaved: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        ChoiceCheckboxRow(
            title: vault.name,
            detail: isSaved ? ConnectCopy.vaultSaved(location: vault.location) : vault.location,
            isSelected: isSelected,
            isDisabled: isDisabled,
            accessibilityID: AccessibilityID.Connect.vault(vault.id),
            toggle: toggle
        )
    }
}
