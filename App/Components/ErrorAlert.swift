import SwiftUI

extension View {
    /// Shows `error` in a standard alert with OK; dismissing sets it back to nil.
    func errorAlert(_ error: Binding<ErrorPresentationModel?>) -> some View {
        alert(
            error.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue
        ) { _ in
            Button(String(localized: "common.ok", defaultValue: "OK")) {
                error.wrappedValue = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: { presentation in
            Text(presentation.message)
        }
    }
}
