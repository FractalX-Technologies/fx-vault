import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// `fxvault-team/v1` (v0.5.0, tasks/todo.md T1–T8): cards and keys, pseudonyms, Add Teammate,
/// the paired handshake with PING, routing, and teammates in chat version 3.
@Suite("Teammates")
struct TeamProtocolTests {
    // MARK: - Fixtures

    struct Device {
        let keys: TeamDeviceKeys
        let card: TeamCardModel

        init(_ name: String) {
            keys = TeamDeviceKeys.generate()
            card = keys.card(login: name.lowercased(), displayName: name, macName: "\(name)'s Mac")
        }
    }

    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// Passes frames between two machines until neither has anything to send.
    static func pump<A, B>(
        _ first: inout A,
        _ second: inout B,
        from initial: [Data],
        firstReceive: (inout A, Data) -> [Data],
        secondReceive: (inout B, Data) -> [Data],
        toSecond rewrite: (Data) -> [Data] = { [$0] }
    ) {
        var toSecond = initial
        var toFirst: [Data] = []
        while !toSecond.isEmpty || !toFirst.isEmpty {
            for frame in toSecond.flatMap(rewrite) {
                toFirst += secondReceive(&second, frame)
            }
            toSecond = []
            for frame in toFirst {
                toSecond += firstReceive(&first, frame)
            }
            toFirst = []
        }
    }

    // MARK: - Cards and keys (T1)

