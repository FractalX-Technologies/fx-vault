import Foundation
import Observation
import VaultCore

/// A repository in the sidebar (column 1).
struct SidebarRepoModel: Identifiable, Hashable {
    let id: RepoID
    let fullName: String
    let isPrivate: Bool
    let isImported: Bool
}

/// An owner group (account or organization) in the sidebar.
struct SidebarOwnerModel: Identifiable, Hashable {
    let id: String
    let login: String
    let repos: [SidebarRepoModel]
}

/// A scope row in column 2: the repository itself or one environment.
struct ScopeRowModel: Identifiable, Hashable {
    let id: String
    let title: String
    let hasPendingChanges: Bool
    let missingValueCount: Int
}

/// How a value cell starts out: masked until revealed, or the "Value missing" chip.
enum ConfigValueDisplayModel: Hashable {
    case masked
    case missing
}

/// One row of the Secrets | Variables table (column 3). Never holds a value: values are
/// decrypted on demand by the reveal action.
struct ConfigRowModel: Identifiable, Hashable {
    let id: ConfigItemID
    let name: String
    let value: ConfigValueDisplayModel
    let updatedAt: Date?
    let status: ConfigSyncStatus
}

/// Supplies the main window's content. Repositories arrive with Milestones 2 and 3; until then
/// ``EmptyMainContentSource`` keeps the three columns empty.
protocol MainContentSource: AnyObject {
    func owners(matching query: String) -> [SidebarOwnerModel]
    func scopes(for repo: RepoID) -> [ScopeRowModel]
    func rows(for repo: RepoID, scopeID: ScopeRowModel.ID, kind: ConfigKind) -> [ConfigRowModel]
}

/// The placeholder source: no accounts, no repositories.
final class EmptyMainContentSource: MainContentSource {
    func owners(matching query: String) -> [SidebarOwnerModel] {
        []
    }

    func scopes(for repo: RepoID) -> [ScopeRowModel] {
        []
    }

    func rows(for repo: RepoID, scopeID: ScopeRowModel.ID, kind: ConfigKind) -> [ConfigRowModel] {
        []
    }
}

/// The three-column main window (§10.4): sidebar, scope list, detail table and the toolbar.
@Observable
final class MainViewModel {
    var searchText = ""
    var selectedRepoID: RepoID?
    var selectedScopeID: ScopeRowModel.ID?
    var selectedKind: ConfigKind = .secret
    var selectedRowIDs: Set<ConfigItemID> = []
    var isShowingSync = false

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private let content: any MainContentSource

    init(app: AppViewModel, content: any MainContentSource) {
        self.app = app
        self.content = content
    }

    // MARK: - Columns

    var owners: [SidebarOwnerModel] {
        content.owners(matching: searchText)
    }

    var scopes: [ScopeRowModel] {
        guard let selectedRepoID else { return [] }
        return content.scopes(for: selectedRepoID)
    }

    var rows: [ConfigRowModel] {
        guard let selectedRepoID, let selectedScopeID else { return [] }
        return content.rows(for: selectedRepoID, scopeID: selectedScopeID, kind: selectedKind)
    }

    var selectedRepo: SidebarRepoModel? {
        owners.lazy.flatMap(\.repos).first { $0.id == selectedRepoID }
    }

    /// Shows the "recovery key not confirmed" banner (the vault locked during onboarding or a
    /// recovery reset before the key was saved).
    var showsRecoveryKeyReminder: Bool {
        app.container.preferences.isRecoveryKeyConfirmationPending
    }

    // MARK: - Toolbar

    var pendingChangeCount: Int {
        app.pendingChangeCount
    }

    var isSyncing: Bool {
        app.isSyncing
    }

    /// Disabled at 0, while locked and while a sync runs (§10 Toolbar).
    var canSync: Bool {
        pendingChangeCount > 0 && app.phase == .unlocked && !isSyncing
    }

    func sync() {
        guard canSync else { return }
        isShowingSync = true
    }

    func lock() {
        app.lock(trigger: .manual)
    }
}
