import SwiftUI

/// Settings in the main window (§10 Preferences, 1.0.2; Cursor-like): where the sidebar sits, a
/// pane with Back, Search Settings and the sections (General, Security, Accounts, Sharing,
/// Advanced); beside it the section's title and cards on the ground. ``MainScreen`` shows it in
/// place of its panels while ``AppViewModel/isShowingSettings``.
struct SettingsScreen: View {
    let app: AppViewModel
    let panelWidth: CGFloat
    @State private var viewModel: PreferencesViewModel

    init(app: AppViewModel, panelWidth: CGFloat) {
        self.app = app
        self.panelWidth = panelWidth
        _viewModel = State(initialValue: app.makePreferencesViewModel())
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsNavigationPanel(viewModel: viewModel) {
                app.closeSettings()
            }
            .padding(.top, Theme.Layout.sidebarPanelTopInset)
            .frame(width: panelWidth)
            .mainColumnHeight()
            .fxSidebarPane()
            .overlay(alignment: .top) {
                WindowDragArea()
                    .frame(height: Theme.Layout.sidebarPanelTopInset)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(Theme.Durations.interactionAnimation, value: viewModel.displayedTab)
                .padding(.horizontal, Theme.Layout.mainPanelInset)
        }
        .onChange(of: viewModel.requestedTab, initial: true) {
            viewModel.showRequestedTab()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = viewModel.displayedTab {
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .fxTextStyle(.title2)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Theme.Layout.dialogInset)
                    .padding(.top, Theme.Layout.settingsTitleTopInset)
                section(tab)
            }
            .frame(maxWidth: Theme.Layout.settingsWidth)
            .id(tab)
            .transition(.opacity)
        } else {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: String(localized: "settings.search.empty.title", defaultValue: "No settings match"),
                message: String(localized: "settings.search.empty.message", defaultValue: "Try another word.")
            )
        }
    }

    @ViewBuilder
    private func section(_ tab: PreferencesViewModel.Tab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        case .security:
            SecuritySettingsScreen(preferences: viewModel, viewModel: viewModel.security)
        case .accounts:
            AccountsSettingsScreen(preferences: viewModel)
        case .sharing:
            SharingSettingsScreen(viewModel: viewModel.sharing)
        case .advanced:
            AdvancedSettingsView(viewModel: viewModel)
        }
    }
}

/// The settings panel: ← Back to the vault (⌘[), Search Settings, then the sections it keeps.
private struct SettingsNavigationPanel: View {
    @Bindable var viewModel: PreferencesViewModel
    let onBack: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button(action: onBack) {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Image(systemName: "chevron.left")
                        .font(Theme.Typography.label)
                        .accessibilityHidden(true)
                    Text(String(localized: "settings.back", defaultValue: "Back"))
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(height: Theme.Layout.sidebarControlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier(AccessibilityID.Settings.back)
            .padding(.horizontal, Theme.Spacing.small)
            PanelSearchField(
                prompt: String(localized: "settings.search.prompt", defaultValue: "Search Settings"),
                label: String(localized: "settings.search.label", defaultValue: "Search Settings"),
                accessibilityID: AccessibilityID.Settings.search,
                text: $viewModel.searchText,
                isFocused: $isSearchFocused
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    ForEach(viewModel.visibleTabs) { tab in
                        SidebarTreeRow(
                            level: 0,
                            systemImage: tab.systemImage,
                            title: tab.title,
                            isSelected: viewModel.displayedTab == tab,
                            accessibilityID: AccessibilityID.Settings.section(tab.rawValue)
                        ) {
                            viewModel.selectedTab = tab
                        }
                    }
                }
                .padding(.bottom, Theme.Spacing.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .animation(Theme.Durations.interactionAnimation, value: viewModel.visibleTabs)
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
        SettingsScreen(app: AppViewModel(container: container), panelWidth: Theme.Layout.sidebarWidth)
            .background(MainWindowGround(sidebarWidth: Theme.Layout.sidebarWidth))
    }
}
