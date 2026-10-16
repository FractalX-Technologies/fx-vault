import Foundation
import os
import SharingKit
@testable import FXVault

/// One end of a test link: frames go straight to the other end once ``TestLink/connect()`` ran.
final class TestLinkEnd: NearbyTransport, @unchecked Sendable {
    let events: AsyncStream<NearbyTransportEvent>
    private let continuation: AsyncStream<NearbyTransportEvent>.Continuation
    private let lock = NSLock()
    private weak var peer: TestLinkEnd?
    private var isClosed = false
    private var isConnected = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
    }

    func link(to peer: TestLinkEnd) {
        lock.withLock { self.peer = peer }
    }

    func markConnected() {
        let isNew = lock.withLock { () -> Bool in
            guard !isConnected, !isClosed else { return false }
            isConnected = true
            return true
        }
        if isNew {
            continuation.yield(.connected)
        }
    }

    func send(_ frame: Data) async throws(ShareError) {
        let (closed, connected, peer) = lock.withLock { (isClosed, isConnected, self.peer) }
        guard !closed else { throw .transport(.closed) }
        guard connected, let peer else { throw .transport(.notConnected) }
        peer.deliver(.received(frame))
    }

    func close() {
        let peer = lock.withLock { () -> TestLinkEnd? in
            guard !isClosed else { return nil }
            isClosed = true
            return self.peer
        }
        continuation.yield(.disconnected)
        continuation.finish()
        peer?.peerClosed()
    }

    private func deliver(_ event: NearbyTransportEvent) {
        guard !lock.withLock({ isClosed }) else { return }
        continuation.yield(event)
    }

    private func peerClosed() {
        let wasOpen = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard wasOpen else { return }
        continuation.yield(.disconnected)
        continuation.finish()
    }
}

/// Two ends that report `.connected` only when someone connects (an advertisement waits).
struct TestLink {
    let listening = TestLinkEnd()
    let connecting = TestLinkEnd()

    init() {
        listening.link(to: connecting)
        connecting.link(to: listening)
    }

    /// Someone connected: both ends report `.connected`.
    func connect() -> TestLinkEnd {
        listening.markConnected()
        connecting.markConnected()
        return connecting
    }
}

/// A nearby network shared by several test Macs: advertisements by purpose and name, presence
/// listeners by pseudonym, and browsers that list them.
@MainActor
final class FakeNearbyNetwork {
    struct Advertisement {
        let purpose: NearbyPurpose
        let name: String
        let link: TestLink
        let owner: String
    }

    private(set) var advertisements: [Advertisement] = []
    private(set) var listeners: [String: FakeTeamListener] = [:]
    private var discoveries: [(purpose: NearbyPurpose, owner: String, discovery: FakePeerDiscovery)] = []

    func networking(for owner: String) -> FakeTeamNetworking {
        FakeTeamNetworking(network: self, owner: owner)
    }

    func register(_ listener: FakeTeamListener) {
        listeners[listener.owner] = listener
        publish()
    }

    func advertise(_ purpose: NearbyPurpose, name: String, owner: String) -> TestLinkEnd {
        let link = TestLink()
        advertisements.removeAll { $0.purpose == purpose && $0.owner == owner }
        advertisements.append(Advertisement(purpose: purpose, name: name, link: link, owner: owner))
        publish()
        return link.listening
    }

    func add(_ discovery: FakePeerDiscovery, purpose: NearbyPurpose, owner: String) {
        discoveries.append((purpose, owner, discovery))
    }

    /// Sends every browser the names on its service (its own Mac included, as Bonjour does).
    func publish() {
        for entry in discoveries {
            let names: [String] = switch entry.purpose {
            case .team: listeners.values.compactMap(\.serviceName)
            default: advertisements.filter { $0.purpose == entry.purpose }.map(\.name)
            }
            entry.discovery.publish(names.sorted().map { NearbyPeerModel(id: $0) })
        }
    }

    /// A connection to the peer advertised as `name` on `purpose`.
    func connect(purpose: NearbyPurpose, name: String) -> (any NearbyTransport)? {
        if purpose == .team {
            guard let listener = listeners.values.first(where: { $0.serviceName == name }) else { return nil }
            let link = TestLink()
            let incoming = link.listening
            let outgoing = link.connect()
            listener.accept(incoming)
            return outgoing
        }
        guard let index = advertisements.firstIndex(where: { $0.purpose == purpose && $0.name == name }) else { return nil }
        let advertisement = advertisements.remove(at: index)
        publish()
        return advertisement.link.connect()
    }
}

@MainActor
final class FakeTeamNetworking: TeamPresenceNetworking {
    private let network: FakeNearbyNetwork
    let owner: String

    init(network: FakeNearbyNetwork, owner: String) {
        self.network = network
        self.owner = owner
    }

    func makeListener() -> any TeamPresenceListening {
        let listener = FakeTeamListener(owner: owner, network: network)
        return listener
    }

    func makeDiscovery(purpose: NearbyPurpose) -> any NearbyPeerDiscovering {
        let discovery = FakePeerDiscovery(purpose: purpose, network: network)
        network.add(discovery, purpose: purpose, owner: owner)
        return discovery
    }

    func makeAdvertisement(purpose: NearbyPurpose, displayName: String) -> NearbyChatAdvertisementModel {
        let transport = network.advertise(purpose, name: displayName, owner: owner)
        return NearbyChatAdvertisementModel(transport: transport, serviceName: displayName)
    }
}

@MainActor
final class FakeTeamListener: TeamPresenceListening {
    let owner: String
    let connections: AsyncStream<any NearbyTransport>
    let failures = AsyncStream<NearbyTransportFailure> { _ in }
    private(set) var serviceName: String?
    private(set) var advertisedNames: [String] = []
    private let continuation: AsyncStream<any NearbyTransport>.Continuation
    private weak var network: FakeNearbyNetwork?

    init(owner: String, network: FakeNearbyNetwork) {
        self.owner = owner
        self.network = network
        (connections, continuation) = AsyncStream.makeStream(of: (any NearbyTransport).self)
    }

    func advertise(as serviceName: String) {
        self.serviceName = serviceName
        advertisedNames.append(serviceName)
        network?.register(self)
    }

    func stop() {
        serviceName = nil
        continuation.finish()
        network?.publish()
    }

    func accept(_ transport: any NearbyTransport) {
        continuation.yield(transport)
    }
}

@MainActor
final class FakePeerDiscovery: NearbyPeerDiscovering {
    let purpose: NearbyPurpose
    let peers: AsyncStream<[NearbyPeerModel]>
    let failures = AsyncStream<NearbyTransportFailure> { _ in }
    private let continuation: AsyncStream<[NearbyPeerModel]>.Continuation
    private weak var network: FakeNearbyNetwork?
    private var isStarted = false

    init(purpose: NearbyPurpose, network: FakeNearbyNetwork) {
        self.purpose = purpose
        self.network = network
        (peers, continuation) = AsyncStream.makeStream(of: [NearbyPeerModel].self)
    }

    func start() {
        isStarted = true
        network?.publish()
    }

    func stop() {
        isStarted = false
        continuation.finish()
    }

    func publish(_ found: [NearbyPeerModel]) {
        guard isStarted else { return }
        continuation.yield(found)
    }

    func connect(to peer: NearbyPeerModel) -> (any NearbyTransport)? {
        network?.connect(purpose: purpose, name: peer.id)
    }
}
