import Foundation
import GitHubKit
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Sends an organization's local changes to GitHub (1.0, tasks/todo.md B6b), through the
/// account that imported it.
///
/// - **Review** lists B12/B13 and blocks what cannot be sent: an add GitHub already has, an item
///   GitHub changed since the vault read it (`updatedAt`), a secret write without its value.
/// - **Run** sends each write with its complete access: the edited list, or for an unchanged
///   `selected` item GitHub's own list read right before the write (B14/B15), so a write never
///   narrows who can use the item. Deletions run only when asked.
/// - **Confirm** re-lists once; a listed write becomes synced with GitHub's `updatedAt`.
/// - No journal: an interrupted run leaves the item pending, and the next review blocks it as
///   changed on GitHub until it is refreshed.
public actor OrganizationSyncRepository {
    private let session: VaultSession
    private let schedulers: any GHSchedulerProviding
    private let clock: any VaultClock
    /// Deletions Refresh must not report as added while GitHub still lists them (D28).
    private let deletions: OrgDeletionLog

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "organizations")

    public init(
        session: VaultSession,
        schedulers: any GHSchedulerProviding,
        clock: any VaultClock = SystemClock(),
        deletions: OrgDeletionLog
    ) {
        self.session = session
        self.schedulers = schedulers
        self.clock = clock
        self.deletions = deletions
    }

    private var store: OrganizationStore {
        OrganizationStore(database: session.database)
    }

    /// What GitHub lists for one item.
    private struct Listed {
        let updatedAt: Date?
        let numSelectedRepos: Int?
    }

    // MARK: - Review

    /// The pending changes of `organizationID`; empty when there are none (GitHub is not called).
    public func review(organizationID: OrganizationID) async -> OrgReviewModel {
        guard let (organization, pending) = try? loadPending(organizationID) else {
            return OrgReviewModel(organizationID: organizationID, login: "", changes: [], blocked: [])
        }
        guard !pending.isEmpty else {
            return OrgReviewModel(organizationID: organizationID, login: organization.login, changes: [], blocked: [])
        }
        let listed: [String: Listed]
        do throws(GHError) {
            listed = try await listing(organization)
        } catch {
            return OrgReviewModel(
                organizationID: organizationID,
                login: organization.login,
                changes: [],
                blocked: pending.map { OrgBlockedChangeModel(change: Self.change(for: $0), reason: .listingFailed(error)) }
            )
        }
        var changes: [OrgChangeModel] = []
        var blocked: [OrgBlockedChangeModel] = []
        for item in pending {
            let change = Self.change(for: item)
            if let reason = Self.blockReason(for: item, operation: change.operation, listed: listed[OrgItemKey.make(item.kind, item.name)]) {
                blocked.append(OrgBlockedChangeModel(change: change, reason: reason))
            } else {
                changes.append(change)
            }
        }
        changes.sort { ($0.operation == .delete ? 1 : 0, $0.name) < ($1.operation == .delete ? 1 : 0, $1.name) }
        return OrgReviewModel(organizationID: organizationID, login: organization.login, changes: changes, blocked: blocked)
    }

    private static func blockReason(for item: OrgItemRecord, operation: OrgChangeModel.Operation, listed: Listed?) -> OrgBlockReason? {
        switch operation {
        case .add:
            return listed == nil ? nil : .existsRemotely
        case .update:
            guard let listed, listed.updatedAt == item.remoteUpdatedAt else { return .remoteChanged }
            return item.kind == .secret && item.valueCiphertext == nil ? .valueMissing : nil
        case .delete:
            guard let listed else { return nil }
            return listed.updatedAt == item.remoteUpdatedAt ? nil : .remoteChanged
        }
    }

    // MARK: - Run

    /// Sends the review's changes; deletions only with `includeDeletions`.
    public func run(_ review: OrgReviewModel, includeDeletions: Bool) async -> OrgRunResultModel {
        var result = OrgRunResultModel()
        guard let organization = try? loadOrganization(review.organizationID) else {
            for change in review.changes { result.outcomes[change.itemID] = .skipped }
            return result
        }
        let scheduler: GHCommandScheduler
        do throws(GHError) {
            scheduler = try await schedulers.scheduler(for: organization.accountLogin)
        } catch {
            for change in review.changes { result.outcomes[change.itemID] = .failed(error) }
            return result
        }
        var sent: [ConfigItemID] = []
        for change in review.changes {
            guard includeDeletions || change.operation != .delete, !Task.isCancelled else {
                result.outcomes[change.itemID] = .skipped
                continue
            }
            let outcome = await execute(change, organization: organization, scheduler: scheduler)
            result.outcomes[change.itemID] = outcome
            if outcome == .done, change.operation != .delete {
                sent.append(change.itemID)
            }
        }
        if !sent.isEmpty {
            for (id, outcome) in await confirm(sent, organization: organization) {
                result.outcomes[id] = outcome
            }
        }
        Self.log.info("Organization sync: \(result.doneCount, privacy: .public) done, \(result.failedCount, privacy: .public) failed")
        return result
    }

    private func execute(_ change: OrgChangeModel, organization: OrganizationRecord, scheduler: GHCommandScheduler) async -> OrgChangeOutcome {
        guard let item = try? loadItem(change.itemID), Self.change(for: item) == change else { return .skipped }
        if change.operation == .delete {
            do throws(GHError) {
                switch item.kind {
                case .secret: try await scheduler.deleteOrganizationSecret(item.name, organization: organization.login)
                case .variable: try await scheduler.deleteOrganizationVariable(item.name, organization: organization.login)
                }
            } catch .notFound {
                // Already gone on GitHub.
            } catch {
                return .failed(error)
            }
            try? write { tx in try store.deleteItem(id: item.id, in: tx) }
            deletions.record(OrgItemKey.make(item.kind, item.name), organizationID: item.organizationID, at: clock.now)
            return .done
        }
        let access: GHOrgRepositoryAccess
        do throws(GHError) {
            guard let resolved = try await self.access(for: item, organization: organization, scheduler: scheduler) else {
                return .blocked(.noRepositories)
            }
            access = resolved
        } catch {
            return .failed(error)
        }
        guard let value = try? openValue(item) else { return .blocked(.valueMissing) }
        defer { value.wipe() }
        do throws(GHError) {
            switch item.kind {
            case .secret:
                try await scheduler.setOrganizationSecret(item.name, organization: organization.login, access: access, value: value)
            case .variable:
                try await scheduler.setOrganizationVariable(
                    item.name,
                    organization: organization.login,
                    access: access,
                    value: value,
                    isUpdate: change.operation == .update
                )
            }
        } catch {
            return .failed(error)
        }
        return .done
    }

    /// The complete access a write sends; nil for a `selected` item that reaches no repository.
    private func access(for item: OrgItemRecord, organization: OrganizationRecord, scheduler: GHCommandScheduler) async throws(GHError) -> GHOrgRepositoryAccess? {
        switch item.visibility {
        case .all: return .all
        case .private: return .private
        case .selected:
            let names: [String]
            if item.repositoriesEdited {
                names = (try? loadRepositories(item.id)) ?? []
            } else {
                names = switch item.kind {
                case .secret: try await scheduler.organizationSecretRepositories(item.name, organization: organization.login)
                case .variable: try await scheduler.organizationVariableRepositories(item.name, organization: organization.login)
                }
            }
            guard !names.isEmpty else { return nil }
            return .selected(try GHSelectedRepositories(names))
        }
    }

    /// Re-lists once: a listed write is synced with GitHub's `updatedAt` and repository count.
    private func confirm(_ ids: [ConfigItemID], organization: OrganizationRecord) async -> [ConfigItemID: OrgChangeOutcome] {
        let listed: [String: Listed]
        do throws(GHError) {
            listed = try await listing(organization)
        } catch {
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, OrgChangeOutcome.unconfirmed) })
        }
        var outcomes: [ConfigItemID: OrgChangeOutcome] = [:]
        for id in ids {
            guard var item = try? loadItem(id), let entry = listed[OrgItemKey.make(item.kind, item.name)] else {
                outcomes[id] = .unconfirmed
                continue
            }
            item.syncedVisibility = item.visibility
            item.syncedFingerprint = item.valueFingerprint
            item.repositoriesEdited = false
            item.remoteUpdatedAt = entry.updatedAt
            item.selectedCount = item.visibility == .selected ? entry.numSelectedRepos : nil
            item.updatedAt = clock.now
            let recorded = item
            do {
                try write { tx in
                    try store.replaceRepositories(itemID: id, names: [], in: tx)
                    try store.updateItem(recorded, in: tx)
                }
                outcomes[id] = .done
            } catch {
                outcomes[id] = .unconfirmed
            }
        }
        return outcomes
    }

    // MARK: - Support

    private func listing(_ organization: OrganizationRecord) async throws(GHError) -> [String: Listed] {
        let (secrets, variables) = try await OrganizationRepository.listItems(
            of: organization.login,
            accountLogin: organization.accountLogin,
            schedulers: schedulers
        )
        defer { variables.forEach { $0.wipe() } }
        var listed: [String: Listed] = [:]
        for secret in secrets {
            listed[OrgItemKey.make(.secret, secret.name)] = Listed(updatedAt: secret.updatedAt, numSelectedRepos: secret.numSelectedRepos)
        }
        for variable in variables {
            listed[OrgItemKey.make(.variable, variable.name)] = Listed(updatedAt: variable.updatedAt, numSelectedRepos: variable.numSelectedRepos)
        }
        return listed
    }

    private static func change(for item: OrgItemRecord) -> OrgChangeModel {
        let operation: OrgChangeModel.Operation = item.isDeleted ? .delete : (item.syncedVisibility == nil ? .add : .update)
        let visibility = operation == .delete ? (item.syncedVisibility ?? item.visibility) : item.visibility
        return OrgChangeModel(itemID: item.id, name: item.name, kind: item.kind, operation: operation, visibility: visibility)
    }

    private func loadOrganization(_ id: OrganizationID) throws -> OrganizationRecord? {
        try session.database.read { tx in try store.fetchOrganization(id: id, in: tx) }
    }

    private func loadPending(_ id: OrganizationID) throws -> (OrganizationRecord, [OrgItemRecord])? {
        try session.database.read { tx in
            guard let organization = try store.fetchOrganization(id: id, in: tx) else { return nil }
            let pending = try store.fetchItemRecords(organizationID: id, in: tx).filter { $0.syncStatus != .synced }
            return (organization, pending)
        }
    }

    private func loadItem(_ id: ConfigItemID) throws -> OrgItemRecord? {
        try session.database.read { tx in try store.fetchItemRecord(id: id, in: tx) }
    }

    private func loadRepositories(_ id: ConfigItemID) throws -> [String] {
        try session.database.read { tx in try store.fetchRepositories(itemID: id, in: tx) }
    }

    private func openValue(_ item: OrgItemRecord) throws -> SecretBytes? {
        try session.read { keys, _ in try OrgFieldCipher.openValue(of: item, keys: keys) }
    }

    private func write(_ body: (StoreTransaction) throws -> Void) throws {
        try session.database.write { tx in try body(tx) }
    }
}
