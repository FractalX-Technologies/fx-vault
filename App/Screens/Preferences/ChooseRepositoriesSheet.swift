import SwiftUI
import VaultData

/// Choose Repositories… (1.0.3; Choose Vaults…'s twin for GitHub): one account's repositories by
/// owner with a search field, the ones already in FX Vault checked and disabled, then Add
/// Repositories.
struct ChooseRepositoriesSheet: View {
    @Bindable var chooser: ChooseRepositoriesModel
    let viewModel: AccountsSettingsViewModel

    var body: some View {
        DialogSheet(
            title: ChooseRepositoriesCopy.title,
            subtitle: chooser.accountLogin,
            footerNote: chooser.importingName.map(ChooseRepositoriesCopy.importing),
            isWorking: chooser.isLoading || chooser.isImporting
        ) {
            if let failure = chooser.failure {
                Banner(.danger, message: failure.message)
            }
            if chooser.isSearchable {
                ChooserSearchField(
                    prompt: ChooseRepositoriesCopy.search,
                    accessibilityID: AccessibilityID.Accounts.repositorySearch,
                    text: $chooser.query
                )
            }
            ChooseRepositoriesList(chooser: chooser)
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                viewModel.closeRepositoryChooser()
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
            .disabled(chooser.isImporting)
            Button(ChooseRepositoriesCopy.add) {
                Task { await viewModel.addChosenRepositories() }
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
            .disabled(chooser.selectedRepositories.isEmpty || chooser.isLoading || chooser.isImporting)
            .accessibilityIdentifier(AccessibilityID.Accounts.addRepositories)
        }
        .frame(width: Theme.Layout.sheetWidth)
        .frame(maxHeight: Theme.Layout.chooseVaultsSheetMaxHeight)
        .task {
            if !chooser.hasLoaded {
                await chooser.load()
            }
        }
    }
}

/// Each owner with its repositories, or why there is nothing to show.
private struct ChooseRepositoriesList: View {
    let chooser: ChooseRepositoriesModel

    var body: some View {
        if let note = chooser.emptyNote {
            OnboardingNote(note)
        }
        ForEach(chooser.visibleOwners) { owner in
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(owner.login)
                if let failure = owner.failure {
                    OnboardingNote(failure.message)
                }
                ForEach(owner.repositories) { repository in
                    ChooseRepositoryRow(
                        repository: repository,
                        isSelected: chooser.isSelected(repository),
                        isDisabled: repository.isImported || chooser.isImporting
                    ) {
                        chooser.toggle(repository)
                    }
                }
            }
        }
    }
}

/// One repository, checked when it will be imported; one already in FX Vault stays checked and
/// disabled, and says so.
private struct ChooseRepositoryRow: View {
    let repository: CatalogRepoModel
    let isSelected: Bool
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        ChoiceCheckboxRow(
            title: repository.ref.name,
            detail: ChooseRepositoriesCopy.detail(repository),
            isSelected: isSelected,
            isDisabled: isDisabled,
            accessibilityID: AccessibilityID.Accounts.repository(repository.id),
            toggle: toggle
        )
    }
}
