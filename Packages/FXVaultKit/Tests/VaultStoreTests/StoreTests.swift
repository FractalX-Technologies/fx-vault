import Foundation
import GRDB
import Testing
import VaultCore
@testable import VaultStore

@Suite("VaultRecordStore")
struct VaultRecordStoreTests {
    @Test func createFetchUpdateAndWraps() throws {
        let seeded = try SeededDatabase()
        #expect(try seeded.vault.hasVault() == false)
        #expect(try seeded.vault.fetchVault() == nil)
        #expect(throws: StoreError.notFound) { try seeded.vault.updateVault(Sample.vault()) }

        try seeded.vault.createVault(Sample.vault(), keyWraps: [Sample.passwordWrap(), Sample.recoveryWrap()])
        #expect(try seeded.vault.fetchVault() == Sample.vault())
        #expect(try seeded.vault.fetchKeyWraps().map(\.method) == [.password, .recovery])
        #expect(try seeded.vault.fetchKeyWrap(.password) == Sample.passwordWrap())

        var rotated = Sample.vault()
        rotated.dekVersion = 2
        rotated.lastPasswordUnlockAt = Sample.date(60)
        rotated.lastPasswordBootSession = "boot-session"
        rotated.biometryStateHash = Data(repeating: 9, count: 32)
        try seeded.vault.updateVault(rotated)
        #expect(try seeded.vault.fetchVault() == rotated)

        // Upsert replaces the wrap of the same method.
        let replacement = Sample.passwordWrap(dekVersion: 2, byte: 0x0A)
        try seeded.vault.saveKeyWrap(replacement)
        #expect(try seeded.vault.fetchKeyWrap(.password) == replacement)
        #expect(try seeded.vault.fetchKeyWraps().count == 2)

        #expect(try seeded.vault.deleteKeyWrap(.recovery))
        #expect(try seeded.vault.deleteKeyWrap(.recovery) == false)
        #expect(try seeded.vault.fetchKeyWrap(.recovery) == nil)
    }

    @Test func createVaultIsAtomic() throws {
        let seeded = try SeededDatabase()
        var invalid = Sample.recoveryWrap()
        invalid.wrappedDEK = Data()
        #expect(throws: StoreError.constraintViolation(.check)) {
            try seeded.vault.createVault(Sample.vault(), keyWraps: [Sample.passwordWrap(), invalid])
        }
        #expect(try seeded.vault.fetchVault() == nil)
        #expect(try seeded.vault.fetchKeyWraps().isEmpty)
    }

    @Test func eraseAllDataEmptiesEveryTable() throws {
        let seeded = try SeededDatabase()
        try seeded.vault.createVault(Sample.vault(), keyWraps: [Sample.passwordWrap()])
        let environment = Sample.environment(repositoryID: seeded.repo.id, policy: .custom([]))
        try seeded.config.insertEnvironment(environment)
        try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "main", type: .branch))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id))
        try seeded.journal.appendInFlight(Sample.journal(runID: SyncRunID(), repositoryID: seeded.repo.id, startedAt: Sample.start))
        try seeded.shares.recordImport(ImportedSharePackageRecord(
            packageID: SharePackageID(), createdAt: Sample.start, importedAt: Sample.start, senderName: nil
        ))

        try seeded.vault.eraseAllData()
        for table in MigrationTests.expectedTables {
            #expect(try seeded.integer("SELECT count(*) FROM \(table)") == 0, "\(table)")
        }
        #expect(try VaultMigrator.isUpToDate(seeded.database))
    }
}

@Suite("AccountStore")
struct AccountStoreTests {
    @Test func saveFetchAnyCaseAndPresence() throws {
        let seeded = try SeededDatabase()
        #expect(try seeded.accounts.fetch(login: Sample.login.uppercased())?.login == Sample.login)

        var updated = Sample.account(Sample.login.uppercased())
        updated.sshHostAlias = "github-fx"
        updated.sshVerifiedLogin = Sample.login
        updated.sshVerifiedAt = Sample.date(5)
        try seeded.accounts.save(updated)
        let stored = try #require(try seeded.accounts.fetch(login: Sample.login))
        #expect(stored.login == Sample.login)
        #expect(stored.sshHostAlias == "github-fx")
        #expect(stored.isSSHAliasVerified)
        #expect(try seeded.accounts.fetchAll().count == 1)

        try seeded.accounts.save(Sample.account("another-login"))
        try seeded.accounts.updatePresence(presentLogins: ["ANOTHER-LOGIN"], now: Sample.date(100))
        let all = try seeded.accounts.fetchAll()
        #expect(all.map(\.login) == ["another-login", Sample.login])
        #expect(all.map(\.isPresent) == [true, false])
        #expect(all.first?.lastSeenAt == Sample.date(100))
        #expect(all.last?.lastSeenAt == Sample.start)

        #expect(try seeded.accounts.delete(login: "Another-Login"))
        #expect(try seeded.accounts.delete(login: "another-login") == false)
    }
}

