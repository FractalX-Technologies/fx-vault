import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Window › Nearby Chat (v0.2.0, experimental): an ephemeral, end-to-end encrypted 1:1 chat with
/// a teammate's Mac nearby, over the local network or peer-to-peer Wi-Fi (no shared network or
/// internet needed).
///
/// - **Visible only while open:** while the window shows the people list, this Mac advertises
///   under the name from Preferences › General (or the macOS user's name) and lists the Macs that
///   advertise. Connecting to someone, or being connected to, stops both.
/// - **Code comparison:** both Macs show the same 6-digit code (`SASCodeView`, equal-weight
///   "Codes match" / "Don't match", no default button) before any message flows.
/// - **Messages** live only in this view model's memory (``entries``); nothing is written to
///   disk. ⌘↩ sends; the limit is `Limits.chatMessageBytes` after sanitizing.
/// - **Attachments:** "Attach…" asks for Touch ID or the master password first, then one item is
///   offered by name (``ChatAttachmentPickerViewModel``). A received offer shows a card (name,
///   kind, repository/environment, never the value) with "Save to my vault", which asks for the
///   value and opens the share import preview (``ChatSaveViewModel``), or "Dismiss".
/// - **Repositories (v0.4.0, chat v2):** with a teammate on 0.4 or later, a whole repository can
///   be attached. Its card has "Import Into…" (choose one of this vault's repositories, then the
///   same preview) and "Save as File…" (an encrypted `.fxvault` through ``ShareExportViewModel``).
/// - **Wiped** on window close (``close()``), vault lock (``vaultDidLock()``; sleep and screen lock
///   lock the vault), disconnect, timeout or when either person ends the chat: the window then
///   shows "Conversation ended. Nothing was saved."
/// - **Availability:** disabled only when no network interface exists at all
///   (`ConnectivityMonitor.hasNetworkInterface`); no internet connection is needed.
@Observable
final class NearbyChatViewModel: LockObserving {
    private(set) var step: NearbyChatStep = .browsing
    /// Nearby Macs with Nearby Chat open (this Mac left out), by advertised (unverified) name.
    private(set) var peers: [NearbyPeerModel] = []
    /// True while this Mac advertises itself.
    private(set) var isVisible = false {
        didSet {
            if isVisible != oldValue {
                app.setChatWindowAdvertising(isVisible)
            }
        }
    }
    /// The teammate who proved who they are instead of comparing the code (v0.5.0).
    private(set) var verifiedTeammateName: String?
    /// The name this Mac is visible under.
    private(set) var displayName = ""
    /// The local user pressed "Codes match".
    private(set) var isCodeConfirmed = false
    /// The other user pressed "Codes match".
    private(set) var isPeerCodeConfirmed = false
    /// The other person's name, as their Mac sent it; trusted only once the codes matched.
    private(set) var peerName: String?
    /// The transcript (memory only).
    private(set) var entries: [ChatEntryModel] = []
    /// Attachment cards by id (names only).
    private(set) var cards: [ChatAttachmentID: ChatAttachmentCardModel] = [:]
    /// The message being typed.
    var draft = ""
    private(set) var isSending = false
    /// Browsing failed (Local Network access denied, Wi-Fi failure).
    private(set) var discoveryError: ErrorPresentationModel?
    /// Advertising failed repeatedly: this Mac is not visible ("Try Again" restarts).
    private(set) var visibilityError: ErrorPresentationModel?
    /// The open "Attach…" sheet.
    var picker: ChatAttachmentPickerViewModel?
    /// The open "Save as File…" sheet of a received configuration (v0.4.0).
    var fileSheet: ShareExportViewModel?
    /// Whether the teammate's FX Vault can receive a whole repository (chat v2), known once the
    /// codes match.
    private(set) var peerAcceptsRepositories = false
    /// The open "Save to my vault" import preview.
    var saveSheet: ChatSaveViewModel?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let network: any NearbyChatNetworking
    @ObservationIgnored private let makeFileDelivery: () -> any ShareFileDelivering
    @ObservationIgnored private let fixedIdentity: ShareLocalIdentityModel?
    @ObservationIgnored private var identity: ShareLocalIdentityModel
    @ObservationIgnored private var conversation: NearbyChatConversation?
    @ObservationIgnored private var discovery: (any NearbyPeerDiscovering)?
    /// The name this Mac's advertisement registered under (requested, then as registered).
    @ObservationIgnored private var ownServiceName: String?
    /// Everything discovery reports, this Mac included (``peers`` leaves it out).
    @ObservationIgnored private var discoveredPeers: [NearbyPeerModel] = []
    /// Changes with every conversation and discovery, so late events of a finished one are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var savedCount = 0
    /// Advertisements restarted in a row after the listener failed without accepting anyone.
    /// A peer that connects and drops never counts, so a stranger cannot make this Mac give up.
    @ObservationIgnored private var readvertiseCount = 0
    /// The current advertisement accepted a connection (the listener stopped advertising).
    @ObservationIgnored private var hasIncomingConnection = false
    /// Failed handshakes in a row (the interception warning). Only chats that reached the code
    /// comparison, or that this Mac started, count.
    @ObservationIgnored private(set) var tracker = NearbyFailureTracker()
    /// A chat through teammate presence: the code waits a moment for the teammate's proof.
    @ObservationIgnored private var expectsTeammate = false
    @ObservationIgnored private let tasks = TaskBag()

