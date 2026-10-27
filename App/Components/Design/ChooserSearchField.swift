import SwiftUI

/// The search field at the top of a chooser list (Choose Vaults…, Choose Repositories…): the
/// panel search field with its own focus, filtering the list as the user types.
struct ChooserSearchField: View {
    let prompt: String
    let accessibilityID: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        PanelSearchField(
            prompt: prompt,
            label: prompt,
            accessibilityID: accessibilityID,
            text: $text,
            isFocused: $isFocused
        )
    }
}
