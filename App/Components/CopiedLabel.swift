import SwiftUI

/// "✓ Copied" where a Copy just put something on the clipboard: a command, the diagnostics, a
/// notes line under Reveal All.
struct CopiedLabel: View {
    var body: some View {
        Label(String(localized: "command.copied", defaultValue: "Copied"), systemImage: "checkmark")
    }
}