    @Test func cardsRoundTripAndBindTheirKeys() throws {
        let device = Device("Ana")
        let decoded = try TeamCardModel.decode(device.card.encoded())
        #expect(decoded == device.card)
        #expect(decoded.deviceID == device.keys.deviceID)
        #expect(decoded.name == "Ana")
        #expect(device.card.encoded().count == 1 + 16 + 32 * 3 + 2 * 3 + "ana".utf8.count + "Ana".utf8.count + "Ana's Mac".utf8.count)

        let other = Device("Ben")
        var forged = device.card.encoded()
        forged.replaceSubrange(17..<49, with: other.keys.signingPublicKey)
        #expect(throws: NearbyFailure.self) { try TeamCardModel.decode(forged) }

        var truncated = device.card.encoded()
        truncated.removeLast()
        #expect(throws: NearbyFailure.self) { try TeamCardModel.decode(truncated) }

        #expect(throws: ShareError.teamCardInvalid) {
            try TeamCardModel(
                deviceID: other.keys.deviceID,
                signingPublicKey: device.keys.signingPublicKey,
                agreementPublicKey: device.keys.agreementPublicKey,
                announceKey: device.card.announceKey,
                login: "ana",
                displayName: "Ana",
                macName: ""
            )
        }
    }

    @Test func namesAreSanitizedAndBounded() {
        let keys = TeamDeviceKeys.generate()
        let card = keys.card(login: "a\u{202E}b", displayName: String(repeating: "é", count: 80), macName: "")
        #expect(card.login == "ab")
        #expect(card.displayName.utf8.count <= TeamProtocol.maxCardStringBytes)
        #expect(card.name == card.displayName)
        #expect(keys.card(login: "", displayName: "", macName: "").name == keys.deviceID.hex)
    }

    @Test func keysRoundTripThroughTheirSecretBytes() throws {
        let keys = TeamDeviceKeys.generate()
        let secret = keys.secretBytes()
        defer { secret.wipe() }
        #expect(secret.count == TeamDeviceKeys.secretByteCount)
        let restored = try TeamDeviceKeys(secretBytes: secret)
        #expect(restored.deviceID == keys.deviceID)
        #expect(restored.announceKey == keys.announceKey)
        #expect(throws: ShareError.teamKeysInvalid) { try TeamDeviceKeys(secretBytes: SecretBytes(count: 95)) }

        let renewed = keys.withNewAnnounceKey()
        #expect(renewed.deviceID == keys.deviceID)
        #expect(renewed.announceKey != keys.announceKey)
    }

    @Test func deviceIDsParseFromHex() throws {
        let id = TeamDeviceKeys.generate().deviceID
        #expect(TeamDeviceID(hex: id.hex) == id)
        #expect(TeamDeviceID(hex: id.hex.uppercased()) == id)
        #expect(TeamDeviceID(hex: "abc") == nil)
        #expect(TeamDeviceID(hex: String(repeating: "zz", count: 16)) == nil)
        #expect(TeamDeviceID(bytes: Data(count: 15)) == nil)
    }

    // MARK: - Pseudonyms (T3)

    @Test func pseudonymsChangeEveryWindowAndOnlyTeammatesRecognizeThem() {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let window = TeamPseudonym.window(at: Self.date)
        let now = TeamPseudonym.name(for: ana.keys, at: Self.date)
        #expect(now.count == 2 * TeamProtocol.pseudonymBytes)
        #expect(now == TeamPseudonym.name(announceKey: ana.card.announceKey, window: window))
        #expect(now != TeamPseudonym.name(announceKey: ana.card.announceKey, window: window + 1))
        #expect(now != TeamPseudonym.name(for: ben.keys, at: Self.date))
        #expect(TeamPseudonym.nextWindowStart(after: Self.date) > Self.date)
        #expect(TeamPseudonym.window(at: TeamPseudonym.nextWindowStart(after: Self.date)) == window + 1)

        let matcher = TeamPresenceMatcher(teammates: [ana.card], at: Self.date)
        #expect(matcher.teammate(advertising: now) == ana.keys.deviceID)
        #expect(matcher.teammate(advertising: now.uppercased()) == ana.keys.deviceID)
        let slow = TeamPseudonym.name(announceKey: ana.card.announceKey, window: window - 1)
        let fast = TeamPseudonym.name(announceKey: ana.card.announceKey, window: window + 1)
        #expect(matcher.teammate(advertising: slow) == ana.keys.deviceID, "a clock a few minutes behind")
        #expect(matcher.teammate(advertising: fast) == ana.keys.deviceID)
        #expect(matcher.teammate(advertising: TeamPseudonym.name(announceKey: ana.card.announceKey, window: window + 2)) == nil)
        #expect(matcher.teammate(advertising: TeamPseudonym.name(for: ben.keys, at: Self.date)) == nil)
        #expect(matcher.teammate(advertising: "Ana's Mac") == nil)

        let renewed = ana.keys.withNewAnnounceKey()
        #expect(matcher.teammate(advertising: TeamPseudonym.name(for: renewed, at: Self.date)) == nil,
                "a new announce key hides the device from a removed teammate")
    }

    // MARK: - Add Teammate (T2)

    struct Pairing {
        var initiator: TeamPairingMachine
        var responder: TeamPairingMachine
        var initiatorEvents: [TeamPairingEvent] = []
        var responderEvents: [TeamPairingEvent] = []

        init(_ ana: Device, _ ben: Device) {
            initiator = TeamPairingMachine(role: .initiator, localName: "Ana's Mac", keys: ana.keys, card: ana.card)
            responder = TeamPairingMachine(role: .responder, localName: "Ben's Mac", keys: ben.keys, card: ben.card)
        }

        mutating func run(_ initial: [Data], rewrite: (Data) -> [Data] = { [$0] }) {
            var initiatorEvents = self.initiatorEvents
            var responderEvents = self.responderEvents
            TeamProtocolTests.pump(
                &initiator,
                &responder,
                from: initial,
                firstReceive: { machine, frame in
                    let step = machine.receive(frame)
                    initiatorEvents += step.events
                    return step.frames
                },
                secondReceive: { machine, frame in
                    let step = machine.receive(frame)
                    responderEvents += step.events
                    return step.frames
                },
                toSecond: rewrite
            )
            self.initiatorEvents = initiatorEvents
            self.responderEvents = responderEvents
        }

        mutating func handshake() throws {
            _ = try responder.start()
            run(try initiator.start().frames)
        }

        mutating func confirmBoth() throws {
            let first = try initiator.confirmSAS()
            initiatorEvents += first.events
            run(first.frames)
            let second = try responder.confirmSAS()
            responderEvents += second.events
            var initiatorEvents = self.initiatorEvents
            var responderEvents = self.responderEvents
            TeamProtocolTests.pump(
                &responder,
                &initiator,
                from: second.frames,
                firstReceive: { machine, frame in
                    let step = machine.receive(frame)
                    responderEvents += step.events
                    return step.frames
                },
                secondReceive: { machine, frame in
                    let step = machine.receive(frame)
                    initiatorEvents += step.events
                    return step.frames
                }
            )
            self.initiatorEvents = initiatorEvents
            self.responderEvents = responderEvents
        }
    }

    @Test func pairingExchangesVerifiedCards() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var pairing = Pairing(ana, ben)
        try pairing.handshake()
        #expect(pairing.initiator.phase == .comparingCodes)
        #expect(pairing.responder.phase == .comparingCodes)
        #expect(pairing.initiator.sas?.value == pairing.responder.sas?.value)
        #expect(pairing.responderEvents.first == .incomingConnection)

        try pairing.confirmBoth()

        #expect(pairing.initiator.phase == .paired)
        #expect(pairing.responder.phase == .paired)
        #expect(pairing.initiatorEvents.contains(.paired(ben.card)))
        #expect(pairing.responderEvents.contains(.paired(ana.card)))
    }

    @Test func pairingStopsWhenTheCodesDoNotMatch() throws {
        var pairing = Pairing(Device("Ana"), Device("Ben"))
        try pairing.handshake()
        let step = try pairing.initiator.rejectSAS()
        pairing.run(step.frames)
        #expect(pairing.initiator.phase == .aborted)
        #expect(pairing.responder.phase == .aborted)
        #expect(pairing.responderEvents.contains { if case .aborted = $0 { true } else { false } })
        #expect(throws: ShareError.nearbyActionNotAllowed) { try pairing.initiator.confirmSAS() }
    }

    @Test func pairingWithItselfIsRefused() throws {
        let ana = Device("Ana")
        var pairing = Pairing(ana, ana)
        try pairing.handshake()
        try pairing.confirmBoth()
        #expect(pairing.initiator.phase == .aborted)
        #expect(pairing.initiatorEvents.contains(.aborted(NearbyAbortModel(reason: .teammateNotRecognized, happenedAfterReveal: true))))
    }

    @Test func pairingAndChatLabelsAreSeparate() {
        #expect(NearbyLabels.pair.commit == Data("fxvault/pair/v1/commit".utf8))
        #expect(NearbyLabels.team.transcript == Data("fxvault/team/v1/transcript".utf8))
        #expect(NearbyPurpose.pair.bonjourServiceType == "_fxvault-pair._tcp")
        #expect(NearbyPurpose.team.bonjourServiceType == "_fxvault-team._tcp")
        var chat = NearbyChatMachine(role: .initiator, localName: "Ana's Mac")
        var pair = TeamPairingMachine(role: .responder, localName: "Ben's Mac", keys: Device("Ben").keys, card: Device("Ben").card)
        _ = try? pair.start()
        _ = try? chat.start()
        let hello = chat.transportConnected().frames
        var replies: [Data] = []
        for frame in hello {
            replies += pair.receive(frame).frames
        }
        for frame in replies {
            for reveal in chat.receive(frame, at: Self.date).frames {
                _ = pair.receive(reveal)
            }
        }
        #expect(pair.phase == .aborted, "a chat REVEAL never matches a pairing commitment")
    }

    // MARK: - Paired handshake and PING (T3, T6)

    struct Session {
        var initiator: TeamSessionMachine
        var responder: TeamSessionMachine
        var initiatorEvents: [TeamSessionEvent] = []
        var responderEvents: [TeamSessionEvent] = []

        mutating func run(_ initial: [Data], rewrite: (Data) -> [Data] = { [$0] }) {
            var initiatorEvents = self.initiatorEvents
            var responderEvents = self.responderEvents
            TeamProtocolTests.pump(
                &initiator,
                &responder,
                from: initial,
                firstReceive: { machine, frame in
                    let step = machine.receive(frame)
                    initiatorEvents += step.events
                    return step.frames
                },
                secondReceive: { machine, frame in
                    let step = machine.receive(frame)
                    responderEvents += step.events
                    return step.frames
                },
                toSecond: rewrite
            )
            self.initiatorEvents = initiatorEvents
            self.responderEvents = responderEvents
        }

        /// I's frames minus the preamble (the listener reads it).
        mutating func start(rewrite: (Data) -> [Data] = { [$0] }) throws {
            _ = try responder.start()
            let frames = try initiator.start().frames
            #expect(frames.first.flatMap(TeamService.decodePreamble) == .team)
            run(Array(frames.dropFirst()), rewrite: rewrite)
        }
    }

    @Test func teammatesAuthenticateAndPing() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var session = Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        try session.start()
        #expect(session.initiator.phase == .ready)
        #expect(session.responder.phase == .ready)
        #expect(session.initiatorEvents == [.authenticated(ben.card)])
        #expect(session.responderEvents == [.authenticated(ana.card)])

        let ping = try session.initiator.ping()
        session.run(ping.frames)
        #expect(session.responderEvents.contains(.pinged(ana.card)))
        #expect(session.initiatorEvents.last == .pingDelivered)
        #expect(session.initiator.phase == .ready)
        let close = session.initiator.close()
        session.run(close.frames)
        #expect(session.initiator.phase == .finished)
        #expect(session.responder.phase == .finished)
    }

    @Test func aCardUpdateHandsOverANewAnnounceKey() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let renewed = ana.keys.withNewAnnounceKey()
        let newCard = renewed.card(login: "ana", displayName: "Ana", macName: "Ana's Mac")
        var session = Session(
            initiator: .initiator(keys: renewed, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        try session.start()
        #expect(throws: ShareError.nearbyActionNotAllowed) { try session.initiator.updateCard(ana.card) }
        let update = try session.initiator.updateCard(newCard)
        session.run(update.frames)
        #expect(session.responderEvents.contains(.cardUpdated(newCard)))
        #expect(session.initiatorEvents.last == .cardUpdateDelivered)
        #expect(session.responder.peer == newCard)

        // A card with other keys cannot replace the authenticated teammate's.
        let eve = Device("Eve")
        var forged = Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        try forged.start()
        var state = forged.initiator
        let frames = try Self.sealForTest(&state, type: .cardUpdate, body: eve.card.encoded())
        forged.initiator = state
        forged.run(frames)
        #expect(forged.responder.phase == .aborted)
        #expect(!forged.responderEvents.contains { if case .cardUpdated = $0 { true } else { false } })
    }

    /// Seals a frame as `machine` would, bypassing its request checks (a malicious peer).
    private static func sealForTest(_ machine: inout TeamSessionMachine, type: TeamMessageType, body: Data) throws -> [Data] {
        try machine.sealForTesting(type, body)
    }

    @Test func aStrangerIsRefusedBeforeTheResponderSaysWhoItIs() throws {
        let stranger = Device("Eve")
        let ben = Device("Ben")
        let ana = Device("Ana")
        var session = Session(
            initiator: .initiator(keys: stranger.keys, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        var sawAuthResponder = false
        try session.start()
        #expect(session.responder.phase == .aborted)
        #expect(session.responderEvents == [.aborted(NearbyAbortModel(reason: .teammateNotRecognized, happenedAfterReveal: true))])
        #expect(session.initiator.phase == .aborted)
        for event in session.initiatorEvents {
            if case .authenticated = event { sawAuthResponder = true }
        }
        #expect(!sawAuthResponder)
    }

    @Test func anAuthMeantForAnotherTeammateIsRefused() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let cleo = Device("Cleo")
        // Ana means Ben, but Cleo (also Ana's teammate) answers at that address.
        var session = Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card),
            responder: .responder(keys: cleo.keys, teammates: [ana.card])
        )
        try session.start()
        #expect(session.responder.phase == .aborted)
        #expect(session.responderEvents == [.aborted(NearbyAbortModel(reason: .signatureInvalid, happenedAfterReveal: true))])
        #expect(session.initiator.phase == .aborted)
    }

    @Test func tamperedReplayedOrMalformedFramesAbort() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var flipped = Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        try flipped.start { frame in
            guard frame.first != TeamMessageType.helloInitiator.rawValue else { return [frame] }
            var copy = frame
            copy[copy.count - 1] ^= 0x01
            return [copy]
        }
        #expect(flipped.responder.phase == .aborted)

        var replayed = Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        try replayed.start { [$0, $0] }
        #expect(replayed.responder.phase == .aborted)

        var responder = TeamSessionMachine.responder(keys: ben.keys, teammates: [ana.card])
        _ = try responder.start()
        _ = responder.receive(Data([TeamMessageType.helloInitiator.rawValue, TeamProtocol.version, 0x01]))
        #expect(responder.phase == .aborted)
        #expect(TeamService.decodePreamble(Data([0x50, 0x01, 0x09])) == nil)
        #expect(TeamService.decodePreamble(Data([0x50, 0x02, 0x01])) == nil)
        #expect(TeamService.decodePreamble(TeamService.chat.preamble) == .chat)
    }

    @Test func pingIsOnlyForAnAuthenticatedInitiator() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var initiator = TeamSessionMachine.initiator(keys: ana.keys, peer: ben.card)
        #expect(throws: ShareError.nearbyActionNotAllowed) { try initiator.ping() }
        var responder = TeamSessionMachine.responder(keys: ben.keys, teammates: [ana.card])
        _ = try responder.start()
        #expect(throws: ShareError.nearbyActionNotAllowed) { try responder.ping() }
        _ = try initiator.start()
        #expect(throws: ShareError.nearbyActionNotAllowed) { try initiator.start() }
    }

    // MARK: - Sessions over a transport

    @Test func pairingSessionsOverATransport() async throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let pair = InMemoryTransportPair()
        let initiator = TeamPairingSession(role: .initiator, localName: "Ana's Mac", keys: ana.keys, card: ana.card, transport: pair.initiator)
        let responder = TeamPairingSession(role: .responder, localName: "Ben's Mac", keys: ben.keys, card: ben.card, transport: pair.responder)
        try await responder.start()
        try await initiator.start()
        async let initiatorResult = Self.pairingOutcome(initiator)
        async let responderResult = Self.pairingOutcome(responder)
        let (first, second) = await (initiatorResult, responderResult)
        #expect(first == ben.card)
        #expect(second == ana.card)
    }

    /// Confirms the code when it shows and returns the paired card.
    private static func pairingOutcome(_ session: TeamPairingSession) async -> TeamCardModel? {
        for await event in session.events {
            switch event {
            case .sasReady:
                try? await session.confirmSAS()
            case .paired(let card):
                return card
            case .aborted:
                return nil
            default:
                break
            }
        }
        return nil
    }

    @Test func pingThroughTheRouter() async throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let pair = InMemoryTransportPair()
        let pinger = TeamSession.ping(ben.card, keys: ana.keys, transport: pair.initiator)
        try await pinger.start()
        let routed = try #require(await TeamRouter.route(pair.responder))
        #expect(routed.service == .team)
        let answer = TeamSession.answer(keys: ben.keys, teammates: [ana.card], transport: routed.transport)
        try await answer.start()

        var answered: [TeamSessionEvent] = []
        for await event in answer.events {
            answered.append(event)
        }
        var pinged: [TeamSessionEvent] = []
        for await event in pinger.events {
            pinged.append(event)
        }
        #expect(answered.contains(.pinged(ana.card)))
        #expect(pinged.contains(.pingDelivered))
    }

    @Test func theRouterClosesAConnectionWithoutAPreamble() async throws {
        let pair = InMemoryTransportPair()
        let clock = ManualClock()
        async let routed = TeamRouter.route(pair.responder, clock: clock)
        try await pair.initiator.send(Data([0x01, 0x02]))
        #expect(await routed == nil)

        let silent = InMemoryTransportPair()
        async let waited = TeamRouter.route(silent.responder, clock: clock)
        try await Task.sleep(for: .milliseconds(50))
        clock.advance(by: Timeouts.nearbyHandshake)
        #expect(await waited == nil)
    }

    // MARK: - Chat version 3 (T7)

    @Test func teammatesSkipTheCodeInChat() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var harness = ChatHarness(
            initiator: NearbyChatMachine(
                role: .initiator,
                localName: "Ana's Mac",
                team: TeamChatIdentityModel(keys: ana.keys, teammates: [ben.card], expectedPeer: ben.keys.deviceID)
            ),
            responder: NearbyChatMachine(
                role: .responder,
                localName: "Ben's Mac",
                team: TeamChatIdentityModel(keys: ben.keys, teammates: [ana.card])
            )
        )
        try harness.runHandshake()
        #expect(harness.initiator.phase == .chatting)
        #expect(harness.responder.phase == .chatting)
        #expect(harness.initiatorEvents.contains(.teammateVerified(ben.card)))
        #expect(harness.responderEvents.contains(.teammateVerified(ana.card)))
        #expect(harness.initiator.verifiedTeammate == ben.card)
    }

    @Test func aStrangerInChatStillComparesTheCode() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let eve = Device("Eve")
        var harness = ChatHarness(
            initiator: NearbyChatMachine(
                role: .initiator,
                localName: "Eve's Mac",
                team: TeamChatIdentityModel(keys: eve.keys, teammates: [ben.card], expectedPeer: ben.keys.deviceID)
            ),
            responder: NearbyChatMachine(
                role: .responder,
                localName: "Ben's Mac",
                team: TeamChatIdentityModel(keys: ben.keys, teammates: [ana.card])
            )
        )
        try harness.runHandshake()
        #expect(harness.responder.phase == .comparingCodes, "Ben does not know Eve: the people compare the code")
        #expect(!harness.responderEvents.contains { if case .teammateVerified = $0 { true } else { false } })
    }

    @Test func anOlderChatPeerComparesTheCode() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var harness = ChatHarness(
            initiator: NearbyChatMachine(
                role: .initiator,
                localName: "Ana's Mac",
                team: TeamChatIdentityModel(keys: ana.keys, teammates: [ben.card], expectedPeer: ben.keys.deviceID)
            ),
            responder: NearbyChatMachine(role: .responder, localName: "Ben's Mac", maxVersion: 2)
        )
        try harness.runHandshake()
        #expect(harness.initiator.phase == .comparingCodes)
        #expect(harness.responder.phase == .comparingCodes)
    }
}
