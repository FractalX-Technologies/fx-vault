import Foundation
import SharingKit
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Applies a reviewed `ShareBundlePlanModel` to the vault in the caller's single
/// `VaultSession.write` transaction (v0.9.0, P7–P9).
///
/// - **GitHub scopes** of every repository imported now (✓) through ``ShareImporter``, exactly as
///   a schema 2 package (environments, items, provenance), without recording the package per
///   repository.
/// - **Destinations** merged into the local destination with the same target key, or created.
///   Items go through ``DestinationItemWriter``.
/// - **Folders** created or merged (kind and fold-key name match, as Save as Folder does).
/// - **Holds** (P8): every written row that would make the next Sync change a remote gets
///   `share_hold` = the package id: a GitHub add, fill or overwrite that is pending, and every
///   destination row written.
///   Folder rows never sync, so they are never held.
/// - **Links** (P9): each link group of the plan whose written rows number at least two gets one
///   fresh `link_id`; rows kept as they were keep their links.
/// - Finally the package id is recorded once for the replay check.
struct ProjectShareImporter {
    let database: VaultDatabase
    let tx: StoreTransaction
    let keys: UnlockedKeys
    let now: Date
    let writePolicy: WriteCollaboratorPolicy

    /// Where an incoming entry was written.
    private enum WrittenRow {
        case config(ConfigItemID)
        case destination(ConfigItemID)
        case folder(ConfigItemID)
    }

    func apply(
        _ plan: ShareBundlePlanModel,
        bundle: ShareBundleModel,
        remotes: [String: ShareRemoteContextModel],
        sender: ShareFileSenderModel
    ) throws -> ShareBundleImportResultModel {
        var result = ShareBundleImportResultModel()
        var written: [ShareEntryID: WrittenRow] = [:]
        var heldConfig: [ConfigItemID] = []
        var heldDestination: [ConfigItemID] = []

        for repositoryPlan in plan.repositories where repositoryPlan.status.isImportedNow {
            guard let entry = bundle.repositories.first(where: { $0.id == repositoryPlan.id }),
                  let repository = try RepoStore(database: database).fetch(
                      ownerLogin: entry.repository.owner,
                      name: entry.repository.name,
                      in: tx
                  )
            else { throw SharingError.planOutdated }
            if result.firstRepositoryID == nil {
                result.firstRepositoryID = repository.id
            }
            if let githubPlan = repositoryPlan.githubPlan {
                let applied = try ShareImporter(database: database, tx: tx, keys: keys, now: now, writePolicy: writePolicy)
                    .applyRows(githubPlan, package: bundle.githubPackage(for: entry), remote: remotes[repositoryPlan.id], recordsImport: false)
                result.repositories.append(applied.result)
                for (entryID, row) in applied.rows {
                    written[entryID] = .config(row.id)
                    if row.isPending { heldConfig.append(row.id) }
                }
            }
            for destinationPlan in repositoryPlan.destinations {
                for (entryID, row) in try applyDestination(destinationPlan, repositoryID: repository.id, bundle: bundle, result: &result) {
                    written[entryID] = .destination(row.id)
                    if row.isPending { heldDestination.append(row.id) }
                }
            }
        }

        for folderPlan in plan.folders {
            guard let folder = bundle.folders.first(where: { $0.id == folderPlan.id }) else { throw SharingError.planOutdated }
            for (entryID, id) in try applyFolder(folderPlan, folder: folder, result: &result) {
                written[entryID] = .folder(id)
            }
        }

        result.linkGroupCount = try link(plan.linkGroups, written: written)

        let packageID = plan.packageID
        try ConfigStore(database: database).setShareHold(packageID, itemIDs: heldConfig, in: tx)
        try DestinationStore(database: database).setShareHold(packageID, itemIDs: heldDestination, in: tx)
        result.heldCount = heldConfig.count + heldDestination.count
        result.firstStage = plan.firstStage

        try SharePackageStore(database: database).recordImport(
            ImportedSharePackageRecord(
                packageID: packageID,
                createdAt: bundle.createdAt,
                importedAt: now,
                senderName: plan.origin.senderName
            ),
            in: tx
        )
        return result
    }

