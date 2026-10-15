import Foundation
import SharingKit

/// A receiver found nearby. The Bonjour instance name is random per session and means nothing
/// to people (§9.4); the peer's display name arrives in the handshake and is shown with the code.
struct NearbyPeerModel: Identifiable, Hashable {
    let id: String

    /// A short, stable label to tell two receivers apart ("Mac ab12").
    var shortLabel: String {
        String(localized: "nearby.peer.label", defaultValue: "Mac \(String(id.suffix(Self.suffixLength)))")
    }

    private static let suffixLength = 4
}

/// Browsing for receivers on the sender side (§9.4: I browses and connects).
protocol NearbyPeerDiscovering: AnyObject {
    /// The current receivers; finishes when browsing stops or fails.
    var peers: AsyncStream<[NearbyPeerModel]> { get }
    /// `.localNetworkDenied` or `.connectionFailed`, then finishes.
    var failures: AsyncStream<NearbyTransportFailure> { get }
    func start()
    func stop()
    /// A started transport to `peer` (one connection, one session), or nil when the peer is
    /// gone.
    func connect(to peer: NearbyPeerModel) -> (any NearbyTransport)?
}

/// The network the nearby sheets use: Bonjour/TCP in the app (D22), in-memory in tests.
protocol NearbyNetworking {
    /// A new browser for one "Share Nearby" sheet.
    func makeDiscovery() -> any NearbyPeerDiscovering
    /// A started receiver transport that advertises under a fresh random name and accepts one
    /// connection. Closing it stops advertising (§9.4: only while "Receive Nearby" is open).
    func makeAdvertisingTransport() -> any NearbyTransport
}

/// `NWNearbyBrowser` and `NWNearbyTransport` (Network framework, local network only).
struct LiveNearbyNetworking: NearbyNetworking {
    func makeDiscovery() -> any NearbyPeerDiscovering {
        LiveNearbyDiscovery()
    }

    func makeAdvertisingTransport() -> any NearbyTransport {
        let transport = NWNearbyTransport.advertising()
        transport.start()
        return transport
    }
}

/// Wraps `NWNearbyBrowser`, keeping the endpoints the peer models stand for.
final class LiveNearbyDiscovery: NearbyPeerDiscovering {
    let peers: AsyncStream<[NearbyPeerModel]>
    let failures: AsyncStream<NearbyTransportFailure>

    private let peersContinuation: AsyncStream<[NearbyPeerModel]>.Continuation
    private let failuresContinuation: AsyncStream<NearbyTransportFailure>.Continuation
    private let browser = NWNearbyBrowser()
    private var endpoints: [String: NearbyEndpointModel] = [:]
    private var tasks: [Task<Void, Never>] = []

    init() {
        (peers, peersContinuation) = AsyncStream.makeStream(of: [NearbyPeerModel].self)
        (failures, failuresContinuation) = AsyncStream.makeStream(of: NearbyTransportFailure.self)
    }

    func start() {
        guard tasks.isEmpty else { return }
        let results = browser.results
        let failures = browser.failures
        tasks.append(Task { [weak self] in
            for await endpoints in results {
                self?.publish(endpoints)
            }
            self?.peersContinuation.finish()
        })
        tasks.append(Task { [weak self] in
            for await failure in failures {
                self?.failuresContinuation.yield(failure)
            }
            self?.failuresContinuation.finish()
        })
        browser.start()
    }

    /// Stops browsing; both streams finish. The owner calls it when the sheet closes.
    func stop() {
        browser.stop()
    }

    func connect(to peer: NearbyPeerModel) -> (any NearbyTransport)? {
        guard let endpoint = endpoints[peer.id] else { return nil }
        let transport = NWNearbyTransport.connecting(to: endpoint)
        transport.start()
        return transport
    }

    private func publish(_ found: [NearbyEndpointModel]) {
        endpoints = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        peersContinuation.yield(found.map { NearbyPeerModel(id: $0.id) })
    }
}
