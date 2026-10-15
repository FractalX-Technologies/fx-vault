import SwiftUI
import VaultCore

/// The non-blocking GitHub CLI status row on Welcome, the lock screen and Settings (§10): a tinted
/// symbol and one muted line. Hidden while the status is unknown. Paths and commands inside the
/// sentence are set in Geist Mono (docs/DESIGN.md: mono for paths); the sentence stays one
/// localized string.
struct GHStatusRow: View {
    let status: GHStatusModel

    var body: some View {
        if let content {
            HStack(spacing: Theme.Spacing.small) {
                if status == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: content.systemImage)
                        .foregroundStyle(content.tint)
                        .accessibilityHidden(true)
                }
                Text(Self.styled(content.text, monoSpans: content.monoSpans))
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The sentence with each of `monoSpans` (its first occurrence) in Geist Mono.
    static func styled(_ text: String, monoSpans: [String]) -> AttributedString {
        var attributed = AttributedString(text)
        for span in monoSpans where !span.isEmpty {
            if let range = attributed.range(of: span) {
                attributed[range].swiftUI.font = Theme.Typography.monoMeta
            }
        }
        return attributed
    }

    private static let installCommand = "brew install gh"
    private static let upgradeCommand = "brew upgrade gh"
    private static let loginCommand = "gh auth login"

    private var content: (systemImage: String, tint: Color, text: String, monoSpans: [String])? {
        switch status {
        case .unknown:
            nil
        case .checking:
            ("terminal", Theme.Colors.subtleText, String(localized: "gh.status.checking", defaultValue: "Looking for the GitHub CLI…"), [])
        case .ready(let version, let path):
            (
                "checkmark.circle.fill",
                Theme.Colors.success,
                String(localized: "gh.status.ready", defaultValue: "GitHub CLI \(version) at \(path)"),
                [path]
            )
        case .notInstalled:
            (
                "exclamationmark.triangle.fill",
                Theme.Colors.warning,
                String(
                    localized: "gh.status.notInstalled",
                    defaultValue: "GitHub CLI not found. Install it with: brew install gh"
                ),
                [Self.installCommand]
            )
        case .outdated(let found, let required):
            (
                "exclamationmark.triangle.fill",
                Theme.Colors.warning,
                String(
                    localized: "gh.status.outdated",
                    defaultValue: "GitHub CLI \(found) is too old; FX Vault needs \(required) or later. Run: brew upgrade gh"
                ),
                [Self.upgradeCommand]
            )
        case .untrusted(let path):
            (
                "exclamationmark.shield.fill",
                Theme.Colors.danger,
                String(
                    localized: "gh.status.untrusted",
                    defaultValue: "The GitHub CLI at \(path) is writable by other users, so FX Vault does not run it."
                ),
                [path]
            )
        case .noAccounts(let version, _):
            (
                "person.crop.circle.badge.exclamationmark",
                Theme.Colors.warning,
                String(
                    localized: "gh.status.noAccounts",
                    defaultValue: "GitHub CLI \(version) has no account logged in. Run: gh auth login"
                ),
                [Self.loginCommand]
            )
        case .failed:
            (
                "exclamationmark.triangle.fill",
                Theme.Colors.warning,
                String(
                    localized: "gh.status.failed",
                    defaultValue: "FX Vault could not check the GitHub CLI."
                ),
                []
            )
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        GHStatusRow(status: .ready(version: Limits.minimumGHVersion, path: AppContainer.previewGHPath))
        GHStatusRow(status: .notInstalled)
        GHStatusRow(status: .checking)
    }
    .padding()
}
