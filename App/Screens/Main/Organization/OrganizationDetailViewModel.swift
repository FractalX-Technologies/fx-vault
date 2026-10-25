import Foundation
import Observation
import VaultCore
import VaultData

/// Column 3 for an imported organization (1.0, tasks/todo.md B5c): its name and counts and a
/// read-only table of its secrets and variables with their visibility. Values are never shown:
/// writes and Reveal come with B6.
@Observable
final class OrganizationDetailViewModel {
    let organizationID: OrganizationID
    private(set) var items: [OrgItemModel] = []

    @ObservationIgnored private let organizationProvider: () -> OrganizationModel?
    @ObservationIgnored private let tasks = TaskBag()

    /// - Parameter organization: the live vault row (its counts follow the sidebar).
    init(organizationID: OrganizationID, dependencies: FeatureDependencies, organization: @escaping () -> OrganizationModel?) {
        self.organizationID = organizationID
        organizationProvider = organization
        observeItems(dependencies.organizations)
    }

    var organization: OrganizationModel? {
        organizationProvider()
    }

    /// Secrets first, then variables, each by name (mockup Org-Visibility).
    var rows: [OrgItemModel] {
        items.sorted { ($0.kind == .secret ? 0 : 1, $0.name) < ($1.kind == .secret ? 0 : 1, $1.name) }
    }

    var counts: String {
        OrganizationCopy.counts(
            secrets: items.lazy.filter { $0.kind == .secret }.count,
            variables: items.lazy.filter { $0.kind == .variable }.count,
            withoutValue: items.lazy.filter { !$0.hasValue }.count
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
