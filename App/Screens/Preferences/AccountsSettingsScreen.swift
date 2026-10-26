import GitHubKit
import SwiftUI
import VaultData

/// Preferences › Accounts (§10; board Settings-Accounts): each gh account with its SSH alias,
/// **Re-check** and **Test**, its token, scopes and organizations (1.0), the accounts FX Vault
/// can't use, then Add Account…. The gh path and version are in Advanced.
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
            VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                PreferencesSection(String(localized: "settings.accounts.github.section", defaultValue: "GitHub")) {
                    if viewModel.accounts.isEmpty {
                        PreferencesBlock {
                            emptyState
                        }
                    }
                    ForEach(Array(viewModel.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 {
                            HairlineDivider()
                        }
                        AccountRow(account: account, viewModel: viewModel)
                    }
                    ForEach(viewModel.unusableAccounts.indices, id: \.self) { index in
                        HairlineDivider()
                        UnusableAccountRow(account: viewModel.unusableAccounts[index])
                    }
                    if let error = viewModel.error {
                        HairlineDivider()
                        PreferencesBlock {
                            InlineErrorView(error: error)
                        }
                    }
                }
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    if viewModel.tokenVariables.isEmpty {
                        Spacer(minLength: 0)
                    } else {
                        TokenVariableNote(variables: viewModel.tokenVariables) { viewModel.copy($0) }
                    }
                    AddAccountButton(viewModel: viewModel)
                }
                if let copied = viewModel.copiedCommand {
                    PreferencesFootnote(String(
                        localized: "settings.accounts.copied",
                        defaultValue: "Copied \(copied). Run it in Terminal, then Re-check."
                    ))
                }
            }
            if !viewModel.unmappedAliases.isEmpty {
                UnmappedAliasesSection(aliases: viewModel.unmappedAliases, viewModel: viewModel)
            }
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if viewModel.isLoading {
            ProgressView()
                .controlSize(.small)
        } else if viewModel.installation == nil {
            emptyText(String(localized: "settings.accounts.gh.missing", defaultValue: "The GitHub CLI was not found."))
        } else {
            emptyText(String(
                localized: "settings.accounts.empty.message",
                defaultValue: "Accounts logged in to the GitHub CLI appear here, with their scopes and SSH aliases."
            ))
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .fxTextStyle(.body)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// **Add Account…** (board Settings-Accounts): gh logs accounts in, interactively, so FX Vault
/// gives the command to run in Terminal and checks again (the in-app device flow is B4b).
private struct AddAccountButton: View {
    let viewModel: AccountsSettingsViewModel
    @State private var isPresented = false

    var body: some View {
        Button(String(localized: "settings.accounts.add", defaultValue: "Add Account…")) {
            isPresented = true
        }
        .fxButtonStyle(.outline, size: .compact)
        .accessibilityIdentifier(AccessibilityID.Accounts.addAccount)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(String(localized: "settings.accounts.add.title", defaultValue: "Add a GitHub account"))
                    .fxTextStyle(.bodyEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                GHLoginSteps(
                    message: String(
                        localized: "settings.accounts.add.message",
                        defaultValue: "Log it in to the GitHub CLI in Terminal, then choose Check Again. gh keeps your other accounts."
                    ),
                    checkAgainID: AccessibilityID.Accounts.addAccountCheckAgain,
                    viewModel: viewModel
                ) {
                    isPresented = false
                }
            }
            .padding(Theme.Spacing.medium)
            .frame(width: Theme.Layout.settingsPopoverWidth)
        }
    }
}

/// A gh login to run in Terminal: why, `gh auth login` with Copy, then Check Again, which reads
/// the accounts again and calls `afterCheck` (Add Account…, SSH aliases without an account).
private struct GHLoginSteps: View {
    let message: String
    let checkAgainID: String
    let viewModel: AccountsSettingsViewModel
    var afterCheck: () -> Void = {}

    var body: some View {
        Text(message)
            .fxTextStyle(.formNote)
            .foregroundStyle(Theme.Colors.subtleText)
            .fixedSize(horizontal: false, vertical: true)
        CommandRow(command: GHSetupViewModel.loginCommand) { viewModel.copy($0) }
        Button(String(localized: "settings.accounts.unmapped.checkAgain", defaultValue: "Check Again")) {
            Task {
                await viewModel.checkAgain()
                afterCheck()
            }
        }
        .fxButtonStyle(.outline, size: .compact)
        .disabled(viewModel.isLoading)
        .accessibilityIdentifier(checkAgainID)
    }
}

