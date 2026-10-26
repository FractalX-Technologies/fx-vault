import SwiftUI

/// The Settings window (§10 Preferences; boards Settings-*): General, Security, Accounts,
/// Sharing (v0.9.0), Advanced, as the system's toolbar tabs.
struct PreferencesScreen: View {
    @State private var viewModel: PreferencesViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makePreferencesViewModel())
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        TabView(selection: $viewModel.selectedTab) {
            GeneralSettingsView(viewModel: viewModel)
                .tabItem {
                    Label(String(localized: "settings.tab.general", defaultValue: "General"), systemImage: "gearshape")
                }
                .tag(PreferencesViewModel.Tab.general)
            SecuritySettingsScreen(preferences: viewModel, viewModel: viewModel.security)
                .tabItem {
                    Label(String(localized: "settings.tab.security", defaultValue: "Security"), systemImage: "lock")
                }
                .tag(PreferencesViewModel.Tab.security)
            AccountsSettingsScreen(preferences: viewModel)
                .tabItem {
                    Label(String(localized: "settings.tab.accounts", defaultValue: "Accounts"), systemImage: "person")
                }
                .tag(PreferencesViewModel.Tab.accounts)
            SharingSettingsScreen(viewModel: viewModel.sharing)
                .tabItem {
                    Label(ProjectShareCopy.settingsTab, systemImage: "square.and.arrow.up")
                }
                .tag(PreferencesViewModel.Tab.sharing)
            AdvancedSettingsView(viewModel: viewModel)
                .tabItem {
                    Label(String(localized: "settings.tab.advanced", defaultValue: "Advanced"), systemImage: "slider.horizontal.3")
                }
                .tag(PreferencesViewModel.Tab.advanced)
        }
        .frame(width: Theme.Layout.settingsWidth)
        .frame(minHeight: Theme.Layout.settingsMinHeight)
        .onChange(of: viewModel.requestedTab, initial: true) {
            viewModel.showRequestedTab()
        }
        .background(WindowAccessor { window in
            // Its sheets can show a recovery key: never restore this window with state (§5.11).
            window.isRestorable = false
        })
    }
}

/// Shown in place of a tab's content while the vault is locked (or does not exist yet).
struct VaultSettingsLockedView: View {
    var body: some View {
        EmptyStateView(
            systemImage: "lock",
            title: String(localized: "settings.locked.title", defaultValue: "Unlock FX Vault to change these settings"),
            message: String(
                localized: "settings.locked.message",
                defaultValue: "These settings are stored in your encrypted vault."
            )
        )
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        PreferencesScreen(app: AppViewModel(container: container))
    }
}
