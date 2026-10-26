/// Where secrets and variables live (v0.7.0): one scope of a vault repository, a folder, or
/// (v0.8.0) a runtime destination of a repository.
///
/// Copy and paste, `.env` import and export and the item editor take a place, so the same flow
/// serves all three. Only scopes ever reach GitHub; destination items reach their provider
/// through their own Sync path.
public enum ItemPlaceModel: Sendable, Hashable {
    case scope(repositoryID: RepoID, scope: ConfigScope)
    case folder(FolderID)
    case destination(DestinationID)

    /// The repository of a scope place; nil for a folder or a destination.
    public var repositoryID: RepoID? {
        if case .scope(let repositoryID, _) = self { return repositoryID }
        return nil
    }

    /// The folder; nil for any other place.
    public var folderID: FolderID? {
        if case .folder(let id) = self { return id }
        return nil
    }

    /// The destination; nil for any other place.
    public var destinationID: DestinationID? {
        if case .destination(let id) = self { return id }
        return nil
    }
}

/// Anything that holds secrets and variables: a place, or an organization (1.0). Copy All reads
/// one (D6c4); a name found by ⌘K says where it is (D6c5).
public enum ItemHolderModel: Sendable, Hashable {
    case place(ItemPlaceModel)
    case organization(OrganizationID)
}

/// A secret or variable found by its name (1.0 D6c5, ⌘K "Secrets by name"): its row, kind and
/// holder, never its value.
public struct ItemNameMatchModel: Sendable, Hashable, Identifiable {
    public let id: ConfigItemID
    public let kind: ConfigKind
    public let name: String
    public let holder: ItemHolderModel

    public init(id: ConfigItemID, kind: ConfigKind, name: String, holder: ItemHolderModel) {
        self.id = id
        self.kind = kind
        self.name = name
        self.holder = holder
    }
}
