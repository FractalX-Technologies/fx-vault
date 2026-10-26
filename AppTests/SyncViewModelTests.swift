import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The Sync sheet: summary, blocked fixes, credential confirmation, deletion review, the run
/// with its sync activity, the result, clones and the security rules (names only).
@MainActor
@Suite("Sync sheet")
struct SyncViewModelTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let urls = URLRecorder()
        /// How often the sheet asked for a clone folder (the panel is "cancelled": nil).
        let folderRequests = Counter()
        let service: FakeSyncService
        let viewModel: SyncViewModel

        init(
            review: Result<SyncReviewModel, SyncRepositoryError>,
            isGitHubReady: Bool = true,
            repositoryIDs: Set<RepoID>? = nil
        ) async throws {
            harness = try await TestHarness(vault: .unlocked)
            service = FakeSyncService(review: review)
            let urls = urls
            let folderRequests = folderRequests
            viewModel = SyncViewModel(
                context: SyncContext(repositoryIDs: repositoryIDs),
                dependencies: harness.dependencies(recorder: recorder, isGitHubReady: isGitHubReady),
                service: service,
                openURL: { urls.opened.append($0) },
                chooseCloneFolder: {
                    folderRequests.value += 1
                    return nil
                }
            )
        }

        /// Loads, starts the run without waiting for it, and waits until it is in progress.
        func startRun(includeDeletions: Bool = false) async -> Task<Void, Never> {
            let model = viewModel
            let task = Task { await model.startSync(includeDeletions: includeDeletions) }
            let service = service
            #expect(await TestFixtures.eventually { !service.startedRuns.isEmpty && model.step == .progress })
            return task
        }
    }

    // MARK: - Summary

    /// B6b3b: organization changes count on the badge, get a group of their own in the toolbar
    /// Sync, and are sent after the repositories.
    @Test func organizationChangesJoinTheBadgeTheSummaryAndTheRun() async throws {
        let (harness, organization) = try await OrganizationEditingTests().imported()
        harness.runner.stub(argumentsPrefix: ["variable", "set"], with: .success(""))
        try harness.data.organizationItems.addItem(organizationID: organization.id, kind: .variable, name: "ZONE", value: SecretBytes(utf8: "eu-west-1"), access: .all)
        #expect(await TestFixtures.eventually { harness.app.pendingChangeCount == 1 })

        let model = SyncViewModel(
            context: SyncContext(repositoryIDs: nil),
            dependencies: harness.dependencies(recorder: ActionRecorder(), isGitHubReady: true),
            service: FakeSyncService(review: .success(SyncFixtures.review([])))
        )
        await model.load()
        let group = try #require(model.repositories.first { $0.id == .organization(organization.id) })
        #expect(group.fullName == "Example-Org")
        #expect(group.scopes.first?.details == ["+ ZONE"])
        #expect(model.executableCount == 1)

        await model.startSync(includeDeletions: false)
        #expect(model.step == .result)
        #expect(harness.runner.invocations.contains { $0.arguments.starts(with: ["variable", "set", "ZONE"]) })
        #expect(model.resultSections.flatMap(\.rows).map(\.title) == ["+ ZONE · Example-Org"])
    }

    /// B8c: the Key Vaults of their own count on the Sync badge and get a group of their own in
    /// the summary, after the repositories.
    @Test func keyVaultsOfTheirOwnJoinTheBadgeAndTheSummary() async throws {
        let fixture = try await Fixture(review: .success(SyncFixtures.review([])))
        let harness = fixture.harness
        try harness.installFakeGH()
        try harness.installFakeAZ()
        harness.transport.stubKeyVault("kv-example-shared", secrets: [:])
        let vault = try harness.data.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-shared", tenantID: nil),
            stage: nil
        )
        try harness.data.destinations.addItem(destinationID: vault, kind: .secret, name: "DATABASE_URL", value: SecretBytes(utf8: "FXV_FIXTURE_SECRET"))
        #expect(await TestFixtures.eventually { harness.app.pendingChangeCount == 1 })

        let model = fixture.viewModel
        await model.load()
        #expect(model.step == .summary)
        let group = try #require(model.repositories.first { $0.id == .keyVaults })
        #expect(group.fullName == MainCopy.azureSection)
        #expect(group.scopes.first?.details == ["+ DATABASE_URL as DATABASE-URL"])
        #expect(group.cards.map(\.place.name) == ["kv-example-shared"])
        #expect(group.cards.first?.place.kind == "Key Vault")
        #expect(group.cards.first?.lines.map(\.detail) == ["secret · as DATABASE-URL"])
        #expect(model.executableCount == 1)
    }

    /// Board Sync-Review: one card per place, the blocked change in its place's card, and the
    /// footer counting it while the button counts what will run.
    @Test func summaryShowsNamesCountsAndTheWriteLimit() async throws {
        let review = SyncFixtures.review([SyncFixtures.preflight(
            executable: [
                SyncFixtures.set(.secret, "API_TOKEN"),
                SyncFixtures.set(.variable, "BASE_URL", isNew: false, reason: .modified),
                SyncFixtures.set(.secret, "DB_URL", environment: "production"),
            ],
            blocked: [SyncBlockedChangeModel(
                change: SyncFixtures.set(.secret, "DOCKER_PASSWORD", environment: "production"),
                reason: .change(.valueMissing)
            )]
        )])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()

        #expect(model.step == .summary)
        let repository = try #require(model.repositories.first)
        #expect(repository.fullName == SyncFixtures.fullName)
        #expect(repository.scopes.map(\.sentence) == ["1 added, 1 modified in Repository", "1 added in production"])
        #expect(repository.scopes.first?.details == ["+ API_TOKEN (secret)", "~ BASE_URL (variable)"])
        let cards = repository.cards
        #expect(cards.map(\.place.name) == [TestFixtures.repoName, "\(TestFixtures.repoName) › production"])
        #expect(cards.map(\.place.kind) == ["repository", "environment"])
        #expect(cards[0].lines.map(\.symbol) == [.added, .modified])
        #expect(cards[0].lines.map(\.name) == ["API_TOKEN", "BASE_URL"])
        #expect(cards[0].lines.map(\.detail) == ["secret", "variable"])
        #expect(cards[0].blocked.isEmpty)
        #expect(cards[1].blocked.map(\.title) == ["Add secret DOCKER_PASSWORD in production"])
        #expect(cards[1].blocked.map(\.name) == ["DOCKER_PASSWORD"])
        #expect(model.writeBudgetLine == "FX Vault write limit this hour: \(SyncFixtures.usedWrites) of \(Limits.writesPerHour)")
        #expect(model.executableCount == 3)
        #expect(model.summaryCountsLine == "4 changes in 2 places · 1 blocked")

        let primary = try #require(model.buttons.last)
        #expect(primary.action == .sync)
        #expect(primary.title == "Sync 3 Changes")
        #expect(primary.isDefault)
        #expect(primary.isEnabled)
        #expect(model.buttons.first?.isCancel == true)
        #expect(fixture.service.preflightCalls == [nil])
    }

    /// §7.1: an environment rename counts once, as on the toolbar's Sync button, however many
    /// items it copies; the footer builds on the same number.
    @Test func anEnvironmentRenameCountsOnceOnTheButtonAndInTheFooter() async throws {
        let rename = ConfigChangeModel(repositoryID: SyncFixtures.repository.id, operation: .renameEnvironment(EnvironmentRenameChangeModel(
            environmentID: SyncFixtures.environmentID, fromName: "staging", toName: "stage", policy: .all, fromGitHubID: 7
        )))
        let copies = ["A", "B", "C", "D", "E"].map { suffix in
            SyncFixtures.set(.secret, "KEY_\(suffix)", environment: "stage", reason: .copiedForEnvironmentRename)
        }
        let fixture = try await Fixture(review: .success(SyncFixtures.review([SyncFixtures.preflight(executable: [rename] + copies)])))
        let model = fixture.viewModel
        await model.load()

        #expect(model.step == .summary)
        #expect(model.summaryCountsLine == "1 change in 1 place")
        #expect(model.buttons.last?.title == "Sync 1 Change")
    }

    /// A rename reads `~ NEW_NAME` with where it came from; the deployment branches line has
    /// no symbol or name, so it reads muted.
    @Test func renameAndPolicyLinesKeepTheirParts() throws {
        let policy = ConfigChangeModel(repositoryID: SyncFixtures.repository.id, operation: .upsertEnvironment(EnvironmentUpsertChangeModel(
            environmentID: SyncFixtures.environmentID, name: "production", policy: .protectedBranches, syncedPolicy: .all, isNew: false
        )))
        let repository = SyncPresentationBuilder.repository(SyncFixtures.preflight(executable: [
            policy,
            SyncFixtures.set(.variable, "NEW_NAME", isNew: false, reason: .renamed(from: "OLD_NAME")),
        ]))
        let cards = repository.cards
        let rename = try #require(cards.first { $0.place.kind == "repository" }?.lines.first)
        #expect(rename.symbol == .modified)
        #expect(rename.name == "NEW_NAME")
        #expect(rename.detail == "variable · renamed from OLD_NAME")
        #expect(rename.text == "OLD_NAME → NEW_NAME (variable)")
        let production = try #require(cards.first { $0.place.kind == "environment" })
        #expect(production.sentence == nil)
        #expect(production.lines.map(\.symbol) == [nil])
        #expect(production.lines.map(\.name) == [nil])
        #expect(production.lines.map(\.detail) == ["Deployment branches: protected only"])
    }

    @Test func preflightIsLimitedToTheContextRepositories() async throws {
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [SyncFixtures.set(.secret, "API_TOKEN")])])
        let fixture = try await Fixture(review: .success(review), repositoryIDs: [SyncFixtures.repository.id])
        await fixture.viewModel.load()
        #expect(fixture.service.preflightCalls == [[SyncFixtures.repository.id]])
    }

    @Test func blockedChangesCarryReasonsAndFixes() async throws {
        let missing = SyncFixtures.set(.secret, "DB_PASSWORD", environment: "production")
        let admin = SyncFixtures.set(.secret, "ADMIN_ONLY")
        let remote = SyncFixtures.set(.secret, "ROTATED", isNew: false, reason: .modified)
        let saml = SyncFixtures.set(.variable, "SAML_VAR")
        let plan = SyncFixtures.set(.variable, "PLAN_VAR", environment: "production")
        let dependent = SyncFixtures.set(.variable, "WAITS")
        let samlURL = try #require(URL(string: "https://github.com/orgs/Example-Org/sso"))
        let review = SyncFixtures.review([SyncFixtures.preflight(
            executable: [SyncFixtures.set(.variable, "OK_VAR")],
            blocked: [
                SyncBlockedChangeModel(change: missing, reason: .change(.valueMissing)),
                SyncBlockedChangeModel(change: admin, reason: .readOnly(.adminRequired)),
                SyncBlockedChangeModel(change: remote, reason: .change(.remoteChanged)),
                SyncBlockedChangeModel(change: saml, reason: .listingFailed(.samlRequired(samlURL))),
                SyncBlockedChangeModel(change: plan, reason: .listingFailed(.planGated)),
                SyncBlockedChangeModel(change: dependent, reason: .dependsOn(changeID: admin.id)),
            ]
        )])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()
        let repository = try #require(model.repositories.first)

        #expect(repository.blocked.map(\.title) == [
            "Add secret DB_PASSWORD in production",
            "Add secret ADMIN_ONLY in Repository",
            "Add variable SAML_VAR in Repository",
            "Add variable PLAN_VAR in production",
        ])
        #expect(repository.blocked[0].reason == "Value missing locally.")
        #expect(repository.dependentCount == 1)
        #expect(repository.remoteChanged.map(\.title) == ["Update secret ROTATED in Repository"])
        // Production has nothing that runs: its blocked changes still get a card of their own.
        let cards = repository.cards
        #expect(cards.map(\.place.kind) == ["repository", "environment"])
        #expect(cards[0].blocked.count == 2)
        #expect(cards[0].dependentCount == 1)
        #expect(cards[0].remoteChanged.count == 1)
        #expect(cards[1].lines.isEmpty)
        #expect(cards[1].blocked.map(\.title) == ["Add secret DB_PASSWORD in production", "Add variable PLAN_VAR in production"])
        #expect(model.summaryCountsLine == "7 changes in 2 places · 6 blocked")

        let fill = ItemEditorContext(
            repositoryID: SyncFixtures.repository.id,
            scope: .environment(SyncFixtures.environmentID),
            mode: .fill(try #require(missing.operation.itemID))
        )
        #expect(repository.blocked[0].fix == .fillValue(fill))
        #expect(repository.remoteChanged[0].fix == .reviewDrift(SyncFixtures.repository.id))
        #expect(repository.blocked[2].fix == .authorizeSAML(samlURL))
        #expect(repository.blocked[3].fix == ExternalLinks.environmentPlans.map(SyncFixActionModel.learnMore))

        // Fixes: editor and drift review through the router, the admin request as plain text,
        // links through the opener.
        model.perform(try #require(repository.blocked[0].fix))
        model.perform(try #require(repository.remoteChanged[0].fix))
        #expect(fixture.recorder.presented == [
            .itemEditor(fill),
            .driftReview(DriftReviewContext(repositoryID: SyncFixtures.repository.id)),
        ])
        model.perform(try #require(repository.blocked[1].fix))
        #expect(fixture.harness.pasteboardString?.contains(SyncFixtures.fullName) == true)
        #expect(!fixture.harness.container.clipboard.ownsContents)
        #expect(model.notice == SyncCopy.adminRequestCopied)
        model.perform(try #require(repository.blocked[2].fix))
        #expect(fixture.urls.opened == [samlURL])
    }

    @Test func renameBlockedOnMissingValuesOffersEnterValues() throws {
        let missing = ConfigItemSnapshotModel(
            scope: .environment(SyncFixtures.environmentID),
            kind: .secret,
            name: "DB_PASSWORD",
            valueFingerprint: nil,
            syncedName: "DB_PASSWORD"
        )
        let rename = ConfigChangeModel(repositoryID: SyncFixtures.repository.id, operation: .renameEnvironment(
            EnvironmentRenameChangeModel(
                environmentID: SyncFixtures.environmentID,
                fromName: "staging",
                toName: "stage",
                policy: .all,
                fromGitHubID: 7
            )
        ))
        let preflight = RepoPreflightModel(
            snapshot: RepoSnapshotModel(repository: SyncFixtures.repository, environments: [], items: [missing]),
            changeSet: ChangeSetModel(repository: SyncFixtures.repository, changes: []),
            executable: [],
            blocked: [SyncBlockedChangeModel(change: rename, reason: .change(.renameNeedsValues(["DB_PASSWORD"])))]
        )
        let issue = try #require(SyncPresentationBuilder.repository(preflight).blocked.first)
        #expect(issue.title == "Recreate environment staging as stage")
        #expect(issue.reason.contains("DB_PASSWORD"))
        #expect(issue.fix == .fillValue(ItemEditorContext(
            repositoryID: SyncFixtures.repository.id,
            scope: .environment(SyncFixtures.environmentID),
            mode: .fill(missing.id)
        )))
    }

    @Test func nothingExecutableDisablesSync() async throws {
        let blocked = SyncFixtures.set(.secret, "DB_PASSWORD")
        let review = SyncFixtures.review([SyncFixtures.preflight(
            executable: [],
            blocked: [SyncBlockedChangeModel(change: blocked, reason: .change(.valueMissing))]
        )])
        let fixture = try await Fixture(review: .success(review))
        await fixture.viewModel.load()
        #expect(fixture.viewModel.executableCount == 0)
        #expect(fixture.viewModel.buttons.last?.isEnabled == false)
        await fixture.viewModel.startSync(includeDeletions: false)
        #expect(fixture.service.startedRuns.isEmpty)
    }

    @Test func credentialLookingVariablesNeedConfirmation() async throws {
        let variable = SyncFixtures.set(.variable, "API_TOKEN")
        let itemID = try #require(variable.operation.itemID)
        let warning = SyncCredentialWarningModel(
            changeID: variable.id,
            repositoryID: SyncFixtures.repository.id,
            itemID: itemID,
            name: "API_TOKEN",
            environmentName: nil,
            reasons: [.keyContains("TOKEN")]
        )
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [variable])], credentialWarnings: [warning])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()

        let row = try #require(model.credentialRows.first)
        #expect(row.title == "API_TOKEN in Repository")
        #expect(row.reasons == "the name contains TOKEN")
        #expect(!model.canProceed)
        #expect(model.buttons.last?.isEnabled == false)
        await model.startSync(includeDeletions: false)
        #expect(fixture.service.startedRuns.isEmpty)

        model.credentialsConfirmed = true
        #expect(model.canProceed)
        #expect(model.buttons.last?.isEnabled == true)

        model.perform(row.fix)
        #expect(fixture.recorder.presented == [.itemEditor(ItemEditorContext(
            repositoryID: SyncFixtures.repository.id,
            scope: .repository,
            mode: .move(itemID)
        ))])
    }

    @Test func preflightFailureOffersRetry() async throws {
        let fixture = try await Fixture(review: .failure(.alreadyRunning))
        let model = fixture.viewModel
        await model.load()
        guard case .failed(let error) = model.step else {
            Issue.record("Expected the failed step")
            return
        }
        #expect(error.message == "A sync is already running.")
        #expect(model.buttons.map(\.action) == [.close, .retry])
        #expect(model.buttons.last?.isDefault == true)
    }

    @Test func syncWithoutGitHubDoesNotRunPreflight() async throws {
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [SyncFixtures.set(.secret, "API_TOKEN")])])
        let fixture = try await Fixture(review: .success(review), isGitHubReady: false)
        await fixture.viewModel.load()
        guard case .failed = fixture.viewModel.step else {
            Issue.record("Expected the failed step")
            return
        }
        #expect(fixture.service.preflightCalls.isEmpty)
    }

    // MARK: - Deletions (§7.5)

    @Test func deletionsNeedAcknowledgementAndNoButtonIsDefault() async throws {
        let deleteEnvironment = SyncFixtures.deleteEnvironment("qa")
        let deleteItem = SyncFixtures.deleteItem(.secret, "OLD_TOKEN")
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [
            SyncFixtures.set(.variable, "BASE_URL"),
            deleteItem,
            deleteEnvironment,
        ])])
        let fixture = try await Fixture(review: .success(review))
        fixture.service.setPreviews([RepoDeletionPreviewModel(
            repositoryID: SyncFixtures.repository.id,
            fullName: SyncFixtures.fullName,
            itemDeletions: [deleteItem],
            environments: [EnvironmentDeletionPreviewModel(
                change: deleteEnvironment,
                environmentID: SyncFixtures.environmentID,
                name: "qa",
                contents: .loaded(EnvironmentContentsModel(
                    policy: .custom,
                    patterns: ["release/*"],
                    foreignRulesJSON: "[{\"type\":\"wait_timer\"}]",
                    items: [
                        DeletionPreviewItemModel(name: "QA_URL", kind: .variable, isInVault: true, isOnGitHub: true),
                        DeletionPreviewItemModel(name: "TEAMMATE_KEY", kind: .secret, isInVault: false, isOnGitHub: true),
                    ]
                ))
            )]
        )])
        let model = fixture.viewModel
        await model.load()

        let primary = try #require(model.buttons.last)
        #expect(primary.action == .reviewDeletions)
        #expect(primary.title == "Review 2 Deletions…")

        await model.reviewDeletions()
        #expect(model.step == .deletions)
        let environment = try #require(model.deletionRows.first?.environments.first)
        guard case .loaded(let items, let patterns, let foreignRules) = environment.contents else {
            Issue.record("Expected loaded contents")
            return
        }
        #expect(items.map(\.title) == ["QA_URL (variable)", "TEAMMATE_KEY (secret)"])
        #expect(items.map(\.willBeLost) == [false, true])
        #expect(patterns == "release/*")
        #expect(foreignRules == ["wait timer"])
        #expect(environment.lostCount == 1)
        #expect(model.deletionRows.first?.items.map(\.title) == ["Delete secret OLD_TOKEN in Repository"])

        // Neither button is the default (Return does nothing); deleting needs the checkbox.
        #expect(model.buttons.allSatisfy { !$0.isDefault })
        let confirm = try #require(model.buttons.first { $0.action == .confirmDeletions })
        #expect(confirm.title == "Delete 2")
        #expect(model.deletionTitle == "Delete 2 items?")
        #expect(model.deletionRows.first?.items.map(\.name) == ["OLD_TOKEN"])
        #expect(confirm.isDestructive)
        #expect(!confirm.isEnabled)
        await model.startSync(includeDeletions: true)
        #expect(fixture.service.startedRuns.isEmpty)

        model.deletionsAcknowledged = true
        #expect(model.buttons.first { $0.action == .confirmDeletions }?.isEnabled == true)
        #expect(model.buttons.allSatisfy { !$0.isDefault })

        // Back resets the acknowledgement.
        model.backToSummary()
        #expect(model.step == .summary)
        #expect(!model.deletionsAcknowledged)
    }

    @Test func unknownContentsNeedTheExtraAcknowledgement() async throws {
        let deleteEnvironment = SyncFixtures.deleteEnvironment("qa")
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [deleteEnvironment])])
        let fixture = try await Fixture(review: .success(review))
        fixture.service.setPreviews([RepoDeletionPreviewModel(
            repositoryID: SyncFixtures.repository.id,
            fullName: SyncFixtures.fullName,
            itemDeletions: [],
            environments: [EnvironmentDeletionPreviewModel(
                change: deleteEnvironment,
                environmentID: SyncFixtures.environmentID,
                name: "qa",
                contents: .unknown(.network)
            )]
        )])
        let model = fixture.viewModel
        await model.load()
        await model.reviewDeletions()

        #expect(model.hasUnknownContents)
        guard case .unknown(let reason) = model.deletionRows.first?.environments.first?.contents else {
            Issue.record("Expected unknown contents")
            return
        }
        #expect(reason == GHError.network.localizedMessage)
        // Only deletions: "Sync Without Deleting" has nothing to run.
        #expect(model.buttons.first { $0.action == .syncWithoutDeleting }?.isEnabled == false)

        model.deletionsAcknowledged = true
        #expect(!model.canConfirmDeletions)
        model.unknownContentsAcknowledged = true
        #expect(model.canConfirmDeletions)

        let run = await fixture.startRun(includeDeletions: true)
        #expect(fixture.service.startedRuns == [FakeSyncService.StartedRun(includeDeletions: true, cloneFolder: nil)])
        fixture.service.run.finish(SyncFixtures.outcome([
            SyncChangeResultModel(change: deleteEnvironment, outcome: .succeeded(.notApplicable)),
        ]))
        await run.value
        #expect(model.step == .result)
    }

    /// Board Sync-Done: a run where nothing failed ends on the short finish, with the places and
    /// what stays pending; a failure keeps the full result.
    @Test func aRunWithoutFailuresEndsOnTheShortFinish() async throws {
        let token = SyncFixtures.set(.secret, "API_TOKEN")
        let url = SyncFixtures.set(.variable, "BASE_URL")
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [url, token])])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()
        let run = await fixture.startRun()
        fixture.service.run.finish(SyncFixtures.outcome([
            SyncChangeResultModel(change: token, outcome: .succeeded(.verified)),
            SyncChangeResultModel(change: url, outcome: .blocked(.change(.valueMissing))),
        ]))
        await run.value

        let done = try #require(model.done)
        #expect(done.syncedCount == 1)
        #expect(done.places == [TestFixtures.repoName])
        #expect(done.pending.map(\.reason) == [SyncCopy.blockReason(.change(.valueMissing))])
        #expect(SyncCopy.doneTitle(count: done.syncedCount) == "Synced 1 change")

        let failing = try await Fixture(review: .success(review))
        await failing.viewModel.load()
        let failedRun = await failing.startRun()
        failing.service.run.finish(SyncFixtures.outcome([
            SyncChangeResultModel(change: token, outcome: .succeeded(.verified)),
            SyncChangeResultModel(change: url, outcome: .failed(.valueMissing)),
        ]))
        await failedRun.value
        #expect(failing.viewModel.step == .result)
        #expect(failing.viewModel.done == nil)
    }

    @Test func syncWithoutDeletingLeavesThemOut() async throws {
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [
            SyncFixtures.set(.variable, "BASE_URL"),
            SyncFixtures.deleteItem(.secret, "OLD_TOKEN"),
        ])])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()
        await model.reviewDeletions()
        #expect(model.buttons.first { $0.action == .syncWithoutDeleting }?.isEnabled == true)

        let run = await fixture.startRun(includeDeletions: false)
        #expect(fixture.service.startedRuns.map(\.includeDeletions) == [false])
        #expect(model.progress.total == 1)
        fixture.service.run.finish(SyncFixtures.outcome([]))
        await run.value
    }

    // MARK: - Run (§7.3, §7.4, D16)

    @Test func runHoldsTheSyncActivityAndReportsProgress() async throws {
        let token = SyncFixtures.set(.secret, "API_TOKEN")
        let url = SyncFixtures.set(.variable, "BASE_URL")
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [url, token])])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        let app = fixture.harness.app
        let autoLock = fixture.harness.container.autoLock
        await model.load()
        #expect(!app.isSyncing)

        let run = await fixture.startRun()
        #expect(app.isSyncing)
        #expect(autoLock.isSyncActive)
        #expect(model.blocksDismissal)

        let fake = fixture.service.run
        // Board Sync-Progress: the summary's lines go from a ring to a spinner to a check.
        let lines = model.progressCards.flatMap(\.lines)
        let tokenLine = try #require(lines.first { $0.name == "API_TOKEN" })
        let urlLine = try #require(lines.first { $0.name == "BASE_URL" })
        #expect(model.lineState(tokenLine) == .waiting)
        fake.send(.started(total: 2))
        fake.send(.changeStarted(changeID: token.id))
        #expect(await TestFixtures.eventually { model.progress.currentName == "API_TOKEN" })
        #expect(model.lineState(tokenLine) == .writing)
        fake.send(.changeFinished(SyncChangeResultModel(change: token, outcome: .succeeded(.verified)), completed: 1, total: 2))
        fake.send(.verifying(.repository))
        #expect(await TestFixtures.eventually { model.progress.phase == .verifying(scope: "Repository") })
        #expect(model.progress.completed == 1)
        #expect(model.progress.fraction == 0.5)
        #expect(model.lineState(tokenLine) == .done)
        #expect(model.lineState(urlLine) == .waiting)

        // Cancel stops after the call in flight.
        #expect(model.buttons.map(\.action) == [.cancelRun])
        #expect(model.buttons.first?.isDefault == false)
        model.cancelRun()
        #expect(fake.isCancelled)
        #expect(model.progress.isCancelling)
        #expect(model.buttons.first?.isEnabled == false)

        fake.finish(SyncFixtures.outcome(
            [
                SyncChangeResultModel(change: token, outcome: .succeeded(.verified)),
                SyncChangeResultModel(change: url, outcome: .skipped(.runStopped(.cancelled))),
            ],
            stopReason: .cancelled
        ))
        await run.value

        #expect(model.step == .result)
        #expect(!app.isSyncing)
        #expect(!autoLock.isSyncActive)
        #expect(model.resultSections.map(\.kind) == [.skipped, .succeeded])
        #expect(model.stopReason?.reason == SyncCopy.stopReason(.cancelled))
        #expect(model.buttons.map(\.action) == [.done])
        #expect(model.buttons.first?.isDefault == true)
        #expect(fixture.recorder.refreshes == [.drift(SyncFixtures.repository.id)])
    }

    @Test func resultSectionsCarryLocalizedReasonsAndFixes() async throws {
        let admin = SyncFixtures.set(.secret, "ADMIN_ONLY", environment: "production")
        let plan = SyncFixtures.set(.variable, "PLAN_VAR", environment: "production")
        let revoked = SyncFixtures.set(.variable, "REVOKED")
        let remote = SyncFixtures.set(.secret, "ROTATED", isNew: false, reason: .modified)
        let dependent = SyncFixtures.set(.variable, "AFTER")
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [admin, plan, revoked, remote, dependent])])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()
        let run = await fixture.startRun()
        fixture.service.run.finish(SyncFixtures.outcome(
            [
                SyncChangeResultModel(change: admin, outcome: .failed(.github(.adminRequired))),
                SyncChangeResultModel(change: plan, outcome: .failed(.github(.planGated))),
                SyncChangeResultModel(change: revoked, outcome: .failed(.github(.tokenRevoked))),
                SyncChangeResultModel(change: remote, outcome: .blocked(.change(.remoteChanged))),
                SyncChangeResultModel(change: dependent, outcome: .skipped(.dependencyFailed(changeID: admin.id))),
            ],
            stopReason: .tokenRevoked,
            warnings: [.valueNormalized(itemID: ConfigItemID(), name: "PEM_KEY")]
        ))
        await run.value

        #expect(model.resultSections.map(\.kind) == [.failed, .blocked, .skipped])
        let failed = try #require(model.resultSections.first { $0.kind == .failed }?.rows)
        #expect(failed[0].reason == GHError.adminRequired.localizedMessage)
        guard case .askAdmin(let request)? = failed[0].fix else {
            Issue.record("Expected Ask an Admin")
            return
        }
        #expect(request.contains(TestFixtures.account) && request.contains(SyncFixtures.fullName))
        #expect(failed[1].fix == ExternalLinks.environmentPlans.map(SyncFixActionModel.learnMore))
        #expect(failed[2].fix == .runInTerminal(command: GHSetupViewModel.loginCommand))
        let blocked = try #require(model.resultSections.first { $0.kind == .blocked }?.rows)
        #expect(blocked[0].fix == .reviewDrift(SyncFixtures.repository.id))
        let skipped = try #require(model.resultSections.first { $0.kind == .skipped }?.rows)
        #expect(skipped[0].reason == "A change it depends on failed.")
        #expect(model.stopReason?.fix == .runInTerminal(command: GHSetupViewModel.loginCommand))
        #expect(model.warnings == ["Trailing line breaks were removed from PEM_KEY before it was pushed."])
        // Nothing succeeded: no drift refresh is requested.
        #expect(fixture.recorder.refreshes.isEmpty)

        // Re-authenticate copies the Terminal command as plain text.
        model.perform(try #require(model.stopReason?.fix))
        #expect(fixture.harness.pasteboardString == GHSetupViewModel.loginCommand)
        #expect(model.notice == SyncCopy.commandCopied)
    }

    @Test func missingScopesOfferTheScopeFixCommand() {
        let change = SyncFixtures.set(.secret, "API_TOKEN")
        let fix = SyncPresentationBuilder.fix(for: .missingScopes(["repo"]), change: change, repository: SyncFixtures.repository)
        guard case .runInTerminal(let command)? = fix else {
            Issue.record("Expected a Terminal command")
            return
        }
        #expect(command.contains("gh auth refresh"))
        #expect(command.contains(TestFixtures.account))
    }

    @Test func lockCancelsTheRunAndEndsTheActivity() async throws {
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [SyncFixtures.set(.secret, "API_TOKEN")])])
        let fixture = try await Fixture(review: .success(review))
        await fixture.viewModel.load()
        let run = await fixture.startRun()
        #expect(fixture.harness.app.isSyncing)

        fixture.harness.app.lock(trigger: .manual)
        #expect(fixture.service.run.isCancelled)
        #expect(!fixture.harness.app.isSyncing)
        #expect(!fixture.harness.container.autoLock.isSyncActive)

        fixture.service.run.finish(SyncFixtures.outcome([], stopReason: .locked))
        await run.value
    }

    // MARK: - Clones (§7.3 step 8)

    @Test func createdRepositoryRefreshesTheCatalogAndClonesWithProgress() async throws {
        let create = SyncFixtures.createRepository(cloneAfter: true)
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [create])])
        let fixture = try await Fixture(review: .success(review))
        let model = fixture.viewModel
        await model.load()
        #expect(model.summaryWarnings == [SyncCopy.cloneFolderMissing])
        #expect(model.repositories.first?.newRepository == "New repository · Private · README")

        let run = await fixture.startRun()
        fixture.service.run.finish(SyncFixtures.outcome(
            [SyncChangeResultModel(change: create, outcome: .succeeded(.verified))],
            warnings: [.cloneRequested(repositoryID: SyncFixtures.repository.id)],
            clones: [RepoCloneOutcomeModel(repositoryID: SyncFixtures.repository.id, state: .notAttempted)]
        ))
        await run.value

        #expect(fixture.recorder.refreshes == [.catalog, .drift(SyncFixtures.repository.id)])
        let row = try #require(model.clones.first)
        #expect(row.state == .notAttempted)
        #expect(row.fullName == SyncFixtures.fullName)
        #expect(model.cloneFix(row) == .clone(SyncFixtures.repository.id))

        // Without a clone folder, Clone asks for one; a cancelled panel clones nothing.
        await model.clone(SyncFixtures.repository.id)
        #expect(fixture.folderRequests.value == 1)
        #expect(fixture.service.clonedRepositories.isEmpty)
        #expect(model.clones.first?.state == .notAttempted)

        // Once a clone folder is set, Clone runs with a busy state and asks nothing.
        let folder = fixture.harness.sandbox.appendingPathComponent("clones", isDirectory: true)
        fixture.harness.preferences.setCloneFolder(folder)
        let cloned = folder.appendingPathComponent(TestFixtures.repoName, isDirectory: true)
        fixture.service.setCloneResult(.success(cloned))
        #expect(model.cloneFix(row) == .clone(SyncFixtures.repository.id))
        await model.clone(SyncFixtures.repository.id)
        #expect(fixture.service.clonedRepositories == [SyncFixtures.repository.id])
        #expect(model.clones.first?.state == .cloned(path: cloned.path))
        #expect(fixture.folderRequests.value == 1)
    }

    @Test func failedCloneShowsTheReason() async throws {
        let create = SyncFixtures.createRepository(cloneAfter: true)
        let review = SyncFixtures.review([SyncFixtures.preflight(executable: [create])])
        let fixture = try await Fixture(review: .success(review))
        let folder = fixture.harness.sandbox.appendingPathComponent("clones", isDirectory: true)
        fixture.harness.preferences.setCloneFolder(folder)
        let model = fixture.viewModel
        await model.load()
        #expect(model.summaryWarnings.isEmpty)

        let run = await fixture.startRun()
        #expect(fixture.service.startedRuns.first?.cloneFolder == folder)
        fixture.service.run.send(.started(total: 1))
        fixture.service.run.finish(SyncFixtures.outcome(
            [SyncChangeResultModel(change: create, outcome: .succeeded(.verified))],
            warnings: [.cloneRequested(repositoryID: SyncFixtures.repository.id)],
            clones: [RepoCloneOutcomeModel(repositoryID: SyncFixtures.repository.id, state: .failed(.sshAliasNotMapped))]
        ))
        await run.value
        let row = try #require(model.clones.first)
        #expect(row.state == .failed(RepoCreationError.sshAliasNotMapped.presentation.message))
        #expect(model.cloneFix(row) == .clone(SyncFixtures.repository.id))
    }

    // MARK: - Security: names only

    @Test func liveSummaryNeverShowsValues() async throws {
        let secretValue = "FXV_FIXTURE_SYNC_SECRET_9f2c"
        let variableValue = "https://fixture.example/value-7d41"
        let harness = try await TestHarness(vault: .unlocked)
        let repositoryID = try await harness.stageRepository(items: [
            TestFixtures.item(.secret, "API_TOKEN", secretValue),
            TestFixtures.item(.variable, "BASE_URL", variableValue),
        ])
        let recorder = ActionRecorder()
        // The live service over the real SyncRepository; gh is not detected, so preflight
        // blocks every change and nothing reaches a process.
        let model = SyncViewModel(
            context: SyncContext(repositoryIDs: [repositoryID]),
            dependencies: harness.dependencies(recorder: recorder, isGitHubReady: true)
        )
        await model.load()

        #expect(model.step == .summary)
        let repository = try #require(model.repositories.first)
        #expect(repository.id == .repository(repositoryID))
        #expect(!repository.blocked.isEmpty)
        #expect(model.executableCount == 0)

        // Built with explicit types: the single-expression form timed out the type checker on
        // Xcode 26 (the blocking CI gate).
        var texts: [String] = [model.summaryText]
        for repository in model.repositories {
            texts.append(repository.fullName)
            for scope in repository.scopes {
                texts.append(scope.sentence)
                texts += scope.details
            }
            for item in repository.blocked + repository.remoteChanged {
                texts += [item.title, item.reason]
            }
        }
        #expect(texts.contains { $0.contains("API_TOKEN") })
        #expect(!texts.contains { $0.contains(secretValue) || $0.contains(variableValue) })

        model.copySummary()
        let copied = try #require(harness.pasteboardString)
        #expect(!copied.contains(secretValue) && !copied.contains(variableValue))
        #expect(!harness.container.clipboard.ownsContents)
        #expect(!harness.runner.invocations.contains { invocation in
            invocation.arguments.contains { $0.contains(secretValue) || $0.contains(variableValue) }
        })
    }
}
