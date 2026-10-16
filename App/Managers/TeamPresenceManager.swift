import AppKit
import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Someone nearby, as a bubble in the main window's toolbar (v0.5.0, T5).
struct NearbyPersonModel: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A paired device, recognized by its pseudonym.
        case teammate(deviceID: String)
        /// Someone in Everyone nearby (or with Nearby Chat open): an advertised, unverified name.
        case stranger(serviceName: String)
    }

    let kind: Kind
    let name: String
    /// The teammate's Mac name, or nil.
    let macName: String?
    var lastSeenAt: Date

    var id: String {
        switch kind {
        case .teammate(let deviceID): "teammate-\(deviceID)"
        case .stranger(let serviceName): "nearby-\(serviceName)"
        }
    }

    var isTeammate: Bool {
        if case .teammate = kind { true } else { false }
    }

    /// One or two letters for the bubble.
    var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        let text = String(letters).uppercased()
        return text.isEmpty ? "?" : text
    }
}

/// The outcome of the last ping, shown under the bubbles for a few seconds.
enum PingFeedbackModel: Hashable {
    case sending(String)
    case delivered(String)
    case unreachable(String)
    case failed(String)

    var text: String {
        switch self {
        case .sending(let name): String(localized: "presence.ping.sending", defaultValue: "Pinging \(name)…")
        case .delivered(let name): String(localized: "presence.ping.delivered", defaultValue: "\(name) got your ping")
        case .unreachable(let name): String(localized: "presence.ping.unreachable", defaultValue: "\(name) is no longer nearby")
        case .failed(let name): String(localized: "presence.ping.failed", defaultValue: "Couldn't reach \(name)")
        }
    }
}

/// How the app starts a chat that did not begin in the chat window (v0.5.0, T7): from a bubble,
/// or a connection to this Mac's presence.
struct NearbyChatStartModel {
    let role: NearbyRole
    let transport: any NearbyTransport
    /// The name to show while connecting (unverified for strangers).
    let peerName: String?
    /// I opened the chat from this teammate's bubble: it proves itself, no code.
    let teammate: TeamCardModel?
    /// The chat came through teammate presence (a bubble, or a connection to the pseudonym):
    /// the window waits a moment for the teammate's proof before it shows the code.
    var expectsTeammate = false
    /// Send Folder… (v0.7.0): once the chat is verified, the attachment picker opens on this
    /// folder (Touch ID or the master password still comes first).
    var folderToSend: FolderID?
}

/// Teammates nearby (v0.5.0, tasks/todo.md T3–T8): presence, bubbles and pings.
///
/// - **Advertising** (T3, T4): while the vault is unlocked and visibility is Teammates or
///   Everyone nearby, this Mac advertises its pseudonym on `_fxvault-team._tcp`, renewed at every
///   15-minute window. Everyone nearby also advertises the display name on the chat service
///   while the Nearby Chat window does not.
/// - **Browsing** (T5, T8): only while the main window is visible and FX Vault is active. A
///   teammate is recognized by its pseudonym; in Everyone nearby, chat advertisers are listed as
///   strangers. A person leaves the bubbles ``Timeouts/presenceGrace`` after the last sighting.
/// - **Pings** (T6): to a teammate only, at most one per teammate every
///   ``Timeouts/pingCooldown``; incoming pings beyond ``Limits/pingsPerMinute`` per teammate are
///   dropped. Muted teammates (and Mute all) bounce their bubble without a sound.
/// - **Card updates**: a teammate whose stored card of this Mac is out of date (an announce key
///   renewed after a removal) gets the new card the next time it is seen.
/// - **Shared spaces** (v0.6.0, S6): connections for the spaces service go to
///   ``spacesConnectionHandler``, a teammate seen nearby is reported to ``teammateSeenHandler``,
///   and ``spacesTransport(to:)`` reaches a teammate for a spaces session.
/// - Everything stops and every key is dropped on lock.
@MainActor
@Observable
final class TeamPresenceManager: LockObserving {
    private(set) var people: [NearbyPersonModel] = []
    private(set) var feedback: PingFeedbackModel?
    /// The bubble that bounces because its person just pinged this Mac.
    private(set) var bouncingPersonID: String?
    /// Bumped by every ping that arrives (the bounce animation's trigger).
    private(set) var bounceCount = 0
    /// The bubble whose popover is open.
    var popoverPersonID: String?
    /// True while advertising or browsing runs.
    private(set) var isRunning = false
    /// Why presence cannot run (Local Network denied, a listener failure), or nil.
    private(set) var failure: NearbyTransportFailure?
    /// Answers a spaces session a teammate opened to this Mac's presence (v0.6.0).
    @ObservationIgnored var spacesConnectionHandler: ((any NearbyTransport) -> Void)?
    /// A teammate was seen nearby (its device id), at most once per sighting update.
    @ObservationIgnored var teammateSeenHandler: ((String) -> Void)?

