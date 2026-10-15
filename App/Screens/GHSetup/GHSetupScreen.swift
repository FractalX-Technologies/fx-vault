import GitHubKit
import SwiftUI
import VaultCore

/// Shown after unlock when the GitHub CLI needs attention (§10.3): missing, older than the
/// required version, untrusted, owned by another user, or without a usable logged-in account.
/// One card on the dotted ground.
struct GHSetupScreen: View {
    @State private var viewModel: GHSetupViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeGHSetupViewModel())
    }

    var body: some View {
        ShellCardLayout {
            SheetHeader(
                label: String(localized: "ghSetup.label", defaultValue: "GitHub CLI"),
                title: title,
                subtitle: subtitle
            )
            if case .trustOwner(let path, let owner, _) = viewModel.kind {
                trustBlock(path: path, owner: owner)
            }
            if case .unusableAccounts(let accounts) = viewModel.kind {
                unusableAccountsList(accounts)
            }
            if !viewModel.commands.isEmpty || viewModel.copiedCommand != nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(viewModel.commands, id: \.self) { command in
                        CommandRow(command: command) { viewModel.copy($0) }
                    }
                    if let copied = viewModel.copiedCommand {
                        Text(String(localized: "ghSetup.copied", defaultValue: "Copied \(copied). Run it in Terminal, then check again."))
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                    }
                }
            }
            if viewModel.hasCopiedDiagnostics {
                Text(String(
                    localized: "ghSetup.diagnostics.copied",
                    defaultValue: "Copied the diagnostics: paths, versions and account names, never tokens or values. Paste them into your message to FractalX."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            }
            GHStatusRow(status: viewModel.status)
            ShellFooter(isWorking: viewModel.isWorking) {
                Button(String(localized: "ghSetup.copyDiagnostics", defaultValue: "Copy Diagnostics")) {
                    Task { await viewModel.copyDiagnostics() }
                }
                .fxButtonStyle(.ghost)
                .disabled(viewModel.isCollectingDiagnostics)
                .help(String(
                    localized: "ghSetup.copyDiagnostics.help",
                    defaultValue: "Copy a report of which gh FX Vault found and why, for support. It contains no tokens or values."
                ))
            } buttons: {
                Button(String(localized: "ghSetup.notNow", defaultValue: "Not Now")) {
                    viewModel.notNow()
                }
                .fxButtonStyle(.secondary, size: .large)
                .help(String(
                    localized: "ghSetup.notNow.help",
                    defaultValue: "Open your vault without GitHub. Listing, importing and syncing stay off."
                ))
                Button(String(localized: "ghSetup.checkAgain", defaultValue: "Check Again")) {
                    Task { await viewModel.checkAgain() }
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isChecking || viewModel.isTrusting)
            }
        }
    }

    /// The path, what trusting means, and **Trust This gh** (deliberately not the default
    /// button: Return checks again, it never consents).
    private func trustBlock(path: String, owner: GHBinaryOwnerModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(verbatim: path)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(String(
                localized: "ghSetup.trust.consequence",
                defaultValue: "If you trust it, FX Vault runs this gh only while the user \(owner.displayName) owns it and no one else can change it. You can revoke this in Settings › Advanced."
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "ghSetup.trust.button", defaultValue: "Trust This gh")) {
                Task { await viewModel.trustOwner() }
            }
            .fxButtonStyle(.outline)
            .disabled(viewModel.isTrusting || viewModel.isChecking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
    }

    /// Each account gh lists that FX Vault cannot use, with the reason.
    private func unusableAccountsList(_ accounts: [GHUnusableAccountModel]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(accounts.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: accounts[index].displayTitle)
                        .fxTextStyle(.monoName)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                    Text(accounts[index].reasonText)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxCalloutBackground()
    }

    private var title: String {
        switch viewModel.kind {
        case .install, nil:
            String(localized: "ghSetup.install.title", defaultValue: "Install the GitHub CLI")
        case .upgrade:
            String(localized: "ghSetup.upgrade.title", defaultValue: "Update the GitHub CLI")
        case .untrusted:
            String(localized: "ghSetup.untrusted.title", defaultValue: "The GitHub CLI is not trusted")
        case .trustOwner:
            String(localized: "ghSetup.trust.title", defaultValue: "The GitHub CLI belongs to another user")
        case .login:
            String(localized: "ghSetup.login.title", defaultValue: "Log in to GitHub")
        case .environmentToken:
            String(localized: "ghSetup.environmentToken.title", defaultValue: "Store your GitHub login in gh")
        case .unusableAccounts:
            String(localized: "ghSetup.unusableAccounts.title", defaultValue: "FX Vault can't use these GitHub accounts")
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
        case .upgrade(let found, let required, let path):
            if let path {
                String(
                    localized: "ghSetup.upgrade.subtitle.path",
                    defaultValue: "Found gh \(found) at \(path), the gh your shell runs. FX Vault needs \(required) or later: earlier versions put environment names into GitHub URLs without escaping them when they set, list or delete secrets and variables, and miss security fixes."
                )
            } else {
                String(
                    localized: "ghSetup.upgrade.subtitle",
                    defaultValue: "Found gh \(found). FX Vault needs \(required) or later: earlier versions put environment names into GitHub URLs without escaping them when they set, list or delete secrets and variables, and miss security fixes."
                )
            }
        case .untrusted(let path, let reason):
            untrustedSubtitle(path: path, reason: reason)
        case .trustOwner(let path, let owner, let isHomebrew):
            isHomebrew
                ? String(
                    localized: "ghSetup.trust.subtitle.homebrew",
                    defaultValue: "Homebrew on this Mac belongs to the user \(owner.displayName); anyone who can sign in as \(owner.displayName) could replace gh and see the values FX Vault sends to it."
                )
                : String(
                    localized: "ghSetup.trust.subtitle",
                    defaultValue: "\(path) belongs to the user \(owner.displayName); anyone who can sign in as \(owner.displayName) could replace gh and see the values FX Vault sends to it."
                )
        case .login:
            String(
                localized: "ghSetup.login.subtitle",
                defaultValue: "The GitHub CLI has no github.com account. Log in once in Terminal; FX Vault uses every account gh knows."
            )
        case .environmentToken(let variables):
            String(
                localized: "ghSetup.environmentToken.subtitle",
                defaultValue: "Your shell sets \(variables.localizedList), so gh in Terminal uses that token and shows you as logged in, and gh auth login refuses to save an account. FX Vault never uses these variables: it needs an account gh stores. Run this in Terminal, then choose Check Again."
            )
        case .unusableAccounts:
            String(
                localized: "ghSetup.unusableAccounts.subtitle",
                defaultValue: "gh is logged in, but FX Vault does not accept these account names. Log in with another account, or copy the diagnostics and send them to FractalX."
            )
        case .failed:
            String(
                localized: "ghSetup.failed.subtitle",
                defaultValue: "Check that gh runs in Terminal. You can also set its path in Settings › Advanced."
            )
        }
    }

    private func untrustedSubtitle(path: String, reason: GHBinaryRejection?) -> String {
        switch reason {
        case .untrustedOwner:
            String(
                localized: "ghSetup.untrusted.owners.subtitle",
                defaultValue: "\(path) or its folder belongs to other users, so FX Vault does not run it. Reinstall gh with Homebrew, or set the path of your own gh in Settings › Advanced."
            )
        case .notExecutable, .notRegularFile:
            String(
                localized: "ghSetup.untrusted.notExecutable.subtitle",
                defaultValue: "\(path) is not an executable file, so FX Vault cannot run it. Reinstall gh with Homebrew, or set its path in Settings › Advanced."
            )
        case .writableFile, .writableDirectory, .notFound, nil:
            String(
                localized: "ghSetup.untrusted.subtitle",
                defaultValue: "\(path) or its folder can be changed by other users, so FX Vault does not run it. Reinstall gh with Homebrew or fix the permissions."
            )
        }
    }
}

#Preview("Outdated") {
    if let container = try? AppContainer.preview(ghStatus: .outdated(
        found: "2.90.0",
        required: Limits.minimumGHVersion,
        path: AppContainer.previewGHPath
    )) {
        GHSetupScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}

#Preview("Owned by another user") {
    if let container = try? AppContainer.preview(ghStatus: .foreignOwner(
        path: AppContainer.previewGHPath,
        owner: GHBinaryOwnerModel(uid: AppContainer.previewOtherOwnerUID, name: "admin-b"),
        isHomebrew: true
    )) {
        GHSetupScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
