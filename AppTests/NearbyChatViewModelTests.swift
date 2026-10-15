import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// A transport that never connects (an advertisement nobody answers). Closing it ends its
/// events, as a closed listener does.
final class IdleChatTransport: NearbyTransport, @unchecked Sendable {
    let events: AsyncStream<NearbyTransportEvent>
    private let continuation: AsyncStream<NearbyTransportEvent>.Continuation
    private let lock = NSLock()
    private var closed = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func send(_ frame: Data) async throws(ShareError) {
        throw .transport(.notConnected)
    }

    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }

    /// The listener failed or a connection dropped before the handshake.
    func fail() {
        continuation.yield(.failed(.connectionFailed))
        continuation.finish()
    }
}

/// Forwards only the first frame (HELLO_I) and swallows the rest: a stranger who connects,
/// says hello and never reveals its key.
final class FirstFrameOnlyTransport: NearbyTransport, @unchecked Sendable {
    private let base: InMemoryTransport
    private let lock = NSLock()
    private var hasForwarded = false

    init(_ base: InMemoryTransport) {
        self.base = base
    }

    var events: AsyncStream<NearbyTransportEvent> {
        base.events
    }

    func send(_ frame: Data) async throws(ShareError) {
        let isFirst = lock.withLock {
            defer { hasForwarded = true }
            return !hasForwarded
        }
        if isFirst {
            try await base.send(frame)
        }
    }

    func close() {
        base.close()
    }
}

/// One Mac's view of the chat "air": its discoveries hand out `connectTransport`, its
/// advertisements come from `advertise` (in order), all in memory.
@MainActor
final class FakeChatNetwork: NearbyChatNetworking {
    let serviceName: String
    /// The name Bonjour registers, when it renames the advertisement on a conflict.
    var registeredName: String?
    private let connectTransport: () -> (any NearbyTransport)?
    private var pendingAdvertisements: [any NearbyTransport]
    private(set) var discoveries: [FakeNearbyDiscovery] = []
    private(set) var advertisedNames: [String] = []
    private(set) var advertisements: [any NearbyTransport] = []

    init(
        serviceName: String,
        connect: @escaping () -> (any NearbyTransport)?,
        advertisements: [any NearbyTransport] = []
    ) {
        self.serviceName = serviceName
        connectTransport = connect
        pendingAdvertisements = advertisements
    }

    func makeDiscovery() -> any NearbyPeerDiscovering {
        let discovery = FakeNearbyDiscovery(transport: connectTransport)
        discoveries.append(discovery)
        return discovery
    }

    func makeAdvertisement(displayName: String) -> NearbyChatAdvertisementModel {
        advertisedNames.append(displayName)
        let transport = pendingAdvertisements.isEmpty ? IdleChatTransport() : pendingAdvertisements.removeFirst()
        advertisements.append(transport)
        let registeredName = registeredName
        return NearbyChatAdvertisementModel(
            transport: transport,
            serviceName: serviceName,
            registeredNames: AsyncStream { continuation in
                if let registeredName {
                    continuation.yield(registeredName)
                }
                continuation.finish()
            }
        )
    }

    var discovery: FakeNearbyDiscovery? {
        discoveries.last
    }
}

/// Nearby Chat window: discovery and visibility, the code comparison, ephemeral text, the
/// attachment flow behind ReauthGate, the card without a value, saving through the share import
/// preview, availability without internet, and the wipe on close, lock, sleep and disconnect.
@MainActor
@Suite("Nearby chat window", .timeLimit(.minutes(1)))
struct NearbyChatViewModelTests {
    static let nameA = "Mac A"
    static let nameB = "Mac B"
    static let repository = "\(TestFixtures.owner)/\(TestFixtures.repoName)"

    @MainActor
    struct Fixture {
        let world: SharingWorld
        let pair = InMemoryTransportPair()
        let initiator: RecordingTransport
        let responder: RecordingTransport
        let networkA: FakeChatNetwork
        let networkB: FakeChatNetwork
        /// Mac A (the sender vault): browses and connects.
        let macA: NearbyChatViewModel
        /// Mac B (the receiver vault): advertises and is connected to.
        let macB: NearbyChatViewModel
        /// Mac B's "Save as File…" save panel.
        let fileDelivery: FakeShareFileDelivery

        init() async throws {
            world = try await SharingWorld()
            let initiator = RecordingTransport(pair.initiator)
            let responder = RecordingTransport(pair.responder)
            let fileDelivery = FakeShareFileDelivery()
            self.initiator = initiator
            self.responder = responder
            self.fileDelivery = fileDelivery
            networkA = FakeChatNetwork(serviceName: NearbyChatViewModelTests.nameA, connect: { initiator })
            networkB = FakeChatNetwork(serviceName: NearbyChatViewModelTests.nameB, connect: { nil }, advertisements: [responder])
            macA = NearbyChatViewModel(
                app: world.sender.app,
                dependencies: world.senderDependencies(),
                network: networkA,
                identity: ShareLocalIdentityModel(displayName: NearbyChatViewModelTests.nameA, appVersion: "1.0.0")
            )
            macB = NearbyChatViewModel(
                app: world.receiver.app,
                dependencies: world.receiverDependencies(),
                network: networkB,
                identity: ShareLocalIdentityModel(displayName: NearbyChatViewModelTests.nameB, appVersion: "1.0.0"),
                makeFileDelivery: { fileDelivery }
            )
        }

