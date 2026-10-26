import SwiftUI
import SyncEngine
import VaultCore
import VaultData

/// Refresh's findings for one organization (1.0 B7b): the repository drift review's rows (§7.7),
/// Keep Local / Accept GitHub with what each does. GitHub is listed again before anything is
/// written; a finding that moved again asks for another Refresh.
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
            explanation: isKeep ? DriftCopy.keepLocalExplanation(finding.kind) : Self.acceptExplanation(finding),
            unavailableReason: unavailable ?? (isOnline ? nil : ConnectivityCopy.offlineHelp),
            needsConfirmation: Self.needsConfirmation(finding, option)
        )
    }

    /// No fill step follows here: a secret GitHub changed is left without a value.
    private static func acceptExplanation(_ finding: OrgDriftModel) -> String {
        finding.kind == .secretModified ? OrganizationCopy.acceptSecretChange : DriftCopy.acceptGitHubExplanation(finding.kind)
    }

    /// Accept GitHub of a deletion removes the vault's row and its value.
    static func needsConfirmation(_ finding: OrgDriftModel, _ option: DriftResolutionOption) -> Bool {
        option == .acceptGitHub && finding.kind == .remoteDeleted
    }

    // MARK: - Resolution

    /// A choice button: asks first when the choice deletes local data.
    func choose(_ id: String, _ option: DriftResolutionOption) async {
        guard isOnline, let finding = findings.first(where: { $0.id == id }), !resolving.contains(id) else { return }
        guard option == .acceptGitHub || finding.canKeepLocal else { return }
        if Self.needsConfirmation(finding, option) {
            confirmation = DriftConfirmationModel(
                driftID: id,
                option: option,
                title: DriftCopy.deleteItemTitle(finding.name),
                message: DriftCopy.deleteItemMessage
            )
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

struct OrgDriftScreen: View {
    @State private var viewModel: OrgDriftViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: OrgDriftContext, dependencies: FeatureDependencies, onResolved: @escaping (Set<String>) -> Void) {
        _viewModel = State(initialValue: OrgDriftViewModel(context: context, dependencies: dependencies, onResolved: onResolved))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            SheetHeader(
                label: PlaceCopy.organization,
                title: DriftCopy.reviewTitle,
                subtitle: viewModel.login
            )
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.top, Theme.Spacing.xxLarge)
            .padding(.bottom, Theme.Spacing.xLarge)
            ScrollView {
                if viewModel.rows.isEmpty {
                    Text(DriftCopy.nothingChanged)
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ConfigSheetList(viewModel.rows) { row in
                        DriftFindingRow(
                            row: row,
                            isResolving: viewModel.resolving.contains(row.id),
                            onChoose: { option in Task { await viewModel.choose(row.id, option) } },
                            onFillValue: { _ in }
                        )
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .padding(.bottom, Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HairlineDivider()
            ConfigSheetFooter(meta: nil, notice: viewModel.notice) {
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.cancelAction)
            }
        }
        .driftSheetFrame()
        .fxSheetBackground()
        .errorAlert($viewModel.alert)
        .driftConfirmationDialog(viewModel.confirmation) {
            await viewModel.confirm()
        } cancel: {
            viewModel.cancelConfirmation()
        }
        .task {
            await viewModel.load()
        }
    }
}
