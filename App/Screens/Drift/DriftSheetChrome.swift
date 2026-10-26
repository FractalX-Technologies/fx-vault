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

    /// "Delete … from your vault?" (or another loss of local data) before the resolution.
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
        ) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
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

/// "Not compared": what the check left out (unreadable scopes, names FX Vault can't hold,
/// pushes never confirmed), one muted line each; nothing when there is none.
struct DriftNotesField: View {
    let notes: [String]

    var body: some View {
        if !notes.isEmpty {
            ConfigSheetField(String(localized: "drift.review.notes", defaultValue: "Not compared")) {
                ForEach(notes, id: \.self) { note in
                    Label {
                        Text(verbatim: note)
                            .fxTextStyle(.callout)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(Theme.Colors.subtleText)
                    }
                }
            }
        }
    }
}
