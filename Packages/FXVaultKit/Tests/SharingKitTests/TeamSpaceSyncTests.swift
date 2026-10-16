import Foundation
import os
import Testing
import VaultCore
@testable import SharingKit

/// The spaces service (v0.6.0, tasks/todo.md S6): pull-only sync over the paired handshake,
/// SPACE_HEADS, SPACE_FETCH, SPACE_VERSION and SPACE_CHUNK, the service split, and the limits.
@Suite("Space sync between teammates")
struct TeamSpaceSyncTests {
    typealias Device = TeamProtocolTests.Device

    /// A vault side that keeps raw versions per space and accepts the next number only.
    final class FakeExchanger: TeamSpaceExchanging, Sendable {
        struct State {
            var logs: [SpaceID: [Data]] = [:]
            var members: [SpaceID: Set<TeamDeviceID>] = [:]
            var receivedBatches: [Int] = []
        }

        let state: OSAllocatedUnfairLock<State>

        init(logs: [SpaceID: [Data]] = [:], members: [SpaceID: Set<TeamDeviceID>] = [:]) {
            state = OSAllocatedUnfairLock(initialState: State(logs: logs, members: members))
        }

        var logs: [SpaceID: [Data]] {
            state.withLock { $0.logs }
        }

        var receivedBatches: [Int] {
            state.withLock { $0.receivedBatches }
        }

        func heads(sharedWith peer: TeamDeviceID) async -> [SpaceHeadModel] {
            state.withLock { state in
                state.logs.compactMap { spaceID, log in
                    guard state.members[spaceID]?.contains(peer) == true, let last = log.last,
                          let version = try? SpaceVersionModel.decode(last)
                    else { return nil }
                    return SpaceHeadModel(spaceID: spaceID, version: version.header.version, hash: version.hash)
                }
            }
        }

        func version(_ number: UInt64, of spaceID: SpaceID, for peer: TeamDeviceID) async -> Data? {
            state.withLock { state in
                guard state.members[spaceID]?.contains(peer) == true,
                      let log = state.logs[spaceID], number >= 1, Int(number) <= log.count
                else { return nil }
                return log[Int(number) - 1]
            }
        }

        func receive(_ versions: [Data], spaceID: SpaceID, from peer: TeamDeviceID) async -> Bool {
            state.withLock { state in
                state.receivedBatches.append(versions.count)
                for data in versions {
                    guard let version = try? SpaceVersionModel.decode(data),
                          version.header.version == UInt64((state.logs[spaceID] ?? []).count + 1)
                    else { return false }
                    state.logs[spaceID, default: []].append(data)
                }
                return true
            }
        }
    }

    /// Ana and Ben share a space with `count` versions: Ana's genesis, then Ben's publishes.
    static func log(_ ana: Device, _ ben: Device, count: Int, spaceID: SpaceID = SpaceID()) throws -> [Data] {
        let (genesis, keychain) = try SpaceVersionBuilder.genesis(
            spaceID: spaceID,
            binding: SpaceProtocolTests.binding,
            members: [ana, ben].map { SpaceMemberModel(card: $0.card) },
            snapshot: SpaceProtocolTests.snapshot([("API_KEY", "v1")]),
            author: ana.keys,
            at: SpaceProtocolTests.date
        )
        var state = try SpaceLog.verify([genesis], spaceID: spaceID)
        var log = [genesis.encoded()]
        while log.count < count {
            let next = try SpaceVersionBuilder.publish(
                state: state,
                keychain: keychain,
                snapshot: SpaceProtocolTests.snapshot([("API_KEY", "v\(log.count + 1)")]),
                author: ben.keys,
                at: SpaceProtocolTests.date
            )
            state = try SpaceLog.apply(next, to: state)
            log.append(next.encoded())
        }
        return log
    }

    /// Ana pulls from Ben over the router; returns both sessions' events.
    static func sync(
        _ ana: Device,
        _ ben: Device,
        initiator: FakeExchanger,
        responder: FakeExchanger
    ) async throws -> (pulled: [TeamSessionEvent], answered: [TeamSessionEvent]) {
        let pair = InMemoryTransportPair()
        let puller = TeamSession.syncSpaces(with: ben.card, keys: ana.keys, exchanger: initiator, transport: pair.initiator)
        try await puller.start()
        let routed = try #require(await TeamRouter.route(pair.responder))
        #expect(routed.service == .spaces)
        let answer = TeamSession.answer(
            keys: ben.keys,
            teammates: [ana.card],
            transport: routed.transport,
            service: .spaces,
            exchanger: responder
        )
        try await answer.start()
        var answered: [TeamSessionEvent] = []
        for await event in answer.events {
            answered.append(event)
        }
        var pulled: [TeamSessionEvent] = []
        for await event in puller.events {
            pulled.append(event)
        }
        return (pulled, answered)
    }

