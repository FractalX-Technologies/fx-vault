import SwiftUI

/// What the strip under the main window's toolbar panel says (v0.2.0; 1.0 board Main2-Offline).
/// Offline wins over GitHub.
enum ConnectivityBannerModel: Equatable {
    /// The system reports no usable route.
    case offline
    /// gh calls could not reach GitHub although the Mac is online.
    case gitHubNotResponding(isRetrying: Bool)

    /// The strip's semibold first words (board Main2-Offline).
    var title: String {
        switch self {
        case .offline:
            String(localized: "connectivity.banner.offline.title", defaultValue: "Offline")
        case .gitHubNotResponding:
            String(localized: "connectivity.banner.github.title", defaultValue: "GitHub isn't responding")
        }
    }

    /// What waits and what doesn't, after the title.
    var detail: String {
        switch self {
        case .offline:
            String(
                localized: "connectivity.banner.offline.detail",
                defaultValue: "edits stay in the vault; Sync, import and drift checks wait"
            )
        case .gitHubNotResponding:
            String(localized: "connectivity.banner.github.detail", defaultValue: "edits stay in the vault; try again in a moment")
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

/// The connectivity notice under the toolbar panel (board Main2-Offline), as a
/// ``MainStatusStrip``: offline, or GitHub not responding with Retry. Offline has no Retry (the
/// board's): the connection is watched, and its return re-checks GitHub by itself.
struct ConnectivityBannerView: View {
    let banner: ConnectivityBannerModel
    let onRetry: () -> Void

    var body: some View {
        switch banner {
        case .offline:
            MainStatusStrip(systemImage: banner.systemImage, title: banner.title, detail: banner.detail)
        case .gitHubNotResponding(let isRetrying):
            MainStatusStrip(
                systemImage: banner.systemImage,
                title: banner.title,
                detail: banner.detail,
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
