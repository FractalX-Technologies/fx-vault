import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// What one teammate's versions did here, for the notice under the bubbles and the Sync sheet.
struct SpaceSyncNoticeModel: Hashable, Identifiable {
    let id = UUID()
    let spaceID: SpaceID
    let version: Int64
    let teammateName: String
    /// Items with a local draft the teammate also changed (the draft stays on top).
    let conflictNames: [String]

    var text: String {
        conflictNames.isEmpty
            ? String(localized: "spaces.sync.received", defaultValue: "Got v\(version) from \(teammateName)")
            : String(
                localized: "spaces.sync.receivedWithDrafts",
                defaultValue: "Got v\(version) from \(teammateName). Your edits to \(conflictNames.formatted()) stay on top."
            )
    }
}

/// Reaches a teammate nearby for a spaces session (``TeamPresenceManager``).
@MainActor
protocol SpacePresenceProviding: AnyObject {
    func spacesTransport(to deviceID: String) async -> (any NearbyTransport)?
}

extension TeamPresenceManager: SpacePresenceProviding {}

/// Shared spaces between teammates (v0.6.0, tasks/todo.md S6): versions travel Mac to Mac,
/// never through a server.
///
/// - **Pull.** A spaces session pulls what this Mac lacks from one teammate
///   (``TeamSession/syncSpaces(with:keys:exchanger:transport:clock:)``). It runs when a teammate
///   who shares a space is seen nearby, every ``Timeouts/spaceSyncInterval`` while FX Vault is
///   active, on ``syncAll()`` (Get Updates from Teammates, after a publish), and back towards a
///   teammate whose heads show it is ahead.
/// - **Answer.** Sessions teammates open (through presence, or the remote listener) are answered
///   with this Mac's versions; a teammate that is ahead is pulled from right after.
/// - **Remote (Q4).** Off unless a teammate is allowed in Preferences › Teammates: then a
///   listener runs on ``PreferencesManager/remoteSpacePort`` (spaces service only, allowed
///   teammates only, backoff after failures), and allowed teammates with an address are reached
///   there when they are not nearby.
/// - Everything stops and the keys are dropped on lock.
@MainActor
@Observable
final class SpaceSyncManager: LockObserving {
    /// The latest versions teammates brought in (newest last; the Sync sheet and main window
    /// show the last one for a few seconds).
    private(set) var notices: [SpaceSyncNoticeModel] = []
    /// Teammates this Mac is syncing with right now (device ids).
    private(set) var activeTeammates: Set<String> = []
    /// Why the remote listener cannot run (the port is taken), or nil.
    private(set) var remoteFailure: NearbyTransportFailure?
    /// Bumped whenever a version arrived (screens reload their space data).
    private(set) var receivedCount = 0
    /// The notice under the bubbles, for ``Timeouts/spaceNoticeShown``.
    private(set) var latestNotice: SpaceSyncNoticeModel?

    @ObservationIgnored private let spaces: SpaceRepository
    @ObservationIgnored private let team: TeamRepository
    @ObservationIgnored private let preferences: PreferencesManager
    @ObservationIgnored private let networking: any SpaceRemoteNetworking
    @ObservationIgnored private let clock: any VaultClock
    @ObservationIgnored private weak var presence: (any SpacePresenceProviding)?
    @ObservationIgnored private let isAppActive: () -> Bool

    @ObservationIgnored private var keys: TeamDeviceKeys?
    @ObservationIgnored private var cards: [String: TeamCardModel] = [:]
    @ObservationIgnored private var remoteAccess: [String: TeammateRemoteAccessModel] = [:]
    @ObservationIgnored private var lastSync: [String: Date] = [:]
    @ObservationIgnored private var remoteListener: (any SpaceRemoteListening)?
    @ObservationIgnored private var listenerPort: UInt16?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let tasks = TaskBag()

    init(
        spaces: SpaceRepository,
        team: TeamRepository,
        preferences: PreferencesManager,
        networking: any SpaceRemoteNetworking,
        clock: any VaultClock,
        presence: (any SpacePresenceProviding)?,
        isAppActive: @escaping () -> Bool
    ) {
        self.spaces = spaces
        self.team = team
        self.preferences = preferences
        self.networking = networking
        self.clock = clock
        self.presence = presence
        self.isAppActive = isAppActive
    }

