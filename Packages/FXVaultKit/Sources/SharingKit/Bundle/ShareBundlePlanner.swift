import Foundation
import VaultCore

/// Builds the receiver's plan for a bundle (v0.9.0, P7–P9). Pure: no database, no keys, no clock.
///
/// - Validates the bundle, then checks its freshness against `local.now` (``ShareError/expired``,
///   `.invalidPackage(.createdInFuture)`).
/// - Each repository gets a status: ✓ in the vault (its GitHub scopes planned by
///   ``ShareImportPlanner``, exactly as a schema 2 package), ⇣ importable from GitHub (planned
///   again once imported), ✕ no access or a different repository under the same name (skipped).
/// - Destinations of a repository in the vault are merged into the local destination with the
///   same target key, or created without a connection; item rules follow ``ShareImportPlanner``
///   (add, fill, skip when the same, keep mine when different).
/// - Folders merge into the local folder with the same name (keeping its items) or are created.
/// - Replay warnings cover the whole bundle (one package id), plus each repository's local changes.
public enum ShareBundlePlanner {
    /// Validates `bundle` for `mode` and plans it against `local`.
    public static func plan(
        _ bundle: ShareBundleModel,
        mode: SharePackageValidator.Mode,
        local: ShareBundleLocalStateModel,
        fingerprint: @escaping ShareFingerprinter,
        destinationFingerprint: @escaping ShareDestinationFingerprinter
    ) throws(ShareError) -> ShareBundlePlanModel {
        try ShareBundleValidator.validate(bundle, mode: mode)
        try bundle.checkFreshness(now: local.now)
        let senderName = bundle.sender.displayName.isEmpty ? nil : bundle.sender.displayName
        var replayWarnings = Set<ShareReplayWarning>()
        if local.importedPackageIDs.contains(bundle.packageID) {
            replayWarnings.insert(.alreadyImported)
        }
        if local.now.timeIntervalSince(bundle.createdAt) > Timeouts.shareReplayMaxAge.timeInterval {
            replayWarnings.insert(.olderThanMaxAge)
        }
        var repositories: [ShareBundleRepositoryPlanModel] = []
        let summaries = bundle.contentSummary.repositories
        for (entry, summary) in zip(bundle.repositories, summaries) {
            let state = local.repositories[entry.id]
            let planned = try planRepository(
                entry,
                summary: summary,
                bundle: bundle,
                mode: mode,
                state: state,
                local: local,
                fingerprint: fingerprint,
                destinationFingerprint: destinationFingerprint
            )
            replayWarnings.formUnion(planned.replayWarnings)
            repositories.append(planned.plan)
        }
        var linkTokens: [ShareEntryID: String] = [:]
        for located in bundle.allItems {
            if let token = located.item.linkToken {
                linkTokens[located.item.id] = token
            }
        }
        return ShareBundlePlanModel(
            packageID: bundle.packageID,
            origin: ShareOriginModel(packageID: bundle.packageID, senderName: senderName),
            mode: mode,
            stages: bundle.stages,
            replayWarnings: replayWarnings,
            repositories: repositories,
            folders: bundle.folders.map { planFolder($0, local: local.folders) },
            linkTokens: linkTokens,
            folderItemIDs: Dictionary(
                uniqueKeysWithValues: bundle.folders.map { folder in
                    (folder.id, (folder.secrets + folder.variables).map(\.id))
                }
            )
        )
    }

    // MARK: - Repositories

    private static func planRepository(
        _ entry: ShareBundleRepositoryModel,
        summary: ShareBundleRepositorySummaryModel,
        bundle: ShareBundleModel,
        mode: SharePackageValidator.Mode,
        state: ShareBundleRepositoryStateModel?,
        local: ShareBundleLocalStateModel,
        fingerprint: @escaping ShareFingerprinter,
        destinationFingerprint: @escaping ShareDestinationFingerprinter
    ) throws(ShareError) -> (plan: ShareBundleRepositoryPlanModel, replayWarnings: Set<ShareReplayWarning>) {
        func result(
            _ status: ShareBundleRepositoryStatus,
            githubPlan: ShareImportPlanModel? = nil,
            destinations: [ShareDestinationPlanModel] = []
        ) -> ShareBundleRepositoryPlanModel {
            ShareBundleRepositoryPlanModel(
                id: entry.id,
                owner: entry.repository.owner,
                name: entry.repository.name,
                githubRepoID: entry.repository.githubRepoID,
                status: status,
                summary: summary,
                githubPlan: githubPlan,
                destinations: destinations
            )
        }
        guard let state else { return (result(.noAccess(.notChecked)), []) }
        guard state.repository != nil else {
            switch state.access {
            case .importable(let login):
                let created = entry.destinations.map { createdDestination($0) }
                return (result(.willImportFromGitHub(accountLogin: login), destinations: created), [])
            case .notVisible:
                return (result(.noAccess(.notVisible)), [])
            case .unreachable:
                return (result(.noAccess(.unreachable)), [])
            case .unknown:
                return (result(.noAccess(.notChecked)), [])
            }
        }
        let githubPlan = try ShareImportPlanner.plan(
            bundle.githubPackage(for: entry),
            mode: mode,
            local: ShareLocalStateModel(
                repository: state.repository,
                environments: state.environments,
                items: state.items,
                remote: state.remote,
                importedPackageIDs: local.importedPackageIDs,
                now: local.now
            ),
            fingerprint: fingerprint
        )
        if let reason = githubPlan.blockReason {
            return (result(.blocked(reason)), [])
        }
        var warnings = githubPlan.replayWarnings
        let destinations = entry.destinations.map { destination in
            planDestination(
                destination,
                local: state.destinations,
                createdAt: bundle.createdAt,
                mode: mode,
                fingerprint: destinationFingerprint
            )
        }
        if destinations.contains(where: { $0.items.contains { $0.warnings.contains(.localChangedSincePackage) } }) {
            warnings.insert(.olderThanLocalChanges)
        }
        return (result(.inVault, githubPlan: githubPlan, destinations: destinations), warnings)
    }

