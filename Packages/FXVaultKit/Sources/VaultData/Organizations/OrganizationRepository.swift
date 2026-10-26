import Foundation
import GitHubKit
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Organizations in the vault (1.0, tasks/todo.md B5): an organization's own secrets and
/// variables, read with B12/B13 through an account that has `admin:org` and the admin role (B4).
///
/// - **Import** (``importOrganization(login:accountLogin:)``): B12 and B13 stored in one
///   transaction. Secrets are value-missing with `remote_updated_at`; variables are sealed with
///   `OrgFieldAAD` and `synced_fp` equal to their fingerprint, stored exactly as listed (D32).
///   Each item keeps its visibility and, for `selected`, how many repositories it reaches.
///   Names the vault cannot hold (D29) are skipped and reported.
/// - Errors reuse ``RepoCatalogError``: an organization is imported like a repository.
/// - Observation streams need no keys and work while locked.
public actor OrganizationRepository {
    private let session: VaultSession
    private let schedulers: any GHSchedulerProviding
    private let clock: any VaultClock

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "organizations")

    public init(session: VaultSession, schedulers: any GHSchedulerProviding, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.schedulers = schedulers
        self.clock = clock
    }

    private var store: OrganizationStore {
        OrganizationStore(database: session.database)
    }

    // MARK: - Organizations

    /// Reads the organization's secrets and variables and stores them.
    ///
    /// - Throws: `.organizationAlreadyImported` when it is in the vault, `.github` when a list
    ///   fails or a row has no visibility (`.malformedOutput`), `.vault(.locked)`.
    public func importOrganization(login: String, accountLogin: String) async throws(RepoCatalogError) -> OrgImportResultModel {
        if let existing = try perform({ try store.fetchOrganization(login: login) }) {
            throw .organizationAlreadyImported(existing.id)
        }
        let scheduler: GHCommandScheduler
        let listedSecrets: [GHSecretDTO]
        let listedVariables: [GHVariableListingModel]
        do {
            scheduler = try await schedulers.scheduler(for: accountLogin)
            listedSecrets = try await scheduler.listOrganizationSecrets(login)
            listedVariables = try await scheduler.listOrganizationVariables(login)
        } catch {
            throw .github(error)
        }
        defer { listedVariables.forEach { $0.wipe() } }

        var skipped: [SkippedRemoteNameModel] = []
        let secrets = try Self.storable(listedSecrets, kind: .secret, name: \.name, visibility: \.visibility, skipped: &skipped)
        let variables = try Self.storable(listedVariables, kind: .variable, name: \.name, visibility: \.visibility, skipped: &skipped)

        let now = clock.now
        let organization = OrganizationRecord(login: login, accountLogin: accountLogin, lastRefreshedAt: now, createdAt: now, updatedAt: now)
        try perform {
            try session.write { keys, tx in
                try store.insertOrganization(organization, in: tx)
                for (name, visibility, secret) in secrets {
                    try store.insertItem(Self.item(
                        organizationID: organization.id,
                        kind: .secret,
                        name: name,
                        visibility: visibility,
                        selectedCount: secret.numSelectedRepos,
                        remoteUpdatedAt: secret.updatedAt,
                        now: now
                    ), in: tx)
                }
                for (name, visibility, variable) in variables {
                    var item = Self.item(
                        organizationID: organization.id,
                        kind: .variable,
                        name: name,
                        visibility: visibility,
                        selectedCount: variable.numSelectedRepos,
                        remoteUpdatedAt: variable.updatedAt,
                        now: now
                    )
                    try OrgFieldCipher.setValue(variable.value, on: &item, keys: keys)
                    item.syncedFingerprint = item.valueFingerprint
                    try store.insertItem(item, in: tx)
                }
            }
        }
        let result = OrgImportResultModel(
            organization: organization.model(secretCount: secrets.count, variableCount: variables.count),
            skippedNames: skipped
        )
        Self.log.info(
            """
            Imported an organization: \(secrets.count, privacy: .public) secrets, \
            \(variables.count, privacy: .public) variables, \(skipped.count, privacy: .public) skipped names
            """
        )
        return result
    }

    /// Every organization by login, with its counts.
    public func organizations() throws(RepoCatalogError) -> [OrganizationModel] {
        try perform { try store.fetchOrganizations() }
    }

    /// The organizations with their counts, now and after each change (the sidebar).
    public nonisolated func observeOrganizations() -> AsyncThrowingStream<[OrganizationModel], any Error> {
        OrganizationStore(database: session.database).observeOrganizations()
    }

    /// Removes an organization and its items from the vault; GitHub is not touched.
    public func removeOrganization(_ id: OrganizationID) throws(RepoCatalogError) {
        guard try perform({ try store.deleteOrganization(id: id) }) else { throw .organizationNotFound }
        Self.log.info("Removed an organization")
    }

    // MARK: - Items

    /// The items of one organization, by name.
    public func items(of id: OrganizationID) throws(RepoCatalogError) -> [OrgItemModel] {
        try perform { try store.fetchItems(organizationID: id) }
    }

    /// The items of one organization, now and after each change.
    public nonisolated func observeItems(of id: OrganizationID) -> AsyncThrowingStream<[OrgItemModel], any Error> {
        OrganizationStore(database: session.database).observeItems(organizationID: id)
    }

    // MARK: - Inherited (B7a)

    /// What a repository owned by `ownerLogin` gets from that organization; nil while the
    /// organization is not in the vault (a person's repository, or one not imported).
    public func inheritedItems(ownerLogin: String, repositoryName: String, isPrivate: Bool) throws(RepoCatalogError) -> InheritedOrgItemsModel? {
        try perform { try store.fetchInheritedItems(ownerLogin: ownerLogin, repositoryName: repositoryName, isPrivate: isPrivate) }
    }

    /// ``inheritedItems(ownerLogin:repositoryName:isPrivate:)`` now and after each change.
    public nonisolated func observeInheritedItems(
        ownerLogin: String,
        repositoryName: String,
        isPrivate: Bool
    ) -> AsyncThrowingStream<InheritedOrgItemsModel?, any Error> {
        OrganizationStore(database: session.database).observeInheritedItems(ownerLogin: ownerLogin, repositoryName: repositoryName, isPrivate: isPrivate)
    }

    // MARK: - Support

    /// The listed rows the vault can hold, by validated name; the first of a repeated name wins.
    /// An organization listing always carries the visibility (B12/B13 ask for it), so a row
    /// without one means gh's output changed: fail rather than guess who can read the item.
    private static func storable<Listing>(
        _ listed: [Listing],
        kind: ConfigKind,
        name: KeyPath<Listing, String>,
        visibility: KeyPath<Listing, OrgVisibility?>,
        skipped: inout [SkippedRemoteNameModel]
    ) throws(RepoCatalogError) -> [(name: String, visibility: OrgVisibility, listing: Listing)] {
        var seen: Set<String> = []
        var result: [(name: String, visibility: OrgVisibility, listing: Listing)] = []
        for listing in listed {
            guard let valid = try? GitHubNameValidator.validate(listing[keyPath: name]), seen.insert(valid).inserted else {
                skipped.append(SkippedRemoteNameModel(kind: .item(kind), environment: nil, name: listing[keyPath: name]))
                continue
            }
            guard let itemVisibility = listing[keyPath: visibility] else { throw .github(.malformedOutput) }
            result.append((valid, itemVisibility, listing))
        }
        return result
    }

    private static func item(
        organizationID: OrganizationID,
        kind: ConfigKind,
        name: String,
        visibility: OrgVisibility,
        selectedCount: Int?,
        remoteUpdatedAt: Date?,
        now: Date
    ) -> OrgItemRecord {
        OrgItemRecord(
            organizationID: organizationID,
            kind: kind,
            name: name,
            visibility: visibility,
            selectedCount: visibility == .selected ? selectedCount : nil,
            remoteUpdatedAt: remoteUpdatedAt,
            syncedVisibility: visibility,
            createdAt: now,
            updatedAt: now
        )
    }

    private func perform<Result>(_ body: () throws -> Result) throws(RepoCatalogError) -> Result {
        try RepoCatalogError.perform(body)
    }
}