    // MARK: - Lifecycle

    /// Starts after an unlock: keys, teammates, the remote listener when needed, the timer.
    func start() {
        stop()
        do {
            keys = try team.deviceKeys()
        } catch {
            AppLog.ui.error("Teammate keys unavailable for space sync")
            return
        }
        isRunning = true
        reloadCards()
        observeTeammates()
        observeRemoteAccess()
        startTimer()
    }

    func stop() {
        generation += 1
        tasks.cancelAll()
        remoteListener?.stop()
        remoteListener = nil
        listenerPort = nil
        keys = nil
        cards = [:]
        remoteAccess = [:]
        activeTeammates = []
        isRunning = false
    }

    func vaultDidLock() {
        stop()
        notices = []
        latestNotice = nil
    }

    /// The remote port changed in Preferences: the listener reopens on it.
    func remotePortChanged() {
        updateRemoteListener()
    }

    // MARK: - Pull

    /// Syncs with every teammate who shares a space with this Mac (after a publish, so members
    /// learn about the new version, and on the timer).
    func syncAll() {
        guard isRunning else { return }
        for deviceID in cards.keys.sorted() where sharesSpace(with: deviceID) {
            sync(with: deviceID)
        }
    }

    /// Get Updates from Teammates: pulls from every teammate who shares a space, and returns
    /// once every session ended.
    func syncAllAndWait() async {
        guard isRunning else { return }
        let teammates = cards.keys.sorted().filter { sharesSpace(with: $0) && !activeTeammates.contains($0) }
        await withTaskGroup(of: Void.self) { group in
            for deviceID in teammates {
                group.addTask { await self.pull(from: deviceID) }
            }
        }
    }

    /// A teammate was seen nearby: sync when it shares a space and the last sync is old enough.
    func teammateSeen(_ deviceID: String) {
        guard isRunning, !activeTeammates.contains(deviceID) else { return }
        let last = lastSync[deviceID] ?? .distantPast
        guard clock.now.timeIntervalSince(last) >= Timeouts.spaceSyncInterval.timeInterval else { return }
        // Checked after the interval: reading the heads verifies every space's log.
        guard sharesSpace(with: deviceID) else {
            lastSync[deviceID] = clock.now
            return
        }
        sync(with: deviceID)
    }

    /// Pulls from one teammate in the background.
    func sync(with deviceID: String) {
        guard isRunning, !activeTeammates.contains(deviceID) else { return }
        tasks.set("sync-\(deviceID)", Task { [weak self] in
            await self?.pull(from: deviceID)
        })
    }

    /// One spaces session with a teammate: nearby first, then its address when remote sync is
    /// allowed.
    private func pull(from deviceID: String) async {
        guard isRunning, !activeTeammates.contains(deviceID), let keys, let card = cards[deviceID] else { return }
        activeTeammates.insert(deviceID)
        lastSync[deviceID] = clock.now
        let generation = generation
        defer {
            if self.generation == generation { activeTeammates.remove(deviceID) }
        }
        var transport = await presence?.spacesTransport(to: deviceID)
        var isRemote = false
        if transport == nil, let access = remoteAccess[deviceID], access.isAllowed, let address = access.address {
            transport = networking.connect(to: address)
            isRemote = true
        }
        guard let transport, self.generation == generation else { return }
        let session = TeamSession.syncSpaces(
            with: card,
            keys: keys,
            exchanger: exchanger(peerName: card.name),
            transport: transport,
            clock: clock
        )
        try? await session.start()
        var finished = false
        for await event in session.events where event == .finished {
            finished = true
        }
        if finished, isRemote {
            try? team.markRemoteConnection(deviceID, at: clock.now)
        }
    }

    // MARK: - Answer

    /// A teammate opened a spaces session to this Mac's presence.
    func answerNearby(_ transport: any NearbyTransport) {
        answer(transport, teammates: Array(cards.values), onFailure: nil)
    }

