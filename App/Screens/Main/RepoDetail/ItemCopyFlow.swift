import Foundation
import Observation
import VaultCore
import VaultData

/// "Replace or keep?" and the copy itself (v0.4.0; folders since v0.7.0), shared by the detail
/// tables of repository scopes and folders and by Copy To › Another Repository….
@Observable
final class ItemCopyFlow {
    /// A copy waiting for "Replace or keep?": the target already has some of the names.
    var pendingCopy: ItemCopyRequestModel?

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(dependencies: FeatureDependencies) {
        self.dependencies = dependencies
    }

    /// Copies `ids` into `target` now, or asks first when it already has some of the names.
    ///
    /// - Returns: the result of a copy made now; nil when nothing was copied yet (the question
    ///   is pending, or there is nothing to copy).
    func request(_ ids: [ConfigItemID], to target: ItemCopyTargetModel) throws(ConfigRepositoryError) -> ItemCopyResultModel? {
        guard !ids.isEmpty, target.isEditable else { return nil }
        let conflicts = try dependencies.copyConflicts(ids, to: target.place)
        let request = ItemCopyRequestModel(ids: ids, target: target, conflicts: conflicts)
        guard conflicts.isEmpty else {
            pendingCopy = request
            return nil
        }
        return try dependencies.copyItems(ids, to: target.place, conflicts: .keep)
    }

    /// The answer to "Replace or keep?": copies with that choice.
    func confirm(replacing: Bool) throws(ConfigRepositoryError) -> (ItemCopyRequestModel, ItemCopyResultModel)? {
        guard let request = pendingCopy else { return nil }
        pendingCopy = nil
        let result = try dependencies.copyItems(request.ids, to: request.target.place, conflicts: replacing ? .replace : .keep)
        return (request, result)
    }
}