@Suite("RepoStore")
struct RepoStoreTests {
    @Test func fullModelRoundTrip() throws {
        let seeded = try SeededDatabase()
        var repo = Sample.repo(name: "fx-created", githubID: nil)
        repo.origin = .created
        repo.ownerType = .organization
        repo.description = "Created by FX Vault"
        repo.visibility = .public
        repo.isArchived = true
        repo.isFork = true
        repo.defaultBranch = "main"
        repo.hasAdmin = false
        repo.hasPush = true
        repo.isEnvPlanGated = true
        repo.isUnavailable = true
        repo.lastRefreshedAt = Sample.date(10)
        repo.createdAtGitHub = Sample.date(20)
        repo.createSpec = RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "mit", cloneAfter: true)
        repo.clonePath = "/Users/test/Developer/fx-created"
        try seeded.repos.insert(repo)

        #expect(try seeded.repos.fetch(id: repo.id) == repo)
        let json = try #require(try seeded.text("SELECT create_spec_json FROM repositories WHERE name = 'fx-created'"))
        #expect(json.contains("\"auto_init\":true"))
        #expect(json.contains("\"gitignore_template\":\"Swift\""))
    }

    @Test func internalVisibilityReadsBackAsPrivate() throws {
        let seeded = try SeededDatabase()
        var repo = Sample.repo(name: "internal-repo", githubID: "R_internal")
        repo.visibility = .internal
        try seeded.repos.insert(repo)
        #expect(try seeded.repos.fetch(id: repo.id)?.visibility == .private)
    }

    @Test func lookupsAndUpdates() throws {
        let seeded = try SeededDatabase()
        #expect(try seeded.repos.fetch(ownerLogin: Sample.login.uppercased(), name: "FX-Test-Repo")?.id == seeded.repo.id)
        #expect(try seeded.repos.fetch(githubID: "R_kgDOTEST0001")?.id == seeded.repo.id)
        #expect(try seeded.repos.fetch(githubID: "R_missing") == nil)
        #expect(try seeded.repos.fetchAll(accountLogin: Sample.login.uppercased()).map(\.id) == [seeded.repo.id])

        var updated = seeded.repo
        updated.isUnavailable = true
        try seeded.repos.update(updated)
        #expect(try seeded.repos.fetch(id: seeded.repo.id)?.isUnavailable == true)
        #expect(throws: StoreError.notFound) { try seeded.repos.update(Sample.repo(name: "ghost")) }

        try seeded.repos.insert(Sample.repo(owner: "a-owner", name: "zeta", githubID: "R_z"))
        try seeded.repos.insert(Sample.repo(owner: "A-owner", name: "Alpha", githubID: "R_a"))
        #expect(try seeded.repos.fetchAll().map(\.name) == ["Alpha", "zeta", "fx-test-repo"])
    }
}

