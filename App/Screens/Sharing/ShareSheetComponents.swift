import SwiftUI

// Small pieces shared by the sharing, nearby, chat and `.env` sheets. The header, callout,
// checkbox row and sheet chrome are design components (App/Components/Design/SheetChrome.swift).

/// The ``SheetHeader`` labels of the sharing, nearby, chat and `.env` sheets, one per feature.
enum ShareSheetLabel {
    static var environmentFile: String {
        String(localized: "envFile.sheet.label", defaultValue: "Environment file")
    }

    static var share: String {
        String(localized: "share.sheet.label", defaultValue: "Share")
    }

    static var nearby: String {
        String(localized: "nearby.sheet.label", defaultValue: "Nearby")
    }

    static var nearbyChat: String {
        String(localized: "chat.sheet.label", defaultValue: "Nearby Chat")
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
struct NearbyProgressRow: View {
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
