import SwiftUI

/// Preferences › Accounts (placeholder until Milestone 2 wires the accounts repository: login,
/// token state, scopes, gh path, SSH alias, Test and Re-check).
struct AccountsSettingsScreen: View {
    let preferences: PreferencesViewModel

    var body: some View {
        if preferences.isVaultSettingsAvailable {
            EmptyStateView(
                systemImage: "person.2",
                title: String(localized: "settings.accounts.empty.title", defaultValue: "No GitHub accounts yet"),
                message: String(
                    localized: "settings.accounts.empty.message",
                    defaultValue: "Accounts logged in to the GitHub CLI appear here, with their scopes and SSH aliases."
                )
            )
        } else {
            VaultSettingsLockedView()
        }
    }
}
