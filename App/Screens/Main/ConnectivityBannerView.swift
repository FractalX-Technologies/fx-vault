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

/// The connectivity notice at the top of the detail column (mockup MainDark): the `.offline`
/// ``Banner`` with its OFFLINE label, or GitHub not responding with Retry.
struct ConnectivityBannerView: View {
    let banner: ConnectivityBannerModel
    let onRetry: () -> Void

    var body: some View {
        switch banner {
        case .offline:
            Banner(.offline, message: banner.message, systemImage: banner.systemImage)
        case .gitHubNotResponding(let isRetrying):
            Banner(
                .warning,
                message: banner.message,
                systemImage: banner.systemImage,
                action: .init(
                    title: isRetrying
                        ? String(localized: "connectivity.banner.retrying", defaultValue: "Retrying…")
                        : String(localized: "connectivity.banner.retry", defaultValue: "Retry"),
                    isEnabled: !isRetrying,
                    handler: onRetry
                )
            )
            .help(String(
                localized: "connectivity.banner.retry.help",
                defaultValue: "List repositories and check the open repository on GitHub again"
            ))
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.medium) {
        ConnectivityBannerView(banner: .offline) {}
        ConnectivityBannerView(banner: .gitHubNotResponding(isRetrying: false)) {}
        ConnectivityBannerView(banner: .gitHubNotResponding(isRetrying: true)) {}
    }
    .padding(Theme.Spacing.xxLarge)
    .frame(width: Theme.Layout.windowDefaultWidth)
    .background(Theme.Colors.ground)
}
