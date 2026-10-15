import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Share › Receive Nearby… (§9.4 responder, §9.5, §10 `NearbyShareScreen` receive). Experimental.
///
/// "Waiting for a teammate…" (advertising only while the sheet is open) → code comparison →
/// **manifest preview** (New / Fills missing value / Value not included / Exists locally; no
/// values) → Accept or Reject → the accepted values arrive → **Same/Differs confirmation**
/// ("Keep mine" for differences) → apply → result. Nothing is applied before the second
/// confirmation, and values never reach this view model (VaultData holds them in the draft).
@Observable
final class NearbyReceiveViewModel: LockObserving {
    enum Step: Equatable {
        case waiting
        case comparing(NearbySASModel)
        /// Code confirmed here; waiting for the sender's confirmation and manifest.
        case awaitingManifest(NearbySASModel)
        case reviewingManifest
        case receiving
        case confirmingPayload
        case applying
        case done
        /// Declined or rejected: nothing was imported.
        case declined
        case failed
    }

    private(set) var step: Step = .waiting
    private(set) var isPeerConfirmed = false
    /// The manifest preview, then the payload preview.
    private(set) var editor: ShareImportPlanEditor?
    private(set) var senderName: String?
    private(set) var result: ShareImportResultModel?
    private(set) var abort: NearbyAbortModel?
    private(set) var showsInterceptionWarning = false
    private(set) var isImportingRepository = false
    private(set) var isAdvertising = false
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let network: any NearbyNetworking
    @ObservationIgnored private let identity: ShareLocalIdentityModel
    @ObservationIgnored private let importer: ShareRepositoryImporter
    @ObservationIgnored private var receiver: NearbyShareReceiver?
    @ObservationIgnored private var manifest: SharePackageModel?
    @ObservationIgnored private var manifestPlan: ShareImportPlanModel?
    @ObservationIgnored private var tracker = NearbyFailureTracker()
    @ObservationIgnored private let tasks = TaskBag()

    init(
        context: NearbyReceiveContext,
        dependencies: FeatureDependencies,
        network: any NearbyNetworking = LiveNearbyNetworking(),
        identity: ShareLocalIdentityModel? = nil
    ) {
        self.dependencies = dependencies
        self.network = network
        self.identity = identity ?? .nearby(preferences: dependencies.preferences)
        importer = ShareRepositoryImporter(
            github: dependencies.github,
            catalog: dependencies.catalog,
            isGitHubReady: dependencies.actions.isGitHubReady
        )
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Advertising

    /// Starts advertising and waits for HELLO_I. Called when the sheet appears and by
    /// "Try Again" (a new session: no automatic retry).
    func start() async {
        cancelSession()
        resetSession()
        step = .waiting
        let transport = network.makeAdvertisingTransport()
        let receiver = await dependencies.sharing.makeNearbyReceiver(transport: transport, localName: identity.displayName)
        self.receiver = receiver
        isAdvertising = true
        let events = receiver.events
        tasks.set("events", Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            self?.isAdvertising = false
        })
        do {
            try await receiver.start()
        } catch {
            alert = error.presentation
            step = .failed
        }
    }

    // MARK: - Code

    func decide(_ decision: SASDecision) async {
        guard case .comparing(let sas) = step, let receiver else { return }
        do {
            switch decision {
            case .match:
                step = .awaitingManifest(sas)
                try await receiver.confirmCode()
            case .mismatch:
                try await receiver.rejectCode()
            }
        } catch {
            alert = error.presentation
        }
    }

    var sas: NearbySASModel? {
        switch step {
        case .comparing(let sas), .awaitingManifest(let sas): sas
        default: nil
        }
    }

    // MARK: - Manifest (first confirmation)

    /// The package's `owner/name`.
    var repositoryFullName: String? {
        manifest?.repository.fullName
    }

    var needsRepositoryImport: Bool {
        step == .reviewingManifest && editor?.blockReason == .repositoryNotImported
    }

    /// Imports the repository through an account with access, then previews the manifest again.
    /// The import goes through gh: offline it is disabled with the offline explanation.
    var isOnline: Bool {
        dependencies.connectivity.isOnline
    }