        /// Both windows open; A sees B and connects; both show a code.
        func connect() async throws {
            await macB.start()
            await macA.start()
            let discovery = try #require(networkA.discovery)
            discovery.publish([
                NearbyPeerModel(id: NearbyChatViewModelTests.nameA),
                NearbyPeerModel(id: NearbyChatViewModelTests.nameB),
            ])
            let macA = macA
            let macB = macB
            #expect(await TestFixtures.eventually { macA.peers.count == 1 })
            await macA.connect(to: try #require(macA.peers.first))
            #expect(await TestFixtures.eventually { macA.sas != nil && macB.sas != nil })
        }

        /// Both press "Codes match".
        func chat() async throws {
            try await connect()
            await macA.decide(.match)
            await macB.decide(.match)
            let macA = macA
            let macB = macB
            #expect(await TestFixtures.eventually { macA.step == .chatting && macB.step == .chatting })
        }

        /// A attaches `name` (re-authenticating with the password); B shows the card.
        func attach(_ name: String = "NEW_SECRET") async throws -> ChatAttachmentID {
            macA.attach()
            let picker = try #require(macA.picker)
            await picker.begin()
            picker.reauth.password = testPassword
            await picker.authenticateWithPassword()
            picker.selectedID = try #require(picker.items.first { $0.name == name }).id
            await picker.send()
            let macB = macB
            #expect(await TestFixtures.eventually { !macB.cards.isEmpty })
            return try #require(macB.cards.keys.first)
        }

        /// A attaches its whole repository (v0.4.0); returns the id of B's new card.
        func attachRepository() async throws -> ChatAttachmentID {
            let known = Set(macB.cards.keys)
            macA.attach()
            let picker = try #require(macA.picker)
            await picker.begin()
            picker.reauth.password = testPassword
            await picker.authenticateWithPassword()
            picker.mode = .repository
            picker.selectedRepositoryID = world.senderRepositoryID
            await picker.send()
            let macB = macB
            #expect(await TestFixtures.eventually { macB.cards.keys.contains { !known.contains($0) } })
            return try #require(macB.cards.keys.first { !known.contains($0) })
        }

        /// B chooses "Save as File…" on the repository card `id` and saves it through the fake
        /// save panel; returns the file and its passphrase.
        func saveRepositoryAsFile(_ id: ChatAttachmentID) async throws -> (url: URL, passphrase: String) {
            await macB.handleConfiguration(id, .saveAsFile)
            let macB = macB
            #expect(await TestFixtures.eventually { macB.fileSheet != nil })
            let sheet = try #require(macB.fileSheet)
            #expect(sheet.isFromChat)
            #expect(macB.cards[id]?.status == .savingToFile)
            await sheet.start()
            #expect(sheet.preview?.itemCount == 4)
            sheet.reauth.password = testPassword
            await sheet.authenticateWithPassword()
            #expect(sheet.canCreate)
            await sheet.createShareFile()
            let passphrase = try #require(sheet.passphrase)
            sheet.hasSavedPassphrase = true
            let destination = world.receiver.sandbox.appendingPathComponent("Received-\(UUID().uuidString).fxvault")
            fileDelivery.saveDestination = destination
            await sheet.saveToFile()
            #expect(sheet.savedFileURL == destination)
            macB.fileSheetDismissed()
            #expect(macB.fileSheet == nil)
            #expect(sheet.passphrase == nil)
            return (destination, passphrase)
        }

        func close() {
            macA.close()
            macB.close()
        }
    }

    // MARK: - Discovery and visibility

    @Test func theWindowListsNearbyPeopleButNotThisMac() async throws {
        let fixture = try await Fixture()
        let macA = fixture.macA
        await macA.start()
        #expect(macA.step == .browsing)
        #expect(macA.isVisible)
        #expect(macA.displayName == Self.nameA)
        #expect(fixture.networkA.advertisedNames == [Self.nameA])
        let discovery = try #require(fixture.networkA.discovery)
        #expect(discovery.isStarted)
        discovery.publish([NearbyPeerModel(id: Self.nameA), NearbyPeerModel(id: "Teammate\u{202E}Mac")])
        #expect(await TestFixtures.eventually { macA.peers.count == 1 })
        // The advertised name is sanitized for display (bidi controls removed).
        #expect(macA.peers.first?.chatDisplayName == "TeammateMac")
        fixture.close()
    }

    @Test func aMacAdvertisingThisUsersNameStaysVisibleWhenBonjourRenamesThisOne() async throws {
        let fixture = try await Fixture()
        let macA = fixture.macA
        // Someone else already advertises "Mac A": Bonjour registers this Mac as "Mac A (2)".
        fixture.networkA.registeredName = "\(Self.nameA) (2)"
        await macA.start()
        let discovery = try #require(fixture.networkA.discovery)
        discovery.publish([
            NearbyPeerModel(id: Self.nameA),
            NearbyPeerModel(id: "\(Self.nameA) (2)"),
            NearbyPeerModel(id: Self.nameB),
        ])
        // The impostor is listed; this Mac (under its registered name) is not.
        #expect(await TestFixtures.eventually { macA.peers.map(\.id) == [Self.nameA, Self.nameB] })
        fixture.close()
    }

    @Test func thisMacIsVisibleOnlyWhileTheWindowIsOpen() async throws {
        let fixture = try await Fixture()
        let macA = fixture.macA
        await macA.start()
        let advertisement = try #require(fixture.networkA.advertisements.first as? IdleChatTransport)
        #expect(!advertisement.isClosed)
        macA.close()
        #expect(!macA.isVisible)
        #expect(fixture.networkA.discovery?.isStopped == true)
        #expect(await TestFixtures.eventually { advertisement.isClosed })
    }

