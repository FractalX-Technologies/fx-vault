import SwiftUI
import VaultData

/// Preferences › Accounts (§10): gh path and version, then each account with its token state,
/// scopes (with copyable fix commands), SSH alias picker, **Test** and **Re-check**.
struct AccountsSettingsScreen: View {
    let preferences: PreferencesViewModel

    var body: some View {
        if preferences.isVaultSettingsAvailable {
            AccountsSettingsContent(viewModel: preferences.accounts)
        } else {
            VaultSettingsLockedView()
        }
    }
}

private struct AccountsSettingsContent: View {
    let viewModel: AccountsSettingsViewModel

    var body: some View {
        Form {
            Section(String(localized: "settings.accounts.gh.section", defaultValue: "GitHub CLI")) {
                if let installation = viewModel.installation {
                    LabeledContent(String(localized: "settings.accounts.gh.path", defaultValue: "Path")) {
                        Text(verbatim: installation.resolvedPath)
                            .font(Theme.Typography.monospaced)
                            .textSelection(.enabled)
                    }
                    LabeledContent(String(localized: "settings.accounts.gh.version", defaultValue: "Version")) {
                        Text(verbatim: installation.version.description)
                    }
                } else if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(String(localized: "settings.accounts.gh.missing", defaultValue: "The GitHub CLI was not found."))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                if let error = viewModel.error {
                    InlineErrorView(error: error)
                }
            }
            if viewModel.accounts.isEmpty, !viewModel.isLoading {
                Section {
                    Text(String(
                        localized: "settings.accounts.empty.message",
                        defaultValue: "Accounts logged in to the GitHub CLI appear here, with their scopes and SSH aliases."
                    ))
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            ForEach(viewModel.accounts) { account in
                AccountSection(account: account, viewModel: viewModel)
            }
            if let copied = viewModel.copiedCommand {
                Section {
                    Text(String(localized: "settings.accounts.copied", defaultValue: "Copied \(copied). Run it in Terminal, then Re-check."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await viewModel.load()
        }
    }
}

/// One account: token state, scopes, fix commands, SSH alias, Test and Re-check.
private struct AccountSection: View {
    let account: GHAccountSummaryModel
    let viewModel: AccountsSettingsViewModel

    var body: some View {
        Section {
            LabeledContent(String(localized: "settings.accounts.token", defaultValue: "Token")) {
                StatusChip(title: account.tokenStateTitle, tint: account.tokenStateTint)
            }
            LabeledContent(String(localized: "settings.accounts.scopes", defaultValue: "Scopes")) {
                StatusChip(title: account.scopesTitle, tint: account.scopesTint)
            }
            if let commands = viewModel.fixCommands[account.id], !commands.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    Text(String(
                        localized: "settings.accounts.scopes.fix",
                        defaultValue: "Run these in Terminal to add the missing scopes:"
                    ))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    ForEach(commands, id: \.self) { command in
                        CommandRow(command: command) { viewModel.copy($0) }
                    }
                }
            }
            Picker(String(localized: "settings.accounts.ssh.alias", defaultValue: "SSH alias"), selection: aliasBinding) {
                Text(String(localized: "settings.accounts.ssh.none", defaultValue: "None")).tag(String?.none)
                ForEach(viewModel.aliasChoices) { host in
                    Text(verbatim: host.alias).tag(String?.some(host.alias))
                }
            }
            .disabled(viewModel.isBusy(account) || !account.isLoggedIn)
            if let result = viewModel.testResults[account.id] {
                Label(result.localizedMessage, systemImage: result.isVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.isVerified ? Theme.Colors.success : Theme.Colors.warning)
                    .font(Theme.Typography.callout)
            } else if account.account.isSSHAliasVerified, let login = account.account.sshVerifiedLogin {
                Label(
                    SSHAliasTestResultModel.authenticatedAsAccount(login: login).localizedMessage,
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(Theme.Colors.success)
                .font(Theme.Typography.callout)
            }
            HStack {
                Spacer()
                if viewModel.isBusy(account) {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "settings.accounts.ssh.test", defaultValue: "Test")) {
                    Task { await viewModel.test(account) }
                }
                .disabled(account.account.sshHostAlias == nil || viewModel.isBusy(account))
                Button(String(localized: "settings.accounts.recheck", defaultValue: "Re-check")) {
                    Task { await viewModel.recheck(account) }
                }
                .disabled(viewModel.isBusy(account) || !account.isLoggedIn)
            }
        } header: {
            Text(verbatim: account.account.login)
        }
    }

    private var aliasBinding: Binding<String?> {
        Binding(
            get: { account.account.sshHostAlias },
            set: { alias in Task { await viewModel.setAlias(alias, for: account) } }
        )
    }
}
