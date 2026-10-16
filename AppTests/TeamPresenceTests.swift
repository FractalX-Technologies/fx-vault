import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Teammates nearby (v0.5.0, tasks/todo.md T1–T8) over a fake nearby network shared by test
/// Macs: pseudonym advertising, bubbles, pings with mute and limits, card updates after a
/// removal, chats from a bubble, Everyone nearby, Add Teammate and lock.
@MainActor
@Suite("Teammates nearby", .serialized)
struct TeamPresenceTests {
    @MainActor
    final class Mac {
        let harness: TestHarness
        let card: TeamCardModel
        let keys: TeamDeviceKeys

        init(_ name: String, network: FakeNearbyNetwork) async throws {
            harness = try await TestHarness(vault: .unlocked, teamNetworking: network.networking(for: name))
            harness.preferences.nearbyDisplayName = name
            keys = try harness.data.team.deviceKeys()
            card = keys.card(login: name.lowercased(), displayName: name, macName: "\(name)'s Mac")
        }

        var presence: TeamPresenceManager {
            harness.app.teamPresence
        }

        func pair(with other: Mac) throws {
            try harness.data.team.addTeammate(other.card)
        }

        func person(_ name: String) -> NearbyPersonModel? {
            presence.people.first { $0.name == name }
        }
    }

    /// Ana and Ben, paired, both browsing.
    static func pairedMacs() async throws -> (FakeNearbyNetwork, Mac, Mac) {
        let network = FakeNearbyNetwork()
        let ana = try await Mac("Ana", network: network)
        let ben = try await Mac("Ben", network: network)
        try ana.pair(with: ben)
        try ben.pair(with: ana)
        ana.presence.start()
        ben.presence.start()
        ana.presence.setBrowsing(true)
        ben.presence.setBrowsing(true)
        return (network, ana, ben)
    }

    // MARK: - Presence (T3, T5)

    @Test func advertisesThePseudonymAndRecognizesTeammates() async throws {
        let (network, ana, ben) = try await Self.pairedMacs()
        #expect(network.listeners["Ana"]?.serviceName == TeamPseudonym.name(for: ana.keys, at: ana.harness.presenceClock.now))
        #expect(await TestFixtures.eventually { ana.person("Ben")?.isTeammate == true })
        #expect(await TestFixtures.eventually { ben.person("Ana") != nil })
        #expect(ana.presence.people.count == 1, "its own pseudonym is not a teammate")
        #expect(await TestFixtures.eventually { (try? ana.harness.data.team.teammates().first?.lastSeenAt) != nil })
    }