    private func answer(_ transport: any NearbyTransport, teammates: [TeamCardModel], onFailure: (() -> Void)?) {
        guard isRunning, let keys else {
            transport.close()
            return
        }
        let session = TeamSession.answer(
            keys: keys,
            teammates: teammates,
            transport: transport,
            clock: clock,
            service: .spaces,
            exchanger: exchanger(peerName: nil)
        )
        let generation = generation
        tasks.set("answer-\(UUID().uuidString)", Task { [weak self] in
            try? await session.start()
            var aheadPeer: String?
            var finished = false
            for await event in session.events {
                switch event {
                case .spaceHeadsRequested(let peer, let theirs):
                    if self?.isBehind(peer.deviceID, theirs: theirs) == true {
                        aheadPeer = peer.deviceID.hex
                    }
                case .finished:
                    finished = true
                default:
                    break
                }
            }
            guard let self, self.generation == generation else { return }
            if !finished { onFailure?() }
            if let aheadPeer {
                self.lastSync[aheadPeer] = nil
                self.sync(with: aheadPeer)
            }
        })
    }

    /// True when a teammate holds a space this Mac lacks, or a newer version of one it has.
    private func isBehind(_ peer: TeamDeviceID, theirs: [SpaceHeadModel]) -> Bool {
        let mine = Dictionary(((try? spaces.heads(sharedWith: peer)) ?? []).map { ($0.spaceID, $0.version) }, uniquingKeysWith: { first, _ in first })
        return theirs.contains { $0.version > (mine[$0.spaceID] ?? 0) }
    }

    private func sharesSpace(with deviceID: String) -> Bool {
        guard let id = TeamDeviceID(hex: deviceID) else { return false }
        return !((try? spaces.heads(sharedWith: id)) ?? []).isEmpty
    }

    // MARK: - Remote (Q4)