@Suite("ConfigStore")
struct ConfigStoreTests {
    @Test func environmentRoundTripWithCustomPatterns() throws {
        let seeded = try SeededDatabase()
        let environmentID = EnvironmentID()
        let patterns = [
            BranchPatternModel(environmentID: environmentID, pattern: "release/*", type: .branch, githubPolicyID: 7),
            BranchPatternModel(environmentID: environmentID, pattern: "v*", type: .tag, isDeleted: true),
        ]
        var environment = Sample.environment(id: environmentID, repositoryID: seeded.repo.id, name: "Producción", policy: .custom(patterns))
        environment.syncedName = "Producción"
        environment.syncedBranchPolicy = .all
        environment.foreignRulesJSON = #"{"wait_timer":5}"#
        environment.githubEnvID = 42
        environment.remoteUpdatedAt = Sample.date(3)
        environment.sortOrder = 2
        try seeded.config.insertEnvironment(environment)

        #expect(try seeded.config.fetchEnvironment(id: environmentID) == environment)
        #expect(try seeded.config.fetchEnvironments(repositoryID: seeded.repo.id) == [environment])
        #expect(try seeded.text("SELECT name_key FROM environments") == "producción")
        #expect(try seeded.text("SELECT synced_name_key FROM environments") == "producción")

        // Rename: the fold key follows the name.
        environment.name = "QA"
        try seeded.config.updateEnvironment(environment)
        #expect(try seeded.text("SELECT name_key FROM environments") == "qa")
        #expect(try seeded.config.fetchEnvironment(id: environmentID)?.hasPendingRename == true)

        // A policy that left custom hides (but keeps) its pattern rows.
        environment.branchPolicy = .protectedBranches
        try seeded.config.updateEnvironment(environment)
        #expect(try seeded.config.fetchEnvironment(id: environmentID)?.branchPolicy == .protectedBranches)
        #expect(try seeded.config.fetchPatterns(environmentID: environmentID).count == 2)
        #expect(try seeded.config.clearPatternPolicyIDs(environmentID: environmentID) == 1)
        #expect(try seeded.config.fetchPatterns(environmentID: environmentID).allSatisfy { $0.githubPolicyID == nil })

        #expect(throws: StoreError.notFound) {
            try seeded.config.updateEnvironment(Sample.environment(repositoryID: seeded.repo.id))
        }
    }

    @Test func environmentRecordKeepsFoldKeysInStep() {
        var record = EnvironmentRecord(Sample.environment(repositoryID: RepoID(), name: "Staging"))
        #expect(record.nameKey == "staging")
        #expect(record.syncedNameKey == nil)
        record.name = "PRODUCCIÓN"
        record.syncedName = "Produccio\u{301}n"
        #expect(record.nameKey == "producción")
        #expect(record.syncedNameKey == record.nameKey)
    }

    @Test func patternsRejectAnotherEnvironmentAtomically() throws {
        let seeded = try SeededDatabase()
        let environmentID = EnvironmentID()
        let stray = BranchPatternModel(environmentID: EnvironmentID(), pattern: "main", type: .branch)
        #expect(throws: StoreError.scopeMismatch) {
            try seeded.config.insertEnvironment(Sample.environment(id: environmentID, repositoryID: seeded.repo.id, policy: .custom([stray])))
        }
        #expect(try seeded.config.fetchEnvironment(id: environmentID) == nil)

        try seeded.config.insertEnvironment(Sample.environment(id: environmentID, repositoryID: seeded.repo.id, policy: .custom([])))
        var pattern = BranchPatternModel(environmentID: environmentID, pattern: "main", type: .branch)
        try seeded.config.insertPattern(pattern)
        pattern.githubPolicyID = 11
        try seeded.config.updatePattern(pattern)
        #expect(try seeded.config.fetchPatterns(environmentID: environmentID) == [pattern])
        var moved = pattern
        moved.environmentID = EnvironmentID()
        #expect(throws: StoreError.scopeMismatch) { try seeded.config.updatePattern(moved) }
        #expect(throws: StoreError.notFound) {
            try seeded.config.updatePattern(BranchPatternModel(environmentID: environmentID, pattern: "x", type: .tag))
        }
        #expect(try seeded.config.deletePattern(id: pattern.id))
        #expect(try seeded.config.fetchPatterns(environmentID: environmentID).isEmpty)
    }

    @Test func itemRecordRoundTripAndProjection() throws {
        let seeded = try SeededDatabase()
        let packageID = SharePackageID()
        let item = ConfigItemRecord(
            repositoryID: seeded.repo.id,
            scope: .repository,
            kind: .secret,
            name: "STRIPE_KEY",
            valueCiphertext: Sample.ciphertext(),
            valueFingerprint: Sample.fingerprint(),
            syncedName: "STRIPE_KEY",
            syncedValueCiphertext: Sample.ciphertext(0x01),
            syncedFingerprint: Sample.fingerprint(),
            remoteUpdatedAt: Sample.date(7),
            verifyState: .pending,
            preWriteUpdatedAt: Sample.date(6),
            provenance: .share,
            shareOrigin: ShareOriginModel(packageID: packageID, senderName: "Teammate"),
            createdAt: Sample.start,
            updatedAt: Sample.date(8)
        )
        try seeded.config.insertItem(item)
        #expect(try seeded.config.fetchItemRecord(id: item.id) == item)

        let state = try #require(try seeded.config.fetchItemStates(repositoryID: seeded.repo.id).first)
        #expect(state == item.state)
        #expect(state.hasValue)
        #expect(state.hasSyncedValue)
        #expect(state.valueFingerprint == Sample.fingerprint())

        let model = try #require(try seeded.config.fetchItems(repositoryID: seeded.repo.id).first)
        #expect(model == item.model)
        #expect(model.shareOrigin?.packageID == packageID)
        #expect(model.syncStatus == .unverifiedShare)
        #expect(model.valueState == .present)
    }

    @Test(arguments: StatusCase.all)
    func statusIsDerivedFromFingerprintsAndFlags(_ statusCase: StatusCase) throws {
        let seeded = try SeededDatabase()
        var item = Sample.item(repositoryID: seeded.repo.id, hasValue: statusCase.hasValue)
        item.syncedName = statusCase.syncedName
        item.syncedFingerprint = statusCase.syncedFingerprint
        item.isDeleted = statusCase.isDeleted
        item.forcePush = statusCase.forcePush
        try seeded.config.insertItem(item)
        #expect(try seeded.config.fetchItems(repositoryID: seeded.repo.id).first?.syncStatus == statusCase.expected)
    }

    struct StatusCase: Sendable, CustomTestStringConvertible {
        var label: String
        var hasValue = true
        var syncedName: String?
        var syncedFingerprint: Data?
        var isDeleted = false
        var forcePush = false
        var expected: ConfigSyncStatus

        var testDescription: String { label }

        static let all: [StatusCase] = [
            StatusCase(label: "new item", expected: .added),
            StatusCase(label: "synced, same value", syncedName: "API_TOKEN", syncedFingerprint: Sample.fingerprint(), expected: .synced),
            StatusCase(
                label: "synced, value edited",
                syncedName: "API_TOKEN",
                syncedFingerprint: Sample.fingerprint(Sample.otherFingerprintByte),
                expected: .modified
            ),
            StatusCase(label: "renamed", syncedName: "OLD_TOKEN", syncedFingerprint: Sample.fingerprint(), expected: .added),
            StatusCase(label: "tombstone", syncedName: "API_TOKEN", syncedFingerprint: Sample.fingerprint(), isDeleted: true, expected: .deleted),
            StatusCase(label: "value missing, synced", hasValue: false, syncedName: "API_TOKEN", expected: .synced),
            StatusCase(label: "value missing, new", hasValue: false, expected: .blocked),
            StatusCase(label: "value missing, force push", hasValue: false, syncedName: "API_TOKEN", forcePush: true, expected: .blocked),
            StatusCase(
                label: "force push",
                syncedName: "API_TOKEN",
                syncedFingerprint: Sample.fingerprint(),
                forcePush: true,
                expected: .willPush
            ),
        ]
    }

    @Test func itemScopeMustBelongToTheRepository() throws {
        let seeded = try SeededDatabase()
        let other = Sample.repo(name: "fx-test-other", githubID: "R_other")
        try seeded.repos.insert(other)
        let foreignEnvironment = Sample.environment(repositoryID: other.id)
        try seeded.config.insertEnvironment(foreignEnvironment)

        #expect(throws: StoreError.scopeMismatch) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(foreignEnvironment.id)))
        }
        #expect(throws: StoreError.constraintViolation(.foreignKey)) {
            try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(EnvironmentID())))
        }
    }

    @Test func kindAndScopeAreLockedOnceSynced() throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id)
        try seeded.config.insertEnvironment(environment)

        // Unsynced: may move and convert.
        var draft = Sample.item(repositoryID: seeded.repo.id)
        try seeded.config.insertItem(draft)
        draft.scope = .environment(environment.id)
        draft.kind = .variable
        try seeded.config.updateItem(draft)
        #expect(try seeded.config.fetchItemRecord(id: draft.id)?.scope == .environment(environment.id))

        // Synced: value and name may change, kind and scope may not.
        var synced = Sample.item(repositoryID: seeded.repo.id, name: "SYNCED")
        synced.syncedName = "SYNCED"
        synced.syncedFingerprint = Sample.fingerprint()
        try seeded.config.insertItem(synced)
        synced.valueFingerprint = Sample.fingerprint(Sample.otherFingerprintByte)
        synced.name = "SYNCED_RENAMED"
        try seeded.config.updateItem(synced)

        var converted = synced
        converted.kind = .variable
        #expect(throws: StoreError.immutableAfterSync) { try seeded.config.updateItem(converted) }
        var moved = synced
        moved.scope = .environment(environment.id)
        #expect(throws: StoreError.immutableAfterSync) { try seeded.config.updateItem(moved) }
        #expect(throws: StoreError.notFound) {
            try seeded.config.updateItem(Sample.item(repositoryID: seeded.repo.id, name: "GHOST"))
        }
    }

    @Test func countsIdsAndDeletes() throws {
        let seeded = try SeededDatabase()
        let first = Sample.item(repositoryID: seeded.repo.id, name: "A")
        var tombstone = Sample.item(repositoryID: seeded.repo.id, name: "B")
        tombstone.syncedName = "B"
        tombstone.isDeleted = true
        try seeded.config.insertItem(first)
        try seeded.config.insertItem(tombstone)
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, kind: .variable, name: "C"))

        #expect(try seeded.config.countActiveItems(repositoryID: seeded.repo.id, scope: .repository, kind: .secret) == 1)
        #expect(try seeded.config.countActiveItems(repositoryID: seeded.repo.id, scope: .repository, kind: .variable) == 1)
        #expect(try seeded.config.fetchItemIDs().count == 3)
        #expect(try seeded.config.fetchItemIDs(repositoryID: RepoID()).isEmpty)
        #expect(try seeded.config.fetchItemRecords(repositoryID: seeded.repo.id).map(\.name) == ["A", "B", "C"])
        #expect(try seeded.config.fetchItemRecords(repositoryID: seeded.repo.id, scope: .environment(EnvironmentID())).isEmpty)

        #expect(try seeded.config.deleteItem(id: first.id))
        #expect(try seeded.config.deleteItem(id: first.id) == false)
        #expect(try seeded.config.fetchItems(repositoryID: seeded.repo.id).map(\.name) == ["B", "C"])
    }

    @Test func pendingInputsCarryNoCiphertext() throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id, policy: .custom([]))
        try seeded.config.insertEnvironment(environment)
        try seeded.config.insertPattern(BranchPatternModel(environmentID: environment.id, pattern: "main", type: .branch))
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(environment.id)))
        let other = Sample.repo(name: "fx-test-other", githubID: "R_other")
        try seeded.repos.insert(other)

        let inputs = try #require(try seeded.config.fetchPendingInputs(repositoryID: seeded.repo.id))
        #expect(inputs.repository == seeded.repo)
        #expect(inputs.environments.map(\.id) == [environment.id])
        #expect(inputs.environments.first?.branchPolicy.patterns.map(\.pattern) == ["main"])
        #expect(inputs.items.map(\.name) == ["API_TOKEN"])
        #expect(try seeded.config.fetchPendingInputs(repositoryID: RepoID()) == nil)

        let all = try seeded.config.fetchAllPendingInputs()
        #expect(all.map(\.repository.id) == [other.id, seeded.repo.id])
        #expect(all.first?.items.isEmpty == true)
        #expect(all.last == inputs)
    }
}

