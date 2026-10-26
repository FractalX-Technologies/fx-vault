import Foundation
import VaultCore
import VaultData

/// A place the quick vault lists (board QuickVault-Search): ⌘K's row for it, with where it is
/// ("example-org › api-service", "Organization"), what holds its lines and its pending dot.
struct QuickVaultPlaceModel: Identifiable, Hashable {
    /// The symbol, the name and the detail; its target is where Expand goes.
    let row: JumpPlaceModel
    let holder: ItemHolderModel
    /// A change here waits for the next Sync (the dot at the trailing edge).
    let hasPendingChanges: Bool

    var id: ItemHolderModel {
        holder
    }
}

/// A row of either section, for ↑↓ across both.
enum QuickVaultResultID: Hashable {
    case place(ItemHolderModel)
    case item(ConfigItemID)
}

/// What the quick vault reads when it opens: the vault's places as ⌘K lists them, the rows its
/// places' lines need, and the pending changes.
struct QuickVaultInputModel {
    var places = JumpPlaceInputModel()
    var repositories: [RepoModel] = []
    var organizations: [OrganizationModel] = []
    var pendingCounts: PendingCountsModel = .empty
    var organizationPendingCounts: [OrganizationID: Int] = [:]
}

/// Builds, filters and remembers the quick vault's places. Pure, so it is tested without the panel.
enum QuickVaultPlaces {
    /// ⌘K's places with lines in the vault, in the sidebar's order: an organization once
    /// imported, a repository as its own scope.
    static func places(_ input: QuickVaultInputModel) -> [QuickVaultPlaceModel] {
        JumpPlaces.places(input.places).compactMap { jump in
            guard let holder = holder(of: jump.target, owners: input.places.owners) else { return nil }
            let row = JumpPlaceModel(
                target: target(of: holder) ?? jump.target,
                name: jump.name,
                detail: detail(of: jump, holder: holder, keyVaults: input.places.keyVaults),
                systemImage: jump.systemImage,
                titleStyle: jump.titleStyle,
                path: jump.path
            )
            return QuickVaultPlaceModel(row: row, holder: holder, hasPendingChanges: isPending(holder, input))
        }
    }

    /// The places of `query` as ⌘K ranks them (``JumpPlaces/filter(_:query:)``).
    static func filter(_ places: [QuickVaultPlaceModel], query: String) -> [QuickVaultPlaceModel] {
        let byTarget = Dictionary(places.map { ($0.row.target, $0) }, uniquingKeysWith: { first, _ in first })
        return JumpPlaces.filter(places.map(\.row), query: query).compactMap { byTarget[$0.target] }
    }

    /// The recent places still in the vault, most recent first.
    static func recents(_ holders: [ItemHolderModel], in places: [QuickVaultPlaceModel]) -> [QuickVaultPlaceModel] {
        let byHolder = Dictionary(places.map { ($0.holder, $0) }, uniquingKeysWith: { first, _ in first })
        return holders.compactMap { byHolder[$0] }
    }

    /// `holder` first, then the other recent places, at most `limit`.
    static func remember(_ holder: ItemHolderModel, in recents: [ItemHolderModel], limit: Int) -> [ItemHolderModel] {
        Array(([holder] + recents.filter { $0 != holder }).prefix(limit))
    }

    private static func holder(of target: JumpPlaceTarget, owners: [SidebarOwnerModel]) -> ItemHolderModel? {
        switch target {
        case .organization(let id):
            owners.first { $0.id == id }?.organization.map { .organization($0.id) }
        case .repository(let id):
            owners.lazy.flatMap(\.repos).first { $0.id == id }?.importedRepoID.map { .place(.scope(repositoryID: $0, scope: .repository)) }
        case .environment(let repositoryID, let environmentID):
            .place(.scope(repositoryID: repositoryID, scope: .environment(environmentID)))
        case .repositoryScope(let repositoryID):
            .place(.scope(repositoryID: repositoryID, scope: .repository))
        case .keyVault(let id):
            .place(.destination(id))
        case .folder(let id):
            .place(.folder(id))
        }
    }

    /// A repository by its id: the main window selects it even before its sidebar row exists.
    private static func target(of holder: ItemHolderModel) -> JumpPlaceTarget? {
        guard case .place(.scope(let repositoryID, .repository)) = holder else { return nil }
        return .repositoryScope(repositoryID)
    }

    /// The board's detail: the path of a scope, a Key Vault's subscription, else its kind.
    private static func detail(of jump: JumpPlaceModel, holder: ItemHolderModel, keyVaults: [DestinationModel]) -> String {
        switch holder {
        case .place(.scope):
            PlaceCopy.path(jump.path)
        case .place(.destination(let id)):
            keyVaults.first { $0.id == id }?.subscription?.name ?? jump.detail
        case .place(.folder):
            jump.detail
        case .organization:
            PlaceCopy.organization
        }
    }

    private static func isPending(_ holder: ItemHolderModel, _ input: QuickVaultInputModel) -> Bool {
        switch holder {
        case .place(.scope(let repositoryID, let scope)):
            input.pendingCounts.counts(for: repositoryID).pendingScopes.contains(scope)
        case .place(.destination(let id)):
            (input.places.keyVaults.first { $0.id == id }?.pendingCount ?? 0) > 0
        case .place(.folder):
            // A folder never syncs.
            false
        case .organization(let id):
            (input.organizationPendingCounts[id] ?? 0) > 0
        }
    }
}

/// The app that gets the keys back when esc or the shortcut closes the quick vault: the one in
/// front when it was asked for, never FX Vault itself (its main window may be open behind).
struct QuickVaultFocusReturn: Equatable {
    private(set) var processID: pid_t?

    /// A request, before FX Vault comes forward. From FX Vault itself (the island waiting for the
    /// unlock, say) it keeps the app of the request still pending.
    mutating func remember(frontmost: pid_t?, own: pid_t) {
        guard let frontmost, frontmost != own else { return }
        processID = frontmost
    }

    /// The request ended without opening the quick vault.
    mutating func forget() {
        processID = nil
    }

    /// On close: the app to activate when the close gives the keys back. Taken once.
    mutating func take(returnsFocus: Bool) -> pid_t? {
        defer { processID = nil }
        return returnsFocus ? processID : nil
    }
}