    private func observeRemoteAccess() {
        let stream = team.observeRemoteAccess()
        let generation = generation
        tasks.set("remote-access", Task { [weak self] in
            do {
                for try await access in stream {
                    guard let self, self.generation == generation else { return }
                    self.remoteAccess = Dictionary(access.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
                    self.updateRemoteListener()
                }
            } catch {
                return
            }
        })
    }

    /// The listener runs while some paired teammate is allowed, on the chosen port.
    private func updateRemoteListener() {
        let wanted = isRunning && remoteAccess.values.contains { $0.isAllowed && cards[$0.deviceID] != nil }
        let port = preferences.remoteSpacePort
        guard wanted else {
            remoteListener?.stop()
            remoteListener = nil
            listenerPort = nil
            remoteFailure = nil
            return
        }
        guard remoteListener == nil || listenerPort != port else { return }
        remoteListener?.stop()
        let listener = networking.makeListener(port: port)
        remoteListener = listener
        listenerPort = port
        remoteFailure = nil
        let generation = generation
        let connections = listener.connections
        let failures = listener.failures
        tasks.set("remote-connections", Task { [weak self] in
            for await connection in connections {
                guard let self, self.generation == generation else { return }
                self.handleRemote(connection, listener: listener)
            }
        })
        tasks.set("remote-failures", Task { [weak self] in
            for await failure in failures {
                guard let self, self.generation == generation else { return }
                self.remoteFailure = failure
            }
        })
        listener.start()
    }

    /// A connection from outside the local network: the spaces service only, answered for the
    /// allowed teammates only; anything else counts toward the backoff.
    private func handleRemote(_ connection: RemoteSpaceConnectionModel, listener: any SpaceRemoteListening) {
        let clock = clock
        let generation = generation
        tasks.set("remote-\(UUID().uuidString)", Task { [weak self] in
            guard let routed = await TeamRouter.route(connection.transport, clock: clock), routed.service == .spaces else {
                listener.recordFailedSession()
                return
            }
            guard let self, self.generation == generation else {
                routed.transport.close()
                return
            }
            let allowed = self.cards.values.filter { self.remoteAccess[$0.deviceID.hex]?.isAllowed == true }
            self.answer(routed.transport, teammates: allowed) {
                listener.recordFailedSession()
            }
        })
    }

    // MARK: - Private

    private func startTimer() {
        let clock = clock
        let generation = generation
        tasks.set("timer", Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Timeouts.spaceSyncInterval)
                } catch {
                    return
                }
                guard let self, self.generation == generation else { return }
                if self.isAppActive() {
                    self.syncAll()
                } else {
                    self.syncRemoteOnly()
                }
            }
        })
    }

    /// While FX Vault is in the background only teammates reached by address are synced.
    private func syncRemoteOnly() {
        for access in remoteAccess.values where access.isAllowed && access.address != nil && sharesSpace(with: access.deviceID) {
            sync(with: access.deviceID)
        }
    }

    private func observeTeammates() {
        let stream = team.observeTeammates()
        let generation = generation
        tasks.set("teammates", Task { [weak self] in
            do {
                for try await models in stream {
                    guard let self, self.generation == generation else { return }
                    if Set(models.map(\.id)) != Set(self.cards.keys) {
                        self.reloadCards()
                        self.updateRemoteListener()
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

    /// The vault side of a session; outcomes come back to the main actor as notices.
    private func exchanger(peerName: String?) -> SpaceExchangeAdapter {
        let generation = generation
        let names = cards.mapValues(\.name)
        return SpaceExchangeAdapter(spaces: spaces) { [weak self] outcome, peer in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.received(outcome, from: peerName ?? names[peer.hex] ?? peer.hex)
            }
        }
    }

    private func received(_ outcome: SpaceReceiveOutcomeModel, from name: String) {
        guard case .stored(let spaceID, let version, let applied) = outcome else { return }
        receivedCount += 1
        let notice = SpaceSyncNoticeModel(spaceID: spaceID, version: version, teammateName: name, conflictNames: applied.conflictNames)
        notices.append(notice)
        if notices.count > Limits.spaceNoticesKept {
            notices.removeFirst(notices.count - Limits.spaceNoticesKept)
        }
        latestNotice = notice
        let clock = clock
        tasks.set("notice", Task { [weak self] in
            try? await clock.sleep(for: Timeouts.spaceNoticeShown)
            guard !Task.isCancelled, self?.latestNotice?.id == notice.id else { return }
            self?.latestNotice = nil
        })
    }
}

/// ``SharingKit/TeamSpaceExchanging`` over ``VaultData/SpaceRepository``.
struct SpaceExchangeAdapter: TeamSpaceExchanging {
    let spaces: SpaceRepository
    let onReceive: @Sendable (SpaceReceiveOutcomeModel, TeamDeviceID) -> Void

    func heads(sharedWith peer: TeamDeviceID) async -> [SpaceHeadModel] {
        (try? spaces.heads(sharedWith: peer)) ?? []
    }

    func version(_ number: UInt64, of spaceID: SpaceID, for peer: TeamDeviceID) async -> Data? {
        (try? spaces.version(number, of: spaceID, for: peer)) ?? nil
    }

    func receive(_ versions: [Data], spaceID: SpaceID, from peer: TeamDeviceID) async -> Bool {
        do {
            let outcome = try spaces.receive(versions, spaceID: spaceID, from: peer)
            onReceive(outcome, peer)
            switch outcome {
            case .stored, .alreadyHave: return true
            case .gap, .forked, .busy, .repositoryMissing, .notAMember, .scopeAlreadyShared: return false
            }
        } catch {
            AppLog.ui.error("A teammate's space version was refused")
            return false
        }
    }
}

extension Limits {
    /// Space sync notices kept for the UI.
    static let spaceNoticesKept = 5
}

extension Timeouts {
    /// How long "Got v9 from Ana" stays under the bubbles.
    static let spaceNoticeShown: Duration = .seconds(8)
}

extension SpaceLocalIdentityModel {
    /// This Mac as teammates see it: the gh login, the nearby display name, the Mac's name (the
    /// card presence and pairing send, and the member entry of the spaces it creates).
    static func local(login: String, preferences: PreferencesManager) -> SpaceLocalIdentityModel {
        SpaceLocalIdentityModel(
            login: login,
            displayName: ShareLocalIdentityModel.nearby(preferences: preferences).displayName,
            macName: Host.current().localizedName ?? ""
        )
    }
}
