import SwiftUI
import VaultCore

/// Column 1 (§10): accounts with their scope warning, owner disclosure groups (Personal, then
/// organizations, with a SAML banner where needed), repositories with badges, and "Add
/// repository by name…" per account.
struct SidebarView: View {
    let main: MainViewModel
    @State private var collapsedOwnerIDs: Set<SidebarOwnerModel.ID> = []

    var body: some View {
        @Bindable var sidebar = main.sidebar
        let sections = sidebar.sections
        VStack(spacing: 0) {
            if main.showsRecoveryKeyReminder {
                RecoveryKeyReminderView()
            }
            if sections.isEmpty {
                emptyState
            } else {
                List(selection: $sidebar.selectedRowID) {
                    ForEach(sections) { account in
                        Section {
                            if let error = sidebar.catalogError(for: account.id) {
                                SidebarNoticeRow(systemImage: "exclamationmark.triangle", text: error.message)
                            }
                            ForEach(account.owners) { owner in
                                DisclosureGroup(isExpanded: expansion(for: owner.id)) {
                                    OwnerContentView(owner: owner, main: main)
                                } label: {
                                    OwnerLabel(owner: owner)
                                }
                            }
                            if account.isLoggedIn {
                                Button {
                                    main.addRepositoryByName(accountLogin: account.login)
                                } label: {
                                    Label(
                                        String(localized: "main.sidebar.addByName", defaultValue: "Add repository by name…"),
                                        systemImage: "plus.magnifyingglass"
                                    )
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .disabled(!sidebar.canAddByName)
                                .help(main.networkHelp(String(
                                    localized: "main.sidebar.addByName.help",
                                    defaultValue: "Find a repository this account reaches as a collaborator"
                                )))
                            }
                        } header: {
                            AccountHeader(account: account)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            SidebarFooter(sidebar: sidebar)
        }
        .errorAlert($sidebar.alert)
        .confirmationDialog(
            String(localized: "main.sidebar.remove.title", defaultValue: "Remove this repository from FX Vault?"),
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: sidebar.pendingRemoval
        ) { _ in
            Button(String(localized: "main.sidebar.remove.confirm", defaultValue: "Remove from Vault"), role: .destructive) {
                Task { await sidebar.confirmRemoval() }
            }
        } message: { repo in
            Text(String(
                localized: "main.sidebar.remove.message",
                defaultValue: "\(repo.fullName) and its local secrets, variables and pending changes are deleted from this Mac. Nothing changes on GitHub."
            ))
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "person.crop.circle.badge.questionmark",
            title: main.sidebar.searchText.isEmpty
                ? String(localized: "main.sidebar.empty.title", defaultValue: "No repositories yet")
                : String(localized: "main.sidebar.noResults.title", defaultValue: "No matching repositories"),
            message: main.sidebar.isGitHubReady
                ? String(
                    localized: "main.sidebar.empty.message",
                    defaultValue: "Repositories of your GitHub CLI accounts appear here."
                )
                : String(
                    localized: "main.sidebar.empty.offline",
                    defaultValue: "Set up the GitHub CLI to list your repositories."
                )
        )
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingRemoval != nil },
            set: { if !$0 { main.sidebar.pendingRemoval = nil } }
        )
    }

    private func expansion(for id: SidebarOwnerModel.ID) -> Binding<Bool> {
        Binding(
            get: { !collapsedOwnerIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedOwnerIDs.remove(id)
                } else {
                    collapsedOwnerIDs.insert(id)
                }
            }
        )
    }
}

/// The account header with its scope warning (§10 Column 1).
private struct AccountHeader: View {
    let account: SidebarAccountModel

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Text(verbatim: account.login)
            if account.hasScopeWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warning)
                    .help(String(
                        localized: "main.sidebar.scopeWarning",
                        defaultValue: "This account's token lacks: \(account.missingScopes.joined(separator: ", ")). See Settings › Accounts."
                    ))
                    .accessibilityLabel(String(localized: "main.sidebar.scopeWarning.short", defaultValue: "Missing scopes"))
            }
            if !account.isLoggedIn {
                Text(String(localized: "main.sidebar.notLoggedIn", defaultValue: "Not logged in"))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

/// "Personal" or the organization's login, with a warning when it could not be listed.
private struct OwnerLabel: View {
    let owner: SidebarOwnerModel

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Label {
                Text(verbatim: owner.isAccount
                    ? String(localized: "main.sidebar.personal", defaultValue: "Personal")
                    : owner.login)
            } icon: {
                Image(systemName: owner.isAccount ? "person" : "building.2")
            }
            if owner.failure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warning)
                    .accessibilityLabel(String(localized: "main.sidebar.ownerUnavailable", defaultValue: "Could not be listed"))
            }
        }
    }
}

/// The rows of one owner group: the SAML or failure banner, the truncation note, then the
/// repositories.
private struct OwnerContentView: View {
    let owner: SidebarOwnerModel
    let main: MainViewModel