    // MARK: - Destinations

    private func applyDestination(
        _ plan: ShareDestinationPlanModel,
        repositoryID: RepoID,
        bundle: ShareBundleModel,
        result: inout ShareBundleImportResultModel
    ) throws -> [ShareEntryID: ShareImportedRowModel] {
        let store = DestinationStore(database: database)
        let destinationID: DestinationID
        switch plan.action {
        case .create:
            destinationID = try createDestination(plan, repositoryID: repositoryID, store: store)
            result.destinationsCreated.append(ShareDestinationLabel.text(plan.target))
        case .useExisting(let id):
            guard try store.fetchDestination(id: id, in: tx)?.repositoryID == repositoryID else { throw SharingError.planOutdated }
            destinationID = id
        }
        let writer = DestinationItemWriter(store: store, keys: keys, tx: tx, now: now)
        var rows: [ShareEntryID: ShareImportedRowModel] = [:]
        for itemPlan in plan.items where itemPlan.writesRow {
            guard let located = bundle.item(withID: itemPlan.id) else { throw SharingError.planOutdated }
            let rowID: ConfigItemID
            switch itemPlan.outcome {
            case .unchanged:
                continue
            case .addedWithoutValue:
                rowID = try insertValueMissing(itemPlan, destinationID: destinationID, store: store, writer: writer)
            case .added:
                let value = try normalizedValue(of: located.item)
                defer { value.wipe() }
                rowID = try writer.add(destinationID: destinationID, kind: itemPlan.kind, name: itemPlan.name, value: value)
            case .filled:
                guard let localID = itemPlan.localItemID else { throw SharingError.planOutdated }
                let value = try normalizedValue(of: located.item)
                defer { value.wipe() }
                try writer.fill(localID, value: value, alreadyMatchesRemote: false)
                rowID = localID
            case .overwritten:
                guard let localID = itemPlan.localItemID else { throw SharingError.planOutdated }
                let value = try normalizedValue(of: located.item)
                defer { value.wipe() }
                try writer.editValue(localID, value: value)
                rowID = localID
            }
            rows[itemPlan.id] = ShareImportedRowModel(id: rowID, isPending: true)
            result.destinationItemsWritten += 1
        }
        return rows
    }

    /// A destination of the receiver's repository.
    private func createDestination(
        _ plan: ShareDestinationPlanModel,
        repositoryID: RepoID,
        store: DestinationStore
    ) throws -> DestinationID {
        let target = try DestinationRules.validate(plan.target)
        let stage = try DestinationRepository.validStage(plan.stage)
        guard try store.countDestinations(repositoryID: repositoryID, in: tx) < Limits.maxDestinationsPerRepository else {
            throw ConfigRepositoryError.tooManyDestinations(limit: Limits.maxDestinationsPerRepository)
        }
        guard try !store.fetchDestinationRecords(repositoryID: repositoryID, in: tx).contains(where: { $0.targetKey == target.targetKey }) else {
            throw SharingError.planOutdated
        }
        let record = DestinationRecord(
            repositoryID: repositoryID,
            target: target,
            stage: stage,
            sortOrder: try store.nextSortOrder(repositoryID: repositoryID, in: tx),
            createdAt: now,
            updatedAt: now
        )
        try store.insertDestination(record, in: tx)
        return record.id
    }

