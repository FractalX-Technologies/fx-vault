import SwiftUI
import VaultCore

/// The sidebar tree (§10; mockups Main2-Home and Main2-Repository): GITHUB with each account and
/// its scope warning, owner groups (Personal, then organizations, with a SAML notice where needed
/// and the organization's own row first), repositories with badges, the selected repository's
/// environments and destinations nested under it, and "Add repository by name…" per account;
/// then FOLDERS, and a mono status line at the bottom. It sits on the window's native sidebar
/// glass (1.0).
///
/// The rows are drawn with `.fxRowBackground(style: .sidebar)` instead of a native `List`
/// selection; ``MainColumnSelection`` keeps Up and Down.
struct SidebarView: View {
    let main: MainViewModel
    @State private var collapsedOwnerIDs: Set<SidebarOwnerModel.ID> = []
    @FocusState private var isListFocused: Bool

    var body: some View {
        @Bindable var sidebar = main.sidebar
        let sections = sidebar.sections
        VStack(spacing: 0) {
            if main.showsRecoveryKeyReminder {
                RecoveryKeyReminderView()
                    .padding([.horizontal, .top], Theme.Spacing.medium)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    if sections.isEmpty {
                        emptyState
                            .padding(.vertical, Theme.Spacing.xLarge)
                    } else {
                        SectionLabel(MainCopy.gitHubSection)
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.bottom, Theme.Spacing.small)
                        ForEach(sections) { account in
                            accountSection(account)
                        }
                    }
                    SidebarFoldersSection(main: main)
                        .padding(.top, Theme.Spacing.large)
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.largePlus)
            }
            .mainColumnKeyboardSelection(
                ids: visibleRepoIDs(in: sections),
                selection: $sidebar.selectedRowID,
                isFocused: $isListFocused
            )
            SidebarFooter(sidebar: sidebar, autoLockMinutes: main.app.container.preferences.autoLockMinutes)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Main.sidebar)
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
        .confirmationDialog(
            OrganizationCopy.removeTitle,
            isPresented: organizationRemovalBinding,
            titleVisibility: .visible,
            presenting: sidebar.pendingOrganizationRemoval
        ) { _ in
            Button(OrganizationCopy.removeConfirm, role: .destructive) {
                Task { await sidebar.confirmOrganizationRemoval() }
            }
        } message: { organization in
            Text(OrganizationCopy.removeMessage(organization.login))
        }
        .confirmationDialog(
            FolderCopy.deleteTitle(sidebar.pendingFolderDeletion?.name ?? ""),
            isPresented: folderDeletionBinding,
            titleVisibility: .visible,
            presenting: sidebar.pendingFolderDeletion
        ) { _ in
            Button(FolderCopy.deleteConfirm, role: .destructive) {
                sidebar.confirmFolderDeletion()
            }
        } message: { _ in
            Text(FolderCopy.deleteMessage)
        }
    }

    private var organizationRemovalBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingOrganizationRemoval != nil },
            set: { if !$0 { main.sidebar.pendingOrganizationRemoval = nil } }
        )
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingFolderDeletion != nil },
            set: { if !$0 { main.sidebar.pendingFolderDeletion = nil } }
        )
    }

    /// One account: its row, the catalog error, the owner groups and "Add repository by name…".
    @ViewBuilder
    private func accountSection(_ account: SidebarAccountModel) -> some View {
        let sidebar = main.sidebar
        SidebarAccountRow(account: account)
        if let error = sidebar.catalogError(for: account.id) {
            SidebarNoticeRow(systemImage: "exclamationmark.triangle", text: error.message)
        }
        ForEach(account.owners) { owner in
            let isExpanded = !collapsedOwnerIDs.contains(owner.id)
            OwnerHeader(owner: owner, isExpanded: isExpanded) {
                toggle(owner.id)
            }
            if isExpanded {
                OwnerContentView(owner: owner, main: main) { repo in
                    main.select(repository: repo)
                    isListFocused = true
                } onSelectOrganization: {
                    sidebar.select(organization: owner)
                    isListFocused = true
                }
            }
        }
        if account.isLoggedIn {
            AddByNameButton(main: main, accountLogin: account.login)
                .padding(.top, Theme.Spacing.small)
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

    /// The repositories the arrow keys walk through: those of expanded owner groups, in order.
    private func visibleRepoIDs(in sections: [SidebarAccountModel]) -> [SidebarRepoModel.ID] {
        sections.flatMap { account in
            account.owners
                .filter { !collapsedOwnerIDs.contains($0.id) }
                .flatMap { $0.repos.map(\.id) }
        }
    }

    private func toggle(_ id: SidebarOwnerModel.ID) {
        withAnimation(Theme.Durations.interactionAnimation) {
            if collapsedOwnerIDs.contains(id) {
                collapsedOwnerIDs.remove(id)
            } else {
                collapsedOwnerIDs.insert(id)
            }
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingRemoval != nil },
            set: { if !$0 { main.sidebar.pendingRemoval = nil } }
        )
    }
}

