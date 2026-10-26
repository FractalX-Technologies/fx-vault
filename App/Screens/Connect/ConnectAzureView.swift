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
            error: azure.failure,
            isWorking: azure.isLoading || viewModel.isImporting
        ) {
            AzureVaultChoicesView(azure: azure, isDisabled: viewModel.isImporting)
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

    /// "2 vaults selected · Secrets with values", or the vault being imported.
    private var statusLine: String {
        if let name = viewModel.importingName {
            return String(localized: "connect.importing", defaultValue: "Importing \(name)…")
        }
        return ConnectCopy.vaultsSelected(azure.selectedVaults.count)
    }
}
