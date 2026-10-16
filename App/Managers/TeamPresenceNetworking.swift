import Foundation
import SharingKit

/// The presence advertisement of this Mac (v0.5.0, T3): accepted connections and failures.
protocol TeamPresenceListening: AnyObject {
    var connections: AsyncStream<any NearbyTransport> { get }
    var failures: AsyncStream<NearbyTransportFailure> { get }
    /// Advertises under `serviceName` (a pseudonym), replacing the current one.
    func advertise(as serviceName: String)
    func stop()
}

/// The network presence uses: Bonjour/TCP in the app, nothing in previews and tests.
protocol TeamPresenceNetworking {
    func makeListener() -> any TeamPresenceListening
    /// A browser for `purpose`: `.team` (teammates' pseudonyms), `.chat` (people in Everyone
    /// nearby or with Nearby Chat open) or `.pair` (Add Teammate).
    func makeDiscovery(purpose: NearbyPurpose) -> any NearbyPeerDiscovering
    /// A started advertisement under `displayName` for `purpose` (`.chat` in Everyone nearby,
    /// `.pair` while Add Teammate is open). It accepts one connection.
    func makeAdvertisement(purpose: NearbyPurpose, displayName: String) -> NearbyChatAdvertisementModel
}

/// `NWTeamListener`, `NWNearbyBrowser` and `NWNearbyTransport`.
struct LiveTeamPresenceNetworking: TeamPresenceNetworking {
    func makeListener() -> any TeamPresenceListening {
        LiveTeamListener()
    }

    func makeDiscovery(purpose: NearbyPurpose) -> any NearbyPeerDiscovering {
        LiveNearbyDiscovery(purpose: purpose)
    }

    func makeAdvertisement(purpose: NearbyPurpose, displayName: String) -> NearbyChatAdvertisementModel {
        let transport = NWNearbyTransport.advertising(purpose: purpose, displayName: displayName)
        transport.start()
        return NearbyChatAdvertisementModel(
            transport: transport,
            serviceName: transport.serviceName,
            registeredNames: transport.registeredServiceNames
        )
    }
}

/// `NWTeamListener` behind ``TeamPresenceListening``.
final class LiveTeamListener: TeamPresenceListening {
    private let listener = NWTeamListener()

    var connections: AsyncStream<any NearbyTransport> {
        listener.connections
    }

    var failures: AsyncStream<NearbyTransportFailure> {
        listener.failures
    }

    func advertise(as serviceName: String) {
        listener.advertise(as: serviceName)
    }

    func stop() {
        listener.stop()
    }
}

/// No network at all (previews and the test host; tests inject their own).
struct InertTeamPresenceNetworking: TeamPresenceNetworking {
    func makeListener() -> any TeamPresenceListening {
        InertTeamListener()
    }

    func makeDiscovery(purpose: NearbyPurpose) -> any NearbyPeerDiscovering {
        InertPeerDiscovery()
    }

    func makeAdvertisement(purpose: NearbyPurpose, displayName: String) -> NearbyChatAdvertisementModel {
        NearbyChatAdvertisementModel(transport: InMemoryTransportPair().responder, serviceName: nil)
    }
}

final class InertTeamListener: TeamPresenceListening {
    let connections = AsyncStream<any NearbyTransport> { $0.finish() }
    let failures = AsyncStream<NearbyTransportFailure> { $0.finish() }

    func advertise(as serviceName: String) {}

    func stop() {}
}

final class InertPeerDiscovery: NearbyPeerDiscovering {
    let peers = AsyncStream<[NearbyPeerModel]> { $0.finish() }
    let failures = AsyncStream<NearbyTransportFailure> { $0.finish() }

    func start() {}

    func stop() {}

    func connect(to peer: NearbyPeerModel) -> (any NearbyTransport)? {
        nil
    }
}