    @Test func aBehindMacFetchesEveryMissingVersionOneByOne() async throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let space = SpaceID()
        let log = try Self.log(ana, ben, count: 4, spaceID: space)
        let members: [SpaceID: Set<TeamDeviceID>] = [space: [ana.keys.deviceID, ben.keys.deviceID]]
        let mine = FakeExchanger(logs: [space: [log[0]]], members: members)
        let theirs = FakeExchanger(logs: [space: log], members: members)

        let (pulled, answered) = try await Self.sync(ana, ben, initiator: mine, responder: theirs)

        #expect(mine.logs[space] == log)
        #expect(mine.receivedBatches == [1, 1, 1])
        #expect(pulled.last == .finished)
        #expect(answered.last == .finished)
        #expect(answered.contains { if case .spaceHeadsRequested(let peer, let heads) = $0 { peer == ana.card && heads.map(\.version) == [1] } else { false } })
    }

    @Test func aNewSpaceArrivesAsItsWholeLog() async throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let space = SpaceID()
        let log = try Self.log(ana, ben, count: 3, spaceID: space)
        let members: [SpaceID: Set<TeamDeviceID>] = [space: [ana.keys.deviceID, ben.keys.deviceID]]
        let mine = FakeExchanger(members: members)
        let theirs = FakeExchanger(logs: [space: log], members: members)

        _ = try await Self.sync(ana, ben, initiator: mine, responder: theirs)

        #expect(mine.receivedBatches == [3])
        #expect(mine.logs[space] == log)
    }

    @Test func aMacThatIsNotAMemberGetsNothing() async throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let space = SpaceID()
        let log = try Self.log(ana, ben, count: 2, spaceID: space)
        let mine = FakeExchanger()
        let theirs = FakeExchanger(logs: [space: log], members: [space: [ben.keys.deviceID]])

        let (pulled, _) = try await Self.sync(ana, ben, initiator: mine, responder: theirs)

        #expect(mine.receivedBatches.isEmpty)
        #expect(pulled.contains(.spaceHeadsAnswered([])))
        #expect(pulled.last == .finished)
    }

    @Test func anUpToDateMacClosesRightAfterTheHeads() async throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let space = SpaceID()
        let log = try Self.log(ana, ben, count: 2, spaceID: space)
        let members: [SpaceID: Set<TeamDeviceID>] = [space: [ana.keys.deviceID, ben.keys.deviceID]]
        let mine = FakeExchanger(logs: [space: log], members: members)
        let theirs = FakeExchanger(logs: [space: log], members: members)

        let (pulled, answered) = try await Self.sync(ana, ben, initiator: mine, responder: theirs)

        #expect(mine.receivedBatches.isEmpty)
        #expect(!answered.contains { if case .spaceVersionRequested = $0 { true } else { false } })
        #expect(pulled.last == .finished)
    }

    // MARK: - Machine rules

    static func spacesSession(_ ana: Device, _ ben: Device) throws -> TeamProtocolTests.Session {
        var session = TeamProtocolTests.Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card, service: .spaces),
            responder: .responder(keys: ben.keys, teammates: [ana.card], service: .spaces)
        )
        _ = try session.responder.start()
        let frames = try session.initiator.start().frames
        #expect(frames.first.flatMap(TeamService.decodePreamble) == .spaces)
        session.run(Array(frames.dropFirst()))
        return session
    }

    /// Hands the responder's frames to the initiator (``TeamProtocolTests/Session/run(_:rewrite:)``
    /// starts from the initiator's).
    static func deliverToInitiator(_ frames: [Data], _ session: inout TeamProtocolTests.Session) {
        for frame in frames {
            session.initiatorEvents += session.initiator.receive(frame).events
        }
    }

    @Test func eachServiceRefusesTheOthersRequests() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        var spaces = try Self.spacesSession(ana, ben)
        #expect(spaces.initiator.phase == .ready)
        #expect(throws: ShareError.nearbyActionNotAllowed) { try spaces.initiator.ping() }
        var state = spaces.initiator
        let ping = try state.sealForTesting(.ping, Data())
        spaces.initiator = state
        spaces.run(ping)
        #expect(spaces.responder.phase == .aborted)

        var team = TeamProtocolTests.Session(
            initiator: .initiator(keys: ana.keys, peer: ben.card),
            responder: .responder(keys: ben.keys, teammates: [ana.card])
        )
        try team.start()
        #expect(throws: ShareError.nearbyActionNotAllowed) { try team.initiator.requestSpaceHeads([]) }
        var teamState = team.initiator
        let heads = try teamState.sealForTesting(.spaceHeads, TeamSpaceWire.encode([]))
        team.initiator = teamState
        team.run(heads)
        #expect(team.responder.phase == .aborted)
    }

    @Test func aVersionArrivesInChunksAndMoreThanAnnouncedAborts() throws {
        let ana = Device("Ana")
        let ben = Device("Ben")
        let space = SpaceID()
        var session = try Self.spacesSession(ana, ben)
        session.run(try session.initiator.requestSpaceVersion(space, version: 1).frames)
        #expect(session.responder.phase == .answering)
        #expect(session.responderEvents.last == .spaceVersionRequested(ana.card, space, 1))

        let big = Data((0..<(3 * NearbyProtocol.maxFramePlaintextBytes)).map { UInt8(truncatingIfNeeded: $0) })
        let answer = session.responder.answerSpaceVersion(big)
        #expect(answer.frames.count == 4)
        Self.deliverToInitiator(answer.frames, &session)
        #expect(session.initiatorEvents.last == .spaceVersionAnswered(big))
        #expect(session.initiator.phase == .ready)

        // A responder that sends more bytes than it announced is cut off.
        session.run(try session.initiator.requestSpaceVersion(space, version: 2).frames)
        var lying = session.responder
        var announced = Data()
        announced.appendBigEndian(UInt32(4))
        var frames = try lying.sealForTesting(.spaceVersion, announced)
        frames += try lying.sealForTesting(.spaceChunk, Data(repeating: 1, count: 8))
        session.responder = lying
        Self.deliverToInitiator(frames, &session)
        #expect(session.initiator.phase == .aborted)
    }

    // MARK: - Remote by address (Q4)

    @Test func remoteAddressesAreHostAndPortOnly() {
        #expect(TeamRemoteAddressModel(text: "mac-a.tail0000.ts.net:52731") == TeamRemoteAddressModel(host: "mac-a.tail0000.ts.net", port: 52_731))
        #expect(TeamRemoteAddressModel(text: " 100.64.0.7:9000 ")?.text == "100.64.0.7:9000")
        #expect(TeamRemoteAddressModel(text: "[fd7a:115c::1]:9000")?.text == "[fd7a:115c::1]:9000")
        for invalid in ["mac-a", "mac-a:0", "mac-a:70000", ":9000", "mac a:9000", "-mac:9000", "mac/a:9000", "[not-ipv6]:9000", "mäc:9000"] {
            #expect(TeamRemoteAddressModel(text: invalid) == nil, "\(invalid)")
        }
        #expect(TeamRemoteAddressModel(text: "\(String(repeating: "a", count: 254)):9000") == nil)
        #expect(TeamRemoteAddressModel(host: "mac-a", port: 9000).endpoint?.id == "mac-a:9000")
    }

    @Test func fiveFailedSessionsCloseTheListenerForTenMinutes() {
        var backoff = RemoteSpaceBackoff()
        let start = SpaceProtocolTests.date
        for minute in 0..<(Limits.remoteSpaceFailures - 1) {
            let closes = backoff.recordFailure(at: start.addingTimeInterval(Double(minute) * 60))
            #expect(!closes)
        }
        #expect(!backoff.isClosed(at: start.addingTimeInterval(300)))
        let closes = backoff.recordFailure(at: start.addingTimeInterval(300))
        #expect(closes)
        #expect(backoff.isClosed(at: start.addingTimeInterval(899)))
        #expect(!backoff.isClosed(at: start.addingTimeInterval(300 + Timeouts.remoteSpaceBackoff.timeInterval)))

        // Failures older than the window do not count.
        var spread = RemoteSpaceBackoff()
        for index in 0..<(Limits.remoteSpaceFailures * 2) {
            let spreadCloses = spread.recordFailure(at: start.addingTimeInterval(Double(index) * 200))
            #expect(!spreadCloses)
        }
    }

    @Test func headsAndFetchesRejectMalformedBodies() throws {
        let space = SpaceID()
        let heads = [SpaceHeadModel(spaceID: space, version: 3, hash: Data(repeating: 7, count: 32))]
        #expect(try TeamSpaceWire.decodeHeads(TeamSpaceWire.encode(heads)) == heads)
        #expect(throws: NearbyFailure.self) { try TeamSpaceWire.decodeHeads(TeamSpaceWire.encode(heads + heads)) }
        #expect(throws: NearbyFailure.self) { try TeamSpaceWire.decodeHeads(TeamSpaceWire.encode(heads).dropLast()) }
        #expect(throws: NearbyFailure.self) { try TeamSpaceWire.decodeFetch(TeamSpaceWire.encodeFetch(space, version: 0)) }
        #expect(try TeamSpaceWire.decodeFetch(TeamSpaceWire.encodeFetch(space, version: 9)) == (space, 9))
    }
}
