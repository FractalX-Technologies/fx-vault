import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Records save-panel and sharing-picker requests instead of showing them.
@MainActor
final class FakeShareFileDelivery: ShareFileDelivering {
    /// What the "save panel" answers (nil: cancelled).
    var saveDestination: URL?
    private(set) var suggestedNames: [String] = []
    private(set) var sharedFiles: [URL] = []
    private var pendingCompletion: ((ShareDeliveryOutcome) -> Void)?

    func chooseSaveDestination(suggestedName: String) async -> URL? {
        suggestedNames.append(suggestedName)
        return saveDestination
    }

    func share(fileURL: URL, completion: @escaping (ShareDeliveryOutcome) -> Void) {
        sharedFiles.append(fileURL)
        pendingCompletion = completion
    }

    /// Finishes the running hand-off as the sharing service would.
    func finishSharing(_ outcome: ShareDeliveryOutcome) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(outcome)
    }
}

/// A transport that forwards to an in-memory one and records `close()` (advertising stops).
final class RecordingTransport: NearbyTransport, @unchecked Sendable {
    private let base: InMemoryTransport
    private let lock = NSLock()
    private var closeCount = 0

    init(_ base: InMemoryTransport) {
        self.base = base
    }

    var events: AsyncStream<NearbyTransportEvent> {
        base.events
    }

    var isClosed: Bool {
        lock.withLock { closeCount > 0 }
    }

    func send(_ frame: Data) async throws(ShareError) {
        try await base.send(frame)
    }

    func close() {
        lock.withLock { closeCount += 1 }
        base.close()
    }

    /// Injects an event as if it came from the network.
    func inject(_ event: NearbyTransportEvent) {
        base.inject(event)
    }
}

/// A discovery the test drives: peers and failures are pushed by hand; `connect` hands out the
/// initiator end of the network's in-memory pair.
@MainActor
final class FakeNearbyDiscovery: NearbyPeerDiscovering {
    let peers: AsyncStream<[NearbyPeerModel]>
    let failures: AsyncStream<NearbyTransportFailure>
    private let peersContinuation: AsyncStream<[NearbyPeerModel]>.Continuation
    private let failuresContinuation: AsyncStream<NearbyTransportFailure>.Continuation
    private let transport: () -> (any NearbyTransport)?
    private(set) var isStarted = false
    private(set) var isStopped = false

    init(transport: @escaping () -> (any NearbyTransport)?) {
        self.transport = transport
        (peers, peersContinuation) = AsyncStream.makeStream(of: [NearbyPeerModel].self)
        (failures, failuresContinuation) = AsyncStream.makeStream(of: NearbyTransportFailure.self)
    }

    func start() {
        isStarted = true
    }

    func stop() {
        isStopped = true
        peersContinuation.finish()
        failuresContinuation.finish()
    }

    func connect(to peer: NearbyPeerModel) -> (any NearbyTransport)? {
        transport()
    }

    func publish(_ found: [NearbyPeerModel]) {
        peersContinuation.yield(found)
    }

    func fail(_ failure: NearbyTransportFailure) {
        failuresContinuation.yield(failure)
    }
}

/// Two Macs on one in-memory "network": the sender's discovery connects to the receiver's
/// advertising transport. Nothing touches the real network.
@MainActor
final class InMemoryNearbyNetwork: NearbyNetworking {
    let pair = InMemoryTransportPair()
    let initiator: RecordingTransport
    let responder: RecordingTransport
    private(set) var discoveries: [FakeNearbyDiscovery] = []
    private(set) var advertisedCount = 0

    init() {
        initiator = RecordingTransport(pair.initiator)
        responder = RecordingTransport(pair.responder)
    }

    func makeDiscovery() -> any NearbyPeerDiscovering {
        let initiator = initiator
        let discovery = FakeNearbyDiscovery { initiator }
        discoveries.append(discovery)
        return discovery
    }

    func makeAdvertisingTransport() -> any NearbyTransport {
        advertisedCount += 1
        return responder
    }

    var discovery: FakeNearbyDiscovery? {
        discoveries.last
    }
}

/// Two vaults (sender and receiver) with the same repository staged, for share round trips.
@MainActor
struct SharingWorld {
    static let secretValue = "FXV_SHARE_SECRET_VALUE"
    static let receiverSecretValue = "FXV_RECEIVER_OWN_VALUE"
    static let variableValue = "https://share.example.com"
    static let environment = "production"
    static let identity = ShareLocalIdentityModel(displayName: "Sender Mac", appVersion: "1.0.0")

