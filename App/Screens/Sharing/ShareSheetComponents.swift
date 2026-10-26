import SwiftUI

// Small pieces shared by the sharing and `.env` sheets. The header, callout,
// checkbox row and sheet chrome are design components (App/Components/Design/SheetChrome.swift).

/// The ``SheetHeader`` label of the `.env` sheets (the 1.0 share dialogs have no eyebrow).
enum ShareSheetLabel {
    static var environmentFile: String {
        String(localized: "envFile.sheet.label", defaultValue: "Environment file")
    }
}

/// A one-line note with an icon (hints, confirmations) in the sharing sheets.
struct ShareNoteView: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.Colors.subtleText

    var body: some View {
        Label {
            Text(text)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Spinner and status line while a sheet waits.
struct SheetProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
