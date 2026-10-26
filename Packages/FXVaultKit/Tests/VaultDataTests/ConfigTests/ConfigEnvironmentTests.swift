import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Environment create, delete, rename, policy and duplicate (§7.1, §7.6, D20; M3, M5).
@Suite("ConfigRepository environments")
struct ConfigEnvironmentTests {
    @Test func namesAreUniqueByFoldKey() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        try harness.config.createEnvironment(in: repo.id, name: "Producci\u{00F3}n")

        for clash in ["PRODUCCI\u{00D3}N", "produccio\u{0301}n", "Producci\u{00F3}n"] {
            #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: clash) } == .validation(.duplicateName))
        }
        let stored = try harness.store.fetchEnvironments(repositoryID: repo.id)
        #expect(stored.count == 1)
        #expect(stored.first?.name == "Producci\u{00F3}n")
    }

    /// The ⌘K palette reads every repository's environments at once (1.0), without tombstones.
    @Test func environmentsOfEveryRepositoryInOneRead() async throws {
        let harness = try await ConfigHarness.make()
        let first = try harness.seedRepository(name: "repo-a")
        let second = try harness.seedRepository(name: "repo-b")
        try harness.config.createEnvironment(in: first.id, name: "staging")
        let preview = try harness.config.createEnvironment(in: first.id, name: "preview")
        // Created after staging: the scopes column's order (by creation), not by name.
        try harness.config.createEnvironment(in: first.id, name: "qa")
        try harness.config.createEnvironment(in: second.id, name: "production")
        try harness.markSynced(first)
        try harness.config.deleteEnvironment(preview)
        #expect(try harness.store.fetchEnvironments(repositoryID: first.id).contains { $0.id == preview && $0.isDeleted })

        let byRepository = try harness.config.environmentsByRepository()
        #expect(byRepository[first.id]?.map(\.name) == ["staging", "qa"])
        #expect(byRepository[second.id]?.map(\.name) == ["production"])
    }

    @Test func namesAreValidated() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let tooLong = String(repeating: "e", count: Limits.maxEnvironmentNameLength + 1)
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: tooLong) } == .validation(.invalidName(.tooLong(maxLength: Limits.maxEnvironmentNameLength))))
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: "..") } == .validation(.invalidPathSegment(.dotSegment)))
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: " staging") } == .validation(.invalidName(.leadingOrTrailingWhitespace)))
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: "a\u{202E}b") } == .validation(.invalidName(.bidiCharacter)))
        let longest = String(repeating: "e", count: Limits.maxEnvironmentNameLength)
        try harness.config.createEnvironment(in: repo.id, name: longest)
    }

    @Test func reservedNamesOfPendingRenamesAndDeletions() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let qa = try harness.config.createEnvironment(in: repo.id, name: "qa")
        try harness.markSynced(repo)

        #expect(try harness.config.renameEnvironment(staging, to: "stage") == .recreateOnGitHub)
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: "Staging") } == .validation(.nameReservedByPendingChange))
        #expect(configError { _ = try harness.config.renameEnvironment(qa, to: "STAGING") } == .validation(.nameReservedByPendingChange))

        // Renaming back to the synced name is a local revert.
        #expect(try harness.config.renameEnvironment(staging, to: "staging") == .local)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func caseOnlyRenameProducesNoChange() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.config.createEnvironment(in: repo.id, name: "production")
        try harness.markSynced(repo)

        #expect(try harness.config.renameEnvironment(id, to: "Production") == .caseOnly)
        let changeSet = try harness.changeSet(repo)
        #expect(changeSet.isEmpty)
        #expect(changeSet.notes.count == 1)
        #expect(try harness.config.renameEnvironment(id, to: "Production") == .unchanged)
    }

    @Test func unsyncedEnvironmentRenameAndDeleteAreLocal() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.config.createEnvironment(in: repo.id, name: "preview")
        try harness.add(repo, "TOKEN", value: ConfigFixture.valueA, scope: .environment(id))

        #expect(try harness.config.renameEnvironment(id, to: "preview-2") == .local)
        #expect(try harness.changeSet(repo).pendingCount == 2)
        try harness.config.deleteEnvironment(id)
        #expect(try harness.store.fetchEnvironment(id: id) == nil)
        #expect(try harness.states(repo).isEmpty)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func deleteThenRecreateRevivesTheTombstone() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.config.createEnvironment(in: repo.id, name: "qa")
        let item = try harness.add(repo, "TOKEN", value: ConfigFixture.valueA, scope: .environment(id))
        try harness.markSynced(repo)

        try harness.config.deleteEnvironment(id)
        let deleted = try #require(try harness.store.fetchEnvironment(id: id))
        #expect(deleted.isDeleted)
        #expect(try harness.changeSet(repo).deletionCount == 1)

        let revived = try harness.config.createEnvironment(in: repo.id, name: "QA")
        #expect(revived == id)
        #expect(try harness.reveal(item) == ConfigFixture.valueA)
        // Only the case differs from GitHub now: no change to push.
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func branchPolicyEditsKeepSyncedPatterns() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let release = BranchPatternDraftModel(pattern: "release/*", type: .branch)
        let tags = BranchPatternDraftModel(pattern: "v*", type: .tag)
        let id = try harness.config.createEnvironment(in: repo.id, name: "production", policy: .custom([release, tags, release]))
        #expect(try harness.store.fetchPatterns(environmentID: id).count == 2)
        try harness.markSynced(repo)

        let main = BranchPatternDraftModel(pattern: "main", type: .branch)
        try harness.config.updateBranchPolicy(id, to: .custom([release, main]))
        let patterns = try harness.store.fetchPatterns(environmentID: id)
        #expect(patterns.count == 3)
        #expect(patterns.first { $0.pattern == "v*" }?.isDeleted == true)
        #expect(patterns.first { $0.pattern == "main" }?.isSynced == false)
        #expect(try harness.changeSet(repo).pendingCount == 1)

        // Putting the pattern back revives the row; the unsynced one is dropped.
        try harness.config.updateBranchPolicy(id, to: .custom([release, tags]))
        let restored = try harness.store.fetchPatterns(environmentID: id)
        #expect(restored.count == 2)
        #expect(restored.allSatisfy { !$0.isDeleted && $0.isSynced })
        #expect(try harness.changeSet(repo).isEmpty)

        try harness.config.updateBranchPolicy(id, to: .protectedBranches)
        #expect(try harness.store.fetchEnvironment(id: id)?.branchPolicy == .protectedBranches)
        try harness.config.revertEnvironment(id)
        #expect(try harness.store.fetchEnvironment(id: id)?.branchPolicy.kind == .custom)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func policyDraftsMirrorStoredPolicies() {
        let environmentID = EnvironmentID()
        let kept = BranchPatternModel(environmentID: environmentID, pattern: "main", type: .branch, githubPolicyID: 1)
        let gone = BranchPatternModel(environmentID: environmentID, pattern: "old", type: .tag, githubPolicyID: 2, isDeleted: true)
        #expect(BranchPolicyDraftModel(.all) == .all)
        #expect(BranchPolicyDraftModel(.protectedBranches) == .protectedBranches)
        #expect(BranchPolicyDraftModel(.custom([kept, gone])) == .custom([BranchPatternDraftModel(pattern: "main", type: .branch)]))
        #expect(BranchPolicyDraftModel.custom([]).kind == .custom)
        #expect(BranchPolicyDraftModel.protectedBranches.kind == .protected)
    }

    @Test func branchPatternsAreValidated() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let tooMany = (0...Limits.maxBranchPatternsPerEnvironment).map { BranchPatternDraftModel(pattern: "p\($0)", type: .branch) }
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: "a", policy: .custom(tooMany)) } == .tooManyBranchPatterns(limit: Limits.maxBranchPatternsPerEnvironment))
        let empty = [BranchPatternDraftModel(pattern: "", type: .branch)]
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: "b", policy: .custom(empty)) } == .validation(.invalidName(.empty)))
    }

    @Test func duplicateReEncryptsUnderTheNewIdentity() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let release = BranchPatternDraftModel(pattern: "release/*", type: .branch)
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging", policy: .custom([release]))
        let scope = ConfigScope.environment(staging)
        let secret = try harness.add(repo, "API_TOKEN", value: ConfigFixture.valueA, scope: scope)
        let variable = try harness.add(repo, "API_URL", kind: .variable, value: ConfigFixture.valueB, scope: scope)
        try harness.markSynced(repo)
        let missing = ConfigItemRecord(
            repositoryID: repo.id,
            scope: scope,
            kind: .secret,
            name: "IMPORTED",
            valueCiphertext: nil,
            valueFingerprint: nil,
            syncedName: "IMPORTED",
            provenance: .github,
            createdAt: ManualClock.defaultStart,
            updatedAt: ManualClock.defaultStart
        )
        try harness.store.insertItem(missing)

        let production = try harness.config.duplicateEnvironment(staging, as: "production")
        let copies = try harness.store.fetchItemRecords(repositoryID: repo.id, scope: .environment(production))
        #expect(copies.map(\.name) == ["API_TOKEN", "API_URL", "IMPORTED"])
        #expect(copies.allSatisfy { $0.syncedName == nil })
        #expect(Set(copies.map(\.id)).isDisjoint(with: [secret, variable, missing.id]))

        let copiedSecret = try #require(copies.first { $0.name == "API_TOKEN" })
        let copiedVariable = try #require(copies.first { $0.name == "API_URL" })
        let copiedMissing = try #require(copies.first { $0.name == "IMPORTED" })
        #expect(try harness.reveal(copiedSecret.id) == ConfigFixture.valueA)
        #expect(try harness.reveal(copiedVariable.id) == ConfigFixture.valueB)
        #expect(copiedMissing.valueCiphertext == nil)
        #expect(copiedMissing.state.model.syncStatus == .blocked)

        // The copy is sealed under its own identity: the source AAD cannot open it.
        let sourceRecord = try harness.record(secret)
        try harness.session.withKeys { keys in
            let ciphertext = try #require(copiedSecret.valueCiphertext)
            #expect(throws: VaultError.corrupted(.fieldDecryptionFailed)) {
                try keys.open(ciphertext, for: ConfigFieldCipher.valueAAD(of: sourceRecord))
            }
        }

        let copiedEnvironment = try #require(try harness.store.fetchEnvironment(id: production))
        #expect(copiedEnvironment.syncedName == nil)
        #expect(copiedEnvironment.branchPolicy.activePatterns.map(\.pattern) == ["release/*"])
        #expect(copiedEnvironment.branchPolicy.activePatterns.allSatisfy { !$0.isSynced })
        #expect(configError { _ = try harness.config.duplicateEnvironment(staging, as: "Production") } == .validation(.duplicateName))
    }

    @Test func scopeSummariesAndPendingCountsAreLive() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let other = try harness.seedRepository(name: "repo-b")
        let counts = harness.config.observePendingCounts()
        var countIterator = counts.makeAsyncIterator()
        #expect(try await countIterator.next() == .empty.withZeroes(for: [repo.id, other.id]))

        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let first = try #require(try await countIterator.next())
        #expect(first.total == 1)
        try harness.add(other, "TOKEN", value: ConfigFixture.valueA)
        let second = try #require(try await countIterator.next())
        #expect(second.total == 2)
        #expect(second.counts(for: other.id).pending == 1)

        var scopes = harness.config.observeScopes(repositoryID: repo.id).makeAsyncIterator()
        let summaries = try #require(try await scopes.next())
        #expect(summaries.map(\.id) == [ConfigScopeLevel.repository.rawValue, staging.uuidString])
        #expect(summaries[1].hasPendingChanges)
        #expect(summaries[0].hasPendingChanges == false)
        try harness.markSynced(repo)
        let synced = try #require(try await scopes.next())
        #expect(synced.allSatisfy { !$0.hasPendingChanges })
    }

    /// The sidebar's count after a repository (1.0 D6d, board Main2-Repository): live secrets
    /// without a value at the repository level and in its live environments.
    @Test func aRepositoryCountsItsSecretsWithoutAValue() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let preview = try harness.config.createEnvironment(in: repo.id, name: "preview")
        let old = try harness.add(repo, "OLD_KEY", value: ConfigFixture.valueA)
        let imported = [
            try harness.add(repo, "API_KEY", value: ConfigFixture.valueA),
            try harness.add(repo, "STAGING_KEY", value: ConfigFixture.valueB, scope: .environment(staging)),
            try harness.add(repo, "PREVIEW_KEY", value: ConfigFixture.valueC, scope: .environment(preview)),
            old,
        ]
        try harness.add(repo, "MODE", kind: .variable, value: "test")
        try harness.add(repo, "FILLED", value: ConfigFixture.valueB)
        try harness.markSynced(repo)
        // Imported from GitHub: names only.
        for var row in try harness.store.fetchItemRecords(repositoryID: repo.id) where imported.contains(row.id) {
            row.valueCiphertext = nil
            row.valueFingerprint = nil
            try harness.store.updateItem(row)
        }
        #expect(try harness.config.pendingCounts().counts(for: repo.id).valueMissing == 4)

        // A tombstone and a deleted environment's secrets wait for Sync; they are not missing.
        try harness.config.deleteItems([old], repositoryID: repo.id)
        try harness.config.deleteEnvironment(preview)
        #expect(try harness.config.pendingCounts().counts(for: repo.id).valueMissing == 2)
        #expect(try harness.config.pendingCounts().counts(for: RepoID()).valueMissing == 0)
    }
}

private extension PendingCountsModel {
    /// Zero counts for each repository (the first observed value).
    func withZeroes(for ids: [RepoID]) -> PendingCountsModel {
        PendingCountsModel(repositories: Dictionary(uniqueKeysWithValues: ids.map { ($0, RepoPendingCountModel(pending: 0, blocked: 0)) }))
    }
}
