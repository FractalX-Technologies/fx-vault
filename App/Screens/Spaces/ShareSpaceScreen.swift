import SwiftUI

/// ShareSpaceScreen (v0.6.0): Scope menu › Share with Teammates…. What sharing does, the paired
/// teammates to choose, an optional note, then the outcome. A scope that is not fully synced
/// lists what to fix instead.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.shareSpace`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct ShareSpaceScreen: View {
    @State private var viewModel: ShareSpaceViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ShareSpaceContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: ShareSpaceViewModel(context: context, dependencies: dependencies))
    }

    /// A screen over an existing view model (previews and snapshots).
    init(viewModel: ShareSpaceViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: SpaceCopy.shareEyebrow,
            title: SpaceCopy.shareTitle,
            subtitle: viewModel.scopeName,
            primaryTitle: viewModel.sharedSpaceID == nil
                ? SpaceCopy.sharePrimary
                : String(localized: "common.done", defaultValue: "Done"),
            isPrimaryEnabled: viewModel.sharedSpaceID != nil || viewModel.canShare,
            isWorking: viewModel.isSharing,
            onCancel: { dismiss() },
            onPrimary: primary
        ) {
            if !viewModel.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if viewModel.sharedSpaceID != nil {
                Banner(.info, message: SpaceCopy.shareDone, action: .init(title: SpaceCopy.showSpace) {
                    viewModel.showSpace()
                })
            } else {
                Text(SpaceCopy.shareExplanation)
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                if let readiness = viewModel.readiness, !readiness.isReady {
                    if !readiness.pendingNames.isEmpty {
                        Banner(.warning, message: SpaceCopy.notReadyPending(readiness.pendingNames))
                    }
                    if !readiness.missingValueNames.isEmpty {
                        Banner(.warning, message: SpaceCopy.notReadyMissing(readiness.missingValueNames))
                    }
                } else {
                    teammateField(viewModel)
                    FXTextField(label: SpaceCopy.shareReason, text: $viewModel.reason, prompt: SpaceCopy.shareReasonPrompt)
                }
            }
        }
        .task {
            viewModel.load()
        }
        .errorAlert($viewModel.alert)
    }

    @ViewBuilder
    private func teammateField(_ viewModel: ShareSpaceViewModel) -> some View {
        ConfigSheetField(SpaceCopy.shareTeammates) {
            if viewModel.teammates.isEmpty {
                Text(SpaceCopy.shareNoTeammates)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            } else {
                ConfigSheetList(viewModel.teammates) { teammate in
                    Toggle(isOn: Binding(
                        get: { viewModel.chosen.contains(teammate.id) },
                        set: { _ in viewModel.toggle(teammate.id) }
                    )) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                            Text(verbatim: teammate.name)
                                .fxTextStyle(.body)
                                .foregroundStyle(Theme.Colors.ink)
                            if !teammate.detail.isEmpty {
                                Text(verbatim: teammate.detail)
                                    .fxTextStyle(.monoMeta)
                                    .foregroundStyle(Theme.Colors.mutedText)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func primary() {
        if viewModel.sharedSpaceID != nil {
            dismiss()
        } else {
            Task { await viewModel.share() }
        }
    }
}
