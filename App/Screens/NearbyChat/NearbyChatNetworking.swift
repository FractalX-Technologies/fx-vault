import Foundation
import SharingKit
import VaultCore

/// What this Mac advertises while the Nearby Chat window is open.
struct NearbyChatAdvertisementModel {
    /// A started responder transport; it accepts one connection, then stops advertising.
    /// Closing it stops advertising at once.
    let transport: any NearbyTransport
    /// The requested Bonjour instance name, so the window can leave this Mac out of its own
    /// people list. Nil when unknown.
    let serviceName: String?
    /// The name the system actually registered, which replaces ``serviceName`` for that filter:
    /// on a conflict Bonjour renames one advertiser ("Bob's Mac (2)"), and a nearby Mac that
    /// advertises this user's name must then stay visible in the list.
    let registeredNames: AsyncStream<String>

    init(
        transport: any NearbyTransport,
        serviceName: String?,
        registeredNames: AsyncStream<String> = AsyncStream { $0.finish() }
    ) {
        self.transport = transport
        self.serviceName = serviceName
        self.registeredNames = registeredNames
    }
}

/// The network the Nearby Chat window uses: Bonjour/TCP over the local network and
/// peer-to-peer Wi-Fi in the app (`_fxvault-chat._tcp`), in-memory in tests.
protocol NearbyChatNetworking {
    /// A new browser for chat peers. A peer's id is its advertised (unverified) display name.
    func makeDiscovery() -> any NearbyPeerDiscovering
    /// A started advertisement under `displayName` (sanitized by SharingKit).
    func makeAdvertisement(displayName: String) -> NearbyChatAdvertisementModel
}

/// `NWNearbyBrowser(purpose: .chat)` and `NWNearbyTransport.advertisingChat(displayName:)`.
struct LiveNearbyChatNetworking: NearbyChatNetworking {
    func makeDiscovery() -> any NearbyPeerDiscovering {
        LiveNearbyDiscovery(purpose: .chat)
    }

    func makeAdvertisement(displayName: String) -> NearbyChatAdvertisementModel {
        let transport = NWNearbyTransport.advertisingChat(displayName: displayName)
        transport.start()
        return NearbyChatAdvertisementModel(
            transport: transport,
            serviceName: transport.serviceName,
            registeredNames: transport.registeredServiceNames
        )
    }
}

extension NearbyPeerModel {
    /// The name a chat peer advertises (sanitized). Unverified: anyone can advertise any name;
    /// only the code proves who it is.
    var chatDisplayName: String {
        let name = DisplayNameSanitizer.sanitize(id)
        return name.isEmpty ? shortLabel : name
    }
}
