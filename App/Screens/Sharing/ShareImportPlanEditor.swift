import Foundation
import Observation
import SharingKit
import VaultCore

/// The user's choices on a share import preview (§9.5), shared by the file import and the
/// nearby receiver: per-item actions (defaults from `ShareImportPlanner`: "Keep mine" for items
/// that differ), "Overwrite all", the "Deployment branches differ" rows (a widening policy needs
/// a second confirmation) and the replay confirmation.
///
/// Holds only the plan (names, chips, actions); values never reach the UI.
@Observable
final class ShareImportPlanEditor {
    /// One choice the user made, for a project share's editor that keeps its own copy of the
    /// plan (v0.9.0).
    enum Change: Equatable {
        case select(ShareItemAction, item: ShareEntryID)
        case policy(SharePolicyDecision, environment: ShareEntryID, wideningConfirmed: Bool)
    }

    private(set) var plan: ShareImportPlanModel
    /// Called after each choice was applied to ``plan``.
    @ObservationIgnored var onChange: ((Change) -> Void)?
    /// "Import anyway" for the replay warnings.
    var confirmsReplay = false
    /// The environment whose widening policy waits for the second confirmation.
    private(set) var pendingWideningEnvironment: ShareEntryID?
    /// Who sent the package (unverified) and from which repository.
    let senderName: String?
    let repositoryFullName: String

    init(plan: ShareImportPlanModel, repositoryFullName: String) {
        self.plan = plan
        self.repositoryFullName = repositoryFullName
        senderName = plan.origin.senderName
    }

    // MARK: - Items

    func select(_ action: ShareItemAction, for item: ShareItemPlanModel) {
        do {
            try plan.select(action, forItem: item.id)
            onChange?(.select(action, item: item.id))
        } catch {
            // The picker offers only allowed actions.
        }
    }

    /// True when at least one item differs from the local value (payload previews only).
    var hasDifferingItems: Bool {
        plan.allItems.contains { $0.chip == .differs }
    }

    /// True when every differing item is already set to overwrite.
    var isOverwritingAll: Bool {
        let differing = plan.allItems.filter { $0.chip == .differs }
        return !differing.isEmpty && differing.allSatisfy { $0.action == .overwrite }
    }

    /// "Overwrite all": every item that differs is overwritten.
    func overwriteAll() {
        let differing = plan.allItems.filter { $0.chip == .differs }.map(\.id)
        plan.overwriteAll()
        for id in differing {
            onChange?(.select(.overwrite, item: id))
        }
    }

    // MARK: - Policies

    /// Chooses the policy of a differing environment. Accepting a widening policy (more refs
    /// may deploy) first asks for the second confirmation (``confirmWidening()``).
    func choosePolicy(_ decision: SharePolicyDecision, for environment: ShareEnvironmentPlanModel) {
        guard let difference = environment.policyDifference else { return }
        if decision == .useIncoming, difference.isWidening {
            pendingWideningEnvironment = environment.id
            return
        }
        setPolicy(decision, environment: environment.id, wideningConfirmed: false)
    }

    /// The second confirmation of a widening policy.
    func confirmWidening() {
        guard let id = pendingWideningEnvironment else { return }
        pendingWideningEnvironment = nil
        setPolicy(.useIncoming, environment: id, wideningConfirmed: true)
    }

    private func setPolicy(_ decision: SharePolicyDecision, environment id: ShareEntryID, wideningConfirmed: Bool) {
        do {
            try plan.setPolicyDecision(decision, forEnvironment: id, wideningConfirmed: wideningConfirmed)
            onChange?(.policy(decision, environment: id, wideningConfirmed: wideningConfirmed))
        } catch {
            // Only differing environments offer a choice.
        }
    }

    func cancelWidening() {
        pendingWideningEnvironment = nil
    }

    /// The environment waiting for the widening confirmation.
    var pendingWidening: ShareEnvironmentPlanModel? {
        plan.environments.first { $0.id == pendingWideningEnvironment }
    }

    /// Carries the policy choices of an earlier (manifest) preview into this one: the nearby
    /// receiver confirms them before accepting, and the payload plan starts from the defaults.
    func adoptPolicyDecisions(from earlier: ShareImportPlanModel) {
        for environment in earlier.environments {
            guard let decision = environment.policyDifference?.decision, decision == .useIncoming,
                  let match = plan.environments.first(where: { $0.name == environment.name })
            else { continue }
            try? plan.setPolicyDecision(decision, forEnvironment: match.id, wideningConfirmed: true)
        }
    }

    // MARK: - Apply

    var blockReason: ShareImportBlockReason? {
        plan.blockReason
    }

    var canApply: Bool {
        plan.blockReason == nil && (!plan.requiresReplayConfirmation || confirmsReplay)
            && pendingWideningEnvironment == nil
    }

    /// Items whose selected action changes the vault.
    var changedCount: Int {
        plan.changedItems.count
    }

    /// Pending changes the import creates (nothing syncs automatically).
    var pendingChangeCount: Int {
        plan.pendingChangeCount
    }

    /// Repository-level items first, then each environment's (a section per scope).
    var sections: [ShareImportSectionModel] {
        var sections: [ShareImportSectionModel] = []
        if !plan.repositoryItems.isEmpty {
            sections.append(ShareImportSectionModel(environment: nil, items: plan.repositoryItems))
        }
        for environment in plan.environments {
            sections.append(ShareImportSectionModel(environment: environment, items: environment.items))
        }
        return sections
    }
}

/// One scope of the import preview: repository level (`environment` nil) or one environment.
struct ShareImportSectionModel: Identifiable {
    let environment: ShareEnvironmentPlanModel?
    let items: [ShareItemPlanModel]

    var id: String {
        environment.map { $0.id.description } ?? Self.repositoryID
    }

    /// Incoming secrets and variables in this scope (names only).
    var counts: ShareItemCountModel {
        ShareItemCountModel(
            secrets: items.filter { $0.key.kind == .secret }.count,
            variables: items.filter { $0.key.kind == .variable }.count
        )
    }

    private static let repositoryID = "repository"
}
