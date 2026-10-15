import SwiftUI
import VaultCore

/// The non-blocking GitHub CLI status row on Welcome and the lock screen (§10). Hidden while the
/// status is unknown.
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
                Text(content.text)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var content: (systemImage: String, tint: Color, text: String)? {
        switch status {
        case .unknown:
            nil
        case .checking:
            ("terminal", Theme.Colors.textSecondary, String(localized: "gh.status.checking", defaultValue: "Looking for the GitHub CLI…"))
        case .ready(let version, let path):
            (
                "checkmark.circle.fill",
                Theme.Colors.success,
                String(localized: "gh.status.ready", defaultValue: "GitHub CLI \(version) at \(path)")
            )
        case .notInstalled:
            (
                "exclamationmark.triangle.fill",
                Theme.Colors.warning,
                String(
                    localized: "gh.status.notInstalled",
                    defaultValue: "GitHub CLI not found. Install it with: brew install gh"
                )
            )
        case .outdated(let found, let required):
            (
                "exclamationmark.triangle.fill",
                Theme.Colors.warning,
                String(
                    localized: "gh.status.outdated",
                    defaultValue: "GitHub CLI \(found) is too old; FX Vault needs \(required) or later. Run: brew upgrade gh"
                )
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
