import Foundation
import FXVaultTestSupport
import SharingKit
import Testing
import VaultCore
@_spi(Testing) @testable import VaultData
import VaultStore

/// `.fxvault` export and import between two vaults with different keys (§9.1–§9.5).
@Suite("Share files", .timeLimit(.minutes(1)))
struct ShareFileTests {
    // MARK: - Round trip with merge defaults

    @Test func exportImportRoundTripUsesTheMergeDefaults() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
        #expect(passphrase.split(separator: "-").count == Limits.passphraseWordCount)

        let draft = try await world.open(file, passphrase: passphrase.uppercased().replacingOccurrences(of: "-", with: " "))
        let plan = draft.plan
        #expect(plan.blockReason == nil)
        #expect(plan.replayWarnings.isEmpty)
        #expect(plan.item("FXV_S1")?.chip == .new)
        #expect(plan.item("FXV_S1")?.action == .add)
        #expect(plan.item("FXV_V1")?.chip == .differs)
        #expect(plan.item("FXV_V1")?.action == .keepMine)
        #expect(plan.item("FXV_S2", environment: "production")?.chip == .fillsMissingValue)
        #expect(plan.item("FXV_S2", environment: "production")?.outcome == .filled(pending: false))
        #expect(plan.item("FXV_V2", environment: "production")?.chip == .new)
        let production = try #require(plan.environments.first)
        #expect(production.action == .useExisting)
        #expect(production.policyDifference?.decision == .keepMine)
        #expect(draft.manifest.flattenedItems.allSatisfy { $0.item.value == nil })

        let result = try await world.receiverSharing.apply(draft, plan: plan, confirmReplay: false)