    // MARK: - Destinations

    /// A destination of a repository that is not in the vault yet: created, every item added.
    private static func createdDestination(_ destination: ShareDestinationModel) -> ShareDestinationPlanModel {
        ShareDestinationPlanModel(
            id: destination.id,
            target: destination.target,
            stage: destination.stage,
            action: .create,
            items: located(destination).map { item, kind in
                newItemPlan(item, kind: kind)
            }
        )
    }

    private static func planDestination(
        _ destination: ShareDestinationModel,
        local: [ShareLocalDestinationModel],
        createdAt: Date,
        mode: SharePackageValidator.Mode,
        fingerprint: ShareDestinationFingerprinter
    ) -> ShareDestinationPlanModel {
        guard let existing = local.first(where: { $0.destination.target.targetKey == destination.target.targetKey }) else {
            return createdDestination(destination)
        }
        var itemsByName: [String: ShareLocalDestinationItemModel] = [:]
        for localItem in existing.items {
            // A live row wins over a tombstone with the same name.
            let key = localItem.item.nameKey
            if itemsByName[key] == nil || itemsByName[key]?.item.isDeleted == true {
                itemsByName[key] = localItem
            }
        }
        let items = located(destination).map { item, kind in
            planItem(
                item,
                kind: kind,
                local: itemsByName[GitHubNameValidator.foldKey(item.name)],
                createdAt: createdAt,
                mode: mode,
                fingerprint: fingerprint
            )
        }
        return ShareDestinationPlanModel(
            id: destination.id,
            target: destination.target,
            stage: destination.stage,
            action: .useExisting(existing.destination.id),
            items: items
        )
    }

    private static func located(_ destination: ShareDestinationModel) -> [(ShareItemModel, ConfigKind)] {
        destination.secrets.map { ($0, ConfigKind.secret) } + destination.variables.map { ($0, ConfigKind.variable) }
    }

    private static func newItemPlan(_ item: ShareItemModel, kind: ConfigKind) -> ShareDestinationItemPlanModel {
        if item.valueState == .missing {
            return ShareDestinationItemPlanModel(
                id: item.id,
                kind: kind,
                name: item.name,
                localItemID: nil,
                chip: .valueNotIncluded,
                defaultAction: .addWithoutValue,
                allowedActions: [.addWithoutValue, .skip]
            )
        }
        return ShareDestinationItemPlanModel(
            id: item.id,
            kind: kind,
            name: item.name,
            localItemID: nil,
            chip: .new,
            defaultAction: .add,
            allowedActions: [.add, .skip]
        )
    }

