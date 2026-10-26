import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Opening a `.fxvault` file: the single generic error, passphrase normalization, chips and
/// "Keep mine" defaults, Overwrite all, the widening second confirmation, replay, the one-click
/// repository import and apply.
@MainActor
@Suite("Share import")
struct SharingImportViewModelTests {
    private func importer(_ world: SharingWorld, file: URL, isGitHubReady: Bool = false) -> ShareImportViewModel {
        ShareImportViewModel(
            context: ShareImportContext(fileURL: file),
            dependencies: world.receiverDependencies(isGitHubReady: isGitHubReady)
        )
    }

    private func opened(_ world: SharingWorld) async throws -> ShareImportViewModel {
        let file = try await world.exportFile()
        let model = importer(world, file: file.url)
        await model.start()
        model.passphrase = file.passphrase
        await model.open()
        #expect(model.step == .preview, "\(String(describing: model.passphraseError))")
        return model
    }

    @Test func aWrongPassphraseShowsTheSingleGenericMessage() async throws {
        let world = try await SharingWorld()
        let file = try await world.exportFile()
        let model = importer(world, file: file.url)
        await model.start()
        #expect(model.step == .passphrase)
        #expect(!model.canOpen)

        let generator = try #require(world.receiver.container.passphraseGenerator)
        let other = try #require(generator.generate().utf8String())
        model.passphrase = other == file.passphrase ? String(file.passphrase.reversed()) : other
        #expect(model.typedWordCount == Limits.passphraseWordCount)
        await model.open()
        #expect(model.step == .passphrase)
        #expect(model.passphraseError == SharingError.wrongPassphraseOrDamagedFile)
        #expect(model.editor == nil)
    }

    @Test func aDamagedFileShowsTheSameMessage() async throws {
        let world = try await SharingWorld()
        let file = try await world.exportFile()
        var bytes = try Data(contentsOf: file.url)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: file.url)
        let model = importer(world, file: file.url)
        await model.start()
        model.passphrase = file.passphrase
        await model.open()
        #expect(model.passphraseError == SharingError.wrongPassphraseOrDamagedFile)

