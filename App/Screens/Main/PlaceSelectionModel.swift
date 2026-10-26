import Foundation
import VaultCore
import VaultData

/// What the sidebar and a repository's scopes select: one place on screen (1.0 N2 goes back to
/// it when the user keeps editing its notes).
struct PlaceSelectionModel: Equatable {
    var rowID: SidebarRepoModel.ID?
    var folderID: FolderID?
    var organizationOwnerID: SidebarOwnerModel.ID?
    var keyVaultID: DestinationID?
    var scopeID: ConfigScopeSummaryModel.ID?
}
