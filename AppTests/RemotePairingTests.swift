import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Add Teammate › Not Nearby… (v0.9.0, P4) between two vaults: invitation, reply, the same six
/// words on both Macs, and The Words Match as the only write. Cancel stores nothing; damaged,
/// expired and own files fail; Share and Save hand over the staged card.
@MainActor
@Suite("Remote pairing")
struct RemotePairingTests {
    static let identityA = SpaceLocalIdentityModel(login: "user-a", displayName: "Teammate A", macName: "Mac A")
    static let identityB = SpaceLocalIdentityModel(login: "user-b", displayName: "Teammate B", macName: "Mac B")

    /// Records hand-offs; Save answers with `saveURL`.
    final class RecordingDelivery: PairingCardDelivering {
        var shared: [URL] = []
        var saveURL: URL?
        var outcome: ShareDeliveryOutcome = .shared

        func chooseSaveDestination(suggestedName: String) async -> URL? {
            saveURL
        }

        func share(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void) {
            shared.append(fileURL)
            completion(outcome)
        }
    }

    @MainActor
    struct Mac {
        let harness: TestHarness
        let identity: SpaceLocalIdentityModel
        let delivery = RecordingDelivery()
        let stagingRoot: URL

        init(_ identity: SpaceLocalIdentityModel) async throws {
            harness = try await TestHarness(vault: .unlocked)
            self.identity = identity
            stagingRoot = harness.sandbox.appendingPathComponent("staging", isDirectory: true)
        }

        var team: TeamRepository {
            harness.data.team
        }

        func pairing(file: Data? = nil) -> RemotePairingViewModel {
            let root = stagingRoot
            let identity = identity
            return RemotePairingViewModel(
                service: team,
                identity: { identity },
                delivery: delivery,
                file: file,
                makeStagingFolder: { try ShareStagingFolder(root: root) }
            )
        }

        func teammates() throws -> [TeammateModel] {
            try team.teammates()
        }
    }

    private func staged(_ model: RemotePairingViewModel) throws -> Data {
        let url = try #require(model.stagedFile)
        return try Data(contentsOf: url)
    }

    // MARK: - Round trip

    @Test func invitationReplyAndTheSameWordsPairBothMacs() async throws {
        let macA = try await Mac(Self.identityA)
        let macB = try await Mac(Self.identityB)

        let invite = macA.pairing()
        #expect(invite.step == .start)
        invite.createInvitation()
        #expect(invite.step == .invitationReady)
        let invitationURL = try #require(invite.stagedFile)
        #expect(invitationURL.lastPathComponent == "FX Vault teammate invitation.fxvcard")
        #expect(AppViewModel.isPairingCard(invitationURL))

        let invited = macB.pairing(file: try staged(invite))
        guard case .invitation(let inviter) = invited.step else {
            Issue.record("expected the invitation, got \(invited.step)")
            return
        }
        #expect(inviter.name == "Teammate A")
        #expect(inviter.detail == "user-a · Mac A")
        #expect(!inviter.isExistingTeammate)

        invited.createReply()
        guard case .replyReady(_, let codeB) = invited.step else {
            Issue.record("expected the reply, got \(invited.step)")
            return
        }
        #expect(codeB.count == 6)
        #expect(invited.stagedFile?.lastPathComponent == "FX Vault teammate reply.fxvcard")

        let reply = macA.pairing(file: try staged(invited))
        guard case .reply(let replier, let codeA) = reply.step else {
            Issue.record("expected the reply on A, got \(reply.step)")
            return
        }
        #expect(replier.name == "Teammate B")
        #expect(codeA == codeB, "both Macs show the same six words")
        #expect(try macA.teammates().isEmpty, "reading a reply stores nothing")
        #expect(try macB.teammates().isEmpty, "making a reply stores nothing")

        reply.confirm()
        invited.confirm()

        #expect(reply.step == .paired(name: "Teammate B", wasUpdate: false))
        #expect(invited.step == .paired(name: "Teammate A", wasUpdate: false))
        let onA = try #require(try macA.teammates().first)
        let onB = try #require(try macB.teammates().first)
        #expect(onA.name == "Teammate B" && onA.pairedVia == .remote && onA.hasAnnounceKey)
        #expect(onB.name == "Teammate A" && onB.pairedVia == .remote && !onB.hasAnnounceKey)

        // Teammates settings explain the remote pairing and the missing announce key.
        let settings = TeammatesSettingsViewModel(app: macB.harness.app)
        #expect(settings.pairingText(onB) == RemotePairingCopy.pairedRemotely)
        #expect(settings.lastSeenText(onB) == RemotePairingCopy.waitingForNearby)
        #expect(settings.pairingText(onA.withPairedVia(.nearby)) == nil)

        invite.close()
        invited.close()
        reply.close()
        #expect(!FileManager.default.fileExists(atPath: invitationURL.path), "the staged card is removed")
    }

