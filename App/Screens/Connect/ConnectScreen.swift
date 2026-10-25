import GitHubKit
import SwiftUI
import VaultCore

/// The Connect phase after onboarding (boards ConnectGitHub, ConnectAzure and FirstImport), in
/// the onboarding column: choose what to import on each step, then the summary of what was stored.
struct ConnectScreen: View {
    @State private var viewModel: ConnectViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeConnectViewModel())
    }

    /// Shows an existing view model (the visual snapshot tests).
    init(viewModel: ConnectViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLargePlus) {
                    HStack {
                        OnboardingPhaseHeader(current: viewModel.summary == nil ? .connect : .import)
                        Spacer(minLength: Theme.Spacing.large)
                        if viewModel.summary == nil {
                            StepCounter(current: viewModel.step.rawValue, total: ConnectViewModel.Step.allCases.count)
                                .accessibilityIdentifier(AccessibilityID.Connect.stepCounter)
                        }
                    }
                    Group {
                        if let summary = viewModel.summary {
                            FirstImportSummaryView(summary: summary) {
                                viewModel.finish()
                            }
                        } else {
                            switch viewModel.step {
                            case .github: ConnectGitHubView(viewModel: viewModel)
                            case .azure: ConnectAzureView(viewModel: viewModel)
                            }
                        }
                    }
                    .transition(.opacity)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.vertical, Theme.Spacing.huge)
                .padding(.horizontal, Theme.Spacing.xHuge)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.Colors.ground)
        .animation(Theme.Durations.interactionAnimation, value: viewModel.summary)
        .animation(Theme.Durations.interactionAnimation, value: viewModel.step)
        .task {
            if !viewModel.hasLoaded {
                await viewModel.load()
            }
        }
    }
}

/// Board ConnectGitHub: each account with its organizations and personal repositories.
private struct ConnectGitHubView: View {
    let viewModel: ConnectViewModel

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "connect.title", defaultValue: "Connect GitHub."),
            subtitle: String(localized: "connect.subtitle", defaultValue: "Choose what FX Vault reads."),
            error: viewModel.error,
            isWorking: viewModel.isLoading || viewModel.isImporting
        ) {
            ForEach(viewModel.sections) { section in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionLabel("\(section.accountLogin) · github.com")
                    ForEach(section.sources) { source in
                        ConnectSourceRow(
                            source: source,
                            isSelected: viewModel.selection.contains(source.id),
                            isDisabled: viewModel.isImporting
                        ) {
                            viewModel.toggle(source)
                        }
                    }
                }
            }
            if viewModel.hasLoaded, viewModel.sections.isEmpty, viewModel.error == nil {
                OnboardingNote(String(
                    localized: "connect.empty",
                    defaultValue: "No GitHub account FX Vault can use. Add one in Settings › Accounts."
                ))
            }
            OnboardingNote(statusLine)
        } footer: {
            Button(String(localized: "connect.notNow", defaultValue: "Not Now")) {
                viewModel.finish()
            }
            .fxButtonStyle(.outline, size: .large)
            .accessibilityIdentifier(AccessibilityID.Connect.notNow)
            .disabled(viewModel.isImporting)
            Button {
                viewModel.goToAzure()
            } label: {
                ShellForwardLabel(title: String(localized: "connect.continue", defaultValue: "Continue"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Connect.toAzure)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canGoToAzure)
        }
    }

    /// "3 selected · Secret names only", or the source being imported.
    private var statusLine: String {
        if let name = viewModel.importingName {
            return String(localized: "connect.importing", defaultValue: "Importing \(name)…")
        }
        let count = viewModel.selectedSources.count
        return String(localized: "connect.selected", defaultValue: "\(count) selected · Secret names only")
    }
}

/// One organization or the account's personal repositories, checked when it will be imported.
private struct ConnectSourceRow: View {
    let source: ConnectViewModel.Source
    let isSelected: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggle() })) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(source.login)
                        .fxTextStyle(.bodyEmphasized)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(detail)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!source.isReady || isDisabled)
            .accessibilityIdentifier(AccessibilityID.Connect.source(source.id))
            Spacer(minLength: Theme.Spacing.medium)
            if case .organization(let status) = source.kind {
                StatusChip(title: status.title, tint: status.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
    }

    private var detail: String {
        switch source.kind {
        case .organization:
            String(localized: "connect.source.organization", defaultValue: "Organization")
        case .personal(let repositories):
            ConnectCopy.personalRepositories(repositories.count)
        }
    }
}

/// Board FirstImport: what was stored, by source.
private struct FirstImportSummaryView: View {
    let summary: FirstImportSummaryModel
    let open: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: String(localized: "connect.summary.title", defaultValue: "Imported."),
            subtitle: String(localized: "connect.summary.subtitle", defaultValue: "Everything FX Vault found, by source."),
            error: nil
        ) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.xLarge, verticalSpacing: Theme.Spacing.medium) {
                GridRow {
                    SectionLabel(String(localized: "connect.summary.source", defaultValue: "Source"))
                    SectionLabel(String(localized: "connect.summary.secrets", defaultValue: "Secrets"))
                    SectionLabel(String(localized: "connect.summary.variables", defaultValue: "Variables"))
                }
                row(
                    title: String(localized: "connect.summary.organizations", defaultValue: "Organizations"),
                    detail: ConnectCopy.organizations(summary.organizationCount),
                    secrets: summary.organizationSecretCount,
                    variables: summary.organizationVariableCount
                )
                row(
                    title: String(localized: "connect.summary.repositories", defaultValue: "Repositories"),
                    detail: ConnectCopy.repositories(summary.repositoryCount, environments: summary.environmentCount),
                    secrets: summary.repositorySecretCount,
                    variables: summary.repositoryVariableCount
                )
                // Key Vault holds secrets only.
                row(
                    title: String(localized: "connect.summary.keyVaults", defaultValue: "Azure Key Vault"),
                    detail: ConnectCopy.keyVaults(summary.keyVaultCount),
                    secrets: summary.keyVaultSecretCount,
                    variables: 0
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Connect.summary)
            Text(ConnectCopy.total(secrets: summary.totalSecretCount, variables: summary.totalVariableCount))
            .fxTextStyle(.bodyEmphasized)
            .foregroundStyle(Theme.Colors.ink)
            if !summary.failedNames.isEmpty {
                Banner(
                    .warning,
                    message: String(
                        localized: "connect.summary.failed",
                        defaultValue: "Not imported: \(summary.failedNames.formatted(.list(type: .and))). Import them later from the sidebar."
                    )
                )
            }
            OnboardingNote(String(
                localized: "connect.summary.note",
                defaultValue: "GitHub never returns secret values: fill them next, or later in each place. Key Vault secrets came with theirs."
            ))
        } footer: {
            Button(action: open) {
                ShellForwardLabel(title: String(localized: "connect.summary.continue", defaultValue: "Continue"))
            }
            .fxButtonStyle(.primary, size: .large)
            .accessibilityIdentifier(AccessibilityID.Connect.openVault)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func row(title: String, detail: String, secrets: Int, variables: Int) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(title)
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                Text(detail)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            Text(secrets, format: .number)
                .fxTextStyle(.mono)
                .foregroundStyle(Theme.Colors.ink)
            Text(variables, format: .number)
                .fxTextStyle(.mono)
                .foregroundStyle(Theme.Colors.ink)
        }
    }
}