    @Test func nobodyAdvertisesNothingButStillSeesTeammates() async throws {
        let (network, ana, ben) = try await Self.pairedMacs()
        ana.harness.preferences.nearbyVisibility = .nobody
        ana.presence.start()
        #expect(await TestFixtures.eventually { network.listeners["Ana"]?.serviceName == nil })
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })
        #expect(ben.person("Ana") != nil, "a bubble stays for the grace period, so it does not flicker")
        ben.harness.presenceClock.advance(by: Timeouts.presenceGrace + .seconds(1))
        #expect(await TestFixtures.eventually { ben.person("Ana") == nil })
    }

    @Test func aStrangersPseudonymIsIgnored() async throws {
        let network = FakeNearbyNetwork()
        let ana = try await Mac("Ana", network: network)
        let eve = try await Mac("Eve", network: network)
        ana.presence.start()
        eve.presence.start()
        ana.presence.setBrowsing(true)
        #expect(await TestFixtures.eventually { network.listeners["Eve"]?.serviceName != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(ana.presence.people.isEmpty)
    }

    // MARK: - Pings (T6)

    @Test func aPingReachesTheTeammate() async throws {
        let (_, ana, ben) = try await Self.pairedMacs()
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })
        let person = try #require(ana.person("Ben"))

        ana.presence.ping(person)

        #expect(await TestFixtures.eventually { ben.harness.pingAlerts.alerts.map(\.name) == ["Ana"] })
        #expect(await TestFixtures.eventually { ana.presence.feedback == .delivered("Ben") })
        #expect(ben.presence.bouncingPersonID == "teammate-\(ana.keys.deviceID.hex)")
        #expect(!ana.presence.canPing(person), "one ping per teammate every 10 seconds")
        #expect(ana.presence.pingCooldown(for: person) > 0)
    }

    @Test func aMutedTeammateBouncesWithoutASound() async throws {
        let (_, ana, ben) = try await Self.pairedMacs()
        try ben.harness.data.team.setMuted(true, teammate: ana.keys.deviceID.hex)
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })
        ana.presence.ping(try #require(ana.person("Ben")))

        #expect(await TestFixtures.eventually { ana.presence.feedback == .delivered("Ben") })
        #expect(ben.harness.pingAlerts.alerts.isEmpty)
        #expect(ben.presence.bounceCount == 1)

        ben.harness.preferences.mutesAllPings = true
        try ben.harness.data.team.setMuted(false, teammate: ana.keys.deviceID.hex)
        ben.presence.receivedPing(from: ana.card)
        #expect(ben.harness.pingAlerts.alerts.isEmpty, "Mute all")
    }

    @Test func incomingPingsAreLimitedPerMinute() async throws {
        let (_, ana, ben) = try await Self.pairedMacs()
        _ = ana
        for _ in 0..<8 {
            ben.presence.receivedPing(from: ana.card)
        }
        #expect(ben.harness.pingAlerts.alerts.count == Limits.pingsPerMinute)
        ben.harness.presenceClock.advance(by: .seconds(61))
        ben.presence.receivedPing(from: ana.card)
        #expect(ben.harness.pingAlerts.alerts.count == Limits.pingsPerMinute + 1)
    }

    // MARK: - Card updates after a removal

    @Test func removingATeammateRenewsThePseudonymAndTheOthersGetTheNewCard() async throws {
        let (network, ana, ben) = try await Self.pairedMacs()
        let cleo = TeamDeviceKeys.generate().card(login: "cleo", displayName: "Cleo", macName: "")
        try ana.harness.data.team.addTeammate(cleo)
        let before = try #require(network.listeners["Ana"]?.serviceName)

        try ana.harness.data.team.removeTeammate(id: cleo.deviceID.hex)
        ana.presence.start()

        #expect(await TestFixtures.eventually { network.listeners["Ana"]?.serviceName != before })
        // Ana sees Ben (his pseudonym did not change) and hands him her new card.
        #expect(await TestFixtures.eventually { (try? ana.harness.data.team.teammates().first?.needsCardUpdate) == false })
        let stored = try #require(try ben.harness.data.team.teammateCards().first)
        #expect(stored.announceKey == (try ana.harness.data.team.deviceKeys().card(login: "", displayName: "", macName: "").announceKey))
        ben.presence.start()
        #expect(await TestFixtures.eventually { ben.person("Ana") != nil }, "Ben recognizes her new pseudonym")
    }

    // MARK: - Chat from a bubble (T7)

    @Test func chatWithATeammateGoesThroughTheirPresence() async throws {
        let (_, ana, ben) = try await Self.pairedMacs()
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })

        ana.presence.chat(with: try #require(ana.person("Ben")))

        #expect(ana.harness.app.chatStartRequests == 1)
        let outgoing = try #require(ana.harness.app.takePendingChatStart())
        #expect(outgoing.role == .initiator)
        #expect(outgoing.teammate == ben.card)
        #expect(outgoing.expectsTeammate)
        // The preamble is sent once the session uses the transport; Ben's listener routes it.
        let events = outgoing.transport.events
        Task {
            for await _ in events {}
        }
        #expect(await TestFixtures.eventually { ben.harness.app.chatStartRequests == 1 })
        let incoming = try #require(ben.harness.app.takePendingChatStart())
        #expect(incoming.role == .responder)
        #expect(incoming.expectsTeammate)
        outgoing.transport.close()
        incoming.transport.close()
    }

    @Test func teammatesChatWithoutTheCode() async throws {
        let (_, ana, ben) = try await Self.pairedMacs()
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })
        let anaChat = ana.harness.app.makeNearbyChatViewModel()
        let benChat = ben.harness.app.makeNearbyChatViewModel()

        ana.presence.chat(with: try #require(ana.person("Ben")))
        await anaChat.startPendingChat()
        #expect(await TestFixtures.eventually { ben.harness.app.chatStartRequests == 1 })
        await benChat.startPendingChat()

        #expect(await TestFixtures.eventually { anaChat.step == .chatting && benChat.step == .chatting })
        #expect(anaChat.verifiedTeammateName == "Ben")
        #expect(benChat.verifiedTeammateName == "Ana")
        #expect(!anaChat.isCodeConfirmed, "nobody pressed Codes match")
        anaChat.close()
        benChat.close()
    }

    // MARK: - Everyone nearby (T4)

    @Test func everyoneNearbyListsStrangersAndOpensTheirChats() async throws {
        let network = FakeNearbyNetwork()
        let ana = try await Mac("Ana", network: network)
        let eve = try await Mac("Eve", network: network)
        ana.harness.preferences.nearbyVisibility = .everyone
        eve.harness.preferences.nearbyVisibility = .everyone
        ana.presence.start()
        eve.presence.start()
        ana.presence.setBrowsing(true)

        #expect(await TestFixtures.eventually { ana.person("Eve")?.isTeammate == false })
        let eveBubble = try #require(ana.person("Eve"))
        #expect(!ana.presence.canPing(eveBubble), "only teammates can be pinged")

        ana.presence.chat(with: eveBubble)
        let outgoing = try #require(ana.harness.app.takePendingChatStart())
        #expect(outgoing.role == .initiator)
        #expect(outgoing.teammate == nil)
        #expect(await TestFixtures.eventually { eve.harness.app.chatStartRequests == 1 })
        let incoming = try #require(eve.harness.app.takePendingChatStart())
        #expect(incoming.role == .responder)
        #expect(!incoming.expectsTeammate)
        #expect(await TestFixtures.eventually {
            network.advertisements.contains { $0.owner == "Eve" && $0.purpose == .chat }
        }, "Eve advertises again for the next person")
        outgoing.transport.close()
        incoming.transport.close()
    }

    // MARK: - Add Teammate (T2)

    @Test func addTeammatePairsTwoMacs() async throws {
        let network = FakeNearbyNetwork()
        let ana = try await Mac("Ana", network: network)
        let ben = try await Mac("Ben", network: network)
        let anaSheet = AddTeammateViewModel(app: ana.harness.app)
        let benSheet = AddTeammateViewModel(app: ben.harness.app)
        await anaSheet.start()
        await benSheet.start()
        #expect(await TestFixtures.eventually { anaSheet.peers.map(\.id) == ["Ben"] })

        anaSheet.pair(with: try #require(anaSheet.peers.first))
        #expect(await TestFixtures.eventually {
            if case .comparing = anaSheet.step, case .comparing = benSheet.step { true } else { false }
        })
        anaSheet.decide(.match)
        benSheet.decide(.match)

        #expect(await TestFixtures.eventually { anaSheet.step == .paired("Ben") && benSheet.step == .paired("Ana") })
        #expect(try ana.harness.data.team.teammates().map(\.name) == ["Ben"])
        #expect(try ben.harness.data.team.teammates().map(\.name) == ["Ana"])
        #expect(try ana.harness.data.team.teammateCards().first?.deviceID == ben.keys.deviceID)
    }

    @Test func addTeammateStopsWhenTheCodesDiffer() async throws {
        let network = FakeNearbyNetwork()
        let ana = try await Mac("Ana", network: network)
        let ben = try await Mac("Ben", network: network)
        let anaSheet = AddTeammateViewModel(app: ana.harness.app)
        let benSheet = AddTeammateViewModel(app: ben.harness.app)
        await anaSheet.start()
        await benSheet.start()
        #expect(await TestFixtures.eventually { !anaSheet.peers.isEmpty })
        anaSheet.pair(with: try #require(anaSheet.peers.first))
        #expect(await TestFixtures.eventually { if case .comparing = benSheet.step { true } else { false } })

        benSheet.decide(.mismatch)

        #expect(await TestFixtures.eventually { if case .failed = anaSheet.step { true } else { false } })
        #expect(try ana.harness.data.team.teammates().isEmpty)
        #expect(try ben.harness.data.team.teammates().isEmpty)
    }

    // MARK: - Settings and lock

    @Test func settingsChangeVisibilityAndRemoveTeammates() async throws {
        let (network, ana, ben) = try await Self.pairedMacs()
        let settings = TeammatesSettingsViewModel(app: ana.harness.app)
        #expect(await TestFixtures.eventually { settings.teammates.map(\.name) == ["Ben"] })

        settings.visibility = .nobody
        #expect(await TestFixtures.eventually { network.listeners["Ana"]?.serviceName == nil })
        settings.visibility = .teammates
        #expect(await TestFixtures.eventually { network.listeners["Ana"]?.serviceName != nil })

        settings.pendingRemoval = settings.teammates.first
        settings.confirmRemoval()
        #expect(await TestFixtures.eventually { settings.teammates.isEmpty })
        #expect(await TestFixtures.eventually { ana.person("Ben") == nil })
        _ = ben
    }

    @Test func lockStopsPresenceAndForgetsPeople() async throws {
        let (network, ana, _) = try await Self.pairedMacs()
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })

        ana.harness.app.lock(trigger: .manual)

        #expect(ana.presence.people.isEmpty)
        #expect(!ana.presence.isRunning)
        #expect(ana.presence.chatIdentity() == nil)
        #expect(await TestFixtures.eventually { network.listeners["Ana"]?.serviceName == nil })
    }
}
