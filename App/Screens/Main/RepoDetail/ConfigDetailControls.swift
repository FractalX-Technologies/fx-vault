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

/// Import .env file (outline circle), Paste multiple (outline pill) and Add secret / Add
/// variable (the tab's kind, primary pill). Paste and import default every row to the tab's
/// kind.
struct ConfigAddActions<Model: ConfigTableModel>: View {
    let viewModel: Model

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Button {
                viewModel.importEnvFile()
            } label: {
                Label(String(localized: "main.detail.importEnvFile", defaultValue: "Import .env File…"), systemImage: "square.and.arrow.down")
            }
            .fxIconButtonStyle()
            .help(String(localized: "main.detail.importEnvFile", defaultValue: "Import .env File…"))
            Button(String(localized: "main.detail.pasteMultiple", defaultValue: "Paste Multiple…")) {
                viewModel.pasteMultiple()
            }
            .fxButtonStyle(.outline)
            Button {
                viewModel.add()
            } label: {
                Label(viewModel.kind.addTitle, systemImage: "plus")
            }
            .fxButtonStyle(.primary)
            .help(String(
                localized: "main.detail.add.help",
                defaultValue: "Add one item, or paste many KEY=value lines at once (⌘V on the table)"
            ))
        }
        .fixedSize()
        .disabled(!viewModel.canEdit)
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
