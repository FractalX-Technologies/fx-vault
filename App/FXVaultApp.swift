import SwiftUI

/// Scene identifiers. One main window (not a WindowGroup): FX Vault has a single vault.
enum SceneID {
    static let main = "main"
}

@main
struct FXVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(Text(String(localized: "app.window.title", defaultValue: "FX Vault")), id: SceneID.main) {
            switch appDelegate.bootstrap {
            case .ready(let viewModel):
                RootScreen(viewModel: viewModel)
            case .failed(let error):
                StartupFailureScreen(error: error)
            }
        }
        .defaultSize(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
        .commands {
            if let viewModel = appDelegate.bootstrap.viewModel {
                VaultCommands(viewModel: viewModel)
            }
        }

        Settings {
            switch appDelegate.bootstrap {
            case .ready(let viewModel):
                PreferencesScreen(app: viewModel)
            case .failed(let error):
                StartupFailureScreen(error: error)
            }
        }
    }
}

/// The Vault menu: Lock (⌃⌘L) and Sync (⇧⌘S) (§10 Toolbar).
struct VaultCommands: Commands {
    let viewModel: AppViewModel

    var body: some Commands {
        CommandMenu(String(localized: "menu.vault", defaultValue: "Vault")) {
            Button(String(localized: "menu.vault.lock", defaultValue: "Lock FX Vault")) {
                viewModel.lock(trigger: .manual)
            }
            .keyboardShortcut("l", modifiers: [.control, .command])
            .disabled(viewModel.phase != .unlocked)

            // Placeholder: the sync flow (and this command's action) arrives with Milestone 3.
            Button(SyncToolbarButton.title(count: viewModel.pendingChangeCount)) {}
                .keyboardShortcut("s", modifiers: [.shift, .command])
                .disabled(true)
        }
    }
}