/// The note under the accounts when the user's shell exports `GH_TOKEN` or `GITHUB_TOKEN`
/// (v0.3.1): gh in Terminal uses that token, FX Vault only the accounts gh stores.
private struct TokenVariableNote: View {
    let variables: [ShellVariableName]
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            Label {
                Text(String(
                    localized: "settings.accounts.tokenVariable.note",
                    defaultValue: "Your shell sets \(variables.localizedList). gh in Terminal uses that token instead of the accounts listed here; FX Vault ignores it and uses only the accounts gh stores. To store one, run:"
                ))
                .fxTextStyle(.formNote)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.ink)
            }
            CommandRow(command: GHSetupViewModel.environmentLoginCommand, onCopy: onCopy)
        }
        .padding(.horizontal, Theme.Spacing.xSmall)
    }
}

/// The GitHub aliases in `~/.ssh/config` that no account uses (v0.3.2), usually the key of an
/// account that is not logged in to gh: log it in, Check Again, then pick the alias in its menu.
private struct UnmappedAliasesSection: View {
    let aliases: [SSHHostEntryModel]
    let viewModel: AccountsSettingsViewModel

    var body: some View {
        PreferencesSection(String(localized: "settings.accounts.unmapped.section", defaultValue: "SSH aliases without an account")) {
            ForEach(aliases) { host in
                PreferencesBlock(spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: host.alias)
                        .font(Theme.Typography.monoMetaEmphasized)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                    if let hostName = host.hostName {
                        Text(verbatim: hostName)
                            .fxTextStyle(.formNote)
                            .foregroundStyle(Theme.Colors.subtleText)
                    }
                }
                .accessibilityElement(children: .combine)
                HairlineDivider()
            }
            PreferencesBlock {
                GHLoginSteps(
                    message: String(
                        localized: "settings.accounts.unmapped.message",
                        defaultValue: "No account here uses these aliases. If one is the key of a GitHub account that is not logged in to the GitHub CLI, log that account in, choose Check Again, then pick the alias in that account's SSH alias menu. gh keeps your other accounts; the new one becomes gh's active account in Terminal (gh auth switch changes it back)."
                    ),
                    checkAgainID: AccessibilityID.Accounts.unmappedCheckAgain,
                    viewModel: viewModel
                )
            }
        }
    }
}

/// An account gh lists that FX Vault cannot use (v0.3.1): its login, quiet, and why.
private struct UnusableAccountRow: View {
    let account: GHUnusableAccountModel

