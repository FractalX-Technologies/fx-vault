import SharingKit

nonisolated extension NearbyTransportFailure {
    var presentation: ErrorPresentationModel {
        switch self {
        case .localNetworkDenied:
            ErrorPresentationModel(
                title: String(localized: "share.nearby.denied.title", defaultValue: "Local network access is off"),
                message: String(
                    localized: "share.nearby.denied.message",
                    defaultValue: "Turn on FX Vault in System Settings › Privacy & Security › Local Network, then try again."
                )
            )
        case .notConnected, .closed, .oversizeFrame, .malformedFrame, .connectionFailed:
            ErrorPresentationModel(
                title: String(localized: "share.nearby.connection.title", defaultValue: "Connection failed"),
                message: String(
                    localized: "share.nearby.connection.message",
                    defaultValue: "The connection to the other Mac failed. Keep both Macs close together with Wi-Fi turned on, then try again."
                )
            )
        }
    }
}
