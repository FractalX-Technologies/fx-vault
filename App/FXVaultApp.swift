import SwiftUI

/// Scene identifiers. One main window (not a WindowGroup): FX Vault has a single vault.
enum SceneID {
    static let main = "main"
}

/// The process entry point. `--diagnose` is answered here, before SwiftUI creates the app
/// delegate (which opens the vault database) or any window (``DiagnoseCommand``).
@main
enum FXVaultMain {
    static func main() {
        DiagnoseCommand.runIfRequested()
        FXVaultApp.main()
    }
}

struct FXVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(Text(AppIdentity.windowTitle), id: SceneID.main) {
            Group {
                switch appDelegate.bootstrap {
                case .ready(let viewModel):
                    RootScreen(viewModel: viewModel)
                case .failed(let error):
                    StartupFailureScreen(error: error)
                }
            }
            .fxWindowBackground()
        }
        // Only the traffic lights over the content (boards Main2, Lock, Onboarding); the main
        // screen adds its empty toolbar for their place (``MainWindowTitleBar``).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
        .commands {
            if let viewModel = appDelegate.bootstrap.viewModel {
                VaultCommands(viewModel: viewModel)
            }
        }

        Settings {
            Group {
                switch appDelegate.bootstrap {
                case .ready(let viewModel):
                    PreferencesScreen(app: viewModel)
                case .failed(let error):
                    StartupFailureScreen(error: error)
                }
            }
            .fxWindowBackground()
        }

        // The menu bar item (board MenuBar). Not while the app hosts unit tests or previews: it
        // would sit in the developer's menu bar.
        MenuBarExtra(
            AppIdentity.windowTitle,
            systemImage: Theme.Symbols.menuBar,
            isInserted: .constant(appDelegate.bootstrap.viewModel?.container.hasSideEffects == true)
        ) {
            if let viewModel = appDelegate.bootstrap.viewModel {
                MenuBarContent(app: viewModel)
            }
        }
    }
}

/// The menu commands (§10 Toolbar): File › New Repository (⌘N), Import .env (⇧⌘I) and Share
/// Project… (⌥⌘S), Edit › Find (⌘F) and Jump Anywhere (⌘K), View › Hide Sidebar (⌃⌘S), and Vault ›
/// Lock (⌃⌘L) and Sync (⇧⌘S). Commands that act on the main window reach it through the focused
/// scene value (``FocusedValues/mainViewModel``).
struct VaultCommands: Commands {
    let viewModel: AppViewModel
    @FocusedValue(\.mainViewModel) private var main

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(MainCopy.newRepository) {
                main?.newRepository()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(main?.canCreateRepository != true)

            Button(FolderCopy.newFolder) {
                main?.newFolder()
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            .disabled(viewModel.phase != .unlocked || main == nil)

            Button(PlaceCopy.importEnv) {
                main?.importEnv()
            }
            .keyboardShortcut("i", modifiers: [.shift, .command])
            .disabled(main?.canImportEnv != true)

            Divider()

            Button(String(localized: "menu.file.shareProject", defaultValue: "Share Project…")) {
                main?.shareProject()
            }
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(main?.canShareProject != true)
        }

        // SwiftUI adds no Find items of its own (TextEditingCommands is opt-in), so ⌘F is free.
        CommandGroup(replacing: .textEditing) {
            Button(String(localized: "menu.edit.find", defaultValue: "Find")) {
                main?.findInSidebar()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(viewModel.phase != .unlocked || main == nil)

            // ⌘K again closes the palette.
            Button(JumpPaletteCopy.jumpAnywhere) {
                main?.showJumpPalette()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(main?.canJump != true)
        }

        // Before Enter Full Screen, which shares the placement. Edit › Find brings a hidden
        // sidebar back too.
        CommandGroup(before: .sidebar) {
            Button(MainCopy.sidebarCommand(isSidebarHidden: main?.isSidebarHidden == true)) {
                main?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(main == nil)
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
        }
    }
}
