import Foundation
import SharingKit
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Teammates (v0.5.0, tasks/todo.md T1–T2): this device's keys sealed in the vault, teammates
/// with sealed announce keys, removal renewing the announce key, card updates, and DEK rotation.
@Suite("TeamRepository")
struct TeamRepositoryTests {
    private static func team(_ harness: ConfigHarness) -> TeamRepository {
        TeamRepository(session: harness.session, clock: harness.clock)
    }

    private static func card(_ name: String) -> TeamCardModel {
        TeamDeviceKeys.generate().card(login: name.lowercased(), displayName: name, macName: "\(name)'s Mac")
    }

    @Test func deviceKeysAreCreatedOnceAndSurviveALock() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let first = try team.deviceKeys()
        #expect(try team.deviceKeys().deviceID == first.deviceID)

        harness.manager.lock()
        #expect(throws: TeamRepositoryError.vault(.locked)) { try team.deviceKeys() }
        try await harness.manager.unlock(password: ConfigFixture.password)
        let reopened = try team.deviceKeys()
        #expect(reopened.deviceID == first.deviceID)
        #expect(reopened.signingPublicKey == first.signingPublicKey)

        let stored = try #require(try harness.database.read { tx in try TeamStore(database: harness.database).fetchIdentity(in: tx) })
        #expect(stored.deviceID == first.deviceID.hex)
        #expect(!stored.secretCiphertext.isEmpty)
    }

    @Test func teammatesAreStoredWithTheirAnnounceKeySealed() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let ana = Self.card("Ana")
        let ben = Self.card("Ben")
        try team.addTeammate(ben)
        try team.addTeammate(ana)

        #expect(try team.teammates().map(\.name) == ["Ana", "Ben"])
        #expect(Set(try team.teammateCards()) == [ana, ben])
        let record = try #require(try harness.database.read { tx in
            try TeamStore(database: harness.database).fetchTeammate(deviceID: ana.deviceID.hex, in: tx)
        })
        #expect(record.announceCiphertext != ana.announceKey)
        #expect(!record.announceCiphertext.contains(ana.announceKey.prefix(8)))

        harness.manager.lock()
        #expect(try team.teammates().count == 2, "names stay readable while locked")
        #expect(throws: TeamRepositoryError.vault(.locked)) { try team.teammateCards() }
    }

    @Test func pairingTheSameDeviceAgainKeepsItsState() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let ana = Self.card("Ana")
        try team.addTeammate(ana)
        try team.setMuted(true, teammate: ana.deviceID.hex)
        harness.clock.advance(by: .seconds(60))
        try team.markSeen(ana.deviceID.hex)

        try team.addTeammate(ana)

        let model = try #require(try team.teammates().first)
        #expect(model.isMuted)
        #expect(model.lastSeenAt == harness.clock.now)
        #expect(throws: TeamRepositoryError.store(.notFound)) { try team.markSeen("00000000000000000000000000000000") }
    }

    @Test func removingATeammateRenewsTheAnnounceKeyForTheOthers() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let before = try team.deviceKeys()
        let ana = Self.card("Ana")
        let ben = Self.card("Ben")
        try team.addTeammate(ana)
        try team.addTeammate(ben)

        try team.removeTeammate(id: ana.deviceID.hex)

        let after = try team.deviceKeys()
        #expect(after.deviceID == before.deviceID, "same keys, same id")
        #expect(TeamPseudonym.name(for: after, at: harness.clock.now) != TeamPseudonym.name(for: before, at: harness.clock.now))
        #expect(try team.teammates().map(\.name) == ["Ben"])
        #expect(try team.teammates().first?.needsCardUpdate == true)
        try team.cardUpdateDelivered(to: ben.deviceID.hex)
        #expect(try team.teammates().first?.needsCardUpdate == false)
        #expect(throws: TeamRepositoryError.teammateNotFound) { try team.removeTeammate(id: ana.deviceID.hex) }
    }

    @Test func aCardUpdateMustKeepTheTeammatesKeys() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let keys = TeamDeviceKeys.generate()
        let ana = keys.card(login: "ana", displayName: "Ana", macName: "")
        try team.addTeammate(ana)
        let renewed = keys.withNewAnnounceKey().card(login: "ana", displayName: "Ana", macName: "")

        try team.applyCardUpdate(renewed)
        #expect(try team.teammateCards() == [renewed])

        #expect(throws: TeamRepositoryError.teammateNotFound) { try team.applyCardUpdate(Self.card("Eve")) }
    }

    @Test func dekRotationKeepsTeamKeysReadable() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let device = try team.deviceKeys()
        let ana = Self.card("Ana")
        try team.addTeammate(ana)

        let recovery = try await harness.manager.rotateDEK(password: ConfigFixture.password)
        recovery.wipe()

        #expect(try team.deviceKeys().deviceID == device.deviceID)
        #expect(try team.teammateCards() == [ana])
    }

    @Test func remoteAccessIsOffUntilTurnedOnPerTeammate() async throws {
        let harness = try await ConfigHarness.make()
        let team = Self.team(harness)
        let ana = Self.card("Ana")
        try team.addTeammate(ana)
        #expect(try team.remoteAccess().isEmpty)

        try team.setRemoteAccess(ana.deviceID.hex, isAllowed: true, address: nil)
        #expect(try team.remoteAccess().map(\.isAllowed) == [true])
        #expect(try team.remoteAccess().first?.address == nil)
        let address = try #require(TeamRemoteAddressModel(text: "mac-a.example:52731"))
        try team.setRemoteAccess(ana.deviceID.hex, isAllowed: true, address: address)
        try team.markRemoteConnection(ana.deviceID.hex, at: harness.clock.now)
        let access = try #require(try team.remoteAccess().first)
        #expect(access.address == address && access.lastConnectedAt == harness.clock.now)
        #expect(throws: TeamRepositoryError.teammateNotFound) {
            try team.setRemoteAccess(Self.card("Eve").deviceID.hex, isAllowed: true, address: nil)
        }

        try team.removeTeammate(id: ana.deviceID.hex)
        #expect(try team.remoteAccess().isEmpty, "removing the teammate removes its address")
    }
}