    var body: some View {
        PreferencesBlock {
            HStack(spacing: Theme.Spacing.small) {
                AccountSymbol(systemName: Theme.Symbols.person)
                Text(verbatim: account.displayTitle)
                    .font(Theme.Typography.monoMetaEmphasized)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                PreferencesStatus(
                    title: String(localized: "settings.accounts.unusable.row", defaultValue: "Can’t use · \(account.reasonText)"),
                    mark: .needsYou
                )
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 14 pt column of an account's symbols, so the 13 pt person and the 11 pt organizations
/// line up (board Settings-Accounts).
private struct AccountSymbol: View {
    let systemName: String
    var isSubline = false

    var body: some View {
        Image(systemName: systemName)
            .font(isSubline ? Theme.Typography.label : Theme.Typography.callout)
            .foregroundStyle(Theme.Colors.mutedText)
            .frame(width: Theme.Layout.settingsSymbolWidth)
            .accessibilityHidden(true)
    }
}

/// One account (board Settings-Accounts): its login and SSH alias with **Re-check** and
/// **Test**, then a line each for the token, the scopes and every organization.
private struct AccountRow: View {
    let account: GHAccountSummaryModel
    let viewModel: AccountsSettingsViewModel

    var body: some View {
        PreferencesBlock(spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                AccountSymbol(systemName: Theme.Symbols.person)
                Text(verbatim: account.account.login)
                    .font(Theme.Typography.monoMetaEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                aliasMenu
                Spacer(minLength: Theme.Spacing.small)
                if viewModel.isBusy(account) {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "settings.accounts.recheck", defaultValue: "Re-check")) {
                    Task { await viewModel.recheck(account) }
                }
                .fxButtonStyle(.outline, size: .compact)
                .disabled(viewModel.isBusy(account) || !account.isLoggedIn)
                Button(String(localized: "settings.accounts.ssh.test", defaultValue: "Test")) {
                    Task { await viewModel.test(account) }
                }
                .fxButtonStyle(.outline, size: .compact)
                .disabled(account.account.sshHostAlias == nil || viewModel.isBusy(account))
            }
            .frame(minHeight: Theme.Layout.settingsAccountLineHeight)
            subline(symbol: "key", name: String(localized: "settings.accounts.token", defaultValue: "Token")) {
                PreferencesStatus(title: account.tokenStateTitle, mark: account.tokenStateMark)
            }
            subline(symbol: "checklist", name: String(localized: "settings.accounts.scopes", defaultValue: "Scopes")) {
                PreferencesStatus(title: account.scopesTitle, mark: account.scopesMark)
            }
            if let commands = viewModel.fixCommands[account.id], !commands.isEmpty {
                commandList(
                    String(localized: "settings.accounts.scopes.fix", defaultValue: "Run these in Terminal to add the missing scopes:"),
                    commands: commands
                )
            }
            ForEach(viewModel.organizations[account.id] ?? []) { organization in
                organizationLine(organization)
            }
            if let commands = viewModel.adminOrgCommands[account.id], !commands.isEmpty {
                commandList(
                    String(
                        localized: "settings.accounts.org.adminOrgFix",
                        defaultValue: "Organization secrets need admin:org. Run these in Terminal, approve in the browser, then Re-check:"
                    ),
                    commands: commands
                )
            }
            if let result = viewModel.testResults[account.id] {
                testResultLabel(result.localizedMessage, isVerified: result.isVerified)
            } else if account.account.isSSHAliasVerified, let login = account.account.sshVerifiedLogin {
                testResultLabel(
                    SSHAliasTestResultModel.authenticatedAsAccount(login: login).localizedMessage,
                    isVerified: true
                )
            }
        }
    }

    /// The SSH alias as the board writes it, quiet beside the login, and the menu to change it.
    private var aliasMenu: some View {
        let label = String(localized: "settings.accounts.ssh.alias", defaultValue: "SSH alias")
        let alias = account.account.sshHostAlias
        return Menu {
            Picker(label, selection: aliasBinding) {
                Text(String(localized: "settings.accounts.ssh.none", defaultValue: "None")).tag(String?.none)
                ForEach(viewModel.aliasChoices) { host in
                    Text(verbatim: host.alias).tag(String?.some(host.alias))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Theme.Spacing.xxSmall) {
                Text(alias ?? String(localized: "settings.accounts.ssh.noAlias", defaultValue: "No SSH alias"))
                    .font(Theme.Typography.monoLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .font(Theme.Typography.label)
            }
            .foregroundStyle(Theme.Colors.subtleText)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(viewModel.isBusy(account) || !account.isLoggedIn)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(alias ?? String(localized: "settings.accounts.ssh.none", defaultValue: "None")))
    }

    private func subline(symbol: String, name: String, @ViewBuilder status: () -> some View) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            AccountSymbol(systemName: symbol, isSubline: true)
            Text(name)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
            status()
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.Layout.settingsSublineHeight)
        .accessibilityElement(children: .combine)
    }

    /// An organization and its access ("example-org ● Ready"), with the SSO page when GitHub
    /// gave one.
    private func organizationLine(_ organization: OrgAccessModel) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            AccountSymbol(systemName: Theme.Symbols.organization, isSubline: true)
            Text(verbatim: organization.login)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            PreferencesStatus(title: organization.status.title, mark: organization.status.mark)
            if let url = organization.status.ssoURL {
                Link(destination: url) {
                    Text(String(localized: "settings.accounts.org.openSSO", defaultValue: "Open SSO Page"))
                        .font(Theme.Typography.labelEmphasized)
                        .underline()
                        .foregroundStyle(Theme.Colors.ink)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.Layout.settingsSublineHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Accounts.organization(organization.login))
    }

    private func commandList(_ lead: String, commands: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(lead)
                .fxTextStyle(.formNote)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(commands, id: \.self) { command in
                CommandRow(command: command) { viewModel.copy($0) }
            }
        }
        .padding(.vertical, Theme.Spacing.xSmall)
    }

    private func testResultLabel(_ message: String, isVerified: Bool) -> some View {
        Label {
            Text(message)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isVerified ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isVerified ? Theme.Colors.success : Theme.Colors.warning)
        }
        .padding(.top, Theme.Spacing.xSmall)
    }

    private var aliasBinding: Binding<String?> {
        Binding(
            get: { account.account.sshHostAlias },
            set: { alias in Task { await viewModel.setAlias(alias, for: account) } }
        )
    }
}