    private static func planItem(
        _ item: ShareItemModel,
        kind: ConfigKind,
        local localItem: ShareLocalDestinationItemModel?,
        createdAt: Date,
        mode: SharePackageValidator.Mode,
        fingerprint: ShareDestinationFingerprinter
    ) -> ShareDestinationItemPlanModel {
        guard let localItem else { return newItemPlan(item, kind: kind) }
        let local = localItem.item
        func skipped(_ chip: ShareItemChip, warnings: Set<ShareItemWarning>) -> ShareDestinationItemPlanModel {
            ShareDestinationItemPlanModel(
                id: item.id,
                kind: kind,
                name: item.name,
                localItemID: local.id,
                chip: chip,
                defaultAction: .skip,
                allowedActions: [.skip],
                warnings: warnings
            )
        }
        var warnings = Set<ShareItemWarning>()
        if local.updatedAt > createdAt {
            warnings.insert(.localChangedSincePackage)
        }
        if local.isDeleted {
            return skipped(.deletedLocally, warnings: warnings.union([.deletedLocally]))
        }
        // One name per destination, whatever the kind (`destination_items_name`).
        if local.kind != kind {
            return ShareDestinationItemPlanModel(
                id: item.id,
                kind: kind,
                name: item.name,
                localItemID: nil,
                chip: .otherKindExists,
                defaultAction: .skip,
                allowedActions: [.skip],
                warnings: warnings.union([.otherKindExists])
            )
        }
        if item.valueState == .missing {
            return skipped(.valueNotIncluded, warnings: warnings)
        }
        if local.valueState == .missing {
            return ShareDestinationItemPlanModel(
                id: item.id,
                kind: kind,
                name: item.name,
                localItemID: local.id,
                chip: .fillsMissingValue,
                defaultAction: .fill,
                allowedActions: [.fill, .skip],
                warnings: warnings
            )
        }
        let chip: ShareItemChip
        switch (mode, item.value) {
        case (.payload, .some(let value)):
            chip = isSame(value, as: localItem, fingerprint: fingerprint) ? .same : .differs
        default:
            chip = .existsLocally
        }
        return ShareDestinationItemPlanModel(
            id: item.id,
            kind: kind,
            name: item.name,
            localItemID: local.id,
            chip: chip,
            defaultAction: chip == .same ? .skip : .keepMine,
            allowedActions: chip == .same ? [.skip] : [.keepMine, .overwrite],
            warnings: warnings
        )
    }

    private static func isSame(
        _ value: SecretBytes,
        as local: ShareLocalDestinationItemModel,
        fingerprint: ShareDestinationFingerprinter
    ) -> Bool {
        guard let stored = local.fingerprint, let incoming = fingerprint(local.item, value) else { return false }
        return stored.withUnsafeBytes { left in
            incoming.withUnsafeBytes { right in SecretBytes.constantTimeEquals(left, right) }
        }
    }

    // MARK: - Folders

    private static func planFolder(_ folder: ShareBundleFolderModel, local: [ShareLocalFolderModel]) -> ShareBundleFolderPlanModel {
        let key = FolderNameValidator.foldKey(folder.name)
        let existing = local.first { FolderNameValidator.foldKey($0.folder.name) == key }
        var conflicting = Set<ShareEntryID>()
        if let existing {
            let names = Set(existing.items.map { FolderItemKey(kind: $0.kind, nameKey: GitHubNameValidator.foldKey($0.name)) })
            let incoming = folder.secrets.map { ($0, ConfigKind.secret) } + folder.variables.map { ($0, ConfigKind.variable) }
            for (item, kind) in incoming where names.contains(FolderItemKey(kind: kind, nameKey: GitHubNameValidator.foldKey(item.name))) {
                conflicting.insert(item.id)
            }
        }
        let action: ShareFolderPlanAction = existing.map { .mergeInto($0.folder.id, conflicts: .keepMine) }
            ?? .createNew(name: folder.name)
        return ShareBundleFolderPlanModel(
            id: folder.id,
            name: folder.name,
            counts: ShareItemCountModel(secrets: folder.secrets.count, variables: folder.variables.count),
            existingFolderID: existing?.folder.id,
            conflictingItemIDs: conflicting,
            defaultAction: action,
            action: action
        )
    }

    private struct FolderItemKey: Hashable {
        let kind: ConfigKind
        let nameKey: String
    }
}

extension ShareBundleModel {
    /// The GitHub scopes of `entry` as a schema 1–2 repository package with this bundle's id,
    /// dates, producer and sender (link tokens dropped), for ``ShareImportPlanner`` and VaultData's
    /// existing importer. The value buffers are shared with the bundle: wipe one of them.
    public func githubPackage(for entry: ShareBundleRepositoryModel) -> SharePackageModel {
        let repository = entry.repository.mapItems { item in
            var copy = item
            copy.linkToken = nil
            return copy
        }
        return SharePackageModel(
            packageID: packageID,
            createdAt: createdAt,
            producer: producer,
            sender: sender,
            scope: .repository,
            repository: repository
        )
    }

    /// The item `id` of the bundle with where it lives, or nil.
    public func item(withID id: ShareEntryID) -> ShareBundleLocatedItemModel? {
        allItems.first { $0.item.id == id }
    }

    /// The folder `id` of the bundle as a schema 3 folder package (``ShareBundleFolderModel/folderPackage(packageID:createdAt:producer:sender:)``).
    public func folderPackage(for id: ShareEntryID) -> SharePackageModel? {
        folders.first { $0.id == id }.map {
            $0.folderPackage(packageID: packageID, createdAt: createdAt, producer: producer, sender: sender)
        }
    }
}