    @ObservationIgnored private let team: TeamRepository
    @ObservationIgnored private let preferences: PreferencesManager
    @ObservationIgnored private let networking: any TeamPresenceNetworking
    @ObservationIgnored private let alerts: any PingAlerting
    @ObservationIgnored private let clock: any VaultClock
    @ObservationIgnored private let localLogin: () -> String
    @ObservationIgnored private let isAppActive: () -> Bool
    @ObservationIgnored private let startChat: (NearbyChatStartModel) -> Void
    @ObservationIgnored private let isChatWindowAdvertising: () -> Bool

    @ObservationIgnored private var keys: TeamDeviceKeys?
    @ObservationIgnored private var cards: [String: TeamCardModel] = [:]
    @ObservationIgnored private var teammates: [String: TeammateModel] = [:]
    @ObservationIgnored private var listener: (any TeamPresenceListening)?
    @ObservationIgnored private var teamDiscovery: (any NearbyPeerDiscovering)?
    @ObservationIgnored private var strangerDiscovery: (any NearbyPeerDiscovering)?
    @ObservationIgnored private var chatAdvertisement: NearbyChatAdvertisementModel?
    /// Everyone nearby: the advertised chat transport, handed to Nearby Chat once someone connects.
    @ObservationIgnored private var advertisedChat: WatchedTransport?
    @ObservationIgnored private var ownChatServiceName: String?
    @ObservationIgnored private var teamPeers: [String: SeenPeer] = [:]
    @ObservationIgnored private var strangers: [String: SeenPeer] = [:]
    @ObservationIgnored private var lastMarkedSeen: [String: Date] = [:]
    @ObservationIgnored private var lastCardUpdate: [String: Date] = [:]
    @ObservationIgnored private var outgoingPings: [String: Date] = [:]
    @ObservationIgnored private var incomingPings: [String: [Date]] = [:]
    @ObservationIgnored private var wantsBrowsing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let tasks = TaskBag()

    private struct SeenPeer {
        let peer: NearbyPeerModel
        var seenAt: Date
        var isListed: Bool
    }

    init(
        team: TeamRepository,
        preferences: PreferencesManager,
        networking: any TeamPresenceNetworking,
        alerts: any PingAlerting,
        clock: any VaultClock,
        localLogin: @escaping () -> String,
        isAppActive: @escaping () -> Bool,
        isChatWindowAdvertising: @escaping () -> Bool,
        startChat: @escaping (NearbyChatStartModel) -> Void
    ) {
        self.team = team
        self.preferences = preferences
        self.networking = networking
        self.alerts = alerts
        self.clock = clock
        self.localLogin = localLogin
        self.isAppActive = isAppActive
        self.isChatWindowAdvertising = isChatWindowAdvertising
        self.startChat = startChat
    }

    // MARK: - Lifecycle

    /// Starts presence after an unlock (and again when visibility changes). With visibility
    /// Nobody this Mac advertises nothing but still sees teammates who are visible.
    func start() {
        stop()
        do {
            keys = try team.deviceKeys()
            reloadCards()
        } catch {
            AppLog.ui.error("Teammate keys unavailable")
            return
        }
        isRunning = true
        failure = nil
        observeTeammates()
        if preferences.nearbyVisibility != .nobody {
            startAdvertising()
        }
        if preferences.nearbyVisibility == .everyone {
            advertiseChat()
        }
        if wantsBrowsing {
            startBrowsing()
        }
        startPruning()
    }

    /// Stops everything and forgets every key and person.
    func stop() {
        generation += 1
        tasks.cancelAll()
        listener?.stop()
        listener = nil
        stopBrowsing()
        chatAdvertisement?.transport.close()
        chatAdvertisement = nil
        advertisedChat = nil
        ownChatServiceName = nil
        keys = nil
        cards = [:]
        teamPeers = [:]
        strangers = [:]
        people = []
        popoverPersonID = nil
        bouncingPersonID = nil
        isRunning = false
    }

