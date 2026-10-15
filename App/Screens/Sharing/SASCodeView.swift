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
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.textPrimary)
            .multilineTextAlignment(.center)
            Text(verbatim: sas.code)
                .font(Theme.Typography.sasCode)
                .foregroundStyle(Theme.Colors.textPrimary)
                .textSelection(.disabled)
                .accessibilityLabel(String(
                    localized: "nearby.sas.accessibility",
                    defaultValue: "Code \(sas.code.map(String.init).joined(separator: " "))"
                ))
            Text(String(
                localized: "nearby.sas.unverifiedName",
                defaultValue: "The name is shown as the other Mac sent it. Only the code proves who it is."
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .multilineTextAlignment(.center)
            if isConfirmed {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isPeerConfirmed
                        ? String(localized: "nearby.sas.bothConfirmed", defaultValue: "Both confirmed.")
                        : String(localized: "nearby.sas.waitingPeer", defaultValue: "Waiting for the other Mac to confirm…"))
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
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
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                if isPeerConfirmed {
                    Text(String(localized: "nearby.sas.peerConfirmed", defaultValue: "The other Mac confirmed the code."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onKeyPress(.return) { .handled }
    }
}
