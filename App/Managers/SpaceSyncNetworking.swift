import Foundation
import SharingKit

/// The remote space listener (v0.6.0, Q4) behind a protocol, for tests.
protocol SpaceRemoteListening: AnyObject {
    var connections: AsyncStream<RemoteSpaceConnectionModel> { get }
    var failures: AsyncStream<NearbyTransportFailure> { get }
    func start()
    func stop()
    /// A session from this listener failed (counts toward the backoff).
    func recordFailedSession()
}

/// The network of space sync outside the local network: a listener on one port, and outgoing
/// connections to the addresses typed for teammates. Nearby sessions go through presence.
protocol SpaceRemoteNetworking {
    func makeListener(port: UInt16) -> any SpaceRemoteListening
    /// A started transport to `address`, or nil when it cannot be built.
    func connect(to address: TeamRemoteAddressModel) -> (any NearbyTransport)?
}

extension NWSpaceListener: SpaceRemoteListening {}

/// `NWSpaceListener` and `NWNearbyTransport`.
struct LiveSpaceRemoteNetworking: SpaceRemoteNetworking {
    func makeListener(port: UInt16) -> any SpaceRemoteListening {
        NWSpaceListener(port: port)
    }

    func connect(to address: TeamRemoteAddressModel) -> (any NearbyTransport)? {
        guard let endpoint = address.endpoint else { return nil }
        let transport = NWNearbyTransport.connecting(to: endpoint)
        transport.start()
        return transport
    }
}

/// No network at all (previews and the test host; tests inject their own).
struct InertSpaceRemoteNetworking: SpaceRemoteNetworking {
    func makeListener(port: UInt16) -> any SpaceRemoteListening {
        InertSpaceListener()
    }

    func connect(to address: TeamRemoteAddressModel) -> (any NearbyTransport)? {
        nil
    }
}

final class InertSpaceListener: SpaceRemoteListening {
    let connections = AsyncStream<RemoteSpaceConnectionModel> { $0.finish() }
    let failures = AsyncStream<NearbyTransportFailure> { $0.finish() }

    func start() {}

    func stop() {}

    func recordFailedSession() {}
}