    func vaultDidLock() {
        stop()
        feedback = nil
    }

    /// Browse only while the main window is visible and FX Vault is active (T8).
    func setBrowsing(_ isWanted: Bool) {
        guard isWanted != wantsBrowsing else { return }
        wantsBrowsing = isWanted
        guard isRunning else { return }
        if isWanted {
            startBrowsing()
        } else {
            stopBrowsing()
            people = []
        }
    }

    /// The Nearby Chat window stopped or started advertising (Everyone nearby yields to it).
    func chatWindowAdvertisingChanged() {
        guard isRunning, preferences.nearbyVisibility == .everyone else { return }
        if isChatWindowAdvertising() {
            chatAdvertisement?.transport.close()
            chatAdvertisement = nil
            advertisedChat = nil
        } else if chatAdvertisement == nil {
            advertiseChat()
        }
    }

    // MARK: - Chat identity

    /// What a chat needs so a teammate can skip the code, or nil while locked or without keys.
    func chatIdentity(expecting teammate: TeamCardModel? = nil) -> TeamChatIdentityModel? {
        guard let keys else { return nil }
        return TeamChatIdentityModel(keys: keys, teammates: Array(cards.values), expectedPeer: teammate?.deviceID)
    }

    // MARK: - Actions (popover)

    /// Seconds before `person` can be pinged again, or 0.
    func pingCooldown(for person: NearbyPersonModel) -> TimeInterval {
        guard let last = outgoingPings[person.id] else { return 0 }
        return max(0, Timeouts.pingCooldown.timeInterval - clock.now.timeIntervalSince(last))
    }

    func canPing(_ person: NearbyPersonModel) -> Bool {
        person.isTeammate && pingCooldown(for: person) == 0
    }

    /// Pings a teammate: the paired handshake, a card update if it needs one, then PING.
    func ping(_ person: NearbyPersonModel) {
        guard case .teammate(let deviceID) = person.kind, canPing(person),
              let keys, let card = cards[deviceID]
        else { return }
        popoverPersonID = nil
        guard let peer = teamPeers[deviceID]?.peer, let transport = teamDiscovery?.connect(to: peer) else {
            show(.unreachable(person.name))
            return
        }
        outgoingPings[person.id] = clock.now
        show(.sending(person.name))
        var requests: [TeamRequest] = []
        if teammates[deviceID]?.needsCardUpdate == true {
            requests.append(.updateCard(localCard(keys)))
        }
        requests.append(.ping)
        let session = TeamSession.connect(to: card, keys: keys, requests: requests, transport: transport, clock: clock)
        let generation = generation
        tasks.set("ping-\(deviceID)", Task { [weak self] in
            try? await session.start()
            var delivered = false
            for await event in session.events {
                switch event {
                case .pingDelivered:
                    delivered = true
                case .cardUpdateDelivered:
                    try? self?.team.cardUpdateDelivered(to: deviceID)
                default:
                    break
                }
            }
            guard let self, self.generation == generation else { return }
            self.show(delivered ? .delivered(person.name) : .failed(person.name))
        })
    }

    /// Opens Nearby Chat with `person`: a teammate through its presence (no code), anyone else
    /// through the chat service (with the code). `folderToSend` (v0.7.0) opens the attachment
    /// picker on that folder once the chat is verified.
    func chat(with person: NearbyPersonModel, sendingFolder folderToSend: FolderID? = nil) {
        popoverPersonID = nil
        switch person.kind {
        case .teammate(let deviceID):
            guard let card = cards[deviceID], let peer = teamPeers[deviceID]?.peer,
                  let transport = teamDiscovery?.connect(to: peer)
            else {
                show(.unreachable(person.name))
                return
            }
            startChat(NearbyChatStartModel(
                role: .initiator,
                transport: PreambleTransport(base: transport, service: .chat),
                peerName: person.name,
                teammate: card,
                expectsTeammate: true,
                folderToSend: folderToSend
            ))
        case .stranger(let serviceName):
            guard let peer = strangers[serviceName]?.peer, let transport = strangerDiscovery?.connect(to: peer) else {
                show(.unreachable(person.name))
                return
            }
            startChat(NearbyChatStartModel(
                role: .initiator,
                transport: transport,
                peerName: person.name,
                teammate: nil,
                folderToSend: folderToSend
            ))
        }
    }

    // MARK: - Advertising

