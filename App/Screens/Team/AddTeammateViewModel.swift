import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Add Teammate (v0.5.0, T2): both people open this sheet on their Macs. Each Mac advertises
/// its display name on `_fxvault-pair._tcp` only while the sheet is open and lists the others;
/// one chooses the other, both compare the 6-digit code, and the two Macs exchange signed
/// teammate cards. From then on they recognize each other nearby without a code.
@Observable
final class AddTeammateViewModel: Identifiable {
    enum Step: Equatable {
        /// Visible as ``displayName`` and listing people with Add Teammate open.
        case browsing
        case connecting(peerName: String?)
        case comparing(NearbySASModel)
        /// Paired with this teammate (stored).
        case paired(String)
        case failed(String)
    }

    let id = UUID()
    private(set) var step: Step = .browsing
    private(set) var peers: [NearbyPeerModel] = []
    private(set) var displayName = ""
    private(set) var isCodeConfirmed = false
    private(set) var isPeerCodeConfirmed = false
    private(set) var discoveryError: ErrorPresentationModel?

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private var keys: TeamDeviceKeys?
    @ObservationIgnored private var card: TeamCardModel?
    @ObservationIgnored private var discovery: (any NearbyPeerDiscovering)?
    @ObservationIgnored private var session: TeamPairingSession?
    @ObservationIgnored private var ownServiceName: String?
    @ObservationIgnored private var discoveredPeers: [NearbyPeerModel] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let tasks = TaskBag()

    init(app: AppViewModel) {
        self.app = app
    }

    private var networking: any TeamPresenceNetworking {
        app.container.teamNetworking
    }

    /// Opens the sheet: advertises and lists people.
    func start() async {
        close()
        do {
            let keys = try app.container.data.team.deviceKeys()
            self.keys = keys
            displayName = ShareLocalIdentityModel.nearby(preferences: app.container.preferences).displayName
            card = keys.card(login: app.primaryLogin, displayName: displayName, macName: Host.current().localizedName ?? "")
        } catch {
            step = .failed(error.presentation.message)
            return
        }
        step = .browsing
        startDiscovery()
        advertise()
    }

    /// Connects to `peer` (this Mac is the initiator).
    func pair(with peer: NearbyPeerModel) {
        guard step == .browsing, let discovery, let transport = discovery.connect(to: peer) else { return }
        stopAdvertisingAndBrowsing()
        step = .connecting(peerName: peer.chatDisplayName)
        run(role: .initiator, transport: transport)
    }

    func decide(_ decision: SASDecision) {
        guard case .comparing = step, let session, !isCodeConfirmed else { return }
        if decision == .match {
            isCodeConfirmed = true
        }
        Task {
            switch decision {
            case .match: try? await session.confirmSAS()
            case .mismatch: try? await session.rejectSAS()
            }
        }
    }

    /// "Try Again" after a failure.
    func restart() async {
        await start()
    }

    /// Closes the sheet: cancels any pairing and stops advertising and browsing.
    func close() {
        generation += 1
        tasks.cancelAll()
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        stopAdvertisingAndBrowsing()
        keys = nil
        card = nil
        isCodeConfirmed = false
        isPeerCodeConfirmed = false
    }

    // MARK: - Private

    private func startDiscovery() {
        let discovery = networking.makeDiscovery(purpose: .pair)
        self.discovery = discovery
        let generation = generation
        let peers = discovery.peers
        let failures = discovery.failures
        tasks.set("peers", Task { [weak self] in
            for await found in peers {
                guard let self, self.generation == generation else { return }
                self.discoveredPeers = found
                self.peers = found.filter { $0.id != self.ownServiceName }
            }
        })
        tasks.set("failures", Task { [weak self] in
            for await failure in failures {
                guard let self, self.generation == generation else { return }
                self.discoveryError = failure.presentation
            }
        })
        discovery.start()
    }

    /// Advertises under the display name; whoever connects starts the pairing (responder).
    private func advertise() {
        let advertisement = networking.makeAdvertisement(purpose: .pair, displayName: displayName)
        ownServiceName = advertisement.serviceName
        let generation = generation
        let registered = advertisement.registeredNames
        tasks.set("registration", Task { [weak self] in
            for await name in registered {
                guard let self, self.generation == generation else { return }
                self.ownServiceName = name
                self.peers = self.discoveredPeers.filter { $0.id != name }
            }
        })
        run(role: .responder, transport: advertisement.transport)
    }

    private func stopAdvertisingAndBrowsing() {
        tasks.cancel("peers")
        tasks.cancel("failures")
        tasks.cancel("registration")
        discovery?.stop()
        discovery = nil
        peers = []
        discoveredPeers = []
        if step == .browsing, let session {
            // The responder session that waited for someone: replaced by the initiator's.
            self.session = nil
            Task { await session.cancel() }
        }
    }

    private func run(role: NearbyRole, transport: any NearbyTransport) {
        guard let keys, let card else { return }
        let session = TeamPairingSession(
            role: role,
            localName: displayName,
            keys: keys,
            card: card,
            transport: transport,
            clock: app.container.clock
        )
        self.session = session
        let generation = generation
        tasks.set("pairing", Task { [weak self] in
            try? await session.start()
            for await event in session.events {
                guard let self, self.generation == generation else { return }
                self.handle(event)
            }
        })
    }

    private func handle(_ event: TeamPairingEvent) {
        switch event {
        case .incomingConnection:
            tasks.cancel("peers")
            tasks.cancel("failures")
            tasks.cancel("registration")
            discovery?.stop()
            discovery = nil
            peers = []
            step = .connecting(peerName: nil)
        case .sasReady(let sas):
            isCodeConfirmed = false
            isPeerCodeConfirmed = false
            step = .comparing(sas)
        case .peerConfirmedSAS:
            isPeerCodeConfirmed = true
        case .paired(let teammate):
            do {
                try app.container.data.team.addTeammate(teammate)
                app.teamPresence.start()
                step = .paired(teammate.name)
            } catch {
                step = .failed(error.presentation.message)
            }
            session = nil
        case .aborted(let abort):
            session = nil
            step = .failed(abort.pairingMessage)
        }
    }
}

extension NearbyAbortModel {
    /// What a failed Add Teammate shows.
    nonisolated var pairingMessage: String {
        switch reason {
        case .sasRejected, .peerAborted(.sasRejected):
            String(localized: "teammates.add.abort.mismatch", defaultValue: "The codes didn't match, so nobody was added.")
        case .cancelled, .peerAborted(.cancelled):
            String(localized: "teammates.add.abort.cancelled", defaultValue: "The other person cancelled. Nobody was added.")
        case .timeout, .peerAborted(.timeout):
            String(localized: "teammates.add.abort.timeout", defaultValue: "The codes were not confirmed in time. Nobody was added.")
        case .disconnected:
            String(localized: "teammates.add.abort.disconnected", defaultValue: "The other Mac disconnected. Nobody was added.")
        case .teammateNotRecognized:
            String(localized: "teammates.add.abort.self", defaultValue: "That is this Mac. Choose someone else's Mac.")
        default:
            String(
                localized: "teammates.add.abort.security",
                defaultValue: "The connection could not be verified, so nobody was added. Try again."
            )
        }
    }
}
