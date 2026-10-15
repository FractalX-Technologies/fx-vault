import SharingKit
import SwiftUI

/// The two answers to "Does the other Mac show the same code?" (§9.4 step 5).
///
/// Both have equal weight and **neither is the default**: a reflexive Return must never confirm
/// a code, so no keyboard shortcut is attached and Return is swallowed (``SASCodeView``).
enum SASDecision: CaseIterable, Identifiable {
    case match
    case mismatch

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .match: String(localized: "nearby.sas.match", defaultValue: "Codes match")
        case .mismatch: String(localized: "nearby.sas.mismatch", defaultValue: "Don't match")
        }
    }

    var systemImage: String {
        switch self {
        case .match: "checkmark"
        case .mismatch: "xmark"
        }
    }

    /// Never a default button (no `.keyboardShortcut(.defaultAction)`, no prominent style).
    var isDefaultAction: Bool {
        false
    }

    /// Both buttons share one style so neither looks preferred.
    var usesProminentStyle: Bool {
        false
    }

    /// The same secondary pill for both answers: equal visual weight, never the ink primary.
    var buttonVariant: FXButtonStyle.Variant {
        .secondary
    }
}

/// The nearby code (`ddd ddd`, large and monospaced) with the peer's unverified name and the
/// two equal-weight decisions. Return does nothing here.
struct SASCodeView: View {
    let sas: NearbySASModel
    /// The local user already answered "Codes match".
    let isConfirmed: Bool
    /// The other side already confirmed.
    let isPeerConfirmed: Bool
    let onDecision: (SASDecision) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Text(String(
                localized: "nearby.sas.prompt",
                defaultValue: "Check that \(sas.peerName) sees the same code."
            ))
            .fxTextStyle(.body)
            .foregroundStyle(Theme.Colors.ink)
            .multilineTextAlignment(.center)
            VStack(spacing: Theme.Spacing.small) {
                SectionLabel(String(localized: "nearby.sas.label", defaultValue: "Code"))
                    .accessibilityHidden(true)
                Text(verbatim: sas.code)
                    .fxTextStyle(.sasCode)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.disabled)
                    .accessibilityLabel(String(
                        localized: "nearby.sas.accessibility",
                        defaultValue: "Code \(sas.code.map(String.init).joined(separator: " "))"
                    ))
            }
            .padding(.vertical, Theme.Spacing.largePlus)
            .padding(.horizontal, Theme.Spacing.xxLarge)
            .fxCardBackground(.container)
            Text(String(
                localized: "nearby.sas.unverifiedName",
                defaultValue: "The name is shown as the other Mac sent it. Only the code proves who it is."
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .multilineTextAlignment(.center)
            if isConfirmed {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isPeerConfirmed
                        ? String(localized: "nearby.sas.bothConfirmed", defaultValue: "Both confirmed.")
                        : String(localized: "nearby.sas.waitingPeer", defaultValue: "Waiting for the other Mac to confirm…"))
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
            } else {
                HStack(spacing: Theme.Spacing.medium) {
                    ForEach(SASDecision.allCases) { decision in
                        Button {
                            onDecision(decision)
                        } label: {
                            Label(decision.title, systemImage: decision.systemImage)
                                .frame(minWidth: Theme.Layout.sasButtonMinWidth)
                        }
                        .fxButtonStyle(decision.buttonVariant, size: .large)
                    }
                }
                if isPeerConfirmed {
                    Text(String(localized: "nearby.sas.peerConfirmed", defaultValue: "The other Mac confirmed the code."))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onKeyPress(.return) { .handled }
    }
}