    @Test func pairingAgainUpdatesTheTeammate() async throws {
        let macA = try await Mac(Self.identityA)
        let macB = try await Mac(Self.identityB)
        for _ in 0..<2 {
            let invite = macA.pairing()
            invite.createInvitation()
            let invited = macB.pairing(file: try staged(invite))
            invited.createReply()
            invited.confirm()
        }
        let invite = macA.pairing()
        invite.createInvitation()
        let invited = macB.pairing(file: try staged(invite))
        guard case .invitation(let inviter) = invited.step else {
            Issue.record("expected the invitation")
            return
        }
        #expect(inviter.isExistingTeammate)
        #expect(try macB.teammates().count == 1)
    }

    // MARK: - Nothing stored

    @Test func cancellingAfterTheReplyStoresNothing() async throws {
        let macA = try await Mac(Self.identityA)
        let macB = try await Mac(Self.identityB)
        let invite = macA.pairing()
        invite.createInvitation()
        let invited = macB.pairing(file: try staged(invite))
        invited.createReply()
        let replyURL = try #require(invited.stagedFile)

        invited.close()

        #expect(try macB.teammates().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: replyURL.path))
        invited.confirm()
        #expect(try macB.teammates().isEmpty, "a closed sheet cannot confirm")
    }

    @Test func aDamagedFileFails() async throws {
        let mac = try await Mac(Self.identityB)
        let model = mac.pairing(file: Data("not a teammate card".utf8))
        guard case .failed = model.step else {
            Issue.record("expected a failure, got \(model.step)")
            return
        }
        #expect(try mac.teammates().isEmpty)
    }

    @Test func anExpiredInvitationFails() async throws {
        let macA = try await Mac(Self.identityA)
        let macB = try await Mac(Self.identityB)
        let invite = macA.pairing()
        invite.createInvitation()
        macB.harness.clock.advance(by: Timeouts.pairingInvitationMaxAge + .seconds(Timeouts.secondsPerHour))

        let invited = macB.pairing(file: try staged(invite))

        #expect(invited.step == .failed(SharingError.share(.pairingExpired).errorPresentation.message))
    }

    @Test func thisMacsOwnInvitationFails() async throws {
        let macA = try await Mac(Self.identityA)
        let invite = macA.pairing()
        invite.createInvitation()

        let reopened = macA.pairing(file: try staged(invite))

        #expect(reopened.step == .failed(SharingError.share(.pairingOwnCard).errorPresentation.message))
    }

    // MARK: - Delivery

    @Test func shareAndSaveHandOverTheStagedCard() async throws {
        let mac = try await Mac(Self.identityA)
        let invite = mac.pairing()
        invite.createInvitation()
        let staged = try #require(invite.stagedFile)

        invite.share()
        #expect(mac.delivery.shared == [staged])
        #expect(await TestFixtures.eventually { invite.notice == RemotePairingCopy.shared })

        let destination = mac.harness.sandbox.appendingPathComponent("saved.fxvcard")
        mac.delivery.saveURL = destination
        await invite.save()
        #expect(try Data(contentsOf: destination) == Data(contentsOf: staged))
        #expect(invite.notice == RemotePairingCopy.saved)
    }

    @Test func onlyTeammateCardsAreRoutedToPairing() throws {
        #expect(AppViewModel.isPairingCard(URL(fileURLWithPath: "/tmp/invite.fxvcard")))
        #expect(AppViewModel.isPairingCard(URL(fileURLWithPath: "/tmp/INVITE.FXVCARD")))
        #expect(!AppViewModel.isPairingCard(URL(fileURLWithPath: "/tmp/share.fxvault")))
        let remote = try #require(URL(string: "https://example.invalid/invite.fxvcard"))
        #expect(!AppViewModel.isPairingCard(remote))
    }
}

private extension TeammateModel {
    func withPairedVia(_ pairing: TeammatePairing) -> TeammateModel {
        var copy = self
        copy.pairedVia = pairing
        return copy
    }
}
