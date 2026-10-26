import Foundation
import VaultCore

/// Where a place of the jump palette leads: the sidebar selection it makes.
enum JumpPlaceTarget: Hashable {
    case organization(SidebarOwnerModel.ID)
    case repository(SidebarRepoModel.ID)
    case environment(RepoID, EnvironmentID)
    case keyVault(DestinationID)
    case folder(FolderID)
}

/// One row under "Places" (board Main2-Search): a symbol, the name (mono for names from GitHub
/// and Azure, sans for the user's folders) and what and where it is.
struct JumpPlaceModel: Identifiable, Hashable {
    let target: JumpPlaceTarget
    let name: String
    /// "Folder", "example-org › repository", "example-org › api-service › environment".
    let detail: String
    let systemImage: String
    let titleStyle: SidebarTitleStyle
    /// The owner and repository a word may match besides the name (never the kind).
    let path: [String]

    var id: JumpPlaceTarget {
        target
    }
}

/// What the palette lists: the sidebar's data when it opens.
struct JumpPlaceInputModel {
    /// Every owner node, whatever the sidebar search.
    var owners: [SidebarOwnerModel] = []
    /// The environments of each repository in the vault.
    var environments: [RepoID: [EnvironmentModel]] = [:]
    var keyVaults: [DestinationModel] = []
    var folders: [FolderModel] = []
}

/// Builds and filters the palette's places. Pure, so it is tested without the window.
enum JumpPlaces {
    /// In the sidebar's order: each organization, its repositories each followed by its
    /// environments (deleted ones left out), then the Key Vaults and the folders.
    static func places(_ input: JumpPlaceInputModel) -> [JumpPlaceModel] {
        var places: [JumpPlaceModel] = []
        for owner in input.owners {
            if owner.isOrganization {
                places.append(place(.organization(owner.id), owner.login, JumpPaletteCopy.organization, Theme.Symbols.organization))
            }
            for repo in owner.repos {
                let repoDetail = JumpPaletteCopy.repository(owner: repo.ownerLogin)
                places.append(place(.repository(repo.id), repo.name, repoDetail, Theme.Symbols.repository, path: [repo.ownerLogin]))
                guard let id = repo.importedRepoID else { continue }
                for environment in input.environments[id] ?? [] where !environment.isDeleted {
                    let detail = JumpPaletteCopy.environment(owner: repo.ownerLogin, repository: repo.name)
                    let target = JumpPlaceTarget.environment(id, environment.id)
                    places.append(place(target, environment.name, detail, Theme.Symbols.environment, path: [repo.ownerLogin, repo.name]))
                }
            }
        }
        places += input.keyVaults.map { place(.keyVault($0.id), $0.title, $0.provider.title, $0.provider.symbolName) }
        places += input.folders.map { place(.folder($0.id), $0.name, PlaceCopy.folder, Theme.Symbols.folder, style: .sans) }
        return places
    }

    private static func place(
        _ target: JumpPlaceTarget,
        _ name: String,
        _ detail: String,
        _ systemImage: String,
        style: SidebarTitleStyle = .mono,
        path: [String] = []
    ) -> JumpPlaceModel {
        JumpPlaceModel(target: target, name: name, detail: detail, systemImage: systemImage, titleStyle: style, path: path)
    }

    /// The places where every word of `query` is in the name or the path (any case or accent):
    /// a name that starts with a word first, then a name that contains one, then a path match,
    /// each by name. An empty query keeps the sidebar's order.
    static func filter(_ places: [JumpPlaceModel], query: String) -> [JumpPlaceModel] {
        let words = Self.words(query)
        guard !words.isEmpty else { return places }
        let ranked = places.compactMap { place in
            rank(of: place, words: words).map { (place: place, rank: $0) }
        }
        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let byName = lhs.place.name.localizedStandardCompare(rhs.place.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.place.detail.localizedStandardCompare(rhs.place.detail) == .orderedAscending
        }
        .map(\.place)
    }

    /// The part of `name` to set in bold: the first word of `query` it contains.
    static func highlight(in name: String, query: String) -> Range<String.Index>? {
        words(query).lazy.compactMap { name.range(of: $0, options: searchOptions) }.first
    }

    private static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 0, 1 or 2 as in ``filter(_:query:)``; nil when a word is in neither the name nor the path.
    private static func rank(of place: JumpPlaceModel, words: [String]) -> Int? {
        let fields = [place.name] + place.path
        for word in words where !fields.contains(where: { $0.range(of: word, options: searchOptions) != nil }) {
            return nil
        }
        if words.contains(where: { place.name.range(of: $0, options: searchOptions.union(.anchored)) != nil }) { return 0 }
        if words.contains(where: { place.name.range(of: $0, options: searchOptions) != nil }) { return 1 }
        return 2
    }
}
