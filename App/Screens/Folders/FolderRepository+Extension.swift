import VaultCore
import VaultData

extension FolderRepository {
    /// The folder's title ("Mobile › Development" for a subfolder), or "" when it is gone (texts
    /// only).
    func folderTitle(_ id: FolderID) -> String {
        PlaceCopy.path(((try? folders()) ?? []).path(of: id))
    }
}