/// The account row (mockup ACCOUNTS): an ink initials circle, the login and, when relevant, the
/// scope warning or "Not logged in" on a mono line.
private struct SidebarAccountRow: View {
    let account: SidebarAccountModel

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Text(verbatim: account.initials)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.onInk)
                .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
                .background(Theme.Colors.ink, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: account.login)
                    .font(Theme.Typography.calloutEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                if !account.isLoggedIn {
                    Text(String(localized: "main.sidebar.notLoggedIn", defaultValue: "Not logged in"))
                        .font(Theme.Typography.monoLabel)
                        .foregroundStyle(Theme.Colors.subtleText)
                } else if account.hasScopeWarning {
                    Label {
                        Text(String(localized: "main.sidebar.scopeWarning.short", defaultValue: "Missing scopes"))
                            .font(Theme.Typography.monoLabel)
                            .foregroundStyle(Theme.Colors.subtleText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.monoLabel)
                            .foregroundStyle(Theme.Colors.warning)
                    }
                    .help(String(
                        localized: "main.sidebar.scopeWarning",
                        defaultValue: "This account's token lacks: \(account.missingScopes.joined(separator: ", ")). See Settings › Accounts."
                    ))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "Personal" or the organization's login as a mono label, with a warning when it could not be
/// listed; clicking it collapses or expands the group.
private struct OwnerHeader: View {
    let owner: SidebarOwnerModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                SectionLabel(title)
                if owner.failure != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.monoLabel)
                        .foregroundStyle(Theme.Colors.warning)
                        .accessibilityLabel(String(localized: "main.sidebar.ownerUnavailable", defaultValue: "Could not be listed"))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .rotationEffect(isExpanded ? .zero : .degrees(-90))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.top, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.smallMinus)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded
            ? String(localized: "main.sidebar.owner.expanded", defaultValue: "Expanded")
            : String(localized: "main.sidebar.owner.collapsed", defaultValue: "Collapsed"))
    }

    private var title: String {
        owner.isAccount
            ? String(localized: "main.sidebar.personal", defaultValue: "Personal")
            : owner.login
    }
}

/// The rows of one owner group: the SAML or failure notice, the organization's own row (1.0),
/// the truncation note, then the repositories.
private struct OwnerContentView: View {
    let owner: SidebarOwnerModel
    let main: MainViewModel
    let onSelect: (SidebarRepoModel) -> Void
    let onSelectOrganization: () -> Void

    var body: some View {
        if owner.isOrganization {
            Button(action: onSelectOrganization) {
                SidebarOrganizationRow(
                    owner: owner,
                    isBusy: main.sidebar.isBusy(owner),
                    isSelected: main.sidebar.selectedOrganizationOwnerID == owner.id
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Main.organization(owner.login))
            .contextMenu {
                if let organization = owner.organization {
                    Button(OrganizationCopy.remove, role: .destructive) {
                        main.sidebar.requestRemoval(organization)
                    }
                } else {
                    Button(OrganizationCopy.importButton) {
                        Task { await main.sidebar.importOrganization(owner) }
                    }
                    .disabled(!main.sidebar.canImportOrganization(owner))
                }
            }
        }
        if owner.requiresSAML {
            SAMLNoticeRow(owner: owner)
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
            Button {
                onSelect(repo)
            } label: {
                SidebarRepoRow(
                    repo: repo,
                    isBusy: main.sidebar.isBusy(repo),
                    isSelected: main.isRowSelected(repo)
                )
            }
            .buttonStyle(.plain)
            .id(repo.id)
            .contextMenu {
                RepoContextMenu(repo: repo, main: main)
            }
            if main.sidebar.selectedRowID == repo.id, let scopeList = main.scopeList {
                ScopeListView(viewModel: scopeList)
            }
        }
    }
}

/// "SAML single sign-on required · Authorize in the browser" for an organization that enforces
/// SAML.
private struct SAMLNoticeRow: View {
    let owner: SidebarOwnerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Label {
                Text(String(localized: "main.sidebar.saml", defaultValue: "SAML single sign-on required"))
                    .foregroundStyle(Theme.Colors.mutedText)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Colors.warning)
            }
            if let url = owner.samlAuthorizationURL {
                Link(String(localized: "main.sidebar.saml.authorize", defaultValue: "Authorize in the browser"), destination: url)
                    .foregroundStyle(Theme.Colors.brand)
            }
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xSmall)
    }
}

/// A small note inside the column.
private struct SidebarNoticeRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xSmall)
    }
}

