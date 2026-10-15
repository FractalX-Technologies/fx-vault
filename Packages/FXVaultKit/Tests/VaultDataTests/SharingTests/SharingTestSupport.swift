import CryptoKit
import Foundation
import FXVaultTestSupport
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// A fast stand-in for Argon2id (SHA-256 over passphrase and salt): the codec, header checks
/// and AES-GCM stay real, only the key stretching is skipped. Tests only.
struct FastKeyDeriver: KeyDeriving {
    func deriveKey(passphrase: SecretBytes, parameters: KeyDerivationParametersModel) async throws -> SecretBytes {
        var hasher = SHA256()
        passphrase.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(parameters.salt))
        return SecretBytes(Data(hasher.finalize()))
    }
}

/// Two vaults with **different keys**, each of which imported `owner-a/api` (same GitHub node
/// id) from its own simulated GitHub:
///
/// | | sender | receiver |
/// |---|---|---|
/// | `FXV_S1` (repository secret) | `a1` | absent |
/// | `FXV_V1` (repository variable) | `v1` | `different` |
/// | `production` policy | custom `release/*` | all |
/// | `production/FXV_S2` (secret) | `a2` | value missing, same `updatedAt` |
/// | `production/FXV_V2` (variable) | `p2` | absent |
struct ShareWorld {
    static let secretUpdatedAt = GitHubSimulator.epoch.addingTimeInterval(500)
    static let senderName = "Sender Mac"
    static let appVersion = "1.0.0"

    let sender: SyncHarness
    let receiver: SyncHarness
    let senderSharing: SharingRepository
    let receiverSharing: SharingRepository
    let folder: VaultTemporaryDirectory

    static func make(receiverGitHub: GitHubSimulator? = nil) async throws -> ShareWorld {
        let senderGitHub = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        senderGitHub.addSecret("FXV_S1", updatedAt: secretUpdatedAt)
        senderGitHub.addVariable("FXV_V1", value: "v1")
        senderGitHub.addEnvironment("production", id: 41, policy: .custom, patterns: [("release/*", .branch)])
        senderGitHub.addSecret("FXV_S2", environment: "production", updatedAt: secretUpdatedAt)
        senderGitHub.addVariable("FXV_V2", value: "p2", environment: "production")
        let sender = try await SyncHarness.make(github: senderGitHub)
        try await sender.importRepository()
        try sender.config.fillValue(try #require(try sender.item("FXV_S1", kind: .secret)).id, value: SecretBytes(utf8: "a1"), pushOnNextSync: false)
        let production = try #require(try sender.environment("production"))
        try sender.config.fillValue(
            try #require(try sender.item("FXV_S2", kind: .secret, scope: .environment(production.id))).id,
            value: SecretBytes(utf8: "a2"),
            pushOnNextSync: false
        )

        let github = receiverGitHub ?? GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        github.addVariable("FXV_V1", value: "different")
        github.addEnvironment("production", id: 41)
        github.addSecret("FXV_S2", environment: "production", updatedAt: secretUpdatedAt)
        let receiver = try await SyncHarness.make(github: github)
        try await receiver.importRepository()

        return ShareWorld(
            sender: sender,
            receiver: receiver,
            senderSharing: SharingRepository(session: sender.session, schedulers: sender.schedulers, deriver: FastKeyDeriver(), clock: sender.clock),
            receiverSharing: SharingRepository(session: receiver.session, schedulers: receiver.schedulers, deriver: FastKeyDeriver(), clock: receiver.clock),
            folder: try VaultTemporaryDirectory()
        )
    }

    /// A single-use authorization for the sender (what `ReauthGate.authorizeShare` returns).
    func authorization(_ purpose: ShareAuthorizationPurpose) -> ShareAuthorizationModel {
        ShareAuthorizationModel(purpose: purpose, session: sender.session)
    }

    /// Exports `selection` from the sender to a new file and returns it with the passphrase text.
    func export(_ selection: ShareSelectionModel? = nil, name: String = "share.fxvault") async throws -> (URL, String) {
        let target = try selection ?? .repository(sender.repository().id)
        let result = try await senderSharing.exportFile(
            target,
            to: folder.url.appendingPathComponent(name),
            senderName: Self.senderName,
            appVersion: Self.appVersion,
            authorization: authorization(.fileExport)
        )
        defer { result.passphrase.wipe() }
        return (result.fileURL, try #require(result.passphrase.utf8String()))
    }

    /// Reads and opens `file` on the receiver.
    func open(_ file: URL, passphrase: String, checkGitHub: Bool = false) async throws -> ShareImportDraftModel {
        try await receiverSharing.openFile(receiverSharing.readFile(at: file), passphrase: passphrase, checkGitHub: checkGitHub)
    }
}

extension ShareImportPlanModel {
    /// The item plan named `name` (repository level when `environment` is nil).
    func item(_ name: String, environment: String? = nil) -> ShareItemPlanModel? {
        allItems.first { $0.key.name == name && $0.key.environmentName == environment }
    }
}

/// Reads an `AsyncStream` from a test.
final class StreamReader<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncStream<Element>.Iterator

    init(_ stream: AsyncStream<Element>) {
        iterator = stream.makeAsyncIterator()
    }

    /// Skips elements until `predicate` matches; nil when the stream ends first.
    func first(where predicate: (Element) -> Bool) async -> Element? {
        while let element = await iterator.next() {
            if predicate(element) { return element }
        }
        return nil
    }
}
