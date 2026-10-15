import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Nearby send and receive over an in-memory network: equal-weight code answers with no
/// default, ReauthGate before MANIFEST, the manifest preview then the Same/Differs
/// confirmation, aborts with nothing transferred, the interception warning, and advertising
/// only while the receive sheet is open.
@MainActor
@Suite("Nearby share", .timeLimit(.minutes(1)))
struct SharingNearbyViewModelTests {
    @MainActor
    struct Fixture {
        let world: SharingWorld
        let network = InMemoryNearbyNetwork()
        let sender: NearbySendViewModel
        let receiver: NearbyReceiveViewModel

        init(selection: ShareSelectionModel?? = nil) async throws {
            world = try await SharingWorld()
            let chosen: ShareSelectionModel? = selection ?? .repository(world.senderRepositoryID)
            sender = NearbySendViewModel(
                context: NearbySendContext(selection: chosen),
                dependencies: world.senderDependencies(),
                network: network,
                identity: SharingWorld.identity
            )
            receiver = NearbyReceiveViewModel(
                context: NearbyReceiveContext(),
                dependencies: world.receiverDependencies(),
                network: network,
                identity: ShareLocalIdentityModel(displayName: "Receiver Mac", appVersion: "1.0.0")
            )
        }

        /// Both sheets open, the sender connects to the advertised receiver, both show a code.
        func connect() async throws {
            await receiver.start()
            await sender.start()
            #expect(sender.step == .browsing)
            let discovery = try #require(network.discovery)
            #expect(discovery.isStarted)
            discovery.publish([NearbyPeerModel(id: "FXVault-0123456789abcdef")])
            let sender = sender
            #expect(await TestFixtures.eventually { sender.peers.count == 1 })
            #expect(sender.peers.first?.shortLabel == "Mac cdef")
            await sender.connect(to: try #require(sender.peers.first))
            #expect(discovery.isStopped)
            let receiver = receiver
            #expect(await TestFixtures.eventually { sender.sas != nil && receiver.sas != nil })
        }

        /// Both users answer "Codes match"; the sender re-authenticates with the password.
        func confirmCodesAndAuthenticate() async throws {
            await receiver.decide(.match)
            await sender.decide(.match)
            let sender = sender
            #expect(await TestFixtures.eventually { sender.isReadyForManifest })
            guard case .authenticating = sender.step else {
                Issue.record("Sender is not authenticating: \(sender.step)")
                return
            }
            sender.reauth.password = testPassword
            await sender.authenticateWithPassword()
        }
    }

    @Test func neitherCodeAnswerIsADefaultButton() {
        #expect(SASDecision.allCases.count == 2)
        #expect(SASDecision.allCases.allSatisfy { !$0.isDefaultAction && !$0.usesProminentStyle })
        #expect(Set(SASDecision.allCases.map(\.title)).count == 2)
    }

    @Test func bothSidesShowTheSameCodeAndTheSenderName() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        let senderCode = try #require(fixture.sender.sas)
        let receiverCode = try #require(fixture.receiver.sas)
        #expect(senderCode.code == receiverCode.code)
        #expect(senderCode.code.count == Limits.nearbySASDigits + 1)
        #expect(receiverCode.peerName == SharingWorld.identity.displayName)
        #expect(senderCode.peerName == "Receiver Mac")
        fixture.sender.close()
        fixture.receiver.close()
    }

    @Test func reauthenticationRunsBeforeTheManifestIsSent() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        await fixture.receiver.decide(.match)
        await fixture.sender.decide(.match)
        let sender = fixture.sender
        let receiver = fixture.receiver
        #expect(await TestFixtures.eventually { sender.isReadyForManifest })

        // Touch ID is off: the automatic attempt is silent and nothing is sent.
        guard case .authenticating = sender.step else {
            Issue.record("Sender is not authenticating: \(sender.step)")
            return
        }
        #expect(sender.reauth.error == nil)
        sender.reauth.password = otherTestPassword
        await sender.authenticateWithPassword()
        #expect(sender.reauth.error != nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(receiver.editor == nil)
        if case .awaitingManifest = receiver.step {} else {
            Issue.record("Receiver got past the code without a manifest: \(receiver.step)")
        }

