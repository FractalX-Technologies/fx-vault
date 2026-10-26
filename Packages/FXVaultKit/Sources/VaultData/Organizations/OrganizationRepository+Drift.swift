import Foundation
import GitHubKit
import os
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Refresh (1.0, tasks/todo.md B7b): B12/B13 again through the importing account, compared
/// with the vault, and Keep Local or Accept GitHub for each difference, as a repository's drift
/// review (§7.7). Findings are not stored: the organization view keeps the last Refresh.
extension OrganizationRepository {
    /// One listed item the vault can hold.
    struct ListedItem {
        let kind: ConfigKind
        let name: String
        let visibility: OrgVisibility
        /// Only for `selected`.
        let selectedCount: Int?
        let updatedAt: Date?
        /// A variable's value, wiped with its ``Listing``.
        let value: SecretBytes?
    }

    struct Listing {
        let items: [String: ListedItem]
        let skipped: [SkippedRemoteNameModel]
        let variables: [GHVariableListingModel]

        func wipe() {
            variables.forEach { $0.wipe() }
        }
    }

    // MARK: - Refresh

    /// Lists the organization and reports how it differs from the vault. A deletion GitHub no
    /// longer has is finished here. Needs no keys.
    ///
    /// - Throws: `.organizationNotFound`, `.github` when a list fails or a row has no visibility.
    public func refresh(organizationID: OrganizationID) async throws(RepoCatalogError) -> OrgRefreshModel {
        guard var organization = try perform({
            try session.database.read { tx in try store.fetchOrganization(id: organizationID, in: tx) }
        }) else {
            throw .organizationNotFound
        }
        let listing = try await list(organization)
        defer { listing.wipe() }
        let now = clock.now
        organization.lastRefreshedAt = now
        let refreshed = organization
        let store = store
        let rows = try perform {
            try session.database.write { tx in
                let rows = try store.fetchItemRecords(organizationID: organizationID, in: tx)
                let gone = Set(rows.filter { $0.isDeleted && listing.items[OrgItemKey.make($0.kind, $0.name)] == nil }.map(\.id))
                for id in gone {
                    try store.deleteItem(id: id, in: tx)
                }
                try store.updateOrganization(refreshed, in: tx)
                return rows.filter { !gone.contains($0.id) }
            }
        }
        let findings = Self.findings(organizationID: organizationID, rows: rows, listed: listing.items)
        Self.log.info("Refreshed an organization: \(findings.count, privacy: .public) differences")
        return OrgRefreshModel(organizationID: organizationID, findings: findings, skippedNames: listing.skipped, listedAt: now)
    }