    var body: some View {
        if owner.requiresSAML {
            SAMLBannerRow(owner: owner)
        } else if let failure = owner.failure {
            SidebarNoticeRow(systemImage: "exclamationmark.triangle", text: failure.presentation.message)
        }
        if owner.isTruncated {
            SidebarNoticeRow(
                systemImage: "ellipsis",
                text: String(
                    localized: "main.sidebar.truncated",
                    defaultValue: "List truncated. Use Add repository by name… for the rest."
                )
            )
        }
        ForEach(owner.repos) { repo in
            SidebarRepoRow(repo: repo, isBusy: main.sidebar.isBusy(repo))
                .tag(repo.id)
                .contextMenu {
                    RepoContextMenu(repo: repo, main: main)
                }
        }
    }
}

/// "SAML SSO required — Authorize" for an organization that enforces SAML.
private struct SAMLBannerRow: View {
    let owner: SidebarOwnerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Label(
                String(localized: "main.sidebar.saml", defaultValue: "SAML single sign-on required"),
                systemImage: "lock.shield"
            )
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.warning)
            if let url = owner.samlAuthorizationURL {
                Link(String(localized: "main.sidebar.saml.authorize", defaultValue: "Authorize in the browser"), destination: url)
                    .font(Theme.Typography.caption)
            }
        }
        .selectionDisabled()
    }
}

/// A small non-selectable note inside the list.
private struct SidebarNoticeRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }
}

/// One repository: name, badges, dimmed when not imported.
private struct SidebarRepoRow: View {
    let repo: SidebarRepoModel
    let isBusy: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Label {
                Text(verbatim: repo.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: repo.isImported ? "shippingbox.fill" : "shippingbox")
            }
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            }
            ForEach(repo.badges, id: \.self) { badge in
                Image(systemName: badge.systemImage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(badge.tint)
                    .help(badge.title)
                    .accessibilityLabel(badge.title)
            }
        }
        .opacity(repo.isImported ? 1 : Theme.Opacity.disabled)
        .help(repo.fullName)
    }
}

/// Import / Clone / Share… / Remove from vault.
private struct RepoContextMenu: View {
    let repo: SidebarRepoModel
    let main: MainViewModel

    var body: some View {
        let sidebar = main.sidebar
        if !repo.isImported {
            Button(String(localized: "main.sidebar.import", defaultValue: "Import")) {
                Task { await sidebar.importRepository(repo) }
            }
            .disabled(!sidebar.canImport(repo))
            .help(main.networkHelp(String(
                localized: "main.sidebar.import.help",
                defaultValue: "Read this repository's environments, secrets and variables from GitHub"
            )))
        } else {
            Button(String(localized: "main.sidebar.clone", defaultValue: "Clone…")) {
                guard let folder = ClonePanel.folder(for: main) else { return }
                Task { await sidebar.clone(repo, into: folder) }
            }
            .disabled(!sidebar.canClone(repo))
            .help(main.networkHelp(String(
                localized: "main.detail.clone.help",
                defaultValue: "Clone through the account's SSH alias"
            )))
            Button(String(localized: "main.sidebar.share", defaultValue: "Share…")) {
                if let id = repo.importedRepoID {
                    main.present(.shareExport(ShareExportContext(selection: .repository(id))))
                }
            }
            Divider()
            Button(String(localized: "main.sidebar.remove", defaultValue: "Remove from Vault…"), role: .destructive) {
                sidebar.requestRemoval(repo)
            }
            .disabled(!sidebar.canRemove(repo))
        }
    }
}

/// Loading state and the last confirmation under the list.
private struct SidebarFooter: View {
    let sidebar: SidebarViewModel

    var body: some View {
        if sidebar.isLoadingCatalog || sidebar.notice != nil || sidebar.accountsError != nil {
            Divider()
            HStack(spacing: Theme.Spacing.small) {
                if sidebar.isLoadingCatalog {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "main.sidebar.loading", defaultValue: "Listing repositories…"))
                } else if let error = sidebar.accountsError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Colors.warning)
                    Text(error.message)
                } else if let notice = sidebar.notice {
                    Text(notice)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .lineLimit(2)
            .padding(Theme.Spacing.small)
        }
    }
}

/// The reminder shown when a recovery key was never confirmed as saved.
private struct RecoveryKeyReminderView: View {
    var body: some View {
        Label {
            Text(String(
                localized: "main.recoveryReminder",
                defaultValue: "Your recovery key was not saved. Create a new one in Settings › Security."
            ))
            .font(Theme.Typography.caption)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Theme.Colors.warning)
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warning.opacity(Theme.Opacity.chipBackground))
    }
}

extension SidebarRepoBadge {
    var systemImage: String {
        switch self {
        case .private: "lock.fill"
        case .archived: "archivebox"
        case .fork: "tuningfork"
        case .unavailable: "exclamationmark.triangle"
        case .notOnGitHub: "icloud.slash"
        }
    }

    var tint: Color {
        switch self {
        case .private, .archived, .fork: Theme.Colors.textSecondary
        case .unavailable: Theme.Colors.warning
        case .notOnGitHub: Theme.Colors.pending
        }
    }

    var title: String {
        switch self {
        case .private: String(localized: "main.badge.private", defaultValue: "Private")
        case .archived: String(localized: "main.badge.archived", defaultValue: "Archived")
        case .fork: String(localized: "main.badge.fork", defaultValue: "Fork")
        case .unavailable: String(localized: "main.badge.unavailable", defaultValue: "Unavailable")
        case .notOnGitHub: String(localized: "main.badge.notOnGitHub", defaultValue: "Created by the next Sync")
        }
    }
}