    /// A secret that travelled by name only (a write-only remote value on the sender's side).
    private func insertValueMissing(
        _ plan: ShareDestinationItemPlanModel,
        destinationID: DestinationID,
        store: DestinationStore,
        writer: DestinationItemWriter
    ) throws -> ConfigItemID {
        let destination = try writer.requireDestination(destinationID)
        let kind = destination.provider.storedKind(for: plan.kind)
        let name = try DestinationRules.validate(plan.name, kind: kind, provider: destination.provider)
        guard try store.countLiveItems(destinationID: destinationID, in: tx) < Limits.maxDestinationItems else {
            throw ConfigRepositoryError.destinationFull(limit: Limits.maxDestinationItems)
        }
        let record = DestinationItemRecord(
            destinationID: destinationID,
            kind: kind,
            name: name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            createdAt: now,
            updatedAt: now
        )
        try store.insertItem(record, in: tx)
        return record.id
    }

    // MARK: - Folders

    /// Creates or merges the folder; returns the row of every incoming item written.
    private func applyFolder(
        _ plan: ShareBundleFolderPlanModel,
        folder: ShareBundleFolderModel,
        result: inout ShareBundleImportResultModel
    ) throws -> [ShareEntryID: ConfigItemID] {
        let store = FolderStore(database: database)
        let folderID: FolderID
        let replaces: Bool
        switch plan.action {
        case .skip:
            return [:]
        case .createNew(let name):
            let validName = try FolderNameValidator.validate(name)
            let key = FolderNameValidator.foldKey(validName)
            guard try !store.fetchFolderRecords(in: tx).contains(where: { $0.parentID == nil && $0.nameKey == key }) else {
                throw ValidationError.duplicateName
            }
            let record = FolderRecord(name: validName, sortOrder: try store.nextSortOrder(parent: nil, in: tx), createdAt: now, updatedAt: now)
            try store.insertFolder(record, in: tx)
            folderID = record.id
            replaces = false
            result.folders.append(validName)
        case .mergeInto(let id, let conflicts):
            folderID = id
            replaces = conflicts == .replace
            result.folders.append(plan.name)
        }
        let writer = FolderItemWriter(store: store, keys: keys, tx: tx, now: now)
        _ = try writer.requireFolder(folderID)
        var rows: [ShareEntryID: ConfigItemID] = [:]
        let incoming = folder.secrets.map { ($0, ConfigKind.secret) } + folder.variables.map { ($0, ConfigKind.variable) }
        for (item, kind) in incoming {
            let value = try normalizedValue(of: item)
            defer { value.wipe() }
            if let existing = try writer.row(folderID: folderID, kind: kind, name: item.name) {
                guard replaces else { continue }
                try writer.editValue(existing.id, value: value)
                rows[item.id] = existing.id
            } else {
                rows[item.id] = try writer.add(folderID: folderID, kind: kind, name: item.name, value: value)
            }
        }
        return rows
    }

    // MARK: - Links

    /// One fresh `link_id` per group with at least two written rows. Returns the groups linked.
    private func link(_ groups: [ShareLinkGroupModel], written: [ShareEntryID: WrittenRow]) throws -> Int {
        let config = ConfigStore(database: database)
        let destinations = DestinationStore(database: database)
        let folders = FolderStore(database: database)
        var linked = 0
        for group in groups {
            let rows = group.memberIDs.compactMap { written[$0] }
            guard rows.count >= 2 else { continue }
            let linkID = ItemLinkID()
            var configIDs: [ConfigItemID] = []
            var destinationIDs: [ConfigItemID] = []
            var folderIDs: [ConfigItemID] = []
            for row in rows {
                switch row {
                case .config(let id): configIDs.append(id)
                case .destination(let id): destinationIDs.append(id)
                case .folder(let id): folderIDs.append(id)
                }
            }
            try config.setLinkID(linkID, itemIDs: configIDs, in: tx)
            try destinations.setLinkID(linkID, itemIDs: destinationIDs, in: tx)
            try folders.setLinkID(linkID, itemIDs: folderIDs, in: tx)
            linked += 1
        }
        return linked
    }

    // MARK: - Values

    /// The incoming value normalized (D32). The caller wipes it.
    private func normalizedValue(of item: ShareItemModel) throws -> SecretBytes {
        guard let value = item.value else { throw SharingError.planOutdated }
        return try ValueNormalizer.normalize(value).value
    }
}
