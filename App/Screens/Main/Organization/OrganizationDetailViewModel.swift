import Foundation
import Observation
import VaultCore
import VaultData

/// Column 3 for an imported organization (1.0, B5c, B6b3a, B7b): its name and counts and the
/// table of its secrets and variables with their visibility and sync status. Add, edit, delete
/// and revert change the vault; the next Sync sends them. Refresh marks what changed on GitHub.
@Observable
final class OrganizationDetailViewModel {
    let organizationID: OrganizationID
    private(set) var items: [OrgItemModel] = []
    var selection: Set<ConfigItemID> = []
    /// Rows on GitHub waiting for the Delete confirmation.
    var pendingDeletion: [OrgItemModel]?
    var alert: ErrorPresentationModel?
    /// The last Refresh (B7b), kept while this organization is open; nil before the first.
    private(set) var refresh: OrgRefreshModel?
    private(set) var isRefreshing = false

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let organizationProvider: () -> OrganizationModel?
    @ObservationIgnored private let repositoryNames: () -> [String]
    @ObservationIgnored private let tasks = TaskBag()

    /// - Parameters:
    ///   - organization: the live vault row (its counts follow the sidebar).
    ///   - repositoryNames: the organization's repositories the sidebar lists (Selected access).
    init(
        organizationID: OrganizationID,
        dependencies: FeatureDependencies,
        organization: @escaping () -> OrganizationModel?,
        repositoryNames: @escaping () -> [String]
    ) {
        self.organizationID = organizationID
        self.dependencies = dependencies
        organizationProvider = organization
        self.repositoryNames = repositoryNames
        observeItems(dependencies.organizations)
    }

    var organization: OrganizationModel? {
        organizationProvider()
    }

    /// Secrets first, then variables, each by name (mockup Org-Visibility).
    var rows: [OrgItemModel] {
        items.sorted { ($0.kind == .secret ? 0 : 1, $0.name) < ($1.kind == .secret ? 0 : 1, $1.name) }
    }

    /// "Organization · 14 secrets · 6 variables · 3 without value" (board Org-Visibility): as a
    /// repository's, pending deletions are left out and "without value" counts secrets only.
    var subline: String {
        let live = items.filter { $0.syncStatus != .deleted }
        return PlaceCopy.subline([
            PlaceCopy.organization,
            PlaceCopy.counts(
                secrets: live.lazy.filter { $0.kind == .secret }.count,
                variables: live.lazy.filter { $0.kind == .variable }.count,
                withoutValue: live.lazy.filter { $0.kind == .secret && !$0.hasValue }.count
            ),
        ])
    }

    // MARK: - Changes

    func add(_ kind: ConfigKind) {
        present(.add(kind))
    }

    func edit(_ row: OrgItemModel) {
        guard row.syncStatus != .deleted else { return }
        present(.edit(row.id))
    }

    private func present(_ mode: OrgItemEditorContext.Mode) {
        dependencies.actions.present(.orgItemEditor(OrgItemEditorContext(
            organizationID: organizationID,
            mode: mode,
            repositoryCandidates: repositoryNames()
        )))
    }

    func rows(for ids: Set<ConfigItemID>) -> [OrgItemModel] {
        rows.filter { ids.contains($0.id) }
    }

    /// Rows on GitHub need the confirmation (the next Sync deletes them there after its review);
    /// rows never synced are removed at once.
    func requestDeletion(of rows: [OrgItemModel]) {
        let deletable = rows.filter { $0.syncStatus != .deleted }
        guard !deletable.isEmpty else { return }
        if deletable.contains(where: \.isOnGitHub) {
            pendingDeletion = deletable
        } else {
            delete(deletable)
        }
    }

    /// The "Delete?" sheet of ``pendingDeletion``.
    var deletionSheet: DeleteItemsSheetModel? {
        pendingDeletion.map {
            DeleteItemsSheetModel(entries: $0.map(DeleteItemsSheetModel.Entry.init), place: organization?.login ?? "", target: .gitHub)
        }
    }

    func confirmDeletion() {
        guard let rows = pendingDeletion else { return }
        pendingDeletion = nil
        delete(rows)
    }

    private func delete(_ rows: [OrgItemModel]) {
        do {
            try dependencies.organizationItems.deleteItems(rows.map(\.id))
            selection.subtract(rows.map(\.id))
        } catch {
            alert = error.presentation
        }
    }

    /// Undoes adds, deletions and access changes; a changed value stays.
    func revert(_ rows: [OrgItemModel]) {
        let revertible = rows.filter(\.canRevert)
        guard !revertible.isEmpty else { return }
        do {
            try dependencies.organizationItems.revertItems(revertible.map(\.id))
        } catch {
            alert = error.presentation
        }
    }

    /// Copy All (1.0 D6c4) needs a live item; the sheet asks for Touch ID or the password first.
    var canCopyAll: Bool {
        items.contains { $0.syncStatus != .deleted }
    }

    func copyAll() {
        dependencies.actions.present(.copyAll(CopyAllContext(place: .organization(organizationID))))
    }

    func copy(_ row: OrgItemModel) {
        do {
            try dependencies.copyOrganizationValue(of: row.id)
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Refresh (B7b)

    /// Lists the organization again and marks what changed on GitHub.
    func refreshNow() {
        guard !isRefreshing else { return }
        guard dependencies.connectivity.isOnline else {
            alert = ErrorPresentationModel(title: OrganizationCopy.refreshFailedTitle, message: ConnectivityCopy.offlineHelp)
            return
        }
        isRefreshing = true
        let organizations = dependencies.organizations
        let id = organizationID
        tasks.set("refresh", Task { [weak self] in
            do throws(RepoCatalogError) {
                let result = try await organizations.refresh(organizationID: id)
                self?.refresh = result
                self?.dependencies.gitHubReachability.recordSuccess()
            } catch {
                self?.dependencies.gitHubReachability.record(error)
                self?.alert = error.presentation
            }
            self?.isRefreshing = false
        })
    }

    var findings: [OrgDriftModel] {
        refresh?.findings ?? []
    }

    func isChangedOnGitHub(_ row: OrgItemModel) -> Bool {
        refresh?.changedItemIDs.contains(row.id) == true
    }

    /// Review: Keep Local or Accept GitHub for each finding.
    func reviewChanges() {
        guard let refresh, !refresh.findings.isEmpty else { return }
        dependencies.actions.present(.orgDrift(OrgDriftContext(
            organizationID: organizationID,
            findings: refresh.findings,
            skippedNames: refresh.skippedNames.map(\.name)
        )))
    }

    /// Findings resolved in the review drop their marks until the next Refresh.
    func didResolve(_ ids: Set<String>) {
        guard let refresh else { return }
        self.refresh = OrgRefreshModel(
            organizationID: refresh.organizationID,
            findings: refresh.findings.filter { !ids.contains($0.id) },
            skippedNames: refresh.skippedNames,
            listedAt: refresh.listedAt
        )
    }

    private func observeItems(_ organizations: OrganizationRepository) {
        let stream = organizations.observeItems(of: organizationID)
        tasks.set("items", Task { [weak self] in
            do {
                for try await items in stream {
                    self?.items = items
                }
            } catch {
                AppLog.ui.error("Organization item observation ended")
            }
        })
    }
}

extension OrgItemModel {
    /// False for an add the next Sync creates: deleting it removes it at once.
    var isOnGitHub: Bool {
        syncStatus != .added
    }

    /// An add, a deletion or an access change; a changed value alone cannot be reverted.
    var canRevert: Bool {
        syncStatus == .added || syncStatus == .deleted || isAccessChanged
    }
}
