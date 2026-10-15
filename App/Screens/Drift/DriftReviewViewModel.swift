import Foundation
import Observation
import SyncEngine
import VaultCore
import VaultData

/// One resolution button of a finding (§7.7 table).
struct DriftChoiceModel: Hashable {
    let option: DriftResolutionOption
    let title: String
    let explanation: String
    /// Why the choice cannot be made, or nil when it can.
    let unavailableReason: String?
    /// Deletes local data: asks first.
    let needsConfirmation: Bool

    var isAvailable: Bool {
        unavailableReason == nil
    }
}

/// One finding as the review lists it.
struct DriftFindingRowModel: Identifiable, Hashable {
    let id: String
    /// "Secret API_TOKEN was changed on GitHub on Oct 12".
    let title: String
    /// "Repository", the environment name, or "Environment".
    let scope: String
    let systemImage: String
    let isConflict: Bool
    /// Extra lines (conflict note, an added environment's item names).
    let details: [String]
    let keepLocal: DriftChoiceModel
    let acceptGitHub: DriftChoiceModel
    /// "Fill Value…" when keeping the local side needs the missing secret value.
    let fillValue: ItemEditorContext?
}

/// A resolution that deletes local data, waiting for the user's confirmation.
struct DriftConfirmationModel: Identifiable, Hashable {
    let driftID: String
    let option: DriftResolutionOption
    let title: String
    let message: String

    var id: String {
        driftID + option.rawValue
    }
}

/// The drift review of one repository (§7.7, D27, M5): each finding with Keep Local / Accept
/// GitHub. A secret's "Accept GitHub" continues in the item editor in fill mode (UI feature
/// contract: `actions.present(.itemEditor(.fill(id)))`). Resolutions that delete local data ask
/// first; neither choice of a finding is a default button.
@Observable
final class DriftReviewViewModel {
    let context: DriftReviewContext
    private(set) var report: DriftReportModel?
    private(set) var isLoading = false
    /// Findings being resolved.
    private(set) var resolving: Set<String> = []
    private(set) var resolvedCount = 0
    private(set) var fullName: String?
    private(set) var notice: String?
    var confirmation: DriftConfirmationModel?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let service: any DriftServicing
    @ObservationIgnored private var didRequestRefresh = false

    init(context: DriftReviewContext, dependencies: FeatureDependencies, service: (any DriftServicing)? = nil) {
        self.context = context
        self.dependencies = dependencies
        self.service = service ?? dependencies.driftService
    }

    var repositoryID: RepoID {
        context.repositoryID
    }

    // MARK: - Loading

    /// The last check of the repository, or a fresh one when there is none.
    func load() async {
        do {
            fullName = try dependencies.config.changeSet(repositoryID: repositoryID)?.repository.fullName
        } catch {
            fullName = nil
        }
        if let cached = await service.cachedReport(for: repositoryID) {
            report = cached
            return
        }
        await refresh()
    }