        #expect(result.added.sorted() == ["FXV_S1", "production/FXV_V2"])
        #expect(result.filled == ["production/FXV_S2"])
        #expect(result.overwritten.isEmpty)
        #expect(result.policiesChanged.isEmpty)
        let receiver = world.receiver
        let s1 = try #require(try receiver.item("FXV_S1", kind: .secret))
        #expect(try receiver.value(s1.id) == "a1")
        #expect(s1.provenance == .share)
        #expect(s1.shareOrigin?.senderName == ShareWorld.senderName)
        #expect(s1.model.syncStatus == .added)
        let v1 = try #require(try receiver.item("FXV_V1", kind: .variable))
        #expect(try receiver.value(v1.id) == "different")
        #expect(v1.provenance == .github)
        let environment = try #require(try receiver.environment("production"))
        #expect(environment.branchPolicy == .all)
        let s2 = try #require(try receiver.item("FXV_S2", kind: .secret, scope: .environment(environment.id)))
        #expect(try receiver.value(s2.id) == "a2")
        #expect(s2.model.syncStatus == .unverifiedShare)
        // v0.1.2 keeps share fills as designed: unverified, never a requested push.
        #expect(!s2.forcePush && s2.forcePushRequestedAt == nil)
        #expect(try receiver.pendingCount() == 2)
        #expect(draft.isClosedForApply)
        await #expect(throws: SharingError.draftClosed) {
            _ = try await world.receiverSharing.apply(draft, plan: plan, confirmReplay: false)
        }
    }

    @Test func aReplayedPackageNeedsConfirmation() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        let first = try await world.open(file, passphrase: passphrase)
        try await world.receiverSharing.apply(first, plan: first.plan, confirmReplay: false)

        let replay = try await world.open(file, passphrase: passphrase)
        #expect(replay.plan.replayWarnings.contains(.alreadyImported))
        #expect(replay.plan.item("FXV_S1")?.chip == .same)
        await #expect(throws: SharingError.replayNotConfirmed) {
            _ = try await world.receiverSharing.apply(replay, plan: replay.plan, confirmReplay: false)
        }
        let result = try await world.receiverSharing.apply(replay, plan: replay.plan, confirmReplay: true)
        #expect(result.changedCount == 0)
    }

    @Test func aPackageImportedSinceThePreviewIsRefusedAsOutdated() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        let first = try await world.open(file, passphrase: passphrase)
        let second = try await world.open(file, passphrase: passphrase)
        #expect(!second.plan.replayWarnings.contains(.alreadyImported))
        try await world.receiverSharing.apply(first, plan: first.plan, confirmReplay: false)
        // The second preview predates the first import: its missing replay warning is stale.
        await #expect(throws: SharingError.planOutdated) {
            _ = try await world.receiverSharing.apply(second, plan: second.plan, confirmReplay: false)
        }
        let fresh = try await world.receiverSharing.replan(second, checkGitHub: false)
        #expect(fresh.plan.replayWarnings.contains(.alreadyImported))
    }

    @Test func overwriteAndTheIncomingPolicyApplyWhenChosen() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        let draft = try await world.open(file, passphrase: passphrase)
        var plan = draft.plan
        try plan.select(.overwrite, forItem: try #require(plan.item("FXV_V1")).id)
        let production = try #require(plan.environments.first)
        #expect(production.policyDifference?.isWidening == false)
        try plan.setPolicyDecision(.useIncoming, forEnvironment: production.id)

        let result = try await world.receiverSharing.apply(draft, plan: plan, confirmReplay: false)

        #expect(result.overwritten == ["FXV_V1"])
        #expect(result.policiesChanged == ["production"])
        let v1 = try #require(try world.receiver.item("FXV_V1", kind: .variable))
        #expect(try world.receiver.value(v1.id) == "v1")
        #expect(v1.model.syncStatus == .modified)
        let environment = try #require(try world.receiver.environment("production"))
        #expect(environment.branchPolicy.patterns.map(\.pattern) == ["release/*"])
        #expect(try world.receiver.pendingCount() == 4)
    }

    @Test func anAddGitHubAlreadyHasIsImportedAsSynced() async throws {
        let github = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        let world = try await ShareWorld.make(receiverGitHub: github)
        defer { world.folder.remove() }
        // GitHub got FXV_S1 after the receiver imported the repository.
        github.addSecret("FXV_S1", updatedAt: ShareWorld.secretUpdatedAt)
        let (file, passphrase) = try await world.export()
        let draft = try await world.open(file, passphrase: passphrase, checkGitHub: true)
        #expect(draft.plan.item("FXV_S1")?.outcome == .added(pending: false))
        try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        let s1 = try #require(try world.receiver.item("FXV_S1", kind: .secret))
        #expect(s1.syncedName == "FXV_S1")
        #expect(s1.model.syncStatus == .unverifiedShare)
        #expect(try world.receiver.syncedValue(s1.id) == "a1")
    }

    // MARK: - Refusals

    @Test func aWrongPassphraseIsTheSingleDamagedFileError() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        let generator = try PassphraseGenerator.bundled()
        var other = try #require(generator.generate().utf8String())
        while other == passphrase {
            other = try #require(generator.generate().utf8String())
        }
        await #expect(throws: SharingError.share(.invalidFile)) {
            _ = try await world.open(file, passphrase: other)
        }
        await #expect(throws: SharingError.share(.invalidPassphrase(.wrongWordCount(found: 2)))) {
            _ = try await world.open(file, passphrase: "two words")
        }
        let garbage = world.folder.url.appendingPathComponent("garbage.fxvault")
        try Data(repeating: 0x42, count: Limits.shareHeaderBytes + Limits.gcmTagBytes).write(to: garbage)
        #expect(throws: SharingError.share(.invalidFile)) {
            _ = try world.receiverSharing.readFile(at: garbage)
        }
        #expect(throws: SharingError.fileUnreadable) {
            _ = try world.receiverSharing.readFile(at: world.folder.url.appendingPathComponent("missing.fxvault"))
        }
    }

    @Test func theAuthorizationIsSingleUseAndBoundToItsPurposeAndKeys() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let selection = ShareSelectionModel.repository(try world.sender.repository().id)
        let authorization = world.authorization(.fileExport)
        _ = try await world.senderSharing.exportLegacyFile(
            selection,
            to: world.folder.url.appendingPathComponent("one.fxvault"),
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: authorization
        )
        #expect(!authorization.isUsable)
        await #expect(throws: SharingError.authorizationInvalid) {
            _ = try await world.senderSharing.exportLegacyFile(
                selection,
                to: world.folder.url.appendingPathComponent("two.fxvault"),
                senderName: ShareWorld.senderName,
                appVersion: ShareWorld.appVersion,
                authorization: authorization
            )
        }
        await #expect(throws: SharingError.authorizationInvalid) {
            _ = try await world.senderSharing.exportLegacyFile(
                selection,
                to: world.folder.url.appendingPathComponent("three.fxvault"),
                senderName: ShareWorld.senderName,
                appVersion: ShareWorld.appVersion,
                authorization: world.authorization(.nearbySend)
            )
        }
        // Granted through ReauthGate with the master password, then invalidated by a lock.
        let granted = try await ReauthGate(manager: world.sender.manager)
            .authorizeShare(.fileExport, with: .password(SyncFixture.password), session: world.sender.session)
        world.sender.manager.lock()
        _ = try await world.sender.manager.unlock(password: SyncFixture.password)
        await #expect(throws: SharingError.authorizationInvalid) {
            _ = try await world.senderSharing.exportLegacyFile(
                selection,
                to: world.folder.url.appendingPathComponent("four.fxvault"),
                senderName: ShareWorld.senderName,
                appVersion: ShareWorld.appVersion,
                authorization: granted
            )
        }
        #expect(!FileManager.default.fileExists(atPath: world.folder.url.appendingPathComponent("two.fxvault").path))
    }

    @Test func aPreviewThatChangedBeforeApplyIsRefused() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        let draft = try await world.open(file, passphrase: passphrase)
        try world.receiver.add("FXV_S1", kind: .secret, value: "mine")
        await #expect(throws: SharingError.planOutdated) {
            _ = try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        }
        let value = try #require(try world.receiver.item("FXV_S1", kind: .secret))
        #expect(try world.receiver.value(value.id) == "mine")
        // Previewing again gives a plan that applies.
        let fresh = try await world.receiverSharing.replan(draft, checkGitHub: false)
        #expect(fresh.plan.item("FXV_S1")?.chip == .differs)
        try await world.receiverSharing.apply(fresh, plan: fresh.plan, confirmReplay: false)
    }

    @Test func aRepositoryMissingOrWithAnotherIDIsBlocked() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (file, passphrase) = try await world.export()
        var repository = try world.receiver.repository()
        repository.githubID = "R_someone_else"
        try RepoStore(database: world.receiver.database).update(repository)
        let mismatched = try await world.open(file, passphrase: passphrase)
        #expect(mismatched.plan.blockReason == .repositoryIDMismatch)
        await #expect(throws: SharingError.importBlocked(.repositoryIDMismatch)) {
            _ = try await world.receiverSharing.apply(mismatched, plan: mismatched.plan, confirmReplay: false)
        }

        try RepoStore(database: world.receiver.database).delete(id: repository.id)
        let missing = try await world.open(file, passphrase: passphrase)
        #expect(missing.plan.blockReason == .repositoryNotImported)
        // The one-click import, then the same draft is planned again.
        try await world.receiver.importRepository()
        let replanned = try await world.receiverSharing.replan(missing, checkGitHub: false)
        #expect(replanned.plan.blockReason == nil)
        #expect(missing.isClosedForApply)
        let result = try await world.receiverSharing.apply(replanned, plan: replanned.plan, confirmReplay: false)
        #expect(result.added.contains("FXV_S1"))
    }

    // MARK: - Export selection

    @Test func previewAndSelections() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let sender = world.sender
        let missing = try sender.insertRow("FXV_MISSING", kind: .secret, value: nil, syncedName: "FXV_MISSING")
        let preview = try await world.senderSharing.previewExport(.repository(try sender.repository().id))
        #expect(preview.scope == .repository)
        #expect(preview.repositoryFullName == "owner-a/api")
        #expect(preview.environmentNames == ["production"])
        #expect(preview.itemCount == 5)
        #expect(preview.valueMissingNames == ["FXV_MISSING"])

        let production = try #require(try sender.environment("production"))
        #expect(try await world.senderSharing.previewExport(.environment(production.id)).itemCount == 2)
        let single = try await world.senderSharing.previewExport(.item(missing))
        #expect(single.scope == .secret)
        #expect(single.itemCount == 1)

        try sender.config.deleteItem(missing)
        await #expect(throws: SharingError.itemNotFound) {
            _ = try await world.senderSharing.previewExport(.item(missing))
        }
        await #expect(throws: SharingError.repositoryNotFound) {
            _ = try await world.senderSharing.previewExport(.repository(RepoID()))
        }
    }

    @Test func aValueMissingSecretTravelsByNameOnly() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        try world.sender.insertRow("FXV_ONLY_NAME", kind: .secret, value: nil, syncedName: "FXV_ONLY_NAME")
        let (file, passphrase) = try await world.export()
        let draft = try await world.open(file, passphrase: passphrase)
        #expect(draft.plan.item("FXV_ONLY_NAME")?.chip == .valueNotIncluded)
        let result = try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.addedWithoutValue == ["FXV_ONLY_NAME"])
        let row = try #require(try world.receiver.item("FXV_ONLY_NAME", kind: .secret))
        #expect(!row.hasValue)
        #expect(row.syncedName == "FXV_ONLY_NAME")
    }
}
