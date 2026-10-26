import SwiftUI
import VaultData

/// Copy All (1.0 D6c4): "Confirm it's you" (Touch ID first, then the master password), then
/// what was copied and when the clipboard clears. See ``CopyAllViewModel`` for the rules.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.copyAll`, from a place's Copy All button and its ⋯ More.
struct CopyAllScreen: View {
    @State private var viewModel: CopyAllViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: CopyAllContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: CopyAllViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        DialogSheet(title: title, subtitle: subtitle) {
            if viewModel.step == .authenticate {
                ReauthView(
                    model: viewModel.reauth,
                    message: CopyAllCopy.message,
                    onTouchID: { await viewModel.authenticateWithTouchID() },
                    onPassword: { await viewModel.authenticateWithPassword() }
                )
            }
        } actions: {
            if viewModel.step == .authenticate {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.outline, size: .dialog)
                .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: Theme.Layout.copyAllSheetWidth)
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .errorAlert($viewModel.alert)
    }

    private var title: String {
        if case .done = viewModel.step { CopyAllCopy.doneTitle } else { CopyAllCopy.title }
    }

    private var subtitle: String? {
        guard case .done(let count) = viewModel.step else { return nil }
        return CopyAllCopy.doneMessage(count: count, seconds: viewModel.clearSeconds)
    }
}
