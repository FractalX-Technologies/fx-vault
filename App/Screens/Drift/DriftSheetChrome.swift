import SwiftUI

extension View {
    /// The drift review's size, shared by a repository's and an organization's (1.0 B7b).
    func driftSheetFrame() -> some View {
        frame(
            minWidth: Theme.Layout.driftSheetWidth,
            idealWidth: Theme.Layout.driftSheetWidth,
            maxWidth: Theme.Layout.driftSheetWidth,
            minHeight: Theme.Layout.driftSheetMinHeight,
            idealHeight: Theme.Layout.driftSheetIdealHeight
        )
    }

    /// "Delete … from your vault?" before a resolution that deletes local data.
    func driftConfirmationDialog(
        _ confirmation: DriftConfirmationModel?,
        confirm: @escaping () async -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            confirmation?.title ?? "",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { cancel() } }
            ),
            presenting: confirmation
        ) { _ in
            Button(DriftCopy.confirmDelete, role: .destructive) {
                Task { await confirm() }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                cancel()
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
