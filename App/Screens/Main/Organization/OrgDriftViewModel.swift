import Foundation
import Observation
import SyncEngine
import VaultCore
import VaultData

/// Refresh's findings for one organization (1.0 B7b): the repository drift review's rows (§7.7),
/// Keep Local / Accept GitHub with what each does. GitHub is listed again before anything is
/// written; a finding that moved again asks for another Refresh. Choices that lose the vault's
/// data (taking GitHub's deletion, or GitHub's item over one added here) ask first.
@Observable
final class OrgDriftViewModel {
    let context: OrgDriftContext
    private(set) var findings: [OrgDriftModel]
    /// Findings being resolved.
    private(set) var resolving: Set<String> = []
    private(set) var notice: String?
    private(set) var login: String?
    var confirmation: DriftConfirmationModel?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let onResolved: (Set<String>) -> Void

    /// - Parameter onResolved: the ids of each resolved batch (the organization view drops their marks).
    init(context: OrgDriftContext, dependencies: FeatureDependencies, onResolved: @escaping (Set<String>) -> Void) {
        self.context = context
        findings = context.findings
        self.dependencies = dependencies
        self.onResolved = onResolved
    }

    /// The organization's login, for the header.
    func load() async {
        login = (try? await dependencies.organizations.organizations())?.first { $0.id == context.organizationID }?.login
    }

    var isOnline: Bool {
        dependencies.connectivity.isOnline
    }

    var rows: [DriftFindingRowModel] {
        findings.map(row)
    }

    /// Listed names FX Vault can't hold, which Refresh did not compare.
    var notes: [String] {
        context.skippedNames.isEmpty ? [] : [DriftCopy.skipped(context.skippedNames)]
    }

    private func row(_ finding: OrgDriftModel) -> DriftFindingRowModel {
        DriftFindingRowModel(
            id: finding.id,
            title: DriftCopy.itemTitle(
                finding.kind,
                itemKind: finding.itemKind,
                name: finding.name,
                date: DriftCopy.findingDate(finding.remoteUpdatedAt, now: dependencies.clock.now)
            ),
            scope: PlaceCopy.organization,
            systemImage: DriftCopy.systemImage(finding.kind),
            isConflict: finding.isConflict,
            details: finding.isConflict ? [DriftCopy.conflict] : [],
            keepLocal: choice(finding, .keepLocal),
            acceptGitHub: choice(finding, .acceptGitHub),
            fillValue: nil
        )
    }

    private func choice(_ finding: OrgDriftModel, _ option: DriftResolutionOption) -> DriftChoiceModel {
        let isKeep = option == .keepLocal
        let unavailable = isKeep && !finding.canKeepLocal ? DriftCopy.unavailable(.valueMissing) : nil
        return DriftChoiceModel(
            option: option,
            title: isKeep ? DriftCopy.keepLocalTitle : DriftCopy.acceptGitHubTitle,
            explanation: Self.explanation(finding, option),
            unavailableReason: unavailable ?? (isOnline ? nil : ConnectivityCopy.offlineHelp),
            needsConfirmation: Self.needsConfirmation(finding, option)
        )
    }

    /// The repository review's texts, except where an organization does something else: an add
    /// on both sides (Keep Local sends the vault's, Accept replaces it) and a changed secret
    /// (no fill step: it is left without a value, unless only its access changed).
    static func explanation(_ finding: OrgDriftModel, _ option: DriftResolutionOption) -> String {
        let isBothAdded = finding.kind == .remoteAdded && finding.itemID != nil
        switch option {
        case .keepLocal:
            return isBothAdded ? DriftCopy.bothAddedKeepLocal : DriftCopy.keepLocalExplanation(finding.kind)
        case .acceptGitHub:
            if isBothAdded { return DriftCopy.bothAddedAcceptGitHub(finding.itemKind, fillsValue: false) }
            guard finding.kind == .secretModified else { return DriftCopy.acceptGitHubExplanation(finding.kind) }
            return finding.isRemoteDateChanged ? OrganizationCopy.acceptSecretChange : OrganizationCopy.acceptAccessChange
        }
    }

    /// Accept GitHub of a deletion removes the vault's row and its value; of an add on both
    /// sides, it replaces a value the vault never sent.
    static func needsConfirmation(_ finding: OrgDriftModel, _ option: DriftResolutionOption) -> Bool {
        guard option == .acceptGitHub else { return false }
        return finding.kind == .remoteDeleted || (finding.kind == .remoteAdded && finding.itemID != nil && finding.hasLocalValue)
    }

    // MARK: - Resolution

    /// A choice button: asks first when the choice loses the vault's data.
    func choose(_ id: String, _ option: DriftResolutionOption) async {
        guard isOnline, let finding = findings.first(where: { $0.id == id }), !resolving.contains(id) else { return }
        guard option == .acceptGitHub || finding.canKeepLocal else { return }
        if Self.needsConfirmation(finding, option) {
            confirmation = finding.kind == .remoteDeleted
                ? DriftConfirmationModel(driftID: id, option: option, title: DriftCopy.deleteItemTitle(finding.name), message: DriftCopy.deleteItemMessage)
                : .replace(driftID: id, name: finding.name)
            return
        }
        await resolve(finding, option)
    }

    func confirm() async {
        guard let confirmation, let finding = findings.first(where: { $0.id == confirmation.driftID }) else { return }
        self.confirmation = nil
        await resolve(finding, confirmation.option)
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    private func resolve(_ finding: OrgDriftModel, _ option: DriftResolutionOption) async {
        resolving.insert(finding.id)
        defer { resolving.remove(finding.id) }
        do throws(DriftRepositoryError) {
            try await dependencies.organizations.resolve([finding], option: option, organizationID: context.organizationID)
            dependencies.gitHubReachability.recordSuccess()
        } catch {
            dependencies.gitHubReachability.record(error)
            alert = error.presentation
            return
        }
        findings.removeAll { $0.id == finding.id }
        notice = DriftCopy.resolved
        onResolved([finding.id])
        AppLog.ui.info("Organization difference resolved with \(option.rawValue, privacy: .public)")
    }
}
