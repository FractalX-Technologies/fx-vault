import AppKit
import Foundation
import Observation
import SwiftUI
import VaultCore
import VaultData

/// The quick vault (1.0 Q1; boards QuickVault-Search, -Place): the shortcut opens it from any app
/// on the vault's places, recent ones first, and the names in them; ↩ shows a place's lines, ⌘↩
/// opens the place in the main window. Only while unlocked; a lock closes it and drops its lines.
@Observable
final class QuickVaultViewModel: LockObserving {
    private(set) var isOpen = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            search()
        }
    }
    private(set) var results: [QuickVaultPlaceModel] = []
    /// "Secrets by name": empty until something is typed.
    private(set) var items: [JumpItemModel] = []
    /// The empty query lists the recent places ("Recent"), else every place ("Places").
    private(set) var showsRecents = false
    var selectedID: QuickVaultResultID?
    /// The place whose lines show; nil on the search.
    private(set) var place: QuickVaultPlaceViewModel?
    /// Bumped when the search shows again (open, back): the field takes the focus.
    private(set) var focusRequest = 0
    /// The screen's notch height; 0 floats the panel under the menu bar.
    var notchHeight: CGFloat = 0

    @ObservationIgnored var onShow: (() -> Void)?
    /// The panel hides; `returnFocusTo` is the app to give the keys back to (``QuickVaultFocusReturn``).
    @ObservationIgnored var onHide: ((_ returnFocusTo: pid_t?) -> Void)?
    /// FX Vault is active and the panel, or no other window, has the keys (the controller says).
    @ObservationIgnored var hasFocus: () -> Bool = { true }
    /// The app in front, read when the quick vault is asked for.
    @ObservationIgnored var frontmostApp: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// The panel's size changed; it keeps its top edge where it is.
    @ObservationIgnored var onSizeChange: ((CGSize) -> Void)?
    /// Most recent first, in memory only: ids, never a name.
    @ObservationIgnored private(set) var recents: [ItemHolderModel] = []
    /// Reads the places of this open (internal so tests can await it).
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// Bumped by each open: a read that ends after a close or a newer open is dropped.
    @ObservationIgnored private var openCount = 0
    @ObservationIgnored private var focusReturn = QuickVaultFocusReturn()
    /// Waits for the end of a check a focus loss came during (internal so tests can await it).
    @ObservationIgnored private(set) var checkWatch: Task<Void, Never>?
    @ObservationIgnored private var input = QuickVaultInputModel()
    @ObservationIgnored private var places: [QuickVaultPlaceModel] = []
    @ObservationIgnored private let app: AppViewModel

    static let recentLimit = 5

    init(app: AppViewModel) {
        self.app = app
        app.addLockObserver(self)
    }

    // MARK: - Open and close

    /// The shortcut or the menu asked for it: remember the app in front before FX Vault comes forward.
    func noteRequest() {
        focusReturn.remember(frontmost: frontmostApp(), own: ProcessInfo.processInfo.processIdentifier)
    }

    /// A request made while locked ended without the quick vault (another app, Open FX Vault).
    func forgetRequest() {
        focusReturn.forget()
    }

    /// Shows the search, then reads the vault's places into it; only while unlocked.
    func open() {
        guard app.phase == .unlocked, !isOpen else { return }
        isOpen = true
        openCount += 1
        focusRequest += 1
        onShow?()
        let count = openCount
        loadTask = Task { [weak self] in
            guard let input = await self?.readInput(), let self, isOpen, openCount == count else { return }
            self.input = input
            places = QuickVaultPlaces.places(input)
            search()
        }
    }

    /// Drops the lines, the search and what it read. `returnsFocus` for esc and the shortcut.
    func close(returnsFocus: Bool = false) {
        guard isOpen else { return }
        loadTask?.cancel()
        loadTask = nil
        checkWatch?.cancel()
        checkWatch = nil
        place?.close()
        place = nil
        isOpen = false
        places = []
        input = QuickVaultInputModel()
        query = ""
        results = []
        items = []
        selectedID = nil
        onHide?(focusReturn.take(returnsFocus: returnsFocus))
    }

    /// Esc: from a place back to the search, from the search away.
    func escape() {
        if place != nil {
            back()
        } else {
            close(returnsFocus: true)
        }
    }

    func back() {
        place?.close()
        place = nil
        focusRequest += 1
    }

    /// Losing the focus closes it. Not while Touch ID or the password check runs (its prompt may
    /// take the focus); then the check's end decides.
    func didLoseFocus() {
        guard isOpen else { return }
        guard place?.isAuthorizing == true else {
            close()
            return
        }
        closeAfterTheCheckWithoutFocus()
    }

    /// Without this, `hidesOnDeactivate` would bring the panel back at the next activation, the
    /// place still open, after a check the user walked away from.
    private func closeAfterTheCheckWithoutFocus() {
        guard checkWatch == nil else { return }
        checkWatch = Task { [weak self] in
            let checks = Observations { @MainActor [weak self] in
                self?.place?.isAuthorizing == true
            }
            for await isAuthorizing in checks where !isAuthorizing {
                break
            }
            guard let self, !Task.isCancelled else { return }
            checkWatch = nil
            if isOpen, !hasFocus() {
                close()
            }
        }
    }

    func vaultDidLock() {
        close()
    }

    // MARK: - Search

    /// Up and Down, across both sections, stopping at the first and the last row.
    func moveSelection(_ direction: MoveCommandDirection) {
        guard let next = MainColumnSelection.id(after: selectedID, in: resultIDs, direction: direction) else { return }
        selectedID = next
    }

    /// ↩: the selected place's lines, or those of the place a name is in.
    func openSelected() {
        guard let holder = selectedHolder else { return }
        show(holder)
    }

    func show(_ holder: ItemHolderModel) {
        guard isOpen, let found = places.first(where: { $0.holder == holder }) else { return }
        recents = QuickVaultPlaces.remember(holder, in: recents, limit: Self.recentLimit)
        place?.close()
        place = makePlace(found)
    }

    func highlight(in name: String) -> Range<String.Index>? {
        JumpPlaces.highlight(in: name, query: query)
    }

    /// ⌘↩ and Expand: the open place, or the selected row's, in the main window.
    func expand() {
        guard let holder = place?.place.holder ?? selectedHolder,
              let target = places.first(where: { $0.holder == holder })?.row.target else { return }
        recents = QuickVaultPlaces.remember(holder, in: recents, limit: Self.recentLimit)
        close()
        app.requestPlace(target)
    }

    private var resultIDs: [QuickVaultResultID] {
        results.map { .place($0.holder) } + items.map { .item($0.id) }
    }

    private var selectedHolder: ItemHolderModel? {
        switch selectedID {
        case .place(let holder): holder
        case .item(let id): items.first { $0.id == id }?.match.holder
        case nil: nil
        }
    }

    private func search() {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let recent = QuickVaultPlaces.recents(recents, in: places)
            showsRecents = !recent.isEmpty
            results = recent.isEmpty ? places : recent
            items = []
        } else {
            showsRecents = false
            results = QuickVaultPlaces.filter(places, query: query)
            items = searchItems(query)
        }
        selectedID = resultIDs.first
    }

    private func searchItems(_ query: String) -> [JumpItemModel] {
        do {
            return JumpPlaces.items(try app.container.data.config.itemNames(matching: query), in: input.places)
        } catch {
            AppLog.ui.error("Quick vault could not read the names")
            return []
        }
    }

    // MARK: - Reads

    /// The vault's places, read once per open: the sidebar's grouping over the vault's rows only.
    private func readInput() async -> QuickVaultInputModel {
        let data = app.container.data
        do {
            let organizations = try await data.organizations.organizations()
            let repositories = try data.config.repositories()
            let owners = SidebarGrouping.owners(
                SidebarInputModel(vaultRepos: repositories, vaultOrganizations: organizations),
                query: ""
            )
            return QuickVaultInputModel(
                places: JumpPlaceInputModel(
                    owners: owners,
                    environments: try data.config.environmentsByRepository(),
                    keyVaults: try data.destinations.destinations(repositoryID: nil),
                    folders: try data.folders.folders()
                ),
                repositories: repositories,
                organizations: organizations,
                pendingCounts: app.pendingCounts,
                organizationPendingCounts: app.organizationPendingCounts
            )
        } catch {
            AppLog.ui.error("Quick vault could not read the places")
            return QuickVaultInputModel()
        }
    }

    /// The place's lines come from the detail view model the main window uses for it.
    private func makePlace(_ place: QuickVaultPlaceModel) -> QuickVaultPlaceViewModel? {
        let dependencies = FeatureDependencies(container: app.container, actions: actions)
        let input = input
        let source: any NotesPlaceModel
        switch place.holder {
        case .place(.scope(let repositoryID, let scope)):
            let repository = input.repositories.first { $0.id == repositoryID }
            let summaries = (try? dependencies.config.scopes(repositoryID: repositoryID)) ?? []
            let detail = RepoDetailViewModel(
                repositoryID: repositoryID,
                dependencies: dependencies,
                repository: { repository },
                scopeSummary: { scope in summaries.first { $0.scope == scope } }
            )
            detail.select(scope: scope)
            source = detail
        case .place(.folder(let id)):
            let folder = input.places.folders.first { $0.id == id }
            source = FolderDetailViewModel(folderID: id, dependencies: dependencies) { folder }
        case .place(.destination(let id)):
            guard let vault = input.places.keyVaults.first(where: { $0.id == id }) else { return nil }
            source = DestinationDetailViewModel(destination: vault, dependencies: dependencies) { vault }
        case .organization(let id):
            let organization = input.organizations.first { $0.id == id }
            source = OrganizationDetailViewModel(
                organizationID: id,
                dependencies: dependencies,
                organization: { organization },
                repositoryNames: { [] }
            )
        }
        let copy: (ConfigItemID) throws(ConfigRepositoryError) -> Void = if case .organization = place.holder {
            dependencies.copyOrganizationValue(of:)
        } else {
            dependencies.copyValue(of:)
        }
        return QuickVaultPlaceViewModel(place: place, source: source, dependencies: dependencies, copyValue: copy)
    }

    /// The quick vault opens no sheet and selects nothing; it follows locks like the window.
    private var actions: MainActions {
        MainActions(
            present: { _ in },
            refresh: { _ in },
            beginSyncActivity: { [app] in app.beginSyncActivity() },
            addLockObserver: { [app] observer in app.addLockObserver(observer) },
            isGitHubReady: { [app] in app.ghStatus.isReady },
            select: { _ in }
        )
    }
}
