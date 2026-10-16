import SwiftUI
import VaultCore
import VaultData

/// Refresh's findings for one destination (v0.8.0, R6): each remote add, change or deletion with
/// Keep Mine and Use Remote, or the same choice for all of them. The destination is listed again
/// before anything is written; a finding that moved again asks for another Refresh.
@Observable
final class DestinationDriftViewModel {
    let context: DestinationDriftContext
    private(set) var findings: [DestinationDriftModel]
    private(set) var destination: DestinationModel?
    private(set) var isWorking = false
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let onResolved: () -> Void
    @ObservationIgnored private let tasks = TaskBag()

    init(context: DestinationDriftContext, dependencies: FeatureDependencies, onResolved: @escaping () -> Void) {
        self.context = context
        findings = context.findings
        self.dependencies = dependencies
        self.onResolved = onResolved
        destination = try? dependencies.destinations.destination(context.destinationID)
    }

    var provider: DestinationProvider {
        destination?.provider ?? .azureKeyVault
    }

    func title(of finding: DestinationDriftModel) -> String {
        DestinationDriftCopy.title(finding, provider: provider)
    }

    func detail(of finding: DestinationDriftModel) -> String {
        DestinationDriftCopy.detail(finding, provider: provider)
    }

    /// Applies `choice` to `findings` (one row, or every row for the bulk buttons).
    func resolve(_ findings: [DestinationDriftModel], choice: DestinationDriftChoice, dismiss: @escaping () -> Void) {
        guard !isWorking, !findings.isEmpty else { return }
        isWorking = true
        let sync = dependencies.destinationSync
        let id = context.destinationID
        let provider = provider
        tasks.set("resolve", Task { [weak self] in
            do throws(DestinationSyncError) {
                try await sync.resolve(findings, choice: choice, destinationID: id)
                guard let self else { return }
                let resolved = Set(findings.map(\.id))
                self.findings.removeAll { resolved.contains($0.id) }
                isWorking = false
                if self.findings.isEmpty {
                    onResolved()
                    dismiss()
                }
            } catch {
                self?.alert = error.presentation(provider: provider)
                self?.isWorking = false
            }
        })
    }
}

struct DestinationDriftScreen: View {
    @State private var viewModel: DestinationDriftViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: DestinationDriftContext, dependencies: FeatureDependencies, onResolved: @escaping () -> Void) {
        _viewModel = State(initialValue: DestinationDriftViewModel(context: context, dependencies: dependencies, onResolved: onResolved))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: DestinationCopy.eyebrow,
                title: DestinationCopy.driftBanner(viewModel.findings.count, provider: viewModel.provider),
                subtitle: viewModel.destination?.copyTargetTitle
            )
            ScrollView {
                ConfigSheetList(viewModel.findings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                            Text(verbatim: viewModel.title(of: finding))
                                .fxTextStyle(.monoName)
                                .foregroundStyle(Theme.Colors.ink)
                            Text(viewModel.detail(of: finding))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button(DestinationDriftCopy.keepMine) {
                            viewModel.resolve([finding], choice: .keepMine) { dismiss() }
                        }
                        .fxButtonStyle(.outline)
                        .disabled(!finding.canKeepMine || viewModel.isWorking)
                        Button(DestinationDriftCopy.useRemote(viewModel.provider)) {
                            viewModel.resolve([finding], choice: .useRemote) { dismiss() }
                        }
                        .fxButtonStyle(.secondary)
                        .disabled(viewModel.isWorking)
                    }
                }
            }
            .frame(maxHeight: Theme.Layout.createRepoStatusHeight)
            HStack(spacing: Theme.Spacing.medium) {
                if viewModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button(String(localized: "common.close", defaultValue: "Close")) { dismiss() }
                    .fxButtonStyle(.secondary, size: .large)
                    .keyboardShortcut(.cancelAction)
                Button(DestinationDriftCopy.useRemoteForAll(viewModel.provider)) {
                    viewModel.resolve(viewModel.findings, choice: .useRemote) { dismiss() }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(viewModel.isWorking || viewModel.findings.isEmpty)
            }
        }
        .padding(Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.destinationSheetWidth)
        .errorAlert($viewModel.alert)
    }
}

enum DestinationDriftCopy {
    static var keepMine: String {
        String(localized: "destinationDrift.keepMine", defaultValue: "Keep Mine")
    }

    static func useRemote(_ provider: DestinationProvider) -> String {
        String(localized: "destinationDrift.useRemote", defaultValue: "Use \(provider.shortTitle)")
    }

    static func useRemoteForAll(_ provider: DestinationProvider) -> String {
        String(localized: "destinationDrift.useRemoteAll", defaultValue: "Use \(provider.shortTitle) for All")
    }

    static func title(_ finding: DestinationDriftModel, provider: DestinationProvider) -> String {
        finding.remoteName == finding.name ? finding.name : "\(finding.name) (\(finding.remoteName))"
    }

    static func detail(_ finding: DestinationDriftModel, provider: DestinationProvider) -> String {
        switch finding.kind {
        case .remoteAdded where finding.itemID != nil:
            String(
                localized: "destinationDrift.added.conflict",
                defaultValue: "Added in \(provider.title) while you added it here. Keep Mine sends yours on the next Sync."
            )
        case .remoteAdded:
            finding.isValueReadable
                ? String(localized: "destinationDrift.added", defaultValue: "Added in \(provider.title). Use it to bring it into FX Vault; Keep Mine deletes it there on the next Sync.")
                : String(localized: "destinationDrift.added.writeOnly", defaultValue: "Added in \(provider.title), which does not return its value: it comes in without one. Keep Mine deletes it there on the next Sync.")
        case .remoteChanged:
            finding.isValueReadable
                ? String(localized: "destinationDrift.changed", defaultValue: "Changed in \(provider.title) since your last sync. Use it to take the new value; Keep Mine sends yours on the next Sync.")
                : String(localized: "destinationDrift.changed.writeOnly", defaultValue: "Changed in \(provider.title), which does not return values: using it leaves the value missing here.")
        case .remoteDeleted:
            String(
                localized: "destinationDrift.deleted",
                defaultValue: "Deleted in \(provider.title). Use it to remove it here; Keep Mine adds it again on the next Sync."
            )
        }
    }
}