    private func startAdvertising() {
        guard let keys else { return }
        let listener = networking.makeListener()
        self.listener = listener
        listener.advertise(as: TeamPseudonym.name(for: keys, at: clock.now))
        let generation = generation
        let connections = listener.connections
        let failures = listener.failures
        tasks.set("connections", Task { [weak self] in
            for await transport in connections {
                guard let self, self.generation == generation else { return }
                self.handleIncoming(transport)
            }
        })
        tasks.set("listener-failures", Task { [weak self] in
            for await failure in failures {
                guard let self, self.generation == generation else { return }
                self.failure = failure
            }
        })
        scheduleRenewal()
    }

    /// Re-advertises under the next pseudonym at each window change.
    private func scheduleRenewal() {
        let clock = clock
        let generation = generation
        tasks.set("renewal", Task { [weak self] in
            while !Task.isCancelled {
                let next = TeamPseudonym.nextWindowStart(after: clock.now)
                let wait = max(1, next.timeIntervalSince(clock.now))
                do {
                    try await clock.sleep(for: .seconds(wait))
                } catch {
                    return
                }
                guard let self, self.generation == generation, let keys = self.keys else { return }
                self.listener?.advertise(as: TeamPseudonym.name(for: keys, at: clock.now))
            }
        })
    }

