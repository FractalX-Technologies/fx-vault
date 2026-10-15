import SwiftUI

/// The name field of the environment sheets: a rounded mono input (environment names are names)
/// with the danger border while the name is invalid. The caller owns the focus state.
struct EnvironmentNameField: View {
    let title: String
    @Binding var name: String
    let prompt: String?
    let isInvalid: Bool
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField(
            title,
            text: $name,
            prompt: prompt.map { Text(verbatim: $0).foregroundStyle(Theme.Colors.subtleText) }
        )
        .focused(isFocused)
        .autocorrectionDisabled()
        .labelsHidden()
        .fxInputField(.rounded, isFocused: isFocused.wrappedValue, isInvalid: isInvalid, isMonospaced: true)
    }
}
