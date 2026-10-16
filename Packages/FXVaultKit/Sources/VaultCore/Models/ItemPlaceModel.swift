/// Where secrets and variables live (v0.7.0): one scope of a vault repository, or a folder.
///
/// Copy and paste, `.env` import and export and the item editor take a place, so the same flow
/// serves both. Only scopes ever reach GitHub.
public enum ItemPlaceModel: Sendable, Hashable {
    case scope(repositoryID: RepoID, scope: ConfigScope)
    case folder(FolderID)

    /// The repository of a scope place; nil for a folder.
    public var repositoryID: RepoID? {
        if case .scope(let repositoryID, _) = self { return repositoryID }
        return nil
    }

    /// The folder; nil for a scope place.
    public var folderID: FolderID? {
        if case .folder(let id) = self { return id }
        return nil
    }
}