/// One repository (32 pt, `surface2` when selected): name in ink when imported and subtle when
/// not, badges, and "Import" in brand for a repository that is not in the vault yet.
private struct SidebarRepoRow: View {
    let repo: SidebarRepoModel
    let isBusy: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Image(systemName: "book.closed")
                .font(Theme.Typography.caption)
                .foregroundStyle(nameColor)
                .accessibilityHidden(true)
            Text(verbatim: repo.name)
                .font(Theme.Typography.callout)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            }
            ForEach(repo.badges, id: \.self) { badge in
                Image(systemName: badge.systemImage)
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(badge.tint)
                    .help(badge.title)
                    .accessibilityLabel(badge.title)
            }
            if !repo.isImported {
                Text(String(localized: "main.sidebar.import", defaultValue: "Import"))
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.brand)
            }
        }
        .fxRowBackground(isSelected: isSelected, style: .sidebar)
        .help(repo.fullName)
    }

    private var nameColor: Color {
        repo.isImported ? Theme.Colors.ink : Theme.Colors.subtleText
    }
}

/// An organization's own secrets and variables (1.0): the counts once imported, "Import" in
/// brand before.
private struct SidebarOrganizationRow: View {
    let owner: SidebarOwnerModel
    let isBusy: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Image(systemName: "building.2")
                .font(Theme.Typography.caption)
                .foregroundStyle(nameColor)
                .accessibilityHidden(true)
            Text(OrganizationCopy.rowTitle)
                .font(Theme.Typography.callout)
                .foregroundStyle(nameColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            }
            if let organization = owner.organization {
                Text(organization.secretCount + organization.variableCount, format: .number)
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.subtleText)
            } else {
                Text(String(localized: "main.sidebar.import", defaultValue: "Import"))
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(Theme.Colors.brand)
            }
        }
        .fxRowBackground(isSelected: isSelected, style: .sidebar)
        .help(owner.login)
    }

    private var nameColor: Color {
        owner.organization != nil ? Theme.Colors.ink : Theme.Colors.subtleText
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

/// "+ Add repository by name…" for one account, as a quiet 32 pt row.
private struct AddByNameButton: View {
    let main: MainViewModel
    let accountLogin: String

    var body: some View {
        let isEnabled = main.sidebar.canAddByName
        Button {
            main.addRepositoryByName(accountLogin: accountLogin)
        } label: {
            Label(
                String(localized: "main.sidebar.addByName", defaultValue: "Add repository by name…"),
                systemImage: "plus"
            )
            .font(Theme.Typography.callout)
            .foregroundStyle(Theme.Colors.mutedText)
            .fxRowBackground(isSelected: false, style: .sidebar)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
        .help(main.networkHelp(String(
            localized: "main.sidebar.addByName.help",
            defaultValue: "Find a repository this account reaches as a collaborator"
        )))
    }
}

/// The bottom of the column: loading state, errors and the last confirmation, then the mono
/// status line ("UNLOCKED · AUTO-LOCK 5 MIN").
private struct SidebarFooter: View {
    let sidebar: SidebarViewModel
    let autoLockMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HairlineDivider()
            Group {
                if sidebar.isLoadingCatalog {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "main.sidebar.loading", defaultValue: "Listing repositories…"))
                    }
                } else if let error = sidebar.accountsError {
                    Label {
                        Text(error.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Theme.Colors.warning)
                    }
                } else if let notice = sidebar.notice {
                    Text(notice)
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .lineLimit(2)
            .padding(.horizontal, Theme.Spacing.small)
            Text(String(
                localized: "main.sidebar.status",
                defaultValue: "Unlocked · Auto-lock \(autoLockMinutes) min"
            ))
            .fxTextStyle(.statusLine)
            .foregroundStyle(Theme.Colors.subtleText)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.largePlus)
    }
}

/// The reminder shown when a recovery key was never confirmed as saved.
private struct RecoveryKeyReminderView: View {
    var body: some View {
        Banner(
            .warning,
            message: String(
                localized: "main.recoveryReminder",
                defaultValue: "Your recovery key was not saved. Create a new one in Settings › Security."
            )
        )
    }
}

extension SidebarAccountModel {
    /// Two letters for the sidebar avatar (``initials(of:)``).
    var initials: String {
        Self.initials(of: login)
    }

    /// Two letters for the avatar: the first letters of the first two words of the login
    /// ("admin-fractalx" → "AF"), or its first two letters ("octocat" → "OC").
    static func initials(of login: String) -> String {
        let words = login.split { !$0.isLetter && !$0.isNumber }
        let letters: [Character] = if words.count >= 2 {
            words.prefix(2).compactMap(\.first)
        } else {
            Array((words.first ?? Substring(login)).prefix(2))
        }
        return String(letters).uppercased()
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
        case .private, .archived, .fork: Theme.Colors.subtleText
        case .unavailable: Theme.Colors.warning
        case .notOnGitHub: Theme.Colors.brand
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
