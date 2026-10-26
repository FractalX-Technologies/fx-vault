import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// New Repository (§10 `CreateRepoScreen`, M4): loading owners and templates, the debounced name
/// check, clone settings, staging (nothing reaches GitHub until Sync), and value hygiene.
@MainActor
@Suite("Create repository")
struct CreateRepoViewModelTests {
    static let secretValue = "FXV_FIXTURE_CREATE_SECRET"
    static let variableValue = "https://example.com/fxv-fixture"
    static let environmentSecretValue = "FXV_FIXTURE_ENV_SECRET"
    static let notFound = "GraphQL: Could not resolve to a Repository with the name 'user-a/new-repo'. (repository)\n"
    static let licenses = "mit\tMIT\tMIT License\napache-2.0\tApache-2.0\tApache License 2.0\n"

    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let viewModel: CreateRepoViewModel

        init(
            context: CreateRepoContext = CreateRepoContext(accountLogin: nil, ownerLogin: nil),
            isGitHubReady: Bool = true,
            organizations: FakeCommandRunner.Response = .success("Example-Org\n")
        ) async throws {
            harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
            try harness.installFakeGH()
            harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
            harness.stubToken()
            harness.runner.stub(argumentsPrefix: ["org", "list"], with: organizations)
            harness.runner.stub(argumentsPrefix: ["repo", "gitignore", "list"], with: .success("Swift\nNode\n"))
            harness.runner.stub(argumentsPrefix: ["repo", "license", "list"], with: .success(CreateRepoViewModelTests.licenses))
            await harness.app.refreshGHStatus()
            viewModel = CreateRepoViewModel(
                context: context,
                dependencies: harness.dependencies(recorder: recorder, isGitHubReady: isGitHubReady)
            )
        }

        /// gh calls whose argv starts with `prefix`.
        func calls(_ prefix: [String]) -> [FakeCommandRunner.Invocation] {
            harness.runner.invocations.filter { Array($0.arguments.prefix(prefix.count)) == prefix }
        }

        /// Types `name` and lets the debounced availability check finish.
        func settleAvailability(name: String) async {
            let sleepers = harness.clock.sleeperCount
            viewModel.name = name
            guard viewModel.availability == .checking else { return }
            await harness.clock.waitForSleepers(count: sleepers + 1)
            harness.clock.advance(by: CreateRepoConstants.availabilityDebounce)
            await viewModel.availabilityTask?.value
        }

        /// A loaded form with a probably-available name and cloning off.
        func readyToCreate(name: String = "new-repo") async {
            harness.runner.stub(argumentsPrefix: ["repo", "view"], with: .failure(stderr: CreateRepoViewModelTests.notFound))
            await viewModel.load()
            viewModel.clonesAfterCreate = false
            await settleAvailability(name: name)
        }

        /// Adds an item through the nested editor, as the sheet does.
        func addItem(_ kind: ConfigKind, _ name: String, _ value: String, to target: CreateRepoItemTargetModel = .repository) throws {
            viewModel.addItem(kind: kind, to: target)
            guard case .item(let editor) = viewModel.editor else {
                Issue.record("No item editor")
                return
            }
            editor.name = name
            editor.value = value
            #expect(editor.save())
        }

