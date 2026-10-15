import SwiftUI
import VaultCore

/// Shown after unlock when the GitHub CLI needs attention (§10.3): missing, older than the
/// required version, untrusted, or without a logged-in account.
struct GHSetupScreen: View {
    @State private var viewModel: GHSetupViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeGHSetupViewModel())
    }

    var body: some View {
        CenteredCard {
            CardHeader(systemImage: "terminal", title: title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(viewModel.commands, id: \.self) { command in
                    CommandRow(command: command) { viewModel.copy($0) }
                }
                if let copied = viewModel.copiedCommand {
                    Text(String(localized: "ghSetup.copied", defaultValue: "Copied \(copied). Run it in Terminal, then check again."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            GHStatusRow(status: viewModel.status)
            HStack {
                Button(String(localized: "ghSetup.notNow", defaultValue: "Not Now")) {
                    viewModel.notNow()
                }
                .help(String(
                    localized: "ghSetup.notNow.help",
                    defaultValue: "Open your vault without GitHub. Listing, importing and syncing stay off."
                ))
                Spacer()
                if viewModel.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "ghSetup.checkAgain", defaultValue: "Check Again")) {
                    Task { await viewModel.checkAgain() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isChecking)
            }
        }
    }

    private var title: String {
        switch viewModel.kind {
        case .install, nil:
            String(localized: "ghSetup.install.title", defaultValue: "Install the GitHub CLI")
        case .upgrade:
            String(localized: "ghSetup.upgrade.title", defaultValue: "Update the GitHub CLI")
        case .untrusted:
            String(localized: "ghSetup.untrusted.title", defaultValue: "The GitHub CLI is not trusted")
        case .login:
            String(localized: "ghSetup.login.title", defaultValue: "Log in to GitHub")
        case .failed:
            String(localized: "ghSetup.failed.title", defaultValue: "FX Vault could not check the GitHub CLI")
        }
    }

    private var subtitle: String {
        switch viewModel.kind {
        case .install, nil:
            String(
                localized: "ghSetup.install.subtitle",
                defaultValue: "FX Vault talks to GitHub only through the GitHub CLI (gh). Install it with Homebrew, then log in."
            )
        case .upgrade(let found, let required):
            String(
                localized: "ghSetup.upgrade.subtitle",
                defaultValue: "Found gh \(found). FX Vault needs \(required) or later: earlier versions put environment names into GitHub URLs without escaping them when they set, list or delete secrets and variables, and miss security fixes."
            )
        case .untrusted(let path):
            String(
                localized: "ghSetup.untrusted.subtitle",
                defaultValue: "\(path) or its folder can be changed by other users, so FX Vault does not run it. Reinstall gh with Homebrew or fix the permissions."
            )
        case .login:
            String(
                localized: "ghSetup.login.subtitle",
                defaultValue: "The GitHub CLI has no github.com account. Log in once in Terminal; FX Vault uses every account gh knows."
            )
        case .failed:
            String(
                localized: "ghSetup.failed.subtitle",
                defaultValue: "Check that gh runs in Terminal. You can also set its path in Settings › Advanced."
            )
        }
    }
}

#Preview {
    if let container = try? AppContainer.preview(ghStatus: .outdated(found: "2.90.0", required: Limits.minimumGHVersion)) {
        GHSetupScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