    @Test func theVisibleNameComesFromPreferences() async throws {
        let world = try await SharingWorld()
        let network = FakeChatNetwork(serviceName: "unused", connect: { nil })
        let preferences = world.sender.preferences
        preferences.nearbyDisplayName = "  User A's MacBook  "
        let viewModel = NearbyChatViewModel(app: world.sender.app, dependencies: world.senderDependencies(), network: network)
        await viewModel.start()
        #expect(viewModel.displayName == "User A's MacBook")
        #expect(network.advertisedNames == ["User A's MacBook"])
        viewModel.close()

        // A blank name falls back to the macOS user's name.
        preferences.nearbyDisplayName = "   "
        #expect(preferences.nearbyDisplayName == nil)
        await viewModel.start()
        #expect(viewModel.displayName == ShareLocalIdentityModel.current.displayName)
        viewModel.close()
    }

    @Test func aDeniedLocalNetworkShowsGuidanceAndTryAgainRestarts() async throws {
        let fixture = try await Fixture()
        let macA = fixture.macA
        await macA.start()
        fixture.networkA.discovery?.fail(.localNetworkDenied)
        #expect(await TestFixtures.eventually { macA.discoveryError != nil })
        #expect(macA.discoveryError == NearbyTransportFailure.localNetworkDenied.presentation)
        await macA.start()
        #expect(macA.discoveryError == nil)
        #expect(fixture.networkA.discoveries.count == 2)
        fixture.close()
    }

    @Test func aFailingAdvertisementIsRetriedAFewTimesThenReported() async throws {
        let world = try await SharingWorld()
        let failing = (0..<4).map { _ in IdleChatTransport() }
        let network = FakeChatNetwork(serviceName: Self.nameA, connect: { nil }, advertisements: failing)
        let viewModel = NearbyChatViewModel(
            app: world.sender.app,
            dependencies: world.senderDependencies(),
            network: network,
            identity: ShareLocalIdentityModel(displayName: Self.nameA, appVersion: "1.0.0")
        )
        await viewModel.start()
        for (index, transport) in failing.enumerated() {
            #expect(await TestFixtures.eventually { network.advertisements.count == index + 1 })
            transport.fail()
        }
        #expect(await TestFixtures.eventually { viewModel.visibilityError != nil })
        #expect(!viewModel.isVisible)
        #expect(viewModel.step == .browsing)
        #expect(network.advertisements.count == failing.count)
        viewModel.close()
    }

    @Test func strangersWhoConnectAndDropOrSendGarbageNeverMakeThisMacInvisible() async throws {
        let world = try await SharingWorld()
        // More than the listener-failure limit: none of these may count toward it.
        let strangers = (0..<5).map { _ in InMemoryTransportPair() }
        let network = FakeChatNetwork(serviceName: Self.nameA, connect: { nil }, advertisements: strangers.map(\.responder))
        let viewModel = NearbyChatViewModel(
            app: world.sender.app,
            dependencies: world.senderDependencies(),
            network: network,
            identity: ShareLocalIdentityModel(displayName: Self.nameA, appVersion: "1.0.0")
        )
        await viewModel.start()
        for (index, stranger) in strangers.enumerated() {
            #expect(await TestFixtures.eventually { network.advertisements.count == index + 1 })
            // The listener withdrew the advertisement when it accepted the connection.
            #expect(await TestFixtures.eventually { !viewModel.isVisible })
            #expect(viewModel.step == .browsing)
            if index.isMultiple(of: 2) {
                // Silent, then gone.
                stranger.initiator.close()
            } else {
                // Garbage instead of HELLO_I.
                try await stranger.initiator.send(Data([0xFF, 0x00, 0x01]))
            }
        }
        #expect(await TestFixtures.eventually { network.advertisements.count == strangers.count + 1 })
        #expect(viewModel.isVisible)
        #expect(viewModel.visibilityError == nil)
        #expect(viewModel.step == .browsing)
        #expect(viewModel.tracker.consecutiveFailures == 0)
        viewModel.close()
    }

    @Test func aStrangerWhoLeavesBeforeTheCodeIsShownLeavesNoEndedScreenOrWarning() async throws {
        let world = try await SharingWorld()
        let strangers = (0..<3).map { _ in InMemoryTransportPair() }
        let network = FakeChatNetwork(serviceName: Self.nameB, connect: { nil }, advertisements: strangers.map(\.responder))
        let viewModel = NearbyChatViewModel(
            app: world.receiver.app,
            dependencies: world.receiverDependencies(),
            network: network,
            identity: ShareLocalIdentityModel(displayName: Self.nameB, appVersion: "1.0.0")
        )
        await viewModel.start()
        for (index, stranger) in strangers.enumerated() {
            #expect(await TestFixtures.eventually { network.advertisements.count == index + 1 })
            let session = NearbyChatSession(
                role: .initiator,
                localName: "Alice (IT)",
                transport: FirstFrameOnlyTransport(stranger.initiator),
                clock: ManualClock()
            )
            try await session.start()
            #expect(await TestFixtures.eventually { viewModel.step == .connecting(peerName: "Alice (IT)") })
            #expect(!viewModel.isVisible)
            await session.close()
            // Back to the people list and advertising again: no "Conversation ended" screen.
            // (The next stranger is already connected to the new advertisement.)
            #expect(await TestFixtures.eventually { network.advertisements.count == index + 2 })
            #expect(viewModel.step == .browsing)
            #expect(viewModel.endModel == nil)
        }
        // Nobody holds the last advertisement: this Mac is visible.
        #expect(viewModel.isVisible)
        // None of them counts as a failed handshake, so no interception warning builds up.
        #expect(viewModel.tracker.consecutiveFailures == 0)
        #expect(viewModel.visibilityError == nil)
        viewModel.close()
    }

    // MARK: - Code comparison