    func importRepository() async {
        guard needsRepositoryImport, isOnline, let manifest, !isImportingRepository else { return }
        isImportingRepository = true
        defer { isImportingRepository = false }
        do {
            _ = try await importer.importRepository(owner: manifest.repository.owner, name: manifest.repository.name)
            dependencies.actions.refresh(.catalog)
            await previewManifest()
        } catch {
            alert = error.presentation
        }
    }

    var canAccept: Bool {
        step == .reviewingManifest && editor?.blockReason == nil && editor?.pendingWideningEnvironment == nil
    }

    /// Accepts what the preview needs (DECISION); the values arrive next.
    func accept() async {
        guard canAccept, let receiver, let editor else { return }
        manifestPlan = editor.plan
        step = .receiving
        do {
            try await receiver.accept(editor.plan)
        } catch {
            alert = error.presentation
        }
    }

    /// Rejects the manifest: nothing is transferred.
    func reject() async {
        guard step == .reviewingManifest, let receiver else { return }
        do {
            try await receiver.decline()
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Payload (second confirmation)

    var canApply: Bool {
        step == .confirmingPayload && editor?.canApply == true
    }

    /// Imports the confirmed payload and tells the sender (RESULT ok).
    func apply() async {
        guard canApply, let receiver, let editor else { return }
        step = .applying
        do {
            result = try await receiver.apply(editor.plan, confirmReplay: editor.confirmsReplay)
            self.editor = nil
            step = .done
        } catch .planOutdated {
            alert = SharingError.planOutdated.presentation
            await previewPayload()
        } catch {
            alert = error.presentation
            step = .confirmingPayload
        }
    }

    /// Rejects the received values: nothing is imported (RESULT not ok).
    func rejectPayload() async {
        guard step == .confirmingPayload, let receiver else { return }
        do {
            try await receiver.rejectPayload()
            editor = nil
            step = .declined
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Lifetime

    var canTryAgain: Bool {
        switch step {
        case .failed, .declined, .done: true
        default: false
        }
    }

    /// The sheet closed: stops advertising and cancels the session (values are wiped).
    func close() {
        cancelSession()
        tasks.cancelAll()
        editor = nil
    }

    func vaultDidLock() {
        close()
        step = .failed
    }

    // MARK: - Session events

    private func handle(_ event: NearbyEvent) async {
        switch event {
        case .sasReady(let sas):
            step = .comparing(sas)
        case .peerConfirmedSAS:
            isPeerConfirmed = true
        case .manifestReceived(let received):
            manifest = received
            senderName = received.sender.displayName
            await previewManifest()
        case .payloadReceived:
            await previewPayload()
        case .completed(let completion):
            tracker.recordSuccess()
            isAdvertising = false
            if case .declined = completion {
                editor = nil
                step = .declined
            }
        case .aborted(let model):
            abort = model
            showsInterceptionWarning = tracker.record(model)
            editor = nil
            isAdvertising = false
            if step != .done {
                step = .failed
            }
        case .readyForManifest, .decisionReceived:
            break
        }
    }

    private func previewManifest() async {
        guard let receiver, let manifest else { return }
        do {
            let plan = try await receiver.previewManifest(checkGitHub: dependencies.checksGitHub)
            editor = ShareImportPlanEditor(plan: plan, repositoryFullName: manifest.repository.fullName)
            step = .reviewingManifest
        } catch {
            alert = error.presentation
        }
    }

    private func previewPayload() async {
        guard let receiver, let manifest else { return }
        do {
            let draft = try await receiver.previewPayload(checkGitHub: dependencies.checksGitHub)
            let payloadEditor = ShareImportPlanEditor(plan: draft.plan, repositoryFullName: manifest.repository.fullName)
            if let manifestPlan {
                payloadEditor.adoptPolicyDecisions(from: manifestPlan)
            }
            editor = payloadEditor
            step = .confirmingPayload
        } catch {
            alert = error.presentation
        }
    }

    private func resetSession() {
        isPeerConfirmed = false
        editor = nil
        manifest = nil
        manifestPlan = nil
        senderName = nil
        result = nil
        abort = nil
        showsInterceptionWarning = false
    }

    private func cancelSession() {
        isAdvertising = false
        guard let receiver else { return }
        self.receiver = nil
        Task { await receiver.cancel() }
    }
}
