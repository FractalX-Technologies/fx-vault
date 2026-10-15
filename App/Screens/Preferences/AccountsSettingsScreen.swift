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
        PreferencesPage {
            PreferencesSection(String(localized: "settings.accounts.gh.section", defaultValue: "GitHub CLI")) {
                if let installation = viewModel.installation {
                    PreferencesRow(String(localized: "settings.accounts.gh.path", defaultValue: "Path")) {
                        Text(verbatim: installation.resolvedPath)
                            .fxTextStyle(.monoName)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    HairlineDivider()
                    PreferencesRow(String(localized: "settings.accounts.gh.version", defaultValue: "Version")) {
                        Text(verbatim: installation.version.description)
                            .fxTextStyle(.monoName)
                            .foregroundStyle(Theme.Colors.mutedText)
                    }
                } else if viewModel.isLoading {
                    PreferencesBlock {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    PreferencesBlock {
                        Text(String(localized: "settings.accounts.gh.missing", defaultValue: "The GitHub CLI was not found."))
                            .fxTextStyle(.body)
                            .foregroundStyle(Theme.Colors.mutedText)
                    }
                }
                if let error = viewModel.error {
                    HairlineDivider()
                    PreferencesBlock {
                        InlineErrorView(error: error)
                    }
                }
            }
            if viewModel.accounts.isEmpty, !viewModel.isLoading {
                PreferencesSection(String(localized: "settings.accounts.section", defaultValue: "Accounts")) {
                    PreferencesBlock {
                        Text(String(
                            localized: "settings.accounts.empty.message",
                            defaultValue: "Accounts logged in to the GitHub CLI appear here, with their scopes and SSH aliases."
                        ))
                        .fxTextStyle(.body)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(viewModel.accounts) { account in
                AccountSection(account: account, viewModel: viewModel)
            }
            if let copied = viewModel.copiedCommand {
                Text(String(localized: "settings.accounts.copied", defaultValue: "Copied \(copied). Run it in Terminal, then Re-check."))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .padding(.horizontal, Theme.Spacing.xSmall)
            }
        }
        .task {
            await viewModel.load()
        }
    }
}

/// One account: login with Test and Re-check, token state, scopes, fix commands, SSH alias.
private struct AccountSection: View {
    let account: GHAccountSummaryModel
    let viewModel: AccountsSettingsViewModel

    var body: some View {
        PreferencesSection(String(localized: "settings.accounts.account.section", defaultValue: "Account")) {
            HStack(spacing: Theme.Spacing.small) {
                Text(verbatim: account.account.login)
                    .fxTextStyle(.mono)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if viewModel.isBusy(account) {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "settings.accounts.ssh.test", defaultValue: "Test")) {
                    Task { await viewModel.test(account) }
                }
                .fxButtonStyle(.secondary)
                .disabled(account.account.sshHostAlias == nil || viewModel.isBusy(account))
                Button(String(localized: "settings.accounts.recheck", defaultValue: "Re-check")) {
                    Task { await viewModel.recheck(account) }
                }
                .fxButtonStyle(.secondary)
                .disabled(viewModel.isBusy(account) || !account.isLoggedIn)
            }
            .padding(.vertical, Theme.Spacing.medium)
            .padding(.horizontal, Theme.Spacing.large)
            HairlineDivider()
            PreferencesRow(String(localized: "settings.accounts.token", defaultValue: "Token")) {
                StatusChip(title: account.tokenStateTitle, tint: account.tokenStateTint)
            }
            HairlineDivider()
            PreferencesRow(String(localized: "settings.accounts.scopes", defaultValue: "Scopes")) {
                StatusChip(title: account.scopesTitle, tint: account.scopesTint)
            }
            if let commands = viewModel.fixCommands[account.id], !commands.isEmpty {
                HairlineDivider()
                PreferencesBlock {
                    Text(String(
                        localized: "settings.accounts.scopes.fix",
                        defaultValue: "Run these in Terminal to add the missing scopes:"
                    ))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    ForEach(commands, id: \.self) { command in
                        CommandRow(command: command) { viewModel.copy($0) }
                    }
                }
            }
            HairlineDivider()
            PreferencesRow(String(localized: "settings.accounts.ssh.alias", defaultValue: "SSH alias")) {
                Picker(String(localized: "settings.accounts.ssh.alias", defaultValue: "SSH alias"), selection: aliasBinding) {
                    Text(String(localized: "settings.accounts.ssh.none", defaultValue: "None")).tag(String?.none)
                    ForEach(viewModel.aliasChoices) { host in
                        Text(verbatim: host.alias).tag(String?.some(host.alias))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(viewModel.isBusy(account) || !account.isLoggedIn)
            }
            if let result = viewModel.testResults[account.id] {
                HairlineDivider()
                PreferencesBlock {
                    testResultLabel(result.localizedMessage, isVerified: result.isVerified)
                }
            } else if account.account.isSSHAliasVerified, let login = account.account.sshVerifiedLogin {
                HairlineDivider()
                PreferencesBlock {
                    testResultLabel(
                        SSHAliasTestResultModel.authenticatedAsAccount(login: login).localizedMessage,
                        isVerified: true
                    )
                }
            }
        }
    }

    private func testResultLabel(_ message: String, isVerified: Bool) -> some View {
        Label {
            Text(message)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isVerified ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isVerified ? Theme.Colors.success : Theme.Colors.warning)
        }
    }

    private var aliasBinding: Binding<String?> {
        Binding(
            get: { account.account.sshHostAlias },
            set: { alias in Task { await viewModel.setAlias(alias, for: account) } }
        )
    }
}