    let sender: TestHarness
    let receiver: TestHarness
    let senderRecorder = ActionRecorder()
    let receiverRecorder = ActionRecorder()
    let senderRepositoryID: RepoID
    /// Nil when the receiver does not have the repository.
    let receiverRepositoryID: RepoID?

    /// - Parameters:
    ///   - receiverHasRepository: stage the same repository in the receiver's vault.
    ///   - receiverPolicy: the receiver's policy of the shared environment.
    init(
        receiverHasRepository: Bool = true,
        receiverPolicy: BranchPolicyDraftModel = .all,
        senderPolicy: BranchPolicyDraftModel = .all,
        receiverGHStatus: GHStatusModel? = .unknown
    ) async throws {
        sender = try await TestHarness(vault: .unlocked)
        receiver = try await TestHarness(vault: .unlocked, ghStatus: receiverGHStatus)
        senderRepositoryID = try await sender.stageRepository(
            items: [
                TestFixtures.item(.secret, "API_TOKEN", Self.secretValue),
                TestFixtures.item(.secret, "NEW_SECRET", Self.secretValue),
                TestFixtures.item(.variable, "BASE_URL", Self.variableValue),
            ],
            environments: [
                RepoCreationEnvironmentDraftModel(
                    name: Self.environment,
                    policy: senderPolicy,
                    items: [TestFixtures.item(.secret, "DEPLOY_KEY", Self.secretValue)]
                ),
            ]
        )
        if receiverHasRepository {
            receiverRepositoryID = try await receiver.stageRepository(
                items: [
                    // Differs from the sender's value.
                    TestFixtures.item(.secret, "API_TOKEN", Self.receiverSecretValue),
                    // Same value as the sender's.
                    TestFixtures.item(.variable, "BASE_URL", Self.variableValue),
                ],
                environments: [
                    RepoCreationEnvironmentDraftModel(name: Self.environment, policy: receiverPolicy),
                ]
            )
        } else {
            receiverRepositoryID = nil
        }
    }

    func senderDependencies() -> FeatureDependencies {
        sender.dependencies(recorder: senderRecorder)
    }

    func receiverDependencies(isGitHubReady: Bool = false) -> FeatureDependencies {
        receiver.dependencies(recorder: receiverRecorder, isGitHubReady: isGitHubReady)
    }

    /// Exports the whole repository from the sender's vault into the sender's sandbox.
    func exportFile(_ selection: ShareSelectionModel? = nil) async throws -> (url: URL, passphrase: String) {
        let authorization = try await sender.container.reauth.authorizeShare(
            .fileExport,
            with: .password(testPassword),
            session: sender.data.session
        )
        let url = sender.sandbox.appendingPathComponent("Share-\(UUID().uuidString).fxvault")
        let result = try await sender.data.sharing.exportFile(
            selection ?? .repository(senderRepositoryID),
            to: url,
            senderName: Self.identity.displayName,
            appVersion: Self.identity.appVersion,
            authorization: authorization
        )
        defer { result.passphrase.wipe() }
        return (url, try #require(result.passphrase.utf8String()))
    }

    /// The receiver's current value of an item, or nil.
    func receiverValue(_ name: String, kind: ConfigKind, scope: ConfigScope = .repository) async throws -> String? {
        guard let receiverRepositoryID else { return nil }
        guard let item = try await items(of: receiver, repositoryID: receiverRepositoryID, scope: scope)
            .first(where: { $0.name == name && $0.kind == kind })
        else { return nil }
        let value = try receiver.data.config.reveal(item.id)
        defer { value.wipe() }
        return value.utf8String()
    }

    /// The items of one scope.
    func items(of harness: TestHarness, repositoryID: RepoID, scope: ConfigScope) async throws -> [ConfigItemModel] {
        for try await items in harness.data.config.observeItems(repositoryID: repositoryID, scope: scope) {
            return items
        }
        return []
    }

    /// The scope of the shared environment in `harness`'s copy of the repository.
    func environmentScope(in harness: TestHarness, repositoryID: RepoID) throws -> ConfigScope {
        let scopes = try harness.data.config.scopes(repositoryID: repositoryID)
        let environment = try #require(scopes.first { $0.environment?.name == Self.environment })
        return environment.scope
    }
}

/// The text of every value-bearing model the UI receives, to prove no value leaks into it.
func textDump(_ values: Any...) -> String {
    values.map { String(reflecting: $0) }.joined(separator: "\n")
}