    /// **Refresh**: a full re-list now.
    func refresh() async {
        guard dependencies.actions.isGitHubReady() else {
            alert = ErrorPresentationModel(
                title: String(localized: "error.drift.title", defaultValue: "GitHub changes not checked"),
                message: DriftCopy.needsGH
            )
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await service.refresh(repositoryID)
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Rows

    var rows: [DriftFindingRowModel] {
        guard let report else { return [] }
        return report.drifts.map(row)
    }

    private func row(_ drift: DriftModel) -> DriftFindingRowModel {
        var details: [String] = []
        if drift.isConflict {
            details.append(DriftCopy.conflict)
        }
        if case .environment(let environment) = drift.subject, drift.kind == .environmentAdded,
           !environment.remoteItemNames.isEmpty {
            details.append(DriftCopy.environmentItems(environment.remoteItemNames))
        }
        var fillValue: ItemEditorContext?
        if drift.keepLocal.unavailableReason == .valueMissing, case .item(let item) = drift.subject, let itemID = item.itemID {
            fillValue = ItemEditorContext(repositoryID: repositoryID, scope: item.scope, mode: .fill(itemID))
        }
        return DriftFindingRowModel(
            id: drift.id,
            title: DriftCopy.title(drift, date: dateText(drift.remoteUpdatedAt)),
            scope: DriftCopy.scope(drift),
            systemImage: DriftCopy.systemImage(drift.kind),
            isConflict: drift.isConflict,
            details: details,
            keepLocal: choice(drift, .keepLocal),
            acceptGitHub: choice(drift, .acceptGitHub),
            fillValue: fillValue
        )
    }

    private func choice(_ drift: DriftModel, _ option: DriftResolutionOption) -> DriftChoiceModel {
        let resolution = drift.resolution(option)
        return DriftChoiceModel(
            option: option,
            title: option == .keepLocal ? DriftCopy.keepLocalTitle : DriftCopy.acceptGitHubTitle,
            explanation: option == .keepLocal
                ? DriftCopy.keepLocalExplanation(drift.kind)
                : DriftCopy.acceptGitHubExplanation(drift.kind),
            unavailableReason: resolution.unavailableReason.map(DriftCopy.unavailable),
            needsConfirmation: Self.needsConfirmation(drift, option)
        )
    }

    /// "Accept GitHub" of a remote deletion removes the local row and its value.
    static func needsConfirmation(_ drift: DriftModel, _ option: DriftResolutionOption) -> Bool {
        option == .acceptGitHub && (drift.kind == .remoteDeleted || drift.kind == .environmentDeleted)
    }

    /// "Oct 12" (with the year when it is not the current one).
    private func dateText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: dependencies.clock.now)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Scopes and names that were not compared, and pushes that were never confirmed.
    var notes: [String] {
        guard let report else { return [] }
        var notes = report.unreadable.map(DriftCopy.unreadable)
        if !report.skippedNames.isEmpty {
            notes.append(DriftCopy.skipped(report.skippedNames.map(\.name)))
        }
        if !report.expiredItems.isEmpty {
            notes.append(DriftCopy.expired(report.expiredItems.count))
        }
        return notes
    }

    var checkedAtText: String? {
        report.map { DriftCopy.checkedAt($0.checkedAt.formatted(date: .abbreviated, time: .shortened)) }
    }

    // MARK: - Resolution

    /// A choice button: asks first when the choice deletes local data.
    func choose(_ driftID: String, _ option: DriftResolutionOption) async {
        guard let drift = drift(driftID), drift.resolution(option).isAvailable, !resolving.contains(driftID) else { return }
        if Self.needsConfirmation(drift, option) {
            confirmation = DriftConfirmationModel(
                driftID: driftID,
                option: option,
                title: DriftCopy.confirmationTitle(drift),
                message: DriftCopy.confirmationMessage(drift)
            )
            return
        }
        await resolve(drift, option)
    }

    /// The confirmed deletion.
    func confirm() async {
        guard let confirmation, let drift = drift(confirmation.driftID) else { return }
        self.confirmation = nil
        await resolve(drift, confirmation.option)
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    private func resolve(_ drift: DriftModel, _ option: DriftResolutionOption) async {
        resolving.insert(drift.id)
        defer { resolving.remove(drift.id) }
        let result: DriftResolutionResultModel
        do {
            result = try await service.resolve(drift, option: option)
        } catch {
            alert = error.presentation
            if error == .stale {
                await refresh()
            }
            return
        }
        report?.drifts.removeAll { $0.id == drift.id }
        resolvedCount += 1
        notice = DriftCopy.resolved
        AppLog.ui.info("Drift finding resolved with \(option.rawValue, privacy: .public)")
        if case .promptFillValue(let itemID)? = result.followUp, case .item(let item) = drift.subject {
            // GitHub never returns secret values: continue in the item editor (fill mode).
            finish()
            // The user accepted GitHub's value: what they enter is taken as GitHub's, not pushed.
            dependencies.actions.present(.itemEditor(ItemEditorContext(
                repositoryID: repositoryID,
                scope: item.scope,
                mode: .fill(itemID),
                fillMatchesGitHub: true
            )))
        }
    }

    /// "Fill Value…" for a finding whose "Keep Local" needs the missing value.
    func fillValue(_ context: ItemEditorContext) {
        finish()
        dependencies.actions.present(.itemEditor(context))
    }

    private func drift(_ id: String) -> DriftModel? {
        report?.drifts.first { $0.id == id }
    }

    /// Called when the sheet closes: after a resolution the main window checks drift again so
    /// the banner matches.
    func finish() {
        guard resolvedCount > 0, !didRequestRefresh else { return }
        didRequestRefresh = true
        dependencies.actions.refresh(.drift(repositoryID))
    }
}
