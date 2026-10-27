import SwiftUI
import VaultCore

/// The sidebar (§10; boards Main2-Home, Main2-Expanded, Main2-Repository): search (⌘F), GitHub
/// owners › repositories › environments, Azure, Folders, then Lock and Settings. It sits in the
/// main window's glass sidebar panel (``MainScreen``); ``MainColumnSelection`` keeps Up and Down
/// on custom rows.
struct SidebarView: View {
    let main: MainViewModel
    @FocusState private var isListFocused: Bool

    var body: some View {
        @Bindable var sidebar = main.sidebar
        let owners = sidebar.owners
        VStack(spacing: Theme.Spacing.small) {
            SidebarSearchField(sidebar: sidebar)
                .padding(.horizontal, Theme.Spacing.medium)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    SidebarSectionHeader(title: MainCopy.gitHubSection) {
                        SidebarRepoFilterMenu(sidebar: sidebar)
                    }
                    if owners.isEmpty {
                        emptyState
                            .padding(.vertical, Theme.Spacing.large)
                    }
                    ForEach(owners) { owner in
                        OwnerNodeView(owner: owner, main: main, isListFocused: $isListFocused)
                    }
                    SidebarKeyVaultsSection(sidebar: sidebar)
                        .padding(.top, Theme.Spacing.smallMinus)
                    SidebarFoldersSection(main: main)
                        .padding(.top, Theme.Spacing.smallMinus)
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.bottom, Theme.Spacing.small)
            }
            .mainColumnKeyboardSelection(
                ids: visibleRepoIDs(in: owners),
                selection: $sidebar.selectedRowID,
                isFocused: $isListFocused
            )
            SidebarFooter(main: main)
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
            DestinationCopy.removeTitle,
            isPresented: keyVaultRemovalBinding,
            titleVisibility: .visible,
            presenting: sidebar.pendingKeyVaultRemoval
        ) { _ in
            Button(DestinationCopy.removeConfirm, role: .destructive) {
                sidebar.confirmKeyVaultRemoval()
            }
        } message: { vault in
            Text(DestinationCopy.removeMessage(vault.copyTargetTitle))
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

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingRemoval != nil },
            set: { if !$0 { main.sidebar.pendingRemoval = nil } }
        )
    }

    private var organizationRemovalBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingOrganizationRemoval != nil },
            set: { if !$0 { main.sidebar.pendingOrganizationRemoval = nil } }
        )
    }

    private var keyVaultRemovalBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingKeyVaultRemoval != nil },
            set: { if !$0 { main.sidebar.pendingKeyVaultRemoval = nil } }
        )
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { main.sidebar.pendingFolderDeletion != nil },
            set: { if !$0 { main.sidebar.pendingFolderDeletion = nil } }
        )
    }

    @ViewBuilder private var emptyState: some View {
        let sidebar = main.sidebar
        // Without gh there is nothing to choose from: the setup message says what to do first.
        if sidebar.repoFilter == .added, sidebar.searchText.isEmpty, sidebar.isGitHubReady {
            EmptyStateView(
                systemImage: "tray",
                title: SidebarCopy.noneAddedTitle,
                message: SidebarCopy.noneAddedMessage
            ) {
                VStack(spacing: Theme.Spacing.small) {
                    Button(SidebarCopy.chooseRepositories) {
                        main.requestAccountsSettings()
                    }
                    .fxButtonStyle(.primary, size: .compact)
                    .accessibilityIdentifier(AccessibilityID.Main.chooseRepositories)
                    Button(SidebarCopy.showAll) {
                        sidebar.repoFilter = .all
                    }
                    .fxButtonStyle(.outline, size: .compact)
                    .accessibilityIdentifier(AccessibilityID.Main.showAllRepositories)
                }
            }
        } else {
            catalogEmptyState
        }
    }

    private var catalogEmptyState: some View {
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

    /// The repositories the arrow keys walk through: those on screen, in order.
    private func visibleRepoIDs(in owners: [SidebarOwnerModel]) -> [SidebarRepoModel.ID] {
        let sidebar = main.sidebar
        return owners
            .filter { sidebar.isExpanded($0) }
            .flatMap { sidebar.repoList(of: $0).shown.map(\.id) }
    }
}

