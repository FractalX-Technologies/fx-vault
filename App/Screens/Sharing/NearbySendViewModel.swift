import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// How a nearby send ended normally.
enum NearbySendOutcome: Equatable {
    /// The receiver applied the share.
    case delivered
    /// The receiver saw the values and rejected them (nothing imported).
    case receiverRejected
    /// The receiver declined the manifest (nothing sent).
    case declined
}

/// Share › Nearby… (§9.4 initiator, §10 `NearbyShareScreen` send, D21–D23, D30). Experimental.
///
/// peers (Bonjour browse) → connect → handshake → code comparison (`SASCodeView`: equal-weight
/// answers, no default) → **ReauthGate(.nearbySend)** → MANIFEST (names only) → the receiver
/// decides → the accepted part is sent → result.
///
/// The manifest is sent only after this user confirmed the code, re-authenticated, and the
/// receiver's confirmation arrived (`.readyForManifest`). Every abort is final (no automatic
/// retry); "Try Again" starts a new session. After an abort that follows the key exchange, or
/// two failed handshakes in a row, the interception warning is shown.
@Observable
final class NearbySendViewModel: LockObserving {
    enum Step: Equatable {
        /// No selection came with the sheet: pick a repository and a scope.
        case chooseSelection
        case browsing
        case connecting
        case comparing(NearbySASModel)
        /// Code confirmed here: re-authenticate while waiting for the other side.
        case authenticating(NearbySASModel)
        case awaitingDecision
        case sending
        case finished(NearbySendOutcome)
        case failed
    }

    private(set) var step: Step
    let reauth: ShareReauthModel
    private(set) var peers: [NearbyPeerModel] = []
    /// Browsing failed (Local Network denied, or the browser failed).
    private(set) var networkError: ErrorPresentationModel?
    private(set) var isPeerConfirmed = false
    private(set) var isReadyForManifest = false
    private(set) var abort: NearbyAbortModel?
    private(set) var showsInterceptionWarning = false
    /// What is sent: names and counts.
    private(set) var preview: ShareExportPreviewModel?
    private(set) var repositories: [RepoModel] = []
    private(set) var tree: ShareScopeTreeModel?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private(set) var selection: ShareSelectionModel?
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let network: any NearbyNetworking
    @ObservationIgnored private let identity: ShareLocalIdentityModel
    @ObservationIgnored private let loader: ShareScopeTreeLoader
    @ObservationIgnored private var discovery: (any NearbyPeerDiscovering)?
    @ObservationIgnored private var sender: NearbyShareSender?
    @ObservationIgnored private var tracker = NearbyFailureTracker()
    @ObservationIgnored private var isManifestSent = false
    @ObservationIgnored private let tasks = TaskBag()

    init(
        context: NearbySendContext,
        dependencies: FeatureDependencies,
        network: any NearbyNetworking = LiveNearbyNetworking(),
        identity: ShareLocalIdentityModel? = nil
    ) {
        self.dependencies = dependencies
        self.network = network
        self.identity = identity ?? .nearby(preferences: dependencies.preferences)
        selection = context.selection
        step = context.selection == nil ? .chooseSelection : .browsing
        loader = ShareScopeTreeLoader(config: dependencies.config, sharing: dependencies.sharing)
        reauth = ShareReauthModel(
            purpose: .nearbySend,
            reauth: dependencies.reauth,
            session: dependencies.session,
            touchIDStatus: dependencies.touchIDStatus()
        )
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - What to send

    /// Loads the selection's summary and starts browsing, or loads the repository picker.
    func start() async {
        if selection == nil {
            do {
                repositories = try await loader.repositories().sorted {
                    $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending
                }
            } catch {
                alert = error.presentation
            }
        } else {
            await refreshPreview()
            startBrowsing()
        }
    }

    /// Shows the scope tree of `repositoryID` with the whole repository checked.
    func chooseRepository(_ repositoryID: RepoID) async {
        do {
            tree = try await loader.tree(repositoryID: repositoryID, selection: .repository(repositoryID))
            await refreshPreview(for: tree?.selection)
        } catch {
            alert = error.presentation
        }
    }

    /// Checks or unchecks a row of the tri-state tree (any combination, as in Share › File…).
    func setChecked(_ checked: Bool, for node: ShareScopeNodeModel) {
        let previous = tree?.selection
        tree?.setChecked(checked, for: node)
        guard tree?.selection != previous else { return }
        // The summary must always describe the checked rows: Continue waits for the new one.
        preview = nil
        Task { await refreshPreview(for: tree?.selection) }
    }

    var canContinueWithSelection: Bool {
        step == .chooseSelection && tree?.selection != nil && preview != nil
    }

    /// Uses the checked scope and starts looking for receivers.
    func continueWithSelection() {
        guard canContinueWithSelection, let chosen = tree?.selection else { return }
        selection = chosen
        startBrowsing()
    }

    // MARK: - Peers

    /// Starts browsing for receivers (a new user action after a failure: no automatic retry).
    func startBrowsing() {
        discovery?.stop()
        let discovery = network.makeDiscovery()
        self.discovery = discovery
        peers = []
        networkError = nil
        step = .browsing
        let peerStream = discovery.peers
        let failureStream = discovery.failures
        tasks.set("peers", Task { [weak self] in
            for await found in peerStream {
                self?.peers = found
            }
        })
        tasks.set("failures", Task { [weak self] in
            for await failure in failureStream {
                self?.networkError = failure.presentation
            }
        })
        discovery.start()
    }

    /// Connects to `peer` and starts the handshake (HELLO_I).
    func connect(to peer: NearbyPeerModel) async {
        guard step == .browsing, let discovery else { return }
        guard let transport = discovery.connect(to: peer) else {
            alert = NearbyTransportFailure.connectionFailed.presentation
            return
        }
        discovery.stop()
        tasks.cancel("peers")
        tasks.cancel("failures")
        resetSession()
        step = .connecting
        let sender = await dependencies.sharing.makeNearbySender(transport: transport, localName: identity.displayName)
        self.sender = sender
        let events = sender.events
        tasks.set("events", Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        })
        do {
            try await sender.start()
        } catch {
            alert = error.presentation
            step = .failed
        }
    }

