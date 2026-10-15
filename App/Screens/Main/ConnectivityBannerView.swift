import SwiftUI

/// What the banner at the top of the main window says (v0.2.0). Offline wins over GitHub.
enum ConnectivityBannerModel: Equatable {
    /// The system reports no usable route.
    case offline
    /// gh calls could not reach GitHub although the Mac is online.
    case gitHubNotResponding(isRetrying: Bool)

    var message: String {
        switch self {
        case .offline:
            String(
                localized: "connectivity.banner.offline",
                defaultValue: "No internet connection. Your changes stay in the vault; sync when you're back online."
            )
        case .gitHubNotResponding:
            String(
                localized: "connectivity.banner.github",
                defaultValue: "GitHub isn't responding. Try again in a moment."
            )
        }
    }

    var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .gitHubNotResponding: "exclamationmark.icloud"
        }
    }
}

/// Texts shared by the offline gating of the main window.
enum ConnectivityCopy {
    /// The `.help` of an action that needs GitHub while the Mac is offline.
    static var offlineHelp: String {
        String(
            localized: "connectivity.offline.help",
            defaultValue: "Needs an internet connection. Your changes stay in the vault until you're back online."
        )
    }
}

/// The banner at the top of the main window: offline, or GitHub not responding with Retry.
struct ConnectivityBannerView: View {
    let banner: ConnectivityBannerModel
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: banner.systemImage)
                .foregroundStyle(Theme.Colors.warning)
                .accessibilityHidden(true)
            Text(banner.message)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .gitHubNotResponding(let isRetrying) = banner {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "connectivity.banner.retry", defaultValue: "Retry"), action: onRetry)
                    .disabled(isRetrying)
                    .help(String(
                        localized: "connectivity.banner.retry.help",
                        defaultValue: "List repositories and check the open repository on GitHub again"
                    ))
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.warning.opacity(Theme.Opacity.chipBackground))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    VStack(spacing: 0) {
        ConnectivityBannerView(banner: .offline) {}
        ConnectivityBannerView(banner: .gitHubNotResponding(isRetrying: false)) {}
        ConnectivityBannerView(banner: .gitHubNotResponding(isRetrying: true)) {}
    }
    .frame(width: Theme.Layout.windowDefaultWidth)
}