        // A file that is not a share at all fails before the passphrase, with the same text.
        let garbage = world.receiver.sandbox.appendingPathComponent("garbage.fxvault")
        try Data("not a share".utf8).write(to: garbage)
        let other = importer(world, file: garbage)
        await other.start()
        #expect(other.step == .failed)
        #expect(other.failure == SharingError.wrongPassphraseOrDamagedFile)
        #expect(!other.hasExpired)
    }

    @Test func thePassphraseIsNormalized() async throws {
        let world = try await SharingWorld()
        let file = try await world.exportFile()
        let model = importer(world, file: file.url)
        await model.start()
        model.passphrase = "  " + file.passphrase.uppercased().replacingOccurrences(of: "-", with: " ") + "\n"
        #expect(model.canOpen)
        await model.open()
        #expect(model.step == .preview)
        // The typed passphrase is dropped once used.
        #expect(model.passphrase.isEmpty)

        let invalid = importer(world, file: file.url)
        await invalid.start()
        invalid.passphrase = "only three words"
        #expect(!invalid.canOpen)
        #expect(invalid.typedWordCount == 3)
    }

    @Test func thePreviewShowsChipsWithKeepMineDefaultsAndNoValues() async throws {
        let world = try await SharingWorld()
        let model = try await opened(world)
        let editor = try #require(model.editor)
        let plan = editor.plan
        func item(_ name: String) -> ShareItemPlanModel? {
            plan.allItems.first { $0.key.name == name }
        }

        #expect(item("API_TOKEN")?.chip == .differs)
        #expect(item("API_TOKEN")?.action == .keepMine)
        #expect(item("API_TOKEN")?.allowedActions.contains(.overwrite) == true)
        #expect(item("NEW_SECRET")?.chip == .new)
        #expect(item("NEW_SECRET")?.action == .add)
        #expect(item("BASE_URL")?.chip == .same)
        #expect(item("DEPLOY_KEY")?.chip == .new)
        #expect(editor.senderName == SharingWorld.identity.displayName)
        #expect(editor.repositoryFullName == "\(TestFixtures.owner)/\(TestFixtures.repoName)")
        #expect(editor.hasDifferingItems)
        #expect(!editor.isOverwritingAll)
        #expect(model.canApply)

        editor.overwriteAll()
        #expect(editor.plan.allItems.first { $0.key.name == "API_TOKEN" }?.action == .overwrite)
        #expect(editor.isOverwritingAll)

        // Values never reach the view model.
        let dump = textDump(editor.plan, editor.sections.map(\.items), model.result as Any)
        #expect(!dump.contains(SharingWorld.secretValue))
        #expect(!dump.contains(SharingWorld.receiverSecretValue))
    }

    @Test func applyKeepsMineByDefaultAndReportsNamesOnly() async throws {
        let world = try await SharingWorld()
        let model = try await opened(world)
        await model.apply()

        #expect(model.step == .done)
        let result = try #require(model.result)
        #expect(result.added.sorted() == ["NEW_SECRET", "\(SharingWorld.environment)/DEPLOY_KEY"].sorted())
        #expect(result.overwritten.isEmpty)
        #expect(try await world.receiverValue("API_TOKEN", kind: .secret) == SharingWorld.receiverSecretValue)
        #expect(try await world.receiverValue("NEW_SECRET", kind: .secret) == SharingWorld.secretValue)
        #expect(!textDump(result).contains(SharingWorld.secretValue))
        // Nothing was pushed: the import only created local pending changes.
        #expect(world.receiver.runner.invocations.isEmpty)
    }

    @Test func overwriteReplacesTheDifferingValue() async throws {
        let world = try await SharingWorld()
        let model = try await opened(world)
        let editor = try #require(model.editor)
        let token = try #require(editor.plan.allItems.first { $0.key.name == "API_TOKEN" })
        editor.select(.overwrite, for: token)
        await model.apply()
        #expect(model.result?.overwritten == ["API_TOKEN"])
        #expect(try await world.receiverValue("API_TOKEN", kind: .secret) == SharingWorld.secretValue)
    }

    @Test func aWideningPolicyNeedsASecondConfirmation() async throws {
        let world = try await SharingWorld(receiverPolicy: .protectedBranches, senderPolicy: .all)
        let model = try await opened(world)
        let editor = try #require(model.editor)
        let environment = try #require(editor.plan.environments.first)
        let difference = try #require(environment.policyDifference)
        #expect(difference.isWidening)
        #expect(difference.decision == .keepMine)

        editor.choosePolicy(.useIncoming, for: environment)
        #expect(editor.pendingWideningEnvironment == environment.id)
        #expect(editor.plan.environments.first?.policyDifference?.decision == .keepMine)
        #expect(!model.canApply)

        editor.cancelWidening()
        #expect(editor.plan.environments.first?.policyDifference?.decision == .keepMine)

        editor.choosePolicy(.useIncoming, for: environment)
        editor.confirmWidening()
        #expect(editor.plan.environments.first?.policyDifference?.decision == .useIncoming)
        #expect(model.canApply)
        await model.apply()
        #expect(model.result?.policiesChanged == [SharingWorld.environment])
    }

    @Test func aReplayedShareNeedsConfirmation() async throws {
        let world = try await SharingWorld()
        let file = try await world.exportFile()
        let first = importer(world, file: file.url)
        await first.start()
        first.passphrase = file.passphrase
        await first.open()
        await first.apply()
        #expect(first.step == .done)

        let again = importer(world, file: file.url)
        await again.start()
        again.passphrase = file.passphrase
        await again.open()
        let editor = try #require(again.editor)
        #expect(editor.plan.replayWarnings.contains(.alreadyImported))
        #expect(!again.canApply)
        editor.confirmsReplay = true
        #expect(again.canApply)
    }

    @Test func aRepositoryNotInTheVaultNeedsGitHubForTheOneClickImport() async throws {
        let world = try await SharingWorld(receiverHasRepository: false)
        let model = try await opened(world)
        #expect(model.editor?.blockReason == .repositoryNotImported)
        #expect(model.needsRepositoryImport)
        #expect(!model.canApply)

        await model.importRepository()
        #expect(model.alert == ShareRepositoryImportError.gitHubUnavailable.errorPresentation)
        #expect(model.needsRepositoryImport)
    }

    @Test func theOneClickImportUsesAnAccountWithAccessThenPlansAgain() async throws {
        let world = try await SharingWorld(receiverHasRepository: false, receiverGHStatus: nil)
        let harness = world.receiver
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(
            argumentsPrefix: ["repo", "view"],
            with: .success(TestFixtures.repoJSON(owner: TestFixtures.owner, name: TestFixtures.repoName, permission: "ADMIN"))
        )
        harness.runner.stub(argumentsPrefix: ["secret", "list"], with: .success("[]"))
        harness.runner.stub(argumentsPrefix: ["variable", "list"], with: .success("[]"))
        harness.runner.stub(argumentsPrefix: ["api"], with: .success("[{\"total_count\":0,\"environments\":[]}]"))
        await harness.app.refreshGHStatus()

        let file = try await world.exportFile()
        let model = importer(world, file: file.url, isGitHubReady: true)
        await model.start()
        model.passphrase = file.passphrase
        await model.open()
        #expect(model.needsRepositoryImport)

        await model.importRepository()
        #expect(model.alert == nil, "\(String(describing: model.alert))")
        #expect(!model.needsRepositoryImport)
        #expect(model.editor?.blockReason == nil)
        #expect(world.receiverRecorder.refreshes == [.catalog])
        #expect(model.canApply)
    }

    @Test func closingAndLockingDiscardTheDraft() async throws {
        let world = try await SharingWorld()
        let model = try await opened(world)
        let other = try await opened(world)
        other.close()
        #expect(other.editor == nil)
        #expect(!other.canApply)

        model.passphrase = "typed words"
        world.receiver.app.lock(trigger: .manual)
        #expect(model.editor == nil)
        #expect(model.passphrase.isEmpty)
        #expect(model.step == .passphrase)
        #expect(!model.canApply)
    }
}