        sender.reauth.password = testPassword
        await sender.authenticateWithPassword()
        #expect(await TestFixtures.eventually { receiver.step == .reviewingManifest })
        #expect(sender.step == .awaitingDecision)
        sender.close()
        receiver.close()
    }

    @Test func aFullShareAsksForTheSecondConfirmationBeforeApplying() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        try await fixture.confirmCodesAndAuthenticate()
        let sender = fixture.sender
        let receiver = fixture.receiver
        #expect(await TestFixtures.eventually { receiver.step == .reviewingManifest })

        // Manifest preview: chips that need no values.
        let manifest = try #require(receiver.editor)
        func chip(_ name: String, in editor: ShareImportPlanEditor) -> ShareItemChip? {
            editor.plan.allItems.first { $0.key.name == name }?.chip
        }
        #expect(chip("NEW_SECRET", in: manifest) == .new)
        #expect(chip("API_TOKEN", in: manifest) == .existsLocally)
        #expect(chip("BASE_URL", in: manifest) == .existsLocally)
        #expect(receiver.senderName == SharingWorld.identity.displayName)
        #expect(receiver.canAccept)

        await receiver.accept()
        #expect(await TestFixtures.eventually { receiver.step == .confirmingPayload })

        // Payload preview: Same / Differs, Keep mine by default, nothing applied yet.
        let payload = try #require(receiver.editor)
        #expect(chip("API_TOKEN", in: payload) == .differs)
        #expect(payload.plan.allItems.first { $0.key.name == "API_TOKEN" }?.action == .keepMine)
        #expect(chip("BASE_URL", in: payload) == .same)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        #expect(!textDump(payload.plan, manifest.plan).contains(SharingWorld.secretValue))

        await receiver.apply()
        #expect(receiver.step == .done)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == SharingWorld.secretValue)
        #expect(try await fixture.world.receiverValue("API_TOKEN", kind: .secret) == SharingWorld.receiverSecretValue)
        #expect(await TestFixtures.eventually { sender.step == .finished(.delivered) })
        #expect(!textDump(receiver.result as Any).contains(SharingWorld.secretValue))
    }

    @Test func rejectingTheValuesImportsNothing() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        try await fixture.confirmCodesAndAuthenticate()
        let sender = fixture.sender
        let receiver = fixture.receiver
        #expect(await TestFixtures.eventually { receiver.step == .reviewingManifest })
        await receiver.accept()
        #expect(await TestFixtures.eventually { receiver.step == .confirmingPayload })
        await receiver.rejectPayload()
        #expect(receiver.step == .declined)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        #expect(await TestFixtures.eventually { sender.step == .finished(.receiverRejected) })
    }

    @Test func rejectingTheManifestTransfersNothing() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        try await fixture.confirmCodesAndAuthenticate()
        let sender = fixture.sender
        let receiver = fixture.receiver
        #expect(await TestFixtures.eventually { receiver.step == .reviewingManifest })
        await receiver.reject()
        #expect(await TestFixtures.eventually { receiver.step == .declined && sender.step == .finished(.declined) })
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
    }

    @Test func dontMatchAbortsBothSidesWithNothingTransferred() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        let sender = fixture.sender
        let receiver = fixture.receiver
        await sender.decide(.mismatch)
        #expect(await TestFixtures.eventually { sender.step == .failed && receiver.step == .failed })
        #expect(sender.abort?.reason == .sasRejected)
        #expect(receiver.abort?.reason == .peerAborted(.sasRejected))
        #expect(receiver.editor == nil)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        // The authorization was never requested.
        #expect(!sender.reauth.isAuthorized)
        // No automatic retry: a new attempt needs Try Again.
        #expect(fixture.network.discoveries.count == 1)
        sender.tryAgain()
        #expect(fixture.network.discoveries.count == 2)
        #expect(sender.step == .browsing)
    }

    @Test func aTamperedFrameAfterTheKeyExchangeShowsTheInterceptionWarning() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        let receiver = fixture.receiver
        // A frame no honest sender produces arrives after REVEAL.
        fixture.network.responder.inject(.received(Data([0x01, 0x11, 0x00])))
        #expect(await TestFixtures.eventually { receiver.step == .failed })
        #expect(receiver.abort?.happenedAfterReveal == true)
        #expect(receiver.showsInterceptionWarning)
        #expect(NearbyAbortModel.interceptionWarning == "Someone nearby may be trying to intercept this share.")
    }

    @Test func theReceiveSheetAdvertisesOnlyWhileOpen() async throws {
        let fixture = try await Fixture()
        let receiver = fixture.receiver
        #expect(fixture.network.advertisedCount == 0)
        await receiver.start()
        #expect(fixture.network.advertisedCount == 1)
        #expect(receiver.isAdvertising)
        #expect(receiver.step == .waiting)

        receiver.close()
        #expect(!receiver.isAdvertising)
        #expect(await TestFixtures.eventually { fixture.network.responder.isClosed })
    }

    @Test func aDeniedLocalNetworkShowsGuidance() async throws {
        let fixture = try await Fixture()
        let sender = fixture.sender
        await sender.start()
        let discovery = try #require(fixture.network.discovery)
        discovery.fail(.localNetworkDenied)
        #expect(await TestFixtures.eventually { sender.networkError != nil })
        #expect(sender.networkError == NearbyTransportFailure.localNetworkDenied.presentation)
        sender.startBrowsing()
        #expect(sender.networkError == nil)
        #expect(fixture.network.discoveries.count == 2)
        sender.close()
    }

    @Test func withoutASelectionTheSenderPicksARepositoryAndScope() async throws {
        let fixture = try await Fixture(selection: .some(nil))
        let sender = fixture.sender
        #expect(sender.step == .chooseSelection)
        await sender.start()
        #expect(sender.repositories.map(\.id) == [fixture.world.senderRepositoryID])
        #expect(!sender.canContinueWithSelection)
        await sender.chooseRepository(fixture.world.senderRepositoryID)
        #expect(sender.tree?.selection == .repository(fixture.world.senderRepositoryID))
        #expect(sender.canContinueWithSelection)
        sender.continueWithSelection()
        #expect(sender.step == .browsing)
        #expect(sender.selection == .repository(fixture.world.senderRepositoryID))
        sender.close()
    }

    @Test func theNearbyPickerUsesTheSameMultiSelectTree() async throws {
        let fixture = try await Fixture(selection: .some(nil))
        let sender = fixture.sender
        await sender.start()
        await sender.chooseRepository(fixture.world.senderRepositoryID)
        let tree = try #require(sender.tree)
        let environment = try #require(tree.root.children?.first { $0.kind == .environment })
        // Repository level only: the environment is left out.
        sender.setChecked(false, for: environment)
        #expect(!sender.canContinueWithSelection)
        #expect(await TestFixtures.eventually {
            sender.preview?.summary.environments.isEmpty == true
                && sender.preview?.summary.repositoryLevel == ShareItemCountModel(secrets: 2, variables: 1)
        })
        guard case .subset(let subset) = sender.tree?.selection else {
            Issue.record("Expected a subset, got \(String(describing: sender.tree?.selection))")
            return
        }
        #expect(subset.environmentIDs.isEmpty)
        #expect(subset.itemIDs.count == 3)
        #expect(sender.canContinueWithSelection)
        sender.continueWithSelection()
        #expect(sender.step == .browsing)
        #expect(sender.selection == .subset(subset))
        sender.close()
    }

    @Test func aLockCancelsTheSessionAndDropsTheAuthorization() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        let sender = fixture.sender
        let receiver = fixture.receiver
        sender.reauth.password = "typed"
        fixture.world.sender.app.lock(trigger: .manual)
        #expect(sender.step == .failed)
        #expect(sender.reauth.password.isEmpty)
        #expect(await TestFixtures.eventually { receiver.step == .failed })
    }
}