        /// Adds an environment through the nested editor.
        func addEnvironment(_ name: String, policy: (CreateRepoEnvironmentEditorViewModel) -> Void = { _ in }) -> UUID? {
            viewModel.addEnvironment()
            guard case .environment(let editor) = viewModel.editor else { return nil }
            editor.name = name
            policy(editor)
            #expect(editor.save())
            return viewModel.environments.last?.id
        }
    }

    // MARK: - Loading

    @Test func loadsAccountsOwnersAndTemplates() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.load()

        #expect(model.phase == .ready)
        #expect(model.accounts == ["user-a", "user-b"])
        #expect(model.accountLogin == "user-a")
        #expect(model.owners.map(\.login) == ["user-a", "Example-Org"])
        #expect(model.owners.map(\.ownerType) == [.user, .organization])
        #expect(model.selectedOwner?.login == "user-a")
        #expect(model.gitignoreTemplates == ["Swift", "Node"])
        #expect(model.licenseTemplates.map(\.key) == ["mit", "apache-2.0"])
        #expect(model.templatesError == nil)
        #expect(model.visibility == .private)
        #expect(model.addsReadme)
        #expect(model.clonesAfterCreate)
        #expect(!model.canCreate)
    }

    @Test func contextPreselectsAccountAndOrganization() async throws {
        let fixture = try await Fixture(context: CreateRepoContext(accountLogin: "USER-A", ownerLogin: "example-org"))
        await fixture.viewModel.load()
        #expect(fixture.viewModel.accountLogin == "user-a")
        #expect(fixture.viewModel.selectedOwner?.login == "Example-Org")
        #expect(fixture.viewModel.selectedOwner?.ownerType == .organization)
    }

    @Test func withoutGitHubTheSheetExplainsAndCallsNothing() async throws {
        let fixture = try await Fixture(isGitHubReady: false)
        await fixture.viewModel.load()
        guard case .loadFailed(let error) = fixture.viewModel.phase else {
            Issue.record("Expected a load failure")
            return
        }
        #expect(!error.title.isEmpty)
        #expect(fixture.calls(["org", "list"]).isEmpty)
        #expect(!fixture.viewModel.canCreate)
    }

    @Test func organizationFailureStillOffersThePersonalAccount() async throws {
        let fixture = try await Fixture(organizations: .failure(stderr: "HTTP 403: Must have admin rights to Repository. (https://api.github.com/user/orgs)\n"))
        await fixture.viewModel.load()
        #expect(fixture.viewModel.owners.map(\.login) == ["user-a"])
        #expect(fixture.viewModel.selectedOwner?.ownerType == .user)
        #expect(fixture.viewModel.ownersWarning != nil)
        #expect(fixture.viewModel.phase == .ready)
    }

    @Test func templatesAreCachedPerAccount() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.load()
        model.gitignoreTemplate = "Swift"
        #expect(fixture.calls(["repo", "gitignore", "list"]).count == 1)

        model.accountLogin = "user-b"
        await model.accountTask?.value
        #expect(model.selectedOwner?.login == "user-b")
        #expect(fixture.calls(["repo", "gitignore", "list"]).count == 2)
        #expect(model.gitignoreTemplate == "Swift")

        model.accountLogin = "user-a"
        await model.accountTask?.value
        #expect(fixture.calls(["repo", "gitignore", "list"]).count == 2)
        #expect(fixture.calls(["repo", "license", "list"]).count == 2)
        #expect(model.gitignoreTemplates == ["Swift", "Node"])
    }

    // MARK: - Name check

    @Test func invalidNamesAreRejectedLocallyWithASuggestion() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.load()

        model.name = "My App"
        #expect(model.availability == .invalid(.invalidCharacter))
        #expect(model.nameError != nil)
        #expect(model.suggestedName == "My-App")
        model.name = "tools.git"
        #expect(model.availability == .invalid(.gitSuffix))
        model.name = ".."
        #expect(model.availability == .invalid(.dotName))
        #expect(!model.canCreate)
        #expect(fixture.calls(["repo", "view"]).isEmpty)

        model.name = "My App"
        model.applySuggestedName()
        #expect(model.name == "My-App")
        #expect(model.availability == .checking)
    }

    @Test func availabilityIsDebouncedAndProbablyAvailable() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        fixture.harness.runner.stub(argumentsPrefix: ["repo", "view"], with: .failure(stderr: Self.notFound))
        await model.load()
        let sleepers = fixture.harness.clock.sleeperCount

        model.name = "new"
        #expect(model.availability == .checking)
        await fixture.harness.clock.waitForSleepers(count: sleepers + 1)
        model.name = "new-repo"
        await fixture.harness.clock.waitForSleepers(count: sleepers + 1)
        #expect(fixture.calls(["repo", "view"]).isEmpty)

        fixture.harness.clock.advance(by: CreateRepoConstants.availabilityDebounce)
        await model.availabilityTask?.value
        let views = fixture.calls(["repo", "view"])
        #expect(views.count == 1)
        #expect(views.first?.arguments.contains("user-a/new-repo") == true)
        #expect(model.availability == .probablyAvailable)
    }

    @Test func aTakenNameBlocksCreate() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        fixture.harness.runner.stub(
            argumentsPrefix: ["repo", "view"],
            with: .success(TestFixtures.repoJSON(owner: "user-a", name: "taken-repo", permission: "ADMIN"))
        )
        await model.load()
        model.clonesAfterCreate = false
        await fixture.settleAvailability(name: "taken-repo")
        #expect(model.availability == .taken)
        #expect(model.availability.blocksCreate)
        #expect(!model.canCreate)
    }

    @Test func aFailedCheckDoesNotBlockCreate() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        fixture.harness.runner.stub(
            argumentsPrefix: ["repo", "view"],
            with: .failure(stderr: "HTTP 403: Must have admin rights to Repository. (https://api.github.com/graphql)\n")
        )
        await model.load()
        model.clonesAfterCreate = false
        await fixture.settleAvailability(name: "maybe-repo")
        guard case .unknown = model.availability else {
            Issue.record("Expected an unknown availability, got \(model.availability)")
            return
        }
        #expect(model.canCreate)
    }

    @Test func changingTheOwnerChecksAgain() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        #expect(fixture.calls(["repo", "view"]).count == 1)

        let organization = try #require(model.owners.last)
        let sleepers = fixture.harness.clock.sleeperCount
        model.ownerID = organization.id
        #expect(model.availability == .checking)
        await fixture.harness.clock.waitForSleepers(count: sleepers + 1)
        fixture.harness.clock.advance(by: CreateRepoConstants.availabilityDebounce)
        await model.availabilityTask?.value
        #expect(fixture.calls(["repo", "view"]).last?.arguments.contains("Example-Org/new-repo") == true)
    }

    // MARK: - Clone

    @Test func cloneToMyMacNeedsAFolder() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        model.clonesAfterCreate = true
        #expect(model.needsCloneFolder)
        #expect(!model.canCreate)
        #expect(model.cloneNeedsSSHAlias)

        model.setCloneFolder(fixture.harness.sandbox)
        #expect(fixture.harness.preferences.cloneFolderURL == fixture.harness.sandbox.standardizedFileURL)
        #expect(!model.needsCloneFolder)
        #expect(model.canCreate)

        model.clonesAfterCreate = false
        #expect(!model.cloneNeedsSSHAlias)
        #expect(model.canCreate)
    }

    /// Board NewRepo shows the account's SSH alias beside the clone folder.
    @Test func cloneShowsTheAccountsSSHAlias() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.harness.data.github.accounts()
        try await fixture.harness.data.github.mapSSHAlias("github-example", to: "user-a")
        let model = fixture.viewModel
        await fixture.readyToCreate()
        model.clonesAfterCreate = true
        #expect(model.accountLogin == "user-a")
        #expect(model.cloneSSHAlias == "github-example")
        #expect(!model.cloneNeedsSSHAlias)

        model.accountLogin = "user-b"
        #expect(model.cloneSSHAlias == nil)
        #expect(model.cloneNeedsSSHAlias)
    }

    // MARK: - Create (staging)

    @Test func createStagesEverythingWithoutTouchingGitHub() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        model.repoDescription = "  Example service  "
        model.visibility = .public
        model.gitignoreTemplate = "Swift"
        model.licenseKey = "mit"
        model.clonesAfterCreate = true
        model.setCloneFolder(fixture.harness.sandbox)
        try fixture.addItem(.secret, "api_token", Self.secretValue)
        try fixture.addItem(.variable, "BASE_URL", Self.variableValue)
        let environmentID = try #require(fixture.addEnvironment("production") { editor in
            editor.policyForm.choice = .selected
            editor.policyForm.newPattern = "release/*"
            editor.policyForm.addPattern()
        })
        try fixture.addItem(.secret, "DEPLOY_KEY", Self.environmentSecretValue, to: .environment(environmentID))
        #expect(model.secretCount == 2)
        #expect(model.variableCount == 1)
        let invocationsBefore = fixture.harness.runner.invocations.count

        #expect(await model.create())

        guard case .staged(let staged) = model.phase else {
            Issue.record("Expected the staged page")
            return
        }
        #expect(staged.fullName == "user-a/new-repo")
        #expect(staged.environmentCount == 1)
        #expect(staged.secretCount == 2)
        #expect(staged.variableCount == 1)
        #expect(staged.cloneFolder?.lastPathComponent == "new-repo")
        // Nothing went to GitHub: staging is local only.
        #expect(fixture.harness.runner.invocations.count == invocationsBefore)
        #expect(fixture.calls(["repo", "create"]).isEmpty)

        let repository = try #require(fixture.harness.repository(staged.repositoryID))
        #expect(!repository.existsOnGitHub)
        #expect(repository.origin == .created)
        #expect(repository.ownerLogin == "user-a")
        #expect(repository.visibility == .public)
        #expect(repository.description == "Example service")
        #expect(repository.createSpec == RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "mit", cloneAfter: true))

        let changes = try #require(try fixture.harness.data.config.changeSet(repositoryID: staged.repositoryID))
        #expect(changes.changes.contains { $0.kind == .createRepository })
        var revealed: [String] = []
        for itemID in changes.changes.compactMap(\.operation.itemID) {
            let value = try fixture.harness.data.config.reveal(itemID)
            revealed.append(value.utf8String() ?? "")
            value.wipe()
        }
        #expect(Set(revealed) == [Self.secretValue, Self.variableValue, Self.environmentSecretValue])
        let scopes = try fixture.harness.data.config.scopes(repositoryID: staged.repositoryID)
        let production = try #require(scopes.first { $0.environment?.name == "production" })
        #expect(production.environment?.branchPolicy.activePatterns.map(\.pattern) == ["release/*"])

        // The typed values are gone from the view model.
        #expect(model.repositoryItems.isEmpty)
        #expect(model.environments.isEmpty)
        #expect(!model.hasUnsavedInput)
    }

    @Test func valuesNeverAppearInSummariesDescriptionsOrGHCalls() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        try fixture.addItem(.secret, "API_TOKEN", Self.secretValue)
        try fixture.addItem(.variable, "BASE_URL", Self.variableValue)
        let environmentID = try #require(fixture.addEnvironment("staging"))
        try fixture.addItem(.secret, "DEPLOY_KEY", Self.environmentSecretValue, to: .environment(environmentID))
        let values = [Self.secretValue, Self.variableValue, Self.environmentSecretValue]

        var texts: [String] = []
        for item in model.repositoryItems + model.environments.flatMap(\.items) {
            texts.append(String(describing: item))
            texts.append(String(reflecting: item))
            var dumped = ""
            dump(item, to: &dumped)
            texts.append(dumped)
        }
        for environment in model.environments {
            texts.append(String(describing: environment))
            var dumped = ""
            dump(environment, to: &dumped)
            texts.append(dumped)
        }

        #expect(await model.create())
        if case .staged(let staged) = model.phase {
            texts.append(String(describing: staged))
        }
        for text in texts {
            for value in values {
                #expect(!text.contains(value), "A value leaked into: \(text.prefix(60))")
            }
        }
        for invocation in fixture.harness.runner.invocations {
            let stdin = String(decoding: invocation.stdin, as: UTF8.self)
            for value in values {
                #expect(!invocation.arguments.joined(separator: " ").contains(value))
                #expect(!stdin.contains(value))
            }
        }
    }

    @Test func trailingNewlinesAreReportedByName() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        try fixture.addItem(.secret, "PEM_KEY", Self.secretValue + "\n")
        #expect(await model.create())
        guard case .staged(let staged) = model.phase else {
            Issue.record("Expected the staged page")
            return
        }
        #expect(staged.strippedTrailingNewlines == ["PEM_KEY"])
    }

    @Test func aStagingErrorKeepsTheForm() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate(name: TestFixtures.repoName)
        try await fixture.harness.stageRepository(owner: "user-a", name: TestFixtures.repoName)
        try fixture.addItem(.secret, "API_TOKEN", Self.secretValue)

        #expect(await model.create() == false)
        #expect(model.phase == .ready)
        #expect(model.alert != nil)
        #expect(model.repositoryItems.map(\.name) == ["API_TOKEN"])
    }

    @Test func createIsANoOpUntilTheFormIsValid() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.load()
        model.clonesAfterCreate = false
        model.name = "bad name"
        #expect(!model.canCreate)
        #expect(await model.create() == false)
        #expect(model.phase == .ready)
        #expect(try fixture.harness.data.config.pendingCounts().total == 0)
    }

    @Test func syncNowOpensSyncForTheStagedRepository() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        #expect(!model.canSyncNow)
        #expect(await model.create())
        guard case .staged(let staged) = model.phase else {
            Issue.record("Expected the staged page")
            return
        }
        #expect(fixture.recorder.selections == [staged.repositoryID], "the staged repository is selected in the sidebar")
        #expect(model.canSyncNow)
        #expect(model.syncNowUnavailableReason == nil)
        model.syncNow()
        #expect(fixture.recorder.presented == [.sync(SyncContext(repositoryIDs: [staged.repositoryID]))])
    }

    @Test func syncNowIsDisabledOfflineAndSaysWhy() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        #expect(await model.create())
        fixture.harness.pathSource.send(.offline)
        #expect(!model.canSyncNow)
        #expect(model.syncNowUnavailableReason == ConnectivityCopy.offlineHelp)
        model.syncNow()
        #expect(fixture.recorder.presented.isEmpty)
    }

    // MARK: - Environments and plan note

    @Test func editingAnEnvironmentKeepsItsItems() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        let id = try #require(fixture.addEnvironment("qa"))
        try fixture.addItem(.variable, "LEVEL", "debug", to: .environment(id))

        model.editEnvironment(id)
        guard case .environment(let editor) = model.editor else {
            Issue.record("No environment editor")
            return
        }
        #expect(!editor.isNew)
        editor.name = "QA-Env"
        editor.policyForm.choice = .protectedBranches
        #expect(editor.save())
        #expect(model.environments.map(\.name) == ["QA-Env"])
        #expect(model.environments.first?.policy == .protectedBranches)
        #expect(model.items(in: .environment(id)).map(\.name) == ["LEVEL"])

        model.removeEnvironment(id)
        #expect(model.environments.isEmpty)
        #expect(model.variableCount == 0)
    }

    @Test func thePlanNoteShowsForPrivateRepositoriesWithEnvironments() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        #expect(!model.showsPlanNote)
        _ = fixture.addEnvironment("production")
        #expect(model.showsPlanNote)
        model.visibility = .public
        #expect(!model.showsPlanNote)
    }

    @Test func itemsCanBeEditedAndRemoved() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        try fixture.addItem(.secret, "API_TOKEN", Self.secretValue)
        let id = try #require(model.repositoryItems.first?.id)

        model.editItem(id, in: .repository)
        guard case .item(let editor) = model.editor else {
            Issue.record("No item editor")
            return
        }
        #expect(!editor.isNew)
        #expect(editor.value == Self.secretValue)
        editor.name = "API_KEY"
        #expect(editor.save())
        #expect(model.repositoryItems.map(\.name) == ["API_KEY"])
        #expect(model.editor == nil)

        model.removeItem(id, from: .repository)
        #expect(model.repositoryItems.isEmpty)
    }

    // MARK: - Cancel and lock

    @Test func cancelAsksBeforeDiscardingTypedInput() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.load()
        #expect(model.requestCancel())
        #expect(!model.isConfirmingDiscard)

        model.name = "draft"
        try fixture.addItem(.secret, "API_TOKEN", Self.secretValue)
        #expect(model.requestCancel() == false)
        #expect(model.isConfirmingDiscard)
        model.discard()
        #expect(!model.isConfirmingDiscard)
        #expect(model.repositoryItems.isEmpty)
        #expect(model.name.isEmpty)
        #expect(model.requestCancel())
    }

    @Test func closingTheItemEditorDropsItsValue() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await model.load()
        model.addItem(kind: .secret, to: .repository)
        guard case .item(let editor) = model.editor else {
            Issue.record("No item editor")
            return
        }
        editor.value = Self.secretValue
        model.dismissEditor()
        #expect(model.editor == nil)
        #expect(editor.value.isEmpty)
        #expect(model.repositoryItems.isEmpty)
    }

    @Test func aLockDropsEveryTypedValue() async throws {
        let fixture = try await Fixture()
        let model = fixture.viewModel
        await fixture.readyToCreate()
        try fixture.addItem(.secret, "API_TOKEN", Self.secretValue)
        let id = try #require(fixture.addEnvironment("production"))
        try fixture.addItem(.secret, "DEPLOY_KEY", Self.environmentSecretValue, to: .environment(id))
        model.addItem(kind: .variable, to: .repository)
        guard case .item(let editor) = model.editor else {
            Issue.record("No item editor")
            return
        }
        editor.value = Self.variableValue

        fixture.harness.app.lock(trigger: .manual)

        #expect(model.repositoryItems.isEmpty)
        #expect(model.environments.isEmpty)
        #expect(model.editor == nil)
        #expect(editor.value.isEmpty)
    }
}