    /// Everyone nearby: the display name on the chat service; a connection opens Nearby Chat.
    private func advertiseChat() {
        guard !isChatWindowAdvertising() else { return }
        let name = ShareLocalIdentityModel.nearby(preferences: preferences).displayName
        let advertisement = networking.makeAdvertisement(purpose: .chat, displayName: name)
        chatAdvertisement = advertisement
        ownChatServiceName = advertisement.serviceName
        let generation = generation
        advertisedChat = WatchedTransport(base: advertisement.transport) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.someoneConnectedToChat()
            }
        }
    }

    /// Someone connected to the Everyone nearby advertisement: Nearby Chat runs the responder
    /// (it waits for the peer's HELLO, then shows the code), and this Mac advertises again.
    private func someoneConnectedToChat() {
        guard let advertisedChat else { return }
        self.advertisedChat = nil
        chatAdvertisement = nil
        startChat(NearbyChatStartModel(role: .responder, transport: advertisedChat, peerName: nil, teammate: nil))
        advertiseChat()
    }

    // MARK: - Incoming

    private func handleIncoming(_ transport: any NearbyTransport) {
        let clock = clock
        let generation = generation
        tasks.set("incoming-\(UUID().uuidString)", Task { [weak self] in
            guard let routed = await TeamRouter.route(transport, clock: clock) else { return }
            guard let self, self.generation == generation, let keys = self.keys else {
                routed.transport.close()
                return
            }
            switch routed.service {
            case .chat:
                self.startChat(NearbyChatStartModel(
                    role: .responder,
                    transport: routed.transport,
                    peerName: nil,
                    teammate: nil,
                    expectsTeammate: true
                ))
            case .spaces:
                guard let handler = self.spacesConnectionHandler else {
                    routed.transport.close()
                    return
                }
                handler(routed.transport)
            case .team:
                let session = TeamSession.answer(
                    keys: keys,
                    teammates: Array(self.cards.values),
                    transport: routed.transport,
                    clock: clock
                )
                try? await session.start()
                for await event in session.events {
                    switch event {
                    case .pinged(let card):
                        self.receivedPing(from: card)
                    case .cardUpdated(let card):
                        try? self.team.applyCardUpdate(card)
                    default:
                        break
                    }
                }
            }
        })
    }

    /// A ping arrived from `card` (internal for the rate-limit tests).
    func receivedPing(from card: TeamCardModel) {
        let id = card.deviceID.hex
        let now = clock.now
        var recent = (incomingPings[id] ?? []).filter { now.timeIntervalSince($0) < Double(Timeouts.secondsPerMinute) }
        guard recent.count < Limits.pingsPerMinute else { return }
        recent.append(now)
        incomingPings[id] = recent
        let person = NearbyPersonModel(kind: .teammate(deviceID: id), name: card.name, macName: card.macName, lastSeenAt: now)
        bounce(person.id)
        let isMuted = preferences.mutesAllPings || teammates[id]?.isMuted == true
        guard !isMuted else { return }
        alerts.alert(from: card.name, isAppActive: isAppActive())
    }

    private func bounce(_ personID: String) {
        bouncingPersonID = personID
        bounceCount += 1
        let clock = clock
        tasks.set("bounce", Task { [weak self] in
            try? await clock.sleep(for: Timeouts.pingBounce)
            guard !Task.isCancelled else { return }
            self?.bouncingPersonID = nil
        })
    }

    // MARK: - Browsing

    private func startBrowsing() {
        guard isRunning, teamDiscovery == nil else { return }
        let generation = generation
        let discovery = networking.makeDiscovery(purpose: .team)
        teamDiscovery = discovery
        let peers = discovery.peers
        tasks.set("team-peers", Task { [weak self] in
            for await found in peers {
                guard let self, self.generation == generation else { return }
                self.updateTeamPeers(found)
            }
        })
        discovery.start()
        guard preferences.nearbyVisibility == .everyone else { return }
        let strangers = networking.makeDiscovery(purpose: .chat)
        strangerDiscovery = strangers
        let strangerPeers = strangers.peers
        tasks.set("stranger-peers", Task { [weak self] in
            for await found in strangerPeers {
                guard let self, self.generation == generation else { return }
                self.updateStrangers(found)
            }
        })
        strangers.start()
    }

    private func stopBrowsing() {
        tasks.cancel("team-peers")
        tasks.cancel("stranger-peers")
        teamDiscovery?.stop()
        teamDiscovery = nil
        strangerDiscovery?.stop()
        strangerDiscovery = nil
    }

    private func updateTeamPeers(_ found: [NearbyPeerModel]) {
        let now = clock.now
        let matcher = TeamPresenceMatcher(teammates: Array(cards.values), at: now)
        for key in teamPeers.keys {
            teamPeers[key]?.isListed = false
        }
        for peer in found {
            guard let deviceID = matcher.teammate(advertising: peer.id)?.hex else { continue }
            teamPeers[deviceID] = SeenPeer(peer: peer, seenAt: now, isListed: true)
            noteSeen(deviceID, at: now)
            teammateSeenHandler?(deviceID)
        }
        rebuildPeople()
    }

    // MARK: - Shared spaces (v0.6.0)

    /// A started transport to teammate `deviceID`'s presence for a spaces session: through the
    /// running browser when it sees the teammate, otherwise a short browse of its own (at most
    /// ``Timeouts/spaceReachWait``). Nil when the teammate is not nearby or presence is off.
    func spacesTransport(to deviceID: String) async -> (any NearbyTransport)? {
        guard isRunning, let card = cards[deviceID] else { return nil }
        if let peer = teamPeers[deviceID]?.peer, let teamDiscovery {
            return teamDiscovery.connect(to: peer)
        }
        let discovery = networking.makeDiscovery(purpose: .team)
        let peers = discovery.peers
        let clock = clock
        discovery.start()
        defer { discovery.stop() }
        let found: NearbyPeerModel? = await withTaskGroup(of: NearbyPeerModel?.self) { group in
            group.addTask {
                for await listed in peers {
                    let matcher = TeamPresenceMatcher(teammates: [card], at: clock.now)
                    if let peer = listed.first(where: { matcher.teammate(advertising: $0.id) != nil }) {
                        return peer
                    }
                }
                return nil
            }
            group.addTask {
                try? await clock.sleep(for: Timeouts.spaceReachWait)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return found.flatMap { discovery.connect(to: $0) }
    }

    private func updateStrangers(_ found: [NearbyPeerModel]) {
        let now = clock.now
        for key in strangers.keys {
            strangers[key]?.isListed = false
        }
        for peer in found where peer.id != ownChatServiceName {
            strangers[peer.id] = SeenPeer(peer: peer, seenAt: now, isListed: true)
        }
        rebuildPeople()
    }

    /// Records the sighting at most once a minute, and hands a pending card update over.
    private func noteSeen(_ deviceID: String, at now: Date) {
        if now.timeIntervalSince(lastMarkedSeen[deviceID] ?? .distantPast) >= Timeouts.presenceSeenWrite.timeInterval {
            lastMarkedSeen[deviceID] = now
            try? team.markSeen(deviceID)
        }
        guard teammates[deviceID]?.needsCardUpdate == true,
              now.timeIntervalSince(lastCardUpdate[deviceID] ?? .distantPast) >= Timeouts.cardUpdateRetry.timeInterval,
              let keys, let card = cards[deviceID], let peer = teamPeers[deviceID]?.peer,
              let transport = teamDiscovery?.connect(to: peer)
        else { return }
        lastCardUpdate[deviceID] = now
        let session = TeamSession.connect(
            to: card,
            keys: keys,
            requests: [.updateCard(localCard(keys))],
            transport: transport,
            clock: clock
        )
        tasks.set("card-\(deviceID)", Task { [weak self] in
            try? await session.start()
            for await event in session.events where event == .cardUpdateDelivered {
                try? self?.team.cardUpdateDelivered(to: deviceID)
            }
        })
    }

    /// Drops people not seen for ``Timeouts/presenceGrace`` every few seconds.
    private func startPruning() {
        let clock = clock
        let generation = generation
        tasks.set("prune", Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Timeouts.presencePrune)
                } catch {
                    return
                }
                guard let self, self.generation == generation else { return }
                self.rebuildPeople()
            }
        })
    }

    private func rebuildPeople() {
        let now = clock.now
        let grace = Timeouts.presenceGrace.timeInterval
        teamPeers = teamPeers.filter { $0.value.isListed || now.timeIntervalSince($0.value.seenAt) < grace }
        strangers = strangers.filter { $0.value.isListed || now.timeIntervalSince($0.value.seenAt) < grace }
        var result: [NearbyPersonModel] = teamPeers.compactMap { deviceID, seen in
            guard let card = cards[deviceID] else { return nil }
            return NearbyPersonModel(kind: .teammate(deviceID: deviceID), name: card.name, macName: card.macName, lastSeenAt: seen.seenAt)
        }
        result += strangers.map { serviceName, seen in
            NearbyPersonModel(
                kind: .stranger(serviceName: serviceName),
                name: seen.peer.chatDisplayName,
                macName: nil,
                lastSeenAt: seen.seenAt
            )
        }
        result.sort { lhs, rhs in
            if lhs.isTeammate != rhs.isTeammate { return lhs.isTeammate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if result.map(\.id) != people.map(\.id) || result.map(\.name) != people.map(\.name) {
            people = result
        }
        if let popoverPersonID, !people.contains(where: { $0.id == popoverPersonID }) {
            self.popoverPersonID = nil
        }
    }

    // MARK: - Teammates

    private func observeTeammates() {
        let stream = team.observeTeammates()
        let generation = generation
        tasks.set("teammates", Task { [weak self] in
            do {
                for try await models in stream {
                    guard let self, self.generation == generation else { return }
                    self.teammates = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    if Set(models.map(\.id)) != Set(self.cards.keys) {
                        self.reloadCards()
                        self.rebuildPeople()
                    }
                }
            } catch {
                return
            }
        })
    }

    private func reloadCards() {
        let loaded = (try? team.teammateCards()) ?? []
        cards = Dictionary(loaded.map { ($0.deviceID.hex, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func localCard(_ keys: TeamDeviceKeys) -> TeamCardModel {
        let identity = SpaceLocalIdentityModel.local(login: localLogin(), preferences: preferences)
        return keys.card(login: identity.login, displayName: identity.displayName, macName: identity.macName)
    }

    private func show(_ feedback: PingFeedbackModel) {
        self.feedback = feedback
        let clock = clock
        tasks.set("feedback", Task { [weak self] in
            try? await clock.sleep(for: Timeouts.pingFeedback)
            guard !Task.isCancelled, self?.feedback == feedback else { return }
            self?.feedback = nil
        })
    }
}

extension Timeouts {
    /// A person leaves the bubbles this long after the last sighting (T5).
    static let presenceGrace: Duration = .seconds(30)
    /// How often stale people are dropped.
    static let presencePrune: Duration = .seconds(5)
    /// `last_seen_at` is written at most this often per teammate.
    static let presenceSeenWrite: Duration = .seconds(60)
    /// A teammate can be pinged again after this long (T6).
    static let pingCooldown: Duration = .seconds(10)
    /// How long a bubble bounces after its ping arrived.
    static let pingBounce: Duration = .seconds(2)
    /// How long the ping outcome stays under the bubbles.
    static let pingFeedback: Duration = .seconds(4)
    /// A failed card update is tried again after this long.
    static let cardUpdateRetry: Duration = .seconds(5 * 60)
    /// How long a spaces session waits to find a teammate nearby when this Mac is not browsing.
    static let spaceReachWait: Duration = .seconds(10)
}

extension Limits {
    /// Pings accepted from one teammate per minute; more are dropped (T6).
    static let pingsPerMinute = 5
}
