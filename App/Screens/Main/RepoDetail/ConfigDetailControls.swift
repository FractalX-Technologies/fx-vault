import SwiftUI
import VaultCore

/// The Secrets | Variables pill of a detail column (repository scope or folder), with counts.
struct ConfigKindPill<Model: ConfigTableModel>: View {
    @Bindable var viewModel: Model

    var body: some View {
        SegmentedPill(
            selection: $viewModel.kind,
            segments: [
                .init(
                    value: ConfigKind.secret,
                    title: String(localized: "main.detail.kind.secrets", defaultValue: "Secrets"),
                    count: viewModel.count(of: .secret)
                ),
                .init(
                    value: ConfigKind.variable,
                    title: String(localized: "main.detail.kind.variables", defaultValue: "Variables"),
                    count: viewModel.count(of: .variable)
                ),
            ],
            accessibilityLabel: String(localized: "main.detail.kind", defaultValue: "Kind")
        )
        .fixedSize()
    }
}

/// "Replace or keep?" for a copy into a place that already has some of the names.
struct ItemCopyConflictDialog<Model: ConfigTableModel>: ViewModifier {
    @Bindable var viewModel: Model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            viewModel.pendingCopy?.title ?? "",
            isPresented: Binding(
                get: { viewModel.pendingCopy != nil },
                set: { if !$0 { viewModel.pendingCopy = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingCopy
        ) { request in
            Button(request.replaceTitle) {
                viewModel.confirmCopy(replacing: true)
            }
            Button(String(localized: "main.detail.copy.conflict.keep", defaultValue: "Keep Existing")) {
                viewModel.confirmCopy(replacing: false)
            }
            Button(String(localized: "main.detail.copy.conflict.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.pendingCopy = nil
            }
        } message: { request in
            Text(request.message)
        }
    }
}
