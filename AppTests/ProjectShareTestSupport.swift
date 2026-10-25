import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Two Macs, for project share round trips (v0.9.0, passphrase files since 1.0). The
/// sender's repository has the stages `staging` and `production` (a GitHub environment each) and a
/// Key Vault destination at `staging`; the receiver has the same repository with a different
/// value for one secret.
@MainActor
final class ProjectShareWorld {
    static let secretValue = "FXV_PROJECT_SECRET_VALUE"
    static let receiverValue = "FXV_PROJECT_RECEIVER_VALUE"
    static let identity = ShareLocalIdentityModel(displayName: "Sender Mac", appVersion: "1.0.0")
    static let vaultName = "kv-example-staging"

    let sender: TestHarness
    let receiver: TestHarness
    let senderRecorder = ActionRecorder()
    let receiverRecorder = ActionRecorder()
    let senderRepositoryID: RepoID
    let receiverRepositoryID: RepoID?
    let destinationID: DestinationID
    /// Overviews the receiver's UI asked to open (repository and stage).
    private(set) var openedScopes: [(RepoID, ConfigScope)] = []

    /// - Parameter receiverUsesGitHub: the receiver starts without a gh status, so a test can
    ///   install a scripted gh and look repositories up.
    init(receiverHasRepository: Bool = true, receiverUsesGitHub: Bool = false) async throws {
        sender = try await TestHarness(vault: .unlocked)
        receiver = try await TestHarness(vault: .unlocked, ghStatus: receiverUsesGitHub ? nil : .unknown)
        senderRepositoryID = try await sender.stageRepository(
            items: [
                TestFixtures.item(.secret, "API_TOKEN", Self.secretValue),
                TestFixtures.item(.variable, "BASE_URL", "https://share.example.com"),
            ],
            environments: [
                RepoCreationEnvironmentDraftModel(
                    name: "staging",
                    policy: .all,
                    items: [TestFixtures.item(.secret, "STAGING_KEY", Self.secretValue)]
                ),
                RepoCreationEnvironmentDraftModel(
                    name: "production",
                    policy: .all,
                    items: [TestFixtures.item(.secret, "PROD_KEY", Self.secretValue)]
                ),
            ]
        )
        destinationID = try sender.data.destinations.createDestination(
            repositoryID: senderRepositoryID,
            target: .azureKeyVault(vaultName: Self.vaultName, tenantID: nil),
            stage: "staging"
        )
        _ = try sender.data.destinations.addItem(
            destinationID: destinationID,
            kind: .secret,
            name: "DATABASE_URL",
            value: SecretBytes(utf8: Self.secretValue)
        )
        if receiverHasRepository {
            receiverRepositoryID = try await receiver.stageRepository(
                items: [TestFixtures.item(.secret, "API_TOKEN", Self.receiverValue)],
                environments: [RepoCreationEnvironmentDraftModel(name: "staging", policy: .all)]
            )
        } else {
            receiverRepositoryID = nil
        }
    }

    func senderDependencies() -> FeatureDependencies {
        sender.dependencies(recorder: senderRecorder)
    }

    /// The receiver's dependencies, recording the Overview it opens after an import.
    func receiverDependencies() -> FeatureDependencies {
        let recorder = receiverRecorder
        let app = receiver.app
        return FeatureDependencies(container: receiver.container, actions: MainActions(
            present: { recorder.presented.append($0) },
            refresh: { recorder.refreshes.append($0) },
            beginSyncActivity: { app.beginSyncActivity() },
            addLockObserver: { app.addLockObserver($0) },
            isGitHubReady: { false },
            select: { recorder.selections.append($0) },
            open: { [weak self] id, scope in self?.openedScopes.append((id, scope)) }
        ))
    }

    /// A project share export straight through the sender's repository.
    func exportBundle(
        stages: [String] = ["staging"],
        expiry: ShareExpiryChoice = .default
    ) async throws -> (url: URL, passphrase: String) {
        let authorization = try await sender.container.reauth.authorizeShare(
            .fileExport,
            with: .password(testPassword),
            session: sender.data.session
        )
        let selection = try await sender.data.sharing.selection(
            repositoryIDs: [senderRepositoryID],
            stages: stages,
            expiry: expiry
        )
        let url = sender.sandbox.appendingPathComponent("Project-\(UUID().uuidString).fxvault")
        let result = try await sender.data.sharing.exportBundle(
            selection,
            to: url,
            senderName: Self.identity.displayName,
            appVersion: Self.identity.appVersion,
            authorization: authorization
        )
        defer { result.passphrase.wipe() }
        return (url, try #require(result.passphrase.utf8String()))
    }

    /// Copies a file into the receiver's sandbox (as if downloaded from a chat).
    func deliver(_ url: URL) throws -> URL {
        let copy = receiver.sandbox.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}