    // MARK: - Code comparison and re-authentication

    /// "Codes match" or "Don't match" (equal weight, no default).
    func decide(_ decision: SASDecision) async {
        guard case .comparing(let sas) = step, let sender else { return }
        switch decision {
        case .match:
            step = .authenticating(sas)
            do {
                try await sender.confirmCode()
            } catch {
                alert = error.presentation
                return
            }
            await authenticateWithTouchID(automatic: true)
        case .mismatch:
            do {
                try await sender.rejectCode()
            } catch {
                alert = error.presentation
            }
        }
    }

    func authenticateWithTouchID(automatic: Bool = false) async {
        guard case .authenticating = step else { return }
        if await reauth.authorizeWithTouchID(automatic: automatic) {
            await sendManifestIfReady()
        }
    }

    func authenticateWithPassword() async {
        guard case .authenticating = step else { return }
        if await reauth.authorizeWithPassword() {
            await sendManifestIfReady()
        }
    }

    // MARK: - Session events

    private func handle(_ event: NearbyEvent) async {
        switch event {
        case .sasReady(let sas):
            step = .comparing(sas)
        case .peerConfirmedSAS:
            isPeerConfirmed = true
        case .readyForManifest:
            isPeerConfirmed = true
            isReadyForManifest = true
            await sendManifestIfReady()
        case .decisionReceived(let decision):
            if decision.accept {
                step = .sending
            }
        case .completed(let completion):
            tracker.recordSuccess()
            step = .finished(Self.outcome(completion))
            endSession()
        case .aborted(let model):
            abort = model
            showsInterceptionWarning = tracker.record(model)
            step = .failed
            endSession()
        case .manifestReceived, .payloadReceived:
            break
        }
    }

    /// Sends the manifest once both confirmations arrived and the re-authentication passed
    /// (§9.4 step 7, D30).
    private func sendManifestIfReady() async {
        guard case .authenticating = step, isReadyForManifest, !isManifestSent, reauth.isAuthorized,
              let sender, let selection, let authorization = reauth.takeAuthorization()
        else { return }
        isManifestSent = true
        do {
            try await sender.sendManifest(
                selection,
                senderName: identity.displayName,
                appVersion: identity.appVersion,
                authorization: authorization
            )
            if case .authenticating = step {
                step = .awaitingDecision
            }
        } catch {
            isManifestSent = false
            alert = error.presentation
        }
    }

    // MARK: - Lifetime

    /// "Try Again" after a failure or a finished share: a new session needs a new user action.
    func tryAgain() {
        guard step == .failed || isFinished else { return }
        resetSession()
        startBrowsing()
    }

    var isFinished: Bool {
        if case .finished = step { return true }
        return false
    }

    /// The sheet closed: cancels the session (the peer sees an abort) and stops browsing.
    func close() {
        cancelSession()
        discovery?.stop()
        discovery = nil
        tasks.cancelAll()
        reauth.reset()
    }

    func vaultDidLock() {
        close()
        step = .failed
    }

    /// The local code to show while the session compares or authenticates.
    var sas: NearbySASModel? {
        switch step {
        case .comparing(let sas), .authenticating(let sas): sas
        default: nil
        }
    }

    private func resetSession() {
        cancelSession()
        isPeerConfirmed = false
        isReadyForManifest = false
        isManifestSent = false
        abort = nil
        showsInterceptionWarning = false
        reauth.reset()
    }

    private func cancelSession() {
        guard let sender else { return }
        self.sender = nil
        Task { await sender.cancel() }
    }

    private func endSession() {
        sender = nil
        reauth.reset()
    }

    private func refreshPreview(for chosen: ShareSelectionModel? = nil) async {
        guard let target = chosen ?? selection else {
            preview = nil
            return
        }
        do {
            let fresh = try await dependencies.sharing.previewExport(target)
            // A newer check may have changed the selection while this one was loading.
            if target == (step == .chooseSelection ? tree?.selection : selection) {
                preview = fresh
            }
        } catch {
            preview = nil
            alert = error.presentation
        }
    }

    private static func outcome(_ completion: NearbyCompletion) -> NearbySendOutcome {
        switch completion {
        case .transferred(let receiverOK): receiverOK ? .delivered : .receiverRejected
        case .resultSent(let ok): ok ? .delivered : .receiverRejected
        case .declined: .declined
        }
    }
}
