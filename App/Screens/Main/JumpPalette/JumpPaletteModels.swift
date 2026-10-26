import Foundation
import VaultCore

/// Where a place of the jump palette leads: the sidebar selection it makes.
enum JumpPlaceTarget: Hashable {
    case organization(SidebarOwnerModel.ID)
    case repository(SidebarRepoModel.ID)
    case environment(RepoID, EnvironmentID)
    /// A repository's own secrets and variables (a name found at the repository level).
    case repositoryScope(RepoID)
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

/// One name under "Secrets by name" (1.0 D6c5; board Main2-Search): the kind's symbol, the mono
/// name and where it is ("example-org › api-service › production", "Folder · Stripe test").
/// Never a value.
struct JumpItemModel: Identifiable, Hashable {
    let match: ItemNameMatchModel
    let detail: String
    /// The place ↩ opens; its detail then selects the row.
    let target: JumpPlaceTarget

    var id: ConfigItemID {
        match.id
    }

    var name: String {
        match.name
    }
}

/// A row of either section, for ↑↓ across both.
enum JumpResultID: Hashable {
    case place(JumpPlaceTarget)
    case item(ConfigItemID)
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

    /// The names the vault found, each with where it is from the sidebar's data; a name whose
    /// place the sidebar doesn't list (a destination of a repository) is left out.
    static func items(_ matches: [ItemNameMatchModel], in input: JumpPlaceInputModel) -> [JumpItemModel] {
        let repositories = Dictionary(
            input.owners.flatMap(\.repos).compactMap { repo in repo.importedRepoID.map { ($0, repo) } },
            uniquingKeysWith: { first, _ in first }
        )
        return matches.compactMap { match in
            switch match.holder {
            case .place(.scope(let repositoryID, let scope)):
                guard let repo = repositories[repositoryID] else { return nil }
                guard case .environment(let environmentID) = scope else {
                    let detail = PlaceCopy.path([repo.ownerLogin, repo.name])
                    return JumpItemModel(match: match, detail: detail, target: .repositoryScope(repositoryID))
                }
                guard let environment = input.environments[repositoryID]?.first(where: { $0.id == environmentID }) else { return nil }
                let detail = PlaceCopy.path([repo.ownerLogin, repo.name, environment.name])
                return JumpItemModel(match: match, detail: detail, target: .environment(repositoryID, environmentID))
            case .place(.folder(let id)):
                guard let folder = input.folders.first(where: { $0.id == id }) else { return nil }
                return JumpItemModel(match: match, detail: PlaceCopy.subline([PlaceCopy.folder, folder.name]), target: .folder(id))
            case .place(.destination(let id)):
                guard let vault = input.keyVaults.first(where: { $0.id == id }) else { return nil }
                return JumpItemModel(match: match, detail: PlaceCopy.subline([vault.provider.title, vault.title]), target: .keyVault(id))
            case .organization(let id):
                guard let owner = input.owners.first(where: { $0.organization?.id == id }) else { return nil }
                let detail = PlaceCopy.subline([owner.login, PlaceCopy.organization])
                return JumpItemModel(match: match, detail: detail, target: .organization(owner.id))
            }
        }
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