    /// - Parameters:
    ///   - identity: fixed in tests; nil reads the name from Preferences on every start.
    ///   - makeFileDelivery: the save panel and sharing picker of each "Save as File…" sheet.
    init(
        app: AppViewModel,
        dependencies: FeatureDependencies,
        network: any NearbyChatNetworking = LiveNearbyChatNetworking(),
        identity: ShareLocalIdentityModel? = nil,
        makeFileDelivery: @escaping () -> any ShareFileDelivering = { SystemShareFileDelivery() }
    ) {
        self.app = app
        self.dependencies = dependencies
        self.network = network
        self.makeFileDelivery = makeFileDelivery
        fixedIdentity = identity
        self.identity = identity ?? .nearby(preferences: dependencies.preferences)
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Availability

    var isVaultUnlocked: Bool {
        app.phase == .unlocked
    }

    /// Some network interface exists (Wi-Fi on, joined or not, or a cable). An internet
    /// connection is not required.
    var isNearbyAvailable: Bool {
        dependencies.connectivity.hasNetworkInterface
    }

    /// Re-evaluates the window after the vault phase or the network interfaces changed (the
    /// window calls it on change). An active chat is left alone: a lost link ends it by itself.
    func refreshAvailability() async {
        switch step {
        case .locked, .unavailable:
            if isVaultUnlocked, isNearbyAvailable {
                await start()
            } else if isVaultUnlocked {
                step = .unavailable
            }
        case .browsing:
            if !isVaultUnlocked {
                tearDown()
                step = .locked
            } else if !isNearbyAvailable {
                tearDown()
                step = .unavailable
            }
        case .connecting, .comparing, .chatting, .ended:
            break
        }
    }

    // MARK: - Visibility and discovery

    /// Starts (or restarts) the window: advertise under the display name and list nearby Macs.
    /// Called when the window appears and by "Start New Chat". Each chat is a new session.
    func start() async {
        tearDown()
        guard isVaultUnlocked else {
            step = .locked
            return
        }
        guard isNearbyAvailable else {
            step = .unavailable
            return
        }
        identity = fixedIdentity ?? .nearby(preferences: dependencies.preferences)
        displayName = identity.displayName
        readvertiseCount = 0
        if let pending = app.takePendingChatStart() {
            await startPending(pending)
            return
        }
        step = .browsing
        startDiscovery()
        await advertise()
    }

    /// A chat from a bubble or a connection to this Mac's presence (v0.5.0) arrived while the
    /// window is open: it replaces the people list; an ongoing chat keeps going and the new one
    /// is refused.
    func startPendingChat() async {
        switch step {
        case .connecting, .comparing, .chatting:
            app.takePendingChatStart()?.transport.close()
        default:
            guard let pending = app.takePendingChatStart() else { return }
            tearDown()
            guard isVaultUnlocked else {
                pending.transport.close()
                step = .locked
                return
            }
            identity = fixedIdentity ?? .nearby(preferences: dependencies.preferences)
            displayName = identity.displayName
            await startPending(pending)
        }
    }

    private func startPending(_ start: NearbyChatStartModel) async {
        expectsTeammate = start.expectsTeammate
        step = .connecting(peerName: start.peerName)
        let conversation = dependencies.chat.makeConversation(
            role: start.role,
            transport: start.transport,
            localName: identity.displayName,
            clock: dependencies.clock,
            team: app.teamPresence.chatIdentity(expecting: start.teammate)
        )
        await run(conversation)
    }

    /// Connects to `peer` (this Mac becomes the initiator): stops advertising and browsing.
    func connect(to peer: NearbyPeerModel) async {
        guard step == .browsing, let discovery else { return }
        guard let transport = discovery.connect(to: peer) else {
            alert = Self.peerGonePresentation
            return
        }
        stopVisibility()
        let conversation = dependencies.chat.makeConversation(
            role: .initiator,
            transport: transport,
            localName: identity.displayName,
            clock: dependencies.clock,
            team: app.teamPresence.chatIdentity()
        )
        step = .connecting(peerName: peer.chatDisplayName)
        await run(conversation)
    }

    /// Cancel while connecting or comparing codes: back to the people list.
    func cancelConnection() async {
        switch step {
        case .connecting, .comparing:
            await start()
        default:
            break
        }
    }

    private func startDiscovery() {
        let discovery = network.makeDiscovery()
        self.discovery = discovery
        discoveryError = nil
        let generation = generation
        let peers = discovery.peers
        let failures = discovery.failures
        tasks.set("peers", Task { [weak self] in
            for await found in peers {
                guard let self, self.generation == generation else { return }
                self.discoveredPeers = found
                self.filterPeers()
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

    /// Advertises under the display name and waits for someone to connect (this Mac is the
    /// responder). Nothing happens until a peer connects.
    private func advertise() async {
        let advertisement = network.makeAdvertisement(displayName: identity.displayName)
        ownServiceName = advertisement.serviceName
        filterPeers()
        let generation = generation
        let registeredNames = advertisement.registeredNames
        tasks.set("registration", Task { [weak self] in
            for await name in registeredNames {
                guard let self, self.generation == generation else { return }
                self.ownServiceName = name
                self.filterPeers()
            }
        })
        hasIncomingConnection = false
        isVisible = true
        let conversation = dependencies.chat.makeConversation(
            role: .responder,
            transport: advertisement.transport,
            localName: identity.displayName,
            clock: dependencies.clock,
            team: app.teamPresence.chatIdentity()
        )
        await run(conversation)
    }

    /// The discovered Macs without this one (by the name its advertisement registered).
    private func filterPeers() {
        peers = discoveredPeers.filter { $0.id != ownServiceName }
    }

    /// Stops listing nearby Macs.
    private func stopBrowsing() {
        tasks.cancel("peers")
        tasks.cancel("failures")
        discovery?.stop()
        discovery = nil
        discoveredPeers = []
        peers = []
    }

    /// Stops advertising and browsing, and closes the current conversation (a chat started
    /// here, or the window is restarting or going away).
    private func stopVisibility() {
        generation += 1
        tasks.cancel("registration")
        stopBrowsing()
        isVisible = false
        if let conversation {
            self.conversation = nil
            Task { await conversation.close() }
        }
    }

    // MARK: - Conversation

    private func run(_ conversation: NearbyChatConversation) async {
        self.conversation = conversation
        let generation = generation
        let events = conversation.events
        tasks.set("events", Task { [weak self] in
            for await event in events {
                guard let self, self.generation == generation else { return }
                await self.handle(event, role: conversation.role)
            }
        })
        do {
            try await conversation.start()
        } catch {
            alert = error.presentation
        }
    }

    private func handle(_ event: NearbyChatEvent, role: NearbyRole) async {
        switch event {
        case .incomingConnection:
            // The listener works, and withdrew the advertisement when it accepted the
            // connection: nobody else can find this Mac until it advertises again.
            hasIncomingConnection = true
            readvertiseCount = 0
            isVisible = false
        case .peerConnected(let name):
            readvertiseCount = 0
            if step == .browsing {
                // Someone connected to this Mac: stop browsing; the listener already stopped
                // advertising when it accepted the connection.
                stopBrowsing()
                isVisible = false
            }
            step = .connecting(peerName: name.isEmpty ? nil : name)
        case .sasReady(let sas):
            isCodeConfirmed = false
            guard expectsTeammate, verifiedTeammateName == nil else {
                step = .comparing(sas)
                return
            }
            // Through teammate presence: the proof normally arrives within milliseconds; the
            // code shows only if it does not (an older teammate, or not a teammate after all).
            let generation = generation
            let clock = dependencies.clock
            tasks.set("code-delay", Task { [weak self] in
                try? await clock.sleep(for: Timeouts.teammateProofWait)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                if case .connecting = self.step {
                    self.step = .comparing(sas)
                }
            })
        case .teammateVerified(let card):
            tasks.cancel("code-delay")
            verifiedTeammateName = card.name
            peerName = card.name
        case .peerConfirmedSAS:
            isPeerCodeConfirmed = true
        case .verified:
            tasks.cancel("code-delay")
            if case .comparing(let sas) = step, verifiedTeammateName == nil {
                peerName = sas.peerName
            }
            tracker.recordSuccess()
            step = .chatting
            peerAcceptsRepositories = await conversation?.acceptsConfigurationAttachments ?? false
        case .message(let message):
            appendMessage(message)
        case .attachmentOffered(let offer):
            add(ChatAttachmentCardModel(offer: offer, date: dependencies.clock.now, status: .offered))
        case .attachmentDeclined(let id):
            updateCard(id) { card in
                switch (card.direction, card.status) {
                case (.sent, .awaitingPeer): card.status = .dismissedByPeer
                case (.received, .offered), (.received, .requested): card.status = .withdrawn
                default: break
                }
            }
        case .attachmentSent(let id):
            updateCard(id) { $0.status = .sent }
        case .attachmentReceived(let id, _):
            updateCard(id) { $0.status = .readyToSave }
            let action = cards[id]?.pendingAction
            updateCard(id) { $0.pendingAction = nil }
            switch action {
            case .saveAsFile:
                saveAsFile(id)
            case .importInto, nil:
                review(id)
            }
        case .peerClosed:
            end(.peerLeft)
        case .aborted(let abort):
            switch (role, step) {
            case (.responder, .browsing):
                // The listener failed, or a connection dropped (or sent garbage) before its
                // HELLO: keep waiting for someone else. Only listener failures count.
                await restartAdvertising(countsTowardLimit: !hasIncomingConnection)
            case (.responder, .connecting):
                // An unverified peer left before any code was shown: back to the people list,
                // without an "ended" screen or a failed-handshake count.
                await start()
            default:
                let warns = tracker.record(abort)
                end(.aborted(abort), showsInterceptionWarning: warns)
            }
        }
    }

    /// Advertises again after the responder's conversation aborted while listing people.
    /// - Parameter countsTowardLimit: the listener failed without accepting anyone; after
    ///   ``maxConsecutiveReadvertising`` such failures in a row this Mac stops trying.
    private func restartAdvertising(countsTowardLimit: Bool) async {
        if let conversation {
            self.conversation = nil
            await conversation.close()
        }
        if countsTowardLimit {
            readvertiseCount += 1
            guard readvertiseCount <= Self.maxConsecutiveReadvertising else {
                isVisible = false
                visibilityError = Self.notVisiblePresentation
                return
            }
        }
        await advertise()
    }

    /// "Codes match" / "Don't match".
    func decide(_ decision: SASDecision) async {
        guard case .comparing = step, let conversation, !isCodeConfirmed else { return }
        do {
            switch decision {
            case .match:
                isCodeConfirmed = true
                try await conversation.confirmCode()
            case .mismatch:
                try await conversation.rejectCode()
            }
        } catch {
            alert = error.presentation
        }
    }

    /// "End Chat": ends it for both people and wipes everything.
    func endChat() async {
        guard step == .chatting else { return }
        end(.endedHere)
    }

    // MARK: - Messages

    /// Bytes left for the message after sanitizing (negative when over the limit).
    var remainingMessageBytes: Int {
        Limits.chatMessageBytes - ChatTextSanitizer.sanitize(draft).utf8.count
    }

    var isDraftTooLong: Bool {
        remainingMessageBytes < 0
    }

    var canSend: Bool {
        step == .chatting && !isSending && !isDraftTooLong && !ChatTextSanitizer.sanitize(draft).isEmpty
    }

    /// ⌘↩ or Send.
    func send() async {
        guard canSend, let conversation else { return }
        let generation = generation
        isSending = true
        defer { isSending = false }
        do {
            let message = try await conversation.sendText(draft)
            // The chat may have ended (and been wiped) while sending: nothing comes back.
            guard isCurrent(generation) else { return }
            appendMessage(message)
            draft = ""
        } catch {
            guard isCurrent(generation) else { return }
            alert = error.presentation
        }
    }

    /// Adds a message to the transcript; beyond ``maxTranscriptMessages`` the oldest message is
    /// dropped (attachment cards stay; their number is limited by the protocol).
    private func appendMessage(_ message: ChatMessageModel) {
        entries.append(.message(message))
        guard entries.lazy.filter(\.isMessage).count > Self.maxTranscriptMessages,
              let oldest = entries.firstIndex(where: \.isMessage)
        else { return }
        entries.remove(at: oldest)
    }

    /// The chat that started an async call is still the one on screen.
    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && step == .chatting
    }

    /// "Copy" on a message: through `ClipboardManager` (concealed, this Mac only, cleared after
    /// `Timeouts.clipboardClear` and on lock), never the general pasteboard as is.
    func copy(_ message: ChatMessageModel) {
        guard entries.contains(.message(message)) else { return }
        dependencies.clipboard.copy(message.text)
    }

    // MARK: - Attachments

    var canAttach: Bool {
        step == .chatting && picker == nil
    }

    /// "Attach…": re-authenticate, then choose one item or a whole repository.
    func attach() {
        guard canAttach else { return }
        picker = ChatAttachmentPickerViewModel(
            dependencies: dependencies,
            acceptsRepositories: peerAcceptsRepositories
        ) { [weak self] choice, authorization in
            await self?.offer(choice, authorization: authorization)
        }
    }

    /// The picker closed without sending.
    func pickerDismissed() {
        picker?.close()
        picker = nil
    }

    private func offer(_ choice: ChatAttachmentChoiceModel, authorization: ShareAuthorizationModel) async {
        defer { pickerDismissed() }
        guard step == .chatting, let conversation else { return }
        let generation = generation
        do {
            let offer = switch choice {
            case .item(let item):
                try await conversation.offerItem(
                    item.id,
                    senderName: identity.displayName,
                    appVersion: identity.appVersion,
                    authorization: authorization
                )
            case .repository(let repository):
                try await conversation.offerRepository(
                    repository.id,
                    senderName: identity.displayName,
                    appVersion: identity.appVersion,
                    authorization: authorization
                )
            }
            guard isCurrent(generation) else { return }
            add(ChatAttachmentCardModel(offer: offer, date: dependencies.clock.now, status: .awaitingPeer))
        } catch {
            guard isCurrent(generation) else { return }
            alert = error.presentation
        }
    }

    /// "Save to my vault": asks the other Mac for the value; the import preview opens when it
    /// arrives.
    func save(_ id: ChatAttachmentID) async {
        guard cards[id]?.isAwaitingDecision == true, let conversation else { return }
        let generation = generation
        updateCard(id) { $0.status = .requested }
        do {
            try await conversation.requestAttachment(id)
        } catch {
            guard isCurrent(generation) else { return }
            updateCard(id) { $0.status = .offered }
            alert = error.presentation
        }
    }

    /// "Import Into…" or "Save as File…" on a received configuration (v0.4.0): asks for the
    /// values first, then runs the action when they arrive; an arrived one runs it at once.
    func handleConfiguration(_ id: ChatAttachmentID, _ action: ChatAttachmentCardModel.ConfigurationAction) async {
        guard let card = cards[id], card.offer.isConfiguration, card.direction == .received else { return }
        if card.isAwaitingDecision {
            updateCard(id) { $0.pendingAction = action }
            await save(id)
            return
        }
        switch action {
        case .importInto:
            review(id)
        case .saveAsFile:
            saveAsFile(id)
        }
    }

    /// "Save as File…": the Share as File sheet for the received package (Touch ID or the master
    /// password, then a fresh passphrase, then Save… or AirDrop…).
    func saveAsFile(_ id: ChatAttachmentID) {
        guard !isPresentingSheet, let card = cards[id], card.canSaveAsFile, let conversation else { return }
        updateCard(id) { $0.status = .savingToFile }
        fileSheet = ShareExportViewModel(
            chatAttachment: ShareExportViewModel.ChatAttachmentSource(conversation: conversation, attachmentID: id),
            dependencies: dependencies,
            delivery: makeFileDelivery()
        ) { [weak self] wroteFile in
            self?.updateCard(id) { card in
                card.hasSavedFile = card.hasSavedFile || wroteFile
                card.status = card.hasSavedFile ? .savedToFile : .readyToSave
            }
        }
    }

    /// The Save as File sheet went away.
    func fileSheetDismissed() {
        fileSheet?.close()
        fileSheet = nil
    }

    /// "Dismiss": declines the offer; nothing is sent.
    func dismiss(_ id: ChatAttachmentID) async {
        guard cards[id]?.isAwaitingDecision == true, let conversation else { return }
        let generation = generation
        do {
            try await conversation.declineAttachment(id)
            guard isCurrent(generation) else { return }
            updateCard(id) { $0.status = .dismissed }
        } catch {
            guard isCurrent(generation) else { return }
            alert = error.presentation
        }
    }

    /// Opens the import preview of an arrived value.
    func review(_ id: ChatAttachmentID) {
        guard !isPresentingSheet, let card = cards[id], card.canReview, let conversation else { return }
        updateCard(id) { $0.status = .reviewing }
        saveSheet = ChatSaveViewModel(card: card, conversation: conversation, dependencies: dependencies) { [weak self] outcome in
            self?.saveFinished(id, outcome)
        }
    }

    /// One sheet at a time: a value that arrives while another sheet is open waits on its card.
    private var isPresentingSheet: Bool {
        picker != nil || saveSheet != nil || fileSheet != nil
    }

    /// The import preview sheet went away (Esc or a lock) without Done or Cancel.
    func saveSheetDismissed() {
        saveSheet?.finish()
    }

    private func saveFinished(_ id: ChatAttachmentID, _ outcome: ChatSaveViewModel.Outcome) {
        updateCard(id) { card in
            switch outcome {
            case .imported: card.status = .saved
            case .wiped: card.status = .notSaved
            case .kept: card.status = card.hasSavedFile ? .savedToFile : .readyToSave
            }
        }
        if outcome == .imported {
            savedCount += 1
        }
        saveSheet = nil
    }

    private func add(_ card: ChatAttachmentCardModel) {
        cards[card.id] = card
        entries.append(.attachment(card.id))
    }

    private func updateCard(_ id: ChatAttachmentID, _ change: (inout ChatAttachmentCardModel) -> Void) {
        guard var card = cards[id] else { return }
        change(&card)
        cards[id] = card
    }

    // MARK: - Ending and wiping

    /// The window closed: ends the chat, stops advertising and wipes everything.
    func close() {
        tearDown()
    }

    func vaultDidLock() {
        switch step {
        case .ended:
            // Keep "Conversation ended" on screen; there is nothing left to wipe but the list.
            tearDown()
        case .locked, .unavailable, .browsing:
            tearDown()
            step = .locked
        case .connecting, .comparing, .chatting:
            end(.locked)
        }
    }

    private func end(_ reason: NearbyChatEndModel.Reason, showsInterceptionWarning: Bool = false) {
        let model = NearbyChatEndModel(
            reason: reason,
            peerName: peerName,
            savedAttachmentCount: savedCount,
            showsInterceptionWarning: showsInterceptionWarning
        )
        tearDown()
        step = .ended(model)
    }

    /// Closes the conversation (CLOSE to the peer), stops advertising and browsing, and wipes
    /// the transcript, the cards, the typed message and any received value.
    private func tearDown() {
        stopVisibility()
        tasks.cancel("events")
        entries.removeAll()
        cards.removeAll()
        draft = ""
        isSending = false
        isCodeConfirmed = false
        isPeerCodeConfirmed = false
        peerName = nil
        verifiedTeammateName = nil
        expectsTeammate = false
        tasks.cancel("code-delay")
        savedCount = 0
        discoveryError = nil
        visibilityError = nil
        picker?.close()
        picker = nil
        saveSheet?.close()
        saveSheet = nil
        fileSheet?.close()
        fileSheet = nil
        peerAcceptsRepositories = false
    }

    /// Listener failures in a row before the window stops trying (a failing listener must not
    /// loop). Connections that drop do not count.
    private static let maxConsecutiveReadvertising = 3

    /// Messages the transcript keeps (memory only); older ones are dropped.
    static let maxTranscriptMessages = 1000

    private static var notVisiblePresentation: ErrorPresentationModel {
        ErrorPresentationModel(
            title: String(localized: "chat.error.notVisible.title", defaultValue: "You're not visible right now"),
            message: String(
                localized: "chat.error.notVisible.message",
                defaultValue: "Nearby Macs can't find this Mac. Check that Wi-Fi is on and FX Vault may use the local network, then try again."
            )
        )
    }

    private static var peerGonePresentation: ErrorPresentationModel {
        ErrorPresentationModel(
            title: String(localized: "chat.error.peerGone.title", defaultValue: "That Mac is no longer nearby"),
            message: String(
                localized: "chat.error.peerGone.message",
                defaultValue: "It closed Nearby Chat or moved out of range. Choose someone else."
            )
        )
    }
}

extension Timeouts {
    /// How long a chat through teammate presence waits for the teammate's proof before it shows
    /// the code (v0.5.0).
    static let teammateProofWait: Duration = .seconds(3)
}