/// The GitHub header's filter: only the repositories added to FX Vault (the default, like Azure
/// lists only its added vaults), or every repository gh lists.
private struct SidebarRepoFilterMenu: View {
    @Bindable var sidebar: SidebarViewModel

    var body: some View {
        Menu {
            Picker(SidebarCopy.filterLabel, selection: $sidebar.repoFilter) {
                ForEach(SidebarRepoFilter.allCases) { filter in
                    Text(SidebarCopy.filterOption(filter)).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(SidebarCopy.filterTitle(sidebar.repoFilter))
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.subtleText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(SidebarCopy.filterLabel)
        .accessibilityLabel(SidebarCopy.filterLabel)
        .accessibilityIdentifier(AccessibilityID.Main.repoFilter)
    }
}

/// The search field at the top (board Main2-Home): it filters the whole tree. Edit › Find (⌘F)
/// focuses it; its ⌘F key does too when clicked.
private struct SidebarSearchField: View {
    @Bindable var sidebar: SidebarViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        PanelSearchField(
            prompt: SidebarCopy.searchPrompt,
            label: SidebarCopy.searchLabel,
            accessibilityID: AccessibilityID.Main.sidebarSearch,
            text: $sidebar.searchText,
            isFocused: $isFocused
        ) {
            Button {
                sidebar.focusSearch()
            } label: {
                KeyHint("⌘F")
            }
            .buttonStyle(.plain)
            .help(SidebarCopy.searchShortcut)
            .accessibilityLabel(SidebarCopy.searchShortcut)
        }
        .task(id: sidebar.searchFocusRequest) {
            await takeFocus()
        }
        .onChange(of: isFocused) { _, isFocused in
            if isFocused {
                sidebar.didFocusSearch()
            }
        }
    }

    /// Edit › Find on a hidden sidebar asks while the column is still hidden, where the focus
    /// cannot land and SwiftUI drops it: the request is retried while the column slides back
    /// (``FocusRetry``), until the field has the focus, then dropped (a newer request cancels it).
    private func takeFocus() async {
        let didFocus = await FocusRetry.take(isFocused: { isFocused }, isWanted: { sidebar.isSearchFocusPending }) {
            isFocused = true
        }
        if didFocus {
            sidebar.didFocusSearch()
        } else if !Task.isCancelled, sidebar.isSearchFocusPending {
            sidebar.cancelSearchFocus()
        }
    }
}

/// One owner under GitHub: its node, the subline when it needs attention, then (expanded) its
/// repositories, "Show N more" and the selected repository's environments.
private struct OwnerNodeView: View {
    let owner: SidebarOwnerModel
    let main: MainViewModel
    var isListFocused: FocusState<Bool>.Binding
    @Environment(\.openURL) private var openURL

    var body: some View {
        let sidebar = main.sidebar
        let isExpanded = sidebar.isExpanded(owner)
        SidebarTreeRow(
            level: 0,
            isExpanded: isExpanded,
            systemImage: owner.isOrganization ? Theme.Symbols.organization : Theme.Symbols.person,
            title: owner.login,
            isSelected: sidebar.selectedOrganizationOwnerID == owner.id,
            accessibilityID: owner.isOrganization ? AccessibilityID.Main.organization(owner.login) : nil,
            toggleAccessibilityID: AccessibilityID.Main.ownerToggle(owner.login),
            onToggle: toggle
        ) {
            if owner.isOrganization {
                sidebar.select(organization: owner)
                isListFocused.wrappedValue = true
            } else {
                toggle()
            }
        } trailing: {
            if sidebar.isBusy(owner) {
                ProgressView()
                    .controlSize(.mini)
            }
            if hasPendingChanges {
                SidebarPendingDot()
            }
        }
        .contextMenu {
            OwnerContextMenu(owner: owner, main: main)
        }
        if let problem = SidebarGrouping.shownProblem(of: owner, isSelected: sidebar.selectedOrganizationOwnerID == owner.id) {
            subline(problem)
        }
        if isExpanded {
            let list = sidebar.repoList(of: owner)
            ForEach(list.shown) { repo in
                RepoNodeView(repo: repo, main: main, isListFocused: isListFocused)
            }
            if list.hiddenCount > 0 {
                Button(SidebarCopy.showMore(list.hiddenCount)) {
                    withAnimation(Theme.Durations.interactionAnimation) {
                        sidebar.showAllRepositories(of: owner)
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.subtleText)
                .frame(height: Theme.Layout.sidebarRowHeight)
                .padding(.leading, SidebarSubline.nameInset(level: 0))
                .accessibilityIdentifier(AccessibilityID.Main.showMore(owner.login))
            } else if owner.isTruncated {
                SidebarSubline(
                    level: 1,
                    text: String(
                        localized: "main.sidebar.truncated",
                        defaultValue: "List truncated. Use Add repository by name… for the rest."
                    )
                )
            }
        }
    }

    private func toggle() {
        withAnimation(Theme.Durations.interactionAnimation) {
            main.sidebar.toggle(owner)
        }
    }

    /// The organization's own changes or a repository's, so a collapsed node still shows them.
    private var hasPendingChanges: Bool {
        let app = main.app
        if let id = owner.organization?.id, app.organizationPendingCounts[id, default: 0] > 0 { return true }
        return owner.repos.contains { repo in
            repo.importedRepoID.map { app.pendingChangeCount(of: $0) > 0 } ?? false
        }
    }

    private func subline(_ problem: SidebarOwnerProblem) -> some View {
        let copy = SidebarCopy.subline(problem)
        var help: String?
        if case .unavailable(let error) = problem {
            help = error.presentation.message
        }
        return SidebarSubline(level: 0, text: copy.text, actionTitle: copy.action, help: help) {
            if case .ssoRequired(let url?) = problem {
                openURL(url)
            } else if !main.approve(owner) {
                // Another account, or a problem gh can't approve here: Settings has the commands.
                main.requestAccountsSettings()
            }
        }
    }
}

/// One repository under its owner: dimmed until imported; the selected one shows its
/// environments under it.
private struct RepoNodeView: View {
    let repo: SidebarRepoModel
    let main: MainViewModel
    var isListFocused: FocusState<Bool>.Binding

    var body: some View {
        let sidebar = main.sidebar
        let isOpen = sidebar.showsEnvironments(of: repo)
        SidebarTreeRow(
            level: 1,
            isExpanded: repo.isImported ? isOpen : nil,
            systemImage: Theme.Symbols.repository,
            title: repo.name,
            isSelected: main.isRowSelected(repo),
            isDimmed: !repo.isImported,
            toggleLabel: isOpen ? SidebarCopy.collapse(repo.name) : SidebarCopy.openRepository(repo.name),
            toggleAccessibilityID: AccessibilityID.Main.repositoryToggle(repo.name),
            onToggle: toggle
        ) {
            select()
        } trailing: {
            if sidebar.isBusy(repo) {
                ProgressView()
                    .controlSize(.mini)
            }
            ForEach(repo.badges.filter(\.needsAttention), id: \.self) { badge in
                Image(systemName: badge.systemImage)
                    .font(Theme.Typography.monoLabel)
                    .foregroundStyle(badge.tint)
                    .help(badge.title)
                    .accessibilityLabel(badge.title)
            }
            if let id = repo.importedRepoID {
                SidebarValueMissingCount(count: main.app.valueMissingCount(of: id))
                if main.app.pendingChangeCount(of: id) > 0 {
                    SidebarPendingDot()
                }
            }
        }
        .id(repo.id)
        .help(([repo.fullName] + repo.badges.map(\.title)).joined(separator: " · "))
        .contextMenu {
            RepoContextMenu(repo: repo, main: main)
        }
        if isOpen, let scopeList = main.scopeList {
            ScopeListView(viewModel: scopeList, detail: main.detail)
        }
    }

    private func select() {
        main.select(repository: repo)
        isListFocused.wrappedValue = true
    }

    /// Opens the repository; on the open one, hides or shows its environments. Hiding them
    /// moves a selected environment's selection up to the repository, as Finder does.
    private func toggle() {
        let sidebar = main.sidebar
        if sidebar.selectedRowID == repo.id {
            if sidebar.showsEnvironments(of: repo) {
                select()
            }
            sidebar.toggleEnvironments(of: repo)
        } else {
            select()
        }
    }
}

/// Import or Remove from Vault for an organization, then New Repository… (the owner
/// preselected) and Add Repository by Name… through the account the owner goes through.
private struct OwnerContextMenu: View {
    let owner: SidebarOwnerModel
    let main: MainViewModel

    var body: some View {
        let sidebar = main.sidebar
        if let organization = owner.organization {
            Button(OrganizationCopy.remove, role: .destructive) {
                sidebar.requestRemoval(organization)
            }
            Divider()
        } else if owner.isOrganization {
            Button(OrganizationCopy.importButton) {
                Task { await sidebar.importOrganization(owner) }
            }
            .disabled(!sidebar.canImportOrganization(owner))
            Divider()
        }
        Button(MainCopy.newRepository) {
            main.newRepository(in: owner)
        }
        .disabled(!main.canCreateRepository)
        Button(SidebarCopy.addByName) {
            main.addRepositoryByName(accountLogin: owner.accountLogin)
        }
        .disabled(!sidebar.canAddByName)
        .help(main.networkHelp(String(
            localized: "main.sidebar.addByName.help",
            defaultValue: "Find a repository this account reaches as a collaborator"
        )))
    }
}

/// Import, or New Environment… / Clone… / Share Securely… / Remove from Vault….
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
            let canCreateEnvironment = main.canCreateEnvironment(in: repo)
            Button(SidebarCopy.newEnvironment) {
                main.newEnvironment(in: repo)
            }
            .disabled(!canCreateEnvironment)
            .help(canCreateEnvironment
                ? String(localized: "main.scopes.newEnvironment.help", defaultValue: "Add an environment to this repository")
                : String(
                    localized: "main.scopes.newEnvironment.adminRequired",
                    defaultValue: "Environments need admin rights on the repository"
                ))
            Divider()
            Button(PlaceCopy.clone) {
                guard let folder = ClonePanel.folder(for: main) else { return }
                Task { await sidebar.clone(repo, into: folder) }
            }
            .disabled(!sidebar.canClone(repo))
            .help(main.networkHelp(String(
                localized: "main.detail.clone.help",
                defaultValue: "Clone through the account's SSH alias"
            )))
            Button(PlaceCopy.shareSecurely) {
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

/// The bottom of the sidebar: the listing state, an error or the last confirmation, then Lock
/// and Settings (board Main2-Home).
private struct SidebarFooter: View {
    let main: MainViewModel

    var body: some View {
        let sidebar = main.sidebar
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Group {
                if sidebar.isLoadingCatalog {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "main.sidebar.loading", defaultValue: "Listing repositories…"))
                    }
                } else if let error = sidebar.accountsError ?? sidebar.catalogError {
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
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Colors.subtleText)
            .lineLimit(2)
            .padding(.horizontal, Theme.Spacing.small)
            HStack(spacing: Theme.Spacing.xSmall) {
                Button {
                    main.lock()
                } label: {
                    footerIcon("lock")
                }
                .buttonStyle(.plain)
                .help(SidebarCopy.lock)
                .accessibilityLabel(SidebarCopy.lock)
                Button {
                    main.app.showSettings()
                } label: {
                    footerIcon("gearshape")
                }
                .buttonStyle(.plain)
                .help(SidebarCopy.settings)
                .accessibilityLabel(SidebarCopy.settings)
                .accessibilityIdentifier(AccessibilityID.Settings.open)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.small)
    }

    private func footerIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .frame(width: Theme.Layout.sidebarControlHeight, height: Theme.Layout.sidebarControlHeight)
            .contentShape(Rectangle())
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

    /// The badges a row shows; the quiet ones (private, archived, fork) are in its help only, so
    /// the tree stays as calm as board Main2.
    var needsAttention: Bool {
        switch self {
        case .unavailable, .notOnGitHub: true
        case .private, .archived, .fork: false
        }
    }
}
