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

/// The menu commands (§10 Toolbar): File › New Repository (⌘N) and Import .env (⇧⌘I), and the
/// Vault menu with Lock (⌃⌘L), Sync (⇧⌘S) and Share. Commands that act on the main window reach
/// it through the focused scene value (``FocusedValues/mainViewModel``).
struct VaultCommands: Commands {
    let viewModel: AppViewModel
    @FocusedValue(\.mainViewModel) private var main

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "menu.file.newRepository", defaultValue: "New Repository…")) {
                main?.newRepository()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(main?.canCreateRepository != true)

            Button(String(localized: "menu.file.importEnv", defaultValue: "Import .env…")) {
                main?.importEnv()
            }
            .keyboardShortcut("i", modifiers: [.shift, .command])
            .disabled(main?.canImportEnv != true)
        }

        CommandMenu(String(localized: "menu.vault", defaultValue: "Vault")) {
            Button(String(localized: "menu.vault.lock", defaultValue: "Lock FX Vault")) {
                viewModel.lock(trigger: .manual)
            }
            .keyboardShortcut("l", modifiers: [.control, .command])
            .disabled(viewModel.phase != .unlocked)

            Button(SyncToolbarButton.title(count: viewModel.pendingChangeCount)) {
                main?.sync()
            }
            .keyboardShortcut("s", modifiers: [.shift, .command])
            .disabled(main?.canSync != true)

            Divider()

            Menu(String(localized: "menu.vault.share", defaultValue: "Share")) {
                Button(String(localized: "toolbar.share.file", defaultValue: "File…")) {
                    main?.shareFile()
                }
                .disabled(main?.canShareFile != true)
                Button(String(localized: "toolbar.share.nearby", defaultValue: "Nearby…")) {
                    main?.shareNearby()
                }
                .disabled(main == nil)
                Button(String(localized: "toolbar.share.receive", defaultValue: "Receive Nearby…")) {
                    main?.receiveNearby()
                }
                .disabled(main == nil)
            }
        }
    }
}