    /// How the vault's rows differ from GitHub's listing, by name then kind.
    static func findings(organizationID: OrganizationID, rows: [OrgItemRecord], listed: [String: ListedItem]) -> [OrgDriftModel] {
        let rowsByKey = Dictionary(rows.map { (OrgItemKey.make($0.kind, $0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var findings: [OrgDriftModel] = []
        for (key, item) in listed {
            let row = rowsByKey[key]
            if row == nil || row?.syncedVisibility == nil {
                findings.append(finding(.remoteAdded, organizationID: organizationID, item: item, row: row))
            } else if let row, differs(row, item) {
                findings.append(finding(row.kind == .secret ? .secretModified : .variableModified, organizationID: organizationID, item: item, row: row))
            }
        }
        for row in rows where row.syncedVisibility != nil && !row.isDeleted && listed[OrgItemKey.make(row.kind, row.name)] == nil {
            findings.append(finding(.remoteDeleted, organizationID: organizationID, item: nil, row: row))
        }
        return findings.sorted { ($0.name, $0.itemKind.rawValue) < ($1.name, $1.itemKind.rawValue) }
    }

    /// GitHub's date or visibility moved since the vault read it, or how many repositories a
    /// `selected` item reaches while the vault keeps GitHub's own list: the count catches a
    /// list change that leaves `updatedAt` alone. A count Revert forgot is unknown, not changed.
    static func differs(_ row: OrgItemRecord, _ item: ListedItem) -> Bool {
        guard item.updatedAt == row.remoteUpdatedAt, item.visibility == row.syncedVisibility else { return true }
        guard item.visibility == .selected, row.visibility == .selected, !row.repositoriesEdited, let count = row.selectedCount else {
            return false
        }
        return item.selectedCount != count
    }

    private static func finding(_ kind: DriftKind, organizationID: OrganizationID, item: ListedItem?, row: OrgItemRecord?) -> OrgDriftModel {
        // Keep Local writes the item again, which needs its value, unless the vault deletes it.
        let canKeepLocal = kind == .remoteAdded || row?.isDeleted == true || row?.valueCiphertext != nil
        return OrgDriftModel(
            organizationID: organizationID,
            kind: kind,
            itemKind: row?.kind ?? item?.kind ?? .secret,
            name: row?.name ?? item?.name ?? "",
            itemID: row?.id,
            remoteUpdatedAt: item?.updatedAt,
            isConflict: row.map { $0.syncStatus != .synced } ?? false,
            canKeepLocal: canKeepLocal
        )
    }

    // MARK: - Resolve

    /// Applies one choice to findings of one organization (§7.7 table). GitHub is listed again
    /// first; a finding that no longer holds throws `.stale` and nothing is written.
    ///
    /// - Throws: `.resolutionUnavailable(.valueMissing)`, `.stale`, `.github`, `.vault(.locked)`.
    public func resolve(
        _ findings: [OrgDriftModel],
        option: DriftResolutionOption,
        organizationID: OrganizationID
    ) async throws(DriftRepositoryError) {
        guard !findings.isEmpty else { return }
        if option == .keepLocal, findings.contains(where: { !$0.canKeepLocal }) {
            throw .resolutionUnavailable(.valueMissing)
        }
        guard !session.isLocked else { throw .vault(.locked) }
        let listing: Listing
        do throws(RepoCatalogError) {
            guard let organization = try perform({
                try session.database.read { tx in try store.fetchOrganization(id: organizationID, in: tx) }
            }) else {
                throw .organizationNotFound
            }
            listing = try await list(organization)
        } catch {
            throw Self.driftError(error)
        }
        defer { listing.wipe() }
        let now = clock.now
        let store = store
        do {
            try session.write { keys, tx in
                let rows = try store.fetchItemRecords(organizationID: organizationID, in: tx)
                let current = Dictionary(
                    Self.findings(organizationID: organizationID, rows: rows, listed: listing.items).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for finding in findings {
                    guard finding.organizationID == organizationID, let held = current[finding.id], held.itemID == finding.itemID else {
                        throw DriftRepositoryError.stale
                    }
                    if option == .keepLocal, !held.canKeepLocal {
                        throw DriftRepositoryError.resolutionUnavailable(.valueMissing)
                    }
                    try Self.apply(
                        held,
                        option: option,
                        listed: listing.items[OrgItemKey.make(held.itemKind, held.name)],
                        keys: keys,
                        tx: tx,
                        store: store,
                        now: now
                    )
                }
            }
        } catch {
            throw DriftRepositoryError.wrap(error)
        }
        Self.log.info("Resolved \(findings.count, privacy: .public) organization differences")
    }

    private static func apply(
        _ finding: OrgDriftModel,
        option: DriftResolutionOption,
        listed: ListedItem?,
        keys: borrowing UnlockedKeys,
        tx: StoreTransaction,
        store: OrganizationStore,
        now: Date
    ) throws {
        let existing = try finding.itemID.flatMap { id in try store.fetchItemRecord(id: id, in: tx) }
        if finding.kind == .remoteDeleted {
            guard var row = existing else { throw DriftRepositoryError.stale }
            if option == .acceptGitHub {
                try store.deleteItem(id: row.id, in: tx)
                return
            }
            // Keep Local: an add again, which the next Sync creates.
            row.syncedVisibility = nil
            row.syncedFingerprint = nil
            row.remoteUpdatedAt = nil
            row.updatedAt = now
            try store.updateItem(row, in: tx)
            return
        }
        guard let listed else { throw DriftRepositoryError.stale }
        guard var row = existing else {
            // Only GitHub has it. Keep Local stores it as a deletion, which the next Sync sends.
            var row = item(
                organizationID: finding.organizationID,
                kind: listed.kind,
                name: listed.name,
                visibility: listed.visibility,
                selectedCount: listed.selectedCount,
                remoteUpdatedAt: listed.updatedAt,
                now: now
            )
            try take(listed, into: &row, keys: keys)
            row.isDeleted = option == .keepLocal
            try store.insertItem(row, in: tx)
            return
        }
        if option == .acceptGitHub {
            try take(listed, into: &row, keys: keys)
            try store.replaceRepositories(itemID: row.id, names: [], in: tx)
        } else {
            adopt(listed, into: &row, keys: keys)
        }
        row.updatedAt = now
        try store.updateItem(row, in: tx)
    }

    /// Accept GitHub: the row becomes GitHub's item. A secret loses its value here: GitHub never
    /// returns one, so the vault's may no longer be GitHub's.
    private static func take(_ listed: ListedItem, into row: inout OrgItemRecord, keys: borrowing UnlockedKeys) throws {
        row.visibility = listed.visibility
        row.syncedVisibility = listed.visibility
        row.selectedCount = listed.selectedCount
        row.remoteUpdatedAt = listed.updatedAt
        row.repositoriesEdited = false
        row.isDeleted = false
        if let value = listed.value {
            try OrgFieldCipher.setValue(value, on: &row, keys: keys)
            row.syncedFingerprint = row.valueFingerprint
        } else {
            row.valueCiphertext = nil
            row.valueFingerprint = nil
            row.syncedFingerprint = nil
        }
    }

    /// Keep Local: what GitHub has now becomes the synced state, so the vault's item is pending
    /// over it; the next Sync's review no longer blocks it as changed on GitHub.
    private static func adopt(_ listed: ListedItem, into row: inout OrgItemRecord, keys: borrowing UnlockedKeys) {
        row.syncedVisibility = listed.visibility
        row.remoteUpdatedAt = listed.updatedAt
        // A secret's value on GitHub is unknown, so the vault's is sent.
        row.syncedFingerprint = listed.value.map { keys.fingerprint($0, rowID: row.id) }
        if row.visibility == .selected, listed.visibility == .selected, !row.repositoriesEdited {
            row.selectedCount = listed.selectedCount
        }
    }

    // MARK: - Listing

    func list(_ organization: OrganizationRecord) async throws(RepoCatalogError) -> Listing {
        let secrets: [GHSecretDTO]
        let variables: [GHVariableListingModel]
        do throws(GHError) {
            (secrets, variables) = try await Self.listItems(
                of: organization.login,
                accountLogin: organization.accountLogin,
                schedulers: schedulers
            )
        } catch {
            throw .github(error)
        }
        var skipped: [SkippedRemoteNameModel] = []
        var items: [String: ListedItem] = [:]
        do throws(RepoCatalogError) {
            for (name, visibility, secret) in try Self.storable(secrets, kind: .secret, name: \.name, visibility: \.visibility, skipped: &skipped) {
                items[OrgItemKey.make(.secret, name)] = ListedItem(
                    kind: .secret,
                    name: name,
                    visibility: visibility,
                    selectedCount: visibility == .selected ? secret.numSelectedRepos : nil,
                    updatedAt: secret.updatedAt,
                    value: nil
                )
            }
            for (name, visibility, variable) in try Self.storable(variables, kind: .variable, name: \.name, visibility: \.visibility, skipped: &skipped) {
                items[OrgItemKey.make(.variable, name)] = ListedItem(
                    kind: .variable,
                    name: name,
                    visibility: visibility,
                    selectedCount: visibility == .selected ? variable.numSelectedRepos : nil,
                    updatedAt: variable.updatedAt,
                    value: variable.value
                )
            }
        } catch {
            variables.forEach { $0.wipe() }
            throw error
        }
        return Listing(items: items, skipped: skipped, variables: variables)
    }

    private static func driftError(_ error: RepoCatalogError) -> DriftRepositoryError {
        switch error {
        case .github(let error): .github(error)
        case .store(let error): .store(error)
        case .vault(let error): .vault(error)
        case .organizationNotFound: .stale
        default: .unexpected
        }
    }
}
