import SwiftUI

/// Scene identifiers. One main window (not a WindowGroup): FX Vault has a single vault.
enum SceneID {
    static let main = "main"
}

@main
struct FXVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appViewModel = AppViewModel(container: .forCurrentProcess())

    var body: some Scene {
        Window(Text(String(localized: "app.window.title", defaultValue: "FX Vault")), id: SceneID.main) {
            RootScreen(viewModel: appViewModel)
        }
        .defaultSize(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)

        Settings {
            Text(String(localized: "settings.placeholder", defaultValue: "Settings will appear here."))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(Theme.Spacing.xLarge)
                .frame(width: Theme.Layout.settingsWidth)
        }
    }
}
