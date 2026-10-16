import VaultCore
import VaultData

extension FolderRepository {
    /// The folder's name, or "" when it is gone (texts only).
    func folderName(_ id: FolderID) -> String {
        ((try? folders()) ?? []).first { $0.id == id }?.name ?? ""
    }
}