    @Test func connectingShowsTheSameCodeOnBothMacsAndStopsVisibility() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        let codeA = try #require(fixture.macA.sas)
        let codeB = try #require(fixture.macB.sas)
        #expect(codeA.code == codeB.code)
        #expect(codeA.peerName == Self.nameB)
        #expect(codeB.peerName == Self.nameA)
        // Neither answer is a default button (shared SASCodeView rule).
        #expect(SASDecision.allCases.allSatisfy { !$0.isDefaultAction && !$0.usesProminentStyle })
        // In a chat nobody else can find either Mac.
        #expect(!fixture.macA.isVisible)
        #expect(!fixture.macB.isVisible)
        #expect(fixture.networkA.discovery?.isStopped == true)
        #expect(fixture.networkB.discovery?.isStopped == true)
        #expect((fixture.networkA.advertisements.first as? IdleChatTransport)?.isClosed == true)
        fixture.close()
    }

    @Test func codesMatchOnBothMacsStartsTheChat() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        await fixture.macA.decide(.match)
        #expect(fixture.macA.isCodeConfirmed)
        let macA = fixture.macA
        let macB = fixture.macB
        #expect(await TestFixtures.eventually { macB.isPeerCodeConfirmed })
        #expect(macA.step != .chatting)
        await macB.decide(.match)
        #expect(await TestFixtures.eventually { macA.step == .chatting && macB.step == .chatting })
        #expect(macA.peerName == Self.nameB)
        #expect(macB.peerName == Self.nameA)
        fixture.close()
    }

    @Test func dontMatchEndsTheChatOnBothMacs() async throws {
        let fixture = try await Fixture()
        try await fixture.connect()
        await fixture.macB.decide(.mismatch)
        let macA = fixture.macA
        let macB = fixture.macB
        #expect(await TestFixtures.eventually { macA.endReason != nil && macB.endReason != nil })
        #expect(macB.endReason == .aborted(NearbyAbortModel(reason: .sasRejected, happenedAfterReveal: true)))
        guard case .aborted(let abort) = macA.endReason else {
            Issue.record("Mac A did not abort: \(macA.step)")
            return
        }
        #expect(abort.reason == .peerAborted(.sasRejected))
        #expect(abort.chatMessage == "The other person pressed Don't Match, so the chat was stopped.")
        // "Start New Chat" makes this Mac visible again.
        await macA.start()
        #expect(macA.step == .browsing)
        #expect(fixture.networkA.advertisements.count == 2)
        fixture.close()
    }

    // MARK: - Messages

    @Test func messagesTravelBothWaysAndLiveOnlyInMemory() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        #expect(!macA.canSend)
        macA.draft = "   \n "
        #expect(!macA.canSend)
        macA.draft = "Hello from A\u{202E}"
        #expect(macA.canSend)
        await macA.send()
        #expect(macA.draft.isEmpty)
        #expect(macA.messages.map(\.text) == ["Hello from A"])
        #expect(macA.messages.first?.direction == .sent)
        #expect(await TestFixtures.eventually { macB.messages.map(\.text) == ["Hello from A"] })
        #expect(macB.messages.first?.direction == .received)

        macB.draft = "Hi A"
        await macB.send()
        #expect(await TestFixtures.eventually { macA.messages.map(\.text) == ["Hello from A", "Hi A"] })
        fixture.close()
    }

    @Test func copyingAMessageGoesThroughTheClipboardManager() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        macA.draft = "example-token-123"
        await macA.send()
        #expect(await TestFixtures.eventually { macB.messages.count == 1 })
        let message = try #require(macB.messages.first)
        macB.copy(message)
        let harness = fixture.world.receiver
        #expect(harness.pasteboardString == "example-token-123")
        #expect(harness.pasteboard.types?.contains(ClipboardManager.Marker.concealed) == true)
        #expect(harness.container.clipboard.ownsContents)
        // Locking clears it, like a copied value.
        harness.app.lock(trigger: .manual)
        #expect(harness.pasteboardString == nil)
        fixture.close()
    }

    @Test func theCharacterLimitIsEnforcedBeforeSending() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        macA.draft = String(repeating: "a", count: Limits.chatMessageBytes)
        #expect(macA.remainingMessageBytes == 0)
        #expect(macA.canSend)
        macA.draft += "b"
        #expect(macA.remainingMessageBytes == -1)
        #expect(macA.isDraftTooLong)
        #expect(!macA.canSend)
        await macA.send()
        #expect(macA.messages.isEmpty)
        fixture.close()
    }

    // MARK: - Attachments

    @Test func attachingAsksForTouchIDOrThePasswordFirst() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        macA.attach()
        let picker = try #require(macA.picker)
        #expect(picker.step == .authenticating)
        // Touch ID is off: the automatic attempt is silent and nothing is listed yet.
        await picker.begin()
        #expect(picker.step == .authenticating)
        #expect(picker.reauth.error == nil)
        #expect(picker.items.isEmpty)
        picker.reauth.password = otherTestPassword
        await picker.authenticateWithPassword()
        #expect(picker.reauth.error != nil)
        #expect(picker.step == .authenticating)
        #expect(picker.items.isEmpty)
        #expect(!picker.canSend)

        picker.reauth.password = testPassword
        await picker.authenticateWithPassword()
        #expect(picker.step == .choosing)
        #expect(picker.reauth.password.isEmpty)
        #expect(picker.items.map(\.name) == ["API_TOKEN", "NEW_SECRET", "BASE_URL", "DEPLOY_KEY"])
        #expect(picker.sections.map(\.environmentName) == [nil, SharingWorld.environment])
        picker.query = "deploy"
        #expect(picker.sections.flatMap(\.items).map(\.name) == ["DEPLOY_KEY"])
        #expect(!picker.canSend)
        picker.selectedID = picker.items.first { $0.name == "DEPLOY_KEY" }?.id
        #expect(picker.canSend)
        // Names only reach the picker.
        #expect(!textDump(picker.items, picker.sections).contains(SharingWorld.secretValue))
        await picker.send()
        #expect(macA.picker == nil)
        #expect(macA.sentCards.map(\.offer.itemName) == ["DEPLOY_KEY"])
        #expect(macA.sentCards.first?.status == .awaitingPeer)
        fixture.close()
    }

    @Test func aLockWhileAttachingDropsThePasswordAndTheAuthorization() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        fixture.macA.attach()
        let picker = try #require(fixture.macA.picker)
        picker.reauth.password = "typed"
        picker.vaultDidLock()
        #expect(picker.reauth.password.isEmpty)
        #expect(!picker.reauth.isAuthorized)
        #expect(picker.items.isEmpty)
        fixture.close()
    }

    @Test func theReceiverSeesACardWithNamesButNeverTheValue() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attach("DEPLOY_KEY")
        let card = try #require(fixture.macB.cards[id])
        #expect(card.direction == .received)
        #expect(card.status == .offered)
        #expect(card.isAwaitingDecision)
        #expect(card.offer.itemName == "DEPLOY_KEY")
        #expect(card.offer.kind == .secret)
        #expect(card.offer.environmentName == SharingWorld.environment)
        #expect(card.offer.repositoryFullName == "\(TestFixtures.owner)/\(TestFixtures.repoName)")
        #expect(card.offer.manifest.flattenedItems.allSatisfy { $0.item.value == nil })
        #expect(!textDump(fixture.macB.cards, fixture.macB.entries).contains(SharingWorld.secretValue))
        fixture.close()
    }

    @Test func saveToMyVaultRunsTheShareImportPreviewThenImports() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attach("NEW_SECRET")
        let macA = fixture.macA
        let macB = fixture.macB
        await macB.save(id)
        #expect(await TestFixtures.eventually { macB.saveSheet != nil })
        let sheet = try #require(macB.saveSheet)
        #expect(macB.cards[id]?.status == .reviewing)
        #expect(await TestFixtures.eventually { macA.sentCards.first?.status == .sent })

        await sheet.prepare()
        #expect(sheet.step == .preview)
        let editor = try #require(sheet.editor)
        #expect(editor.plan.allItems.map(\.key.name) == ["NEW_SECRET"])
        #expect(editor.plan.allItems.first?.chip == .new)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        #expect(!textDump(editor.plan, macB.cards, macB.entries).contains(SharingWorld.secretValue))

        await sheet.apply()
        #expect(sheet.step == .done)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == SharingWorld.secretValue)
        sheet.finish()
        #expect(macB.saveSheet == nil)
        #expect(macB.cards[id]?.status == .saved)
        #expect(!textDump(sheet.result as Any).contains(SharingWorld.secretValue))

        // Ending the chat afterwards keeps the saved item and says so.
        await macB.endChat()
        #expect(macB.endModel?.savedAttachmentCount == 1)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == SharingWorld.secretValue)
        fixture.close()
    }

    @Test func cancellingThePreviewImportsNothingAndWipesTheValue() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attach("NEW_SECRET")
        let macB = fixture.macB
        await macB.save(id)
        #expect(await TestFixtures.eventually { macB.saveSheet != nil })
        let sheet = try #require(macB.saveSheet)
        await sheet.prepare()
        sheet.finish()
        #expect(macB.cards[id]?.status == .notSaved)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        fixture.close()
    }

    @Test func dismissSendsNothing() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attach("NEW_SECRET")
        let macA = fixture.macA
        let macB = fixture.macB
        await macB.dismiss(id)
        #expect(macB.cards[id]?.status == .dismissed)
        #expect(!(macB.cards[id]?.isAwaitingDecision ?? true))
        #expect(await TestFixtures.eventually { macA.sentCards.first?.status == .dismissedByPeer })
        #expect(macB.saveSheet == nil)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        fixture.close()
    }

    // MARK: - Repositories (v0.4.0)

    @Test func aWholeRepositoryIsOfferedByNamesAndCounts() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        #expect(macA.peerAcceptsRepositories)
        #expect(macB.peerAcceptsRepositories)

        macA.attach()
        let picker = try #require(macA.picker)
        #expect(picker.acceptsRepositories)
        picker.reauth.password = testPassword
        await picker.authenticateWithPassword()
        picker.mode = .repository
        let listed = try #require(picker.matchingRepositories.first)
        #expect(picker.matchingRepositories.map(\.fullName) == [Self.repository])
        #expect(listed.environmentCount == 1)
        #expect(listed.itemCount == 4)
        #expect(!picker.canSend)
        picker.selectedRepositoryID = fixture.world.senderRepositoryID
        // An item chosen in the other tab does not change what Attach sends.
        picker.selectedID = picker.items.first?.id
        #expect(picker.choice == .repository(listed))
        #expect(picker.canSend)
        await picker.send()
        #expect(macA.picker == nil)
        let sent = try #require(macA.sentCards.first)
        #expect(sent.offer.isConfiguration)
        #expect(sent.status == .awaitingPeer)

        #expect(await TestFixtures.eventually { !macB.cards.isEmpty })
        let card = try #require(macB.cards.values.first)
        guard case .configuration(let summary) = card.offer.content else {
            Issue.record("expected a repository card")
            return
        }
        #expect(card.offer.repositoryFullName == Self.repository)
        #expect(summary.environmentNames == [SharingWorld.environment])
        #expect(summary.secretCount == 3)
        #expect(summary.variableCount == 1)
        #expect(summary.valueMissingCount == 0)
        #expect(card.isAwaitingDecision)
        #expect(!textDump(macA.cards, macB.cards, macB.entries).contains(SharingWorld.secretValue))
        fixture.close()
    }

    @Test func importIntoAsksWhichRepositoryThenRunsThePreview() async throws {
        let fixture = try await Fixture()
        let receiver = fixture.world.receiver
        let otherID = try await receiver.stageRepository(name: "other-repo")
        try await fixture.chat()
        let id = try await fixture.attachRepository()
        let macA = fixture.macA
        let macB = fixture.macB

        await macB.handleConfiguration(id, .importInto)
        #expect(await TestFixtures.eventually { macB.saveSheet != nil })
        #expect(await TestFixtures.eventually { macA.sentCards.first?.status == .sent })
        let sheet = try #require(macB.saveSheet)
        #expect(macB.cards[id]?.status == .reviewing)
        #expect(sheet.isConfiguration)
        #expect(sheet.step == .choosingTarget)
        #expect(sheet.targets.map(\.fullName) == [Self.repository, "\(TestFixtures.owner)/other-repo"])
        // The sender's repository is preselected when this vault has it.
        #expect(sheet.selectedTargetID == fixture.world.receiverRepositoryID)
        // The sheet appearing does not plan anything before Continue.
        await sheet.prepare()
        #expect(sheet.step == .choosingTarget)
        #expect(sheet.editor == nil)

        sheet.selectedTargetID = otherID
        #expect(sheet.canChooseTarget)
        await sheet.importIntoSelectedTarget()
        #expect(sheet.step == .preview)
        let editor = try #require(sheet.editor)
        #expect(sheet.repositoryFullName == "\(TestFixtures.owner)/other-repo")
        #expect(Set(editor.plan.allItems.map(\.key.name)) == ["API_TOKEN", "NEW_SECRET", "BASE_URL", "DEPLOY_KEY"])
        #expect(editor.plan.allItems.allSatisfy { $0.chip == .new })
        #expect(editor.plan.environments.map(\.createsEnvironment) == [true])
        #expect(!textDump(editor.plan, macB.cards, macB.entries).contains(SharingWorld.secretValue))
        #expect(editor.canApply)

        await sheet.apply()
        #expect(sheet.step == .done)
        sheet.finish()
        #expect(macB.saveSheet == nil)
        #expect(macB.cards[id]?.status == .saved)

        let repositoryItems = try await fixture.world.items(of: receiver, repositoryID: otherID, scope: .repository)
        #expect(Set(repositoryItems.map(\.name)) == ["API_TOKEN", "NEW_SECRET", "BASE_URL"])
        let token = try #require(repositoryItems.first { $0.name == "API_TOKEN" })
        let value = try receiver.data.config.reveal(token.id)
        defer { value.wipe() }
        #expect(value.utf8String() == SharingWorld.secretValue)
        let production = try fixture.world.environmentScope(in: receiver, repositoryID: otherID)
        #expect(try await fixture.world.items(of: receiver, repositoryID: otherID, scope: production).map(\.name) == ["DEPLOY_KEY"])
        // This vault's copy of the sender's repository is untouched.
        #expect(try await fixture.world.receiverValue("API_TOKEN", kind: .secret) == SharingWorld.receiverSecretValue)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        fixture.close()
    }

    @Test func saveAsFileWritesAnEncryptedFileAndTheRepositoryCanStillBeImported() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attachRepository()
        let macB = fixture.macB

        let file = try await fixture.saveRepositoryAsFile(id)
        #expect(macB.cards[id]?.status == .savedToFile)
        #expect(macB.cards[id]?.hasSavedFile == true)
        #expect(macB.cards[id]?.canReview == true)
        #expect(!textDump(macB.cards, macB.entries).contains(file.passphrase))
        #expect(!textDump(macB.cards, macB.entries).contains(SharingWorld.secretValue))

        // The file opens with its passphrase and keeps the sender's name.
        let sharing = fixture.world.receiver.data.sharing
        let opened = try await sharing.openFile(try sharing.readFile(at: file.url), passphrase: file.passphrase, checkGitHub: false)
        #expect(opened.manifest.flattenedItems.count == 4)
        #expect(opened.manifest.repository.fullName == Self.repository)
        #expect(opened.manifest.sender.displayName == Self.nameA)
        opened.discard()

        // Then Import Into… this vault's copy of the sender's repository.
        await macB.handleConfiguration(id, .importInto)
        let sheet = try #require(macB.saveSheet)
        #expect(sheet.selectedTargetID == fixture.world.receiverRepositoryID)
        await sheet.importIntoSelectedTarget()
        let editor = try #require(sheet.editor)
        #expect(editor.plan.allItems.first { $0.key.name == "API_TOKEN" }?.chip == .differs)
        #expect(editor.plan.allItems.first { $0.key.name == "BASE_URL" }?.chip == .same)
        #expect(editor.canApply)
        await sheet.apply()
        #expect(sheet.step == .done)
        sheet.finish()
        #expect(macB.cards[id]?.status == .saved)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == SharingWorld.secretValue)
        fixture.close()
    }

    @Test func closingSaveAsFileOrCancellingTheImportSaysWhatIsLeft() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attachRepository()
        let macB = fixture.macB

        // Save as File… closed before Save: the values are still here.
        await macB.handleConfiguration(id, .saveAsFile)
        #expect(await TestFixtures.eventually { macB.fileSheet != nil })
        macB.fileSheetDismissed()
        #expect(macB.cards[id]?.status == .readyToSave)
        #expect(macB.cards[id]?.hasSavedFile == false)

        // Saved once, then a second Save as File… closed without saving keeps "saved as a file".
        _ = try await fixture.saveRepositoryAsFile(id)
        await macB.handleConfiguration(id, .saveAsFile)
        macB.fileSheetDismissed()
        #expect(macB.cards[id]?.status == .savedToFile)

        // Import Into… cancelled at the repository choice: nothing was planned, the values stay.
        await macB.handleConfiguration(id, .importInto)
        let chooser = try #require(macB.saveSheet)
        #expect(chooser.step == .choosingTarget)
        chooser.finish()
        #expect(macB.saveSheet == nil)
        #expect(macB.cards[id]?.status == .savedToFile)
        #expect(macB.cards[id]?.canSaveAsFile == true)

        // Import Into… cancelled at the preview: nothing imported, the values here are wiped, the
        // file stays.
        await macB.handleConfiguration(id, .importInto)
        let sheet = try #require(macB.saveSheet)
        await sheet.importIntoSelectedTarget()
        #expect(sheet.step == .preview)
        sheet.finish()
        #expect(macB.cards[id]?.status == .notSaved)
        #expect(macB.cards[id]?.hasSavedFile == true)
        #expect(macB.cards[id]?.canSaveAsFile == false)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        fixture.close()
    }

    @Test func aRepositoryThatArrivesWhileAnotherSheetIsOpenWaitsOnItsCard() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let first = try await fixture.attachRepository()
        let second = try await fixture.attachRepository()
        let macB = fixture.macB

        await macB.handleConfiguration(first, .saveAsFile)
        #expect(await TestFixtures.eventually { macB.fileSheet != nil })
        await macB.handleConfiguration(second, .importInto)
        #expect(await TestFixtures.eventually { macB.cards[second]?.status == .readyToSave })
        #expect(macB.saveSheet == nil, "one sheet at a time")

        macB.fileSheetDismissed()
        await macB.handleConfiguration(second, .importInto)
        #expect(macB.saveSheet?.id == second)
        fixture.close()
    }

    @Test func aTeammateOnAnOlderVersionCannotBeSentARepository() async throws {
        let world = try await SharingWorld()
        let picker = ChatAttachmentPickerViewModel(dependencies: world.senderDependencies(), acceptsRepositories: false) { _, _ in
            Issue.record("nothing may be offered")
        }
        picker.reauth.password = testPassword
        await picker.authenticateWithPassword()
        picker.mode = .repository
        picker.selectedRepositoryID = world.senderRepositoryID
        #expect(picker.selectedRepository != nil)
        #expect(picker.choice == nil)
        #expect(!picker.canSend)
        await picker.send()
        #expect(picker.step == .choosing)
        // One item still goes.
        picker.mode = .item
        picker.selectedID = picker.items.first?.id
        #expect(picker.canSend)
        picker.close()
    }

    /// Bryan: some accounts lack access to some things. A repository this account cannot change
    /// is listed with the reason and cannot be chosen.
    @Test func importTargetsSayWhyARepositoryCannotBeChosen() {
        func repository(_ name: String, admin: Bool = true, push: Bool = true, archived: Bool = false) -> RepoModel {
            RepoModel(
                accountLogin: TestFixtures.account,
                githubID: "R_\(name)",
                ownerLogin: TestFixtures.owner,
                ownerType: .organization,
                name: name,
                visibility: .private,
                isArchived: archived,
                hasAdmin: admin,
                hasPush: push,
                origin: .imported,
                importedAt: ManualClock.defaultStart
            )
        }
        let sender = Self.repository.uppercased()
        let admin = ChatImportTargetModel(repository: repository(TestFixtures.repoName), senderFullName: sender, hasEnvironments: true)
        #expect(admin.isEditable)
        #expect(admin.isSenderRepository)

        let write = repository("write-access", admin: false)
        #expect(ChatImportTargetModel(repository: write, senderFullName: sender, hasEnvironments: true).readOnlyReason == .adminRequired)
        #expect(ChatImportTargetModel(repository: write, senderFullName: sender, hasEnvironments: false).readOnlyReason == .adminRequired)
        let read = repository("read-access", admin: false, push: false)
        #expect(ChatImportTargetModel(repository: read, senderFullName: sender, hasEnvironments: false).readOnlyReason == .adminRequired)

        let archived = ChatImportTargetModel(repository: repository("archived", archived: true), senderFullName: sender, hasEnvironments: false)
        #expect(archived.readOnlyReason == .archived)
        #expect(!archived.isEditable)
        #expect(!archived.isSenderRepository)
    }

    // MARK: - Wipe

    @Test func closingTheWindowEndsAndWipesTheChatOnBothMacs() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        macA.draft = "First"
        await macA.send()
        _ = try await fixture.attach("API_TOKEN")
        macB.draft = "unsent"
        #expect(await TestFixtures.eventually { macB.messages.count == 1 })

        macB.close()
        #expect(macB.entries.isEmpty)
        #expect(macB.cards.isEmpty)
        #expect(macB.draft.isEmpty)
        #expect(!macB.isVisible)
        #expect(await TestFixtures.eventually { macA.endReason == .peerLeft })
        #expect(macA.entries.isEmpty)
        #expect(macA.cards.isEmpty)
        fixture.close()
    }

    @Test(arguments: [LockTrigger.manual, .systemSleep, .screenLocked])
    func aLockOrSleepEndsAndWipesTheChat(trigger: LockTrigger) async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        macB.draft = "Hello"
        await macB.send()
        #expect(await TestFixtures.eventually { macA.messages.count == 1 })
        macA.draft = "typing"

        fixture.world.sender.app.lock(trigger: trigger)
        #expect(macA.endReason == .locked)
        #expect(macA.entries.isEmpty)
        #expect(macA.draft.isEmpty)
        #expect(!macA.isVaultUnlocked)
        #expect(await TestFixtures.eventually { macB.endReason == .peerLeft })
        #expect(macB.entries.isEmpty)
        fixture.close()
    }

    @Test func aLockWhilePreviewingDiscardsTheReceivedValue() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let id = try await fixture.attach("NEW_SECRET")
        let macB = fixture.macB
        await macB.save(id)
        #expect(await TestFixtures.eventually { macB.saveSheet != nil })
        let sheet = try #require(macB.saveSheet)
        await sheet.prepare()
        #expect(sheet.editor != nil)

        fixture.world.receiver.app.lock(trigger: .manual)
        #expect(macB.saveSheet == nil)
        #expect(sheet.editor == nil)
        #expect(macB.endReason == .locked)
        try await fixture.world.receiver.vaultManager.unlock(password: testPassword)
        #expect(try await fixture.world.receiverValue("NEW_SECRET", kind: .secret) == nil)
        fixture.close()
    }

    @Test func aDisconnectEndsTheChatWithNothingSaved() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        macA.draft = "Still there?"
        await macA.send()
        #expect(await TestFixtures.eventually { macB.messages.count == 1 })
        fixture.initiator.close()
        #expect(await TestFixtures.eventually { macA.endReason != nil && macB.endReason != nil })
        #expect(macB.endReason == .aborted(NearbyAbortModel(reason: .disconnected, happenedAfterReveal: true)))
        #expect(macA.entries.isEmpty)
        #expect(macB.entries.isEmpty)
        fixture.close()
    }

    @Test func endChatEndsItForBoth() async throws {
        let fixture = try await Fixture()
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB
        await macA.endChat()
        #expect(macA.endReason == .endedHere)
        #expect(await TestFixtures.eventually { macB.endReason == .peerLeft })
        #expect(macB.endModel?.peerName == Self.nameA)
        fixture.close()
    }

    // MARK: - Availability

    @Test func noInternetDoesNotDisableChatButNoInterfaceDoes() async throws {
        let fixture = try await Fixture()
        let harness = fixture.world.sender
        let macA = fixture.macA
        harness.pathSource.send(.online)
        await macA.start()
        #expect(macA.step == .browsing)

        // Wi-Fi on but joined to no network: offline for GitHub, fine for peer-to-peer.
        harness.pathSource.send(NetworkPathModel(status: .unsatisfied, hasInterface: true))
        #expect(macA.isNearbyAvailable)
        await macA.refreshAvailability()
        #expect(macA.step == .browsing)
        #expect(macA.isVisible)

        // Wi-Fi off and no cable.
        harness.pathSource.send(NetworkPathModel(status: .unsatisfied, hasInterface: false))
        #expect(!macA.isNearbyAvailable)
        await macA.refreshAvailability()
        #expect(macA.step == .unavailable)
        #expect(!macA.isVisible)
        let firstAdvertisement = try #require(fixture.networkA.advertisements.first as? IdleChatTransport)
        #expect(await TestFixtures.eventually { firstAdvertisement.isClosed })

        harness.pathSource.send(NetworkPathModel(status: .unsatisfied, hasInterface: true))
        await macA.refreshAvailability()
        #expect(macA.step == .browsing)
        #expect(macA.isVisible)
        fixture.close()
    }

    @Test func aLockedVaultShowsTheLockedStateUntilUnlocked() async throws {
        let fixture = try await Fixture()
        let harness = fixture.world.sender
        let macA = fixture.macA
        harness.app.lock(trigger: .manual)
        await macA.start()
        #expect(macA.step == .locked)
        #expect(fixture.networkA.advertisements.isEmpty)
        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        await macA.refreshAvailability()
        #expect(macA.step == .browsing)
        #expect(macA.isVisible)
        fixture.close()
    }

    @Test func connectivityReportsInterfacesSeparatelyFromInternet() async {
        let source = FakeNetworkPathSource()
        let monitor = ConnectivityMonitor(source: source, clock: ManualClock())
        monitor.start()
        #expect(monitor.hasNetworkInterface)
        source.send(NetworkPathModel(status: .unsatisfied, hasInterface: true))
        #expect(!monitor.isOnline)
        #expect(monitor.hasNetworkInterface)
        // Interface changes apply at once (no debounce).
        source.send(.offline)
        #expect(!monitor.hasNetworkInterface)
        source.send(NetworkPathModel(status: .satisfied))
        #expect(monitor.hasNetworkInterface)
        #expect(NetworkPathModel.online.hasInterface)
        #expect(!NetworkPathModel.offline.hasInterface)
        monitor.stop()
    }

    @Test func chatAbortsUseChatWording() {
        let idle = NearbyAbortModel(reason: .timeout(.chatIdle), happenedAfterReveal: true)
        #expect(idle.chatMessage == "The chat ended after 10 minutes without messages.")
        let keepalive = NearbyAbortModel(reason: .timeout(.keepalive), happenedAfterReveal: true)
        #expect(keepalive.chatMessage == "The other Mac stopped answering.")
        #expect(!NearbyAbortModel(reason: .disconnected, happenedAfterReveal: true).chatMessage.contains("share"))
    }
}

extension NearbyChatViewModel {
    var sas: NearbySASModel? {
        if case .comparing(let sas) = step { return sas }
        return nil
    }

    var endModel: NearbyChatEndModel? {
        if case .ended(let model) = step { return model }
        return nil
    }

    var endReason: NearbyChatEndModel.Reason? {
        endModel?.reason
    }

    var messages: [ChatMessageModel] {
        entries.compactMap { entry in
            if case .message(let message) = entry { return message }
            return nil
        }
    }

    var sentCards: [ChatAttachmentCardModel] {
        entries.compactMap { entry in
            if case .attachment(let id) = entry, let card = cards[id], card.direction == .sent { return card }
            return nil
        }
    }
}