@Suite("SharePackageStore")
struct SharePackageStoreTests {
    @Test func recordsAndDetectsReplays() throws {
        let seeded = try SeededDatabase()
        let packageID = SharePackageID()
        #expect(try seeded.shares.hasImported(packageID) == false)

        let first = ImportedSharePackageRecord(packageID: packageID, createdAt: Sample.start, importedAt: Sample.date(10), senderName: "Teammate")
        try seeded.shares.recordImport(first)
        #expect(try seeded.shares.hasImported(packageID))
        #expect(try seeded.shares.fetch(packageID) == first)

        var again = first
        again.importedAt = Sample.date(20)
        try seeded.shares.recordImport(again)
        #expect(try seeded.shares.fetchAll() == [again])
    }
}

@Suite("Transactions")
struct TransactionTests {
    @Test func aThrowingBodyRollsBackAndItsErrorPassesThrough() throws {
        let seeded = try SeededDatabase()
        #expect(throws: TestError.rollback) {
            try seeded.database.write { tx in
                try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id), in: tx)
                throw TestError.rollback
            }
        }
        #expect(try seeded.config.fetchItems(repositoryID: seeded.repo.id).isEmpty)
    }

    @Test func writesFailInsideARead() throws {
        let seeded = try SeededDatabase()
        #expect(throws: StoreError.self) {
            try seeded.database.read { tx in
                try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id), in: tx)
            }
        }
    }
}
