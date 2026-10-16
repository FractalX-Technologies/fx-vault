import CryptoKit
import DestinationKit
import Foundation
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// An in-memory destination: what a provider would hold, with switches for failures.
final class FakeDestinationRemote: DestinationRemoting, @unchecked Sendable {
    struct Entry {
        var value: Data
        var kind: ConfigKind
        var version: Int
        var isReadable: Bool
    }

    let provider: DestinationProvider
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextVersion = 100
    var failNextWrite: DestinationError?
    var failList: DestinationError?
    private(set) var writes: [String] = []
    private(set) var deletes: [String] = []

    init(provider: DestinationProvider) {
        self.provider = provider
    }

    /// Puts an item in the remote as a teammate would.
    func put(_ name: String, value: String, kind: ConfigKind = .secret, readable: Bool? = nil) {
        lock.withLock {
            nextVersion += 1
            entries[DestinationRules.remoteName(for: name, provider: provider)] = Entry(
                value: Data(value.utf8),
                kind: kind,
                version: nextVersion,
                isReadable: readable ?? provider.returnsValues
            )
        }
    }

    func remove(_ name: String) {
        _ = lock.withLock { entries.removeValue(forKey: DestinationRules.remoteName(for: name, provider: provider)) }
    }

    func value(of name: String) -> String? {
        lock.withLock { entries[DestinationRules.remoteName(for: name, provider: provider)].map { String(decoding: $0.value, as: UTF8.self) } }
    }

    var names: [String] {
        lock.withLock { entries.keys.sorted() }
    }

    func list() async throws(DestinationError) -> [RemoteDestinationItemModel] {
        if let failList { throw failList }
        return lock.withLock {
            entries.map { remoteName, entry in
                let digest = provider == .supabase ? SHA256.hash(data: entry.value).map { String(format: "%02x", $0) }.joined() : nil
                return RemoteDestinationItemModel(
                    remoteName: remoteName,
                    name: DestinationRules.localName(forRemoteName: remoteName, provider: provider),
                    unusableReason: DestinationRules.unusableReason(forRemoteName: remoteName, provider: provider).map { .invalidName($0) },
                    kind: entry.kind,
                    remoteRef: provider == .vercel ? "env_\(remoteName)" : nil,
                    version: digest ?? String(entry.version),
                    digest: digest,
                    isValueReadable: entry.isReadable,
                    otherTargets: [],
                    updatedAt: nil
                )
            }
        }
    }

    func readValue(of item: RemoteDestinationItemModel) async throws(DestinationError) -> SecretBytes {
        guard let entry = lock.withLock({ entries[item.remoteName] }), entry.isReadable else {
            throw .invalidRequest(code: "writeOnly")
        }
        return SecretBytes(entry.value)
    }

    func setValue(_ value: SecretBytes, name: String, kind: ConfigKind, existing: RemoteDestinationItemModel?) async throws(DestinationError) -> RemoteWriteResultModel {
        if let failure = lock.withLock({ () -> DestinationError? in
            defer { failNextWrite = nil }
            return failNextWrite
        }) {
            throw failure
        }
        let remoteName = DestinationRules.remoteName(for: name, provider: provider)
        let bytes = value.withUnsafeBytes { Data($0) }
        let version = lock.withLock { () -> Int in
            nextVersion += 1
            entries[remoteName] = Entry(value: bytes, kind: provider.storedKind(for: kind), version: nextVersion, isReadable: provider.returnsValues)
            writes.append(name)
            return nextVersion
        }
        return RemoteWriteResultModel(version: provider == .supabase ? nil : String(version), remoteRef: nil)
    }

    func delete(_ item: RemoteDestinationItemModel) async throws(DestinationError) {
        let removed = lock.withLock { () -> Bool in
            guard entries.removeValue(forKey: item.remoteName) != nil else { return false }
            deletes.append(item.name ?? item.remoteName)
            return true
        }
        guard removed else { throw .notFound }
    }
}

/// Hands out one fake remote per destination.
final class FakeDestinationRemotes: DestinationRemoteProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var remotes: [DestinationID: FakeDestinationRemote] = [:]
    private(set) var tokens: [String] = []

    func remote(for destination: DestinationModel, token: SecretBytes?) async throws(DestinationError) -> any DestinationRemoting {
        if let token, let text = token.utf8String() {
            lock.withLock { tokens.append(text) }
        }
        return fake(for: destination.id, provider: destination.provider)
    }

    func fake(for id: DestinationID, provider: DestinationProvider) -> FakeDestinationRemote {
        lock.withLock {
            if let remote = remotes[id] { return remote }
            let remote = FakeDestinationRemote(provider: provider)
            remotes[id] = remote
            return remote
        }
    }
}

/// Destination Sync, Refresh and import (v0.8.0, tasks/todo.md R5, R6) over in-memory remotes.
@Suite("DestinationSyncRepository")
struct DestinationSyncRepositoryTests {
    struct Fixture {
        let harness: ConfigHarness
        let destinations: DestinationRepository
        let sync: DestinationSyncRepository
        let remotes: FakeDestinationRemotes
        let repo: RepoModel

        static func make() async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            let remotes = FakeDestinationRemotes()
            return Fixture(
                harness: harness,
                destinations: DestinationRepository(session: harness.session, clock: harness.clock),
                sync: DestinationSyncRepository(session: harness.session, remotes: remotes, clock: harness.clock),
                remotes: remotes,
                repo: try harness.seedRepository()
            )
        }

        func keyVault() throws -> (DestinationID, FakeDestinationRemote) {
            let id = try destinations.createDestination(
                repositoryID: repo.id,
                target: .azureKeyVault(vaultName: "kv-sample-prod", tenantID: nil),
                stage: "production",
                connectionID: nil
            )
            return (id, remotes.fake(for: id, provider: .azureKeyVault))
        }

        func supabase() throws -> (DestinationID, FakeDestinationRemote) {
            let connection = try destinations.addConnection(provider: .supabase, label: "Supabase", token: SecretBytes(utf8: "sbp_sample"), accountHint: nil)
            let id = try destinations.createDestination(
                repositoryID: repo.id,
                target: .supabase(projectRef: "abcdefghijklmnopqrst"),
                stage: "production",
                connectionID: connection
            )
            return (id, remotes.fake(for: id, provider: .supabase))
        }

        func vercel() throws -> (DestinationID, FakeDestinationRemote) {
            let connection = try destinations.addConnection(provider: .vercel, label: "Vercel", token: SecretBytes(utf8: "vercel-token"), accountHint: nil)
            let id = try destinations.createDestination(
                repositoryID: repo.id,
                target: .vercel(projectID: "prj_sample", projectName: "sample-web", teamID: nil, environment: .production),
                stage: "production",
                connectionID: connection
            )
            return (id, remotes.fake(for: id, provider: .vercel))
        }

        @discardableResult
        func add(_ destination: DestinationID, _ name: String, kind: ConfigKind = .secret, value: String) throws -> ConfigItemID {
            try destinations.addItem(destinationID: destination, kind: kind, name: name, value: SecretBytes(utf8: value)).itemID
        }

        func item(_ destination: DestinationID, _ name: String) throws -> DestinationItemModel {
            try #require(try destinations.items(destinationID: destination).first { $0.name == name })
        }

        func reveal(_ id: ConfigItemID) throws -> String? {
            let value = try destinations.reveal(id)
            defer { value.wipe() }
            return value.utf8String()
        }

        func syncAll(includeDeletions: Bool = true) async -> (DestinationReviewModel, DestinationRunResultModel) {
            let review = await sync.review(repositoryID: repo.id)
            let result = await sync.run(review, includeDeletions: includeDeletions)
            return (review, result)
        }
    }

    // MARK: - Run

    @Test func aSyncPushesAddsUpdatesAndDeletesThenConfirms() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        try fixture.add(vault, "DATABASE_URL", value: "postgres://a")
        try fixture.add(vault, "OLD_KEY", value: "old")
        var (review, result) = await fixture.syncAll()
        #expect(review.executableCount == 2)
        #expect(result.doneCount == 2)
        #expect(remote.names == ["DATABASE-URL", "OLD-KEY"])
        #expect(remote.value(of: "DATABASE_URL") == "postgres://a")
        #expect(try fixture.item(vault, "DATABASE_URL").syncStatus == .synced)
        #expect(try fixture.item(vault, "DATABASE_URL").verifyState == .verified)
        #expect(try fixture.destinations.pendingCounts().isEmpty)

        let database = try fixture.item(vault, "DATABASE_URL")
        try fixture.destinations.editItem(database.id, name: "DATABASE_URL", kind: .secret, value: SecretBytes(utf8: "postgres://b"))
        try fixture.destinations.deleteItems([try fixture.item(vault, "OLD_KEY").id])
        (review, result) = await fixture.syncAll(includeDeletions: false)
        #expect(review.sections.first?.deletions.map(\.name) == ["OLD_KEY"])
        #expect(result.outcomes.values.contains(.skipped))
        #expect(remote.value(of: "DATABASE_URL") == "postgres://b")
        #expect(remote.names.contains("OLD-KEY"))

        (_, result) = await fixture.syncAll()
        #expect(result.doneCount == 1)
        #expect(remote.names == ["DATABASE-URL"])
        #expect(try fixture.destinations.items(destinationID: vault).map(\.name) == ["DATABASE_URL"])
        #expect(try fixture.destinations.pendingCounts().isEmpty)
    }

    @Test func reviewBlocksWhatCannotBeSent() async throws {
        let fixture = try await Fixture.make()
        let (web, remote) = try fixture.vercel()
        try fixture.add(web, "NEXT_PUBLIC_STRIPE_KEY", kind: .variable, value: "sk_live_" + String(repeating: "a", count: 24))
        try fixture.add(web, "NEXT_PUBLIC_ANON_KEY", kind: .variable, value: ConfigFixture.sampleJWT)
        try fixture.add(web, "TAKEN_KEY", value: "mine")
        remote.put("TAKEN_KEY", value: "theirs")
        try fixture.add(web, "API_KEY", value: "a")
        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        let section = try #require(review.sections.first)
        #expect(section.changes.map(\.name) == ["API_KEY", "NEXT_PUBLIC_ANON_KEY"])
        let reasons = Dictionary(uniqueKeysWithValues: section.blocked.map { ($0.change.name, $0.reason) })
        #expect(reasons["NEXT_PUBLIC_STRIPE_KEY"] == .publicCredential(prefix: "NEXT_PUBLIC_"))
        #expect(reasons["TAKEN_KEY"] == .existsRemotely)
        #expect(section.warnings.map(\.name) == ["NEXT_PUBLIC_ANON_KEY"])
        // The provider token reached the remote.
        #expect(fixture.remotes.tokens.contains("vercel-token"))

        // Mark as Public lets the value through.
        try fixture.destinations.setPublicAllowed(try fixture.item(web, "NEXT_PUBLIC_STRIPE_KEY").id, allowed: true)
        let again = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(again.sections.first?.changes.map(\.name).contains("NEXT_PUBLIC_STRIPE_KEY") == true)
    }

    @Test func aRemoteChangeSinceTheLastSyncBlocksTheUpdate() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let id = try fixture.add(vault, "API_KEY", value: "a")
        _ = await fixture.syncAll()
        remote.put("API_KEY", value: "teammate")
        try fixture.destinations.editItem(id, name: "API_KEY", kind: .secret, value: SecretBytes(utf8: "mine"))
        let (review, result) = await fixture.syncAll()
        #expect(review.sections.first?.blocked.first?.reason == .remoteChanged)
        #expect(result.outcomes.isEmpty)
        #expect(remote.value(of: "API_KEY") == "teammate")

        // Refresh shows it; Keep Mine pushes ours on the next Sync.
        let refresh = try await fixture.sync.refresh(destinationID: vault)
        #expect(refresh.findings.map(\.kind) == [.remoteChanged])
        try await fixture.sync.resolve(refresh.findings, choice: .keepMine, destinationID: vault)
        let (_, pushed) = await fixture.syncAll()
        #expect(pushed.doneCount == 1)
        #expect(remote.value(of: "API_KEY") == "mine")
    }

    @Test func aFailedWriteStaysPendingAndIsJournaled() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        try fixture.add(vault, "API_KEY", value: "a")
        remote.failNextWrite = .forbidden
        let (_, result) = await fixture.syncAll()
        #expect(result.failedCount == 1)
        #expect(try fixture.item(vault, "API_KEY").syncStatus == .added)
        let journal = try DestinationStore(database: fixture.harness.database).fetchJournal()
        #expect(journal.map(\.state) == [.failed])
        #expect(journal.first?.errorCode == DestinationError.forbidden.logCode)
        #expect(journal.first?.itemName == "API_KEY")
    }

    @Test func anInterruptedWriteIsReconciledByTheNextListing() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let id = try fixture.add(vault, "API_KEY", value: "a")
        // The write went through but the answer was lost (a timeout).
        remote.failNextWrite = .timeout
        _ = await fixture.syncAll()
        #expect(try fixture.item(vault, "API_KEY").syncStatus == .added)
        let store = DestinationStore(database: fixture.harness.database)
        let record = try #require(try store.fetchItemRecord(id: id))
        // The fingerprint of the value sent was journaled before the write.
        #expect(try store.fetchJournal().map(\.pushedFingerprint) == [record.valueFingerprint])
        remote.put("API_KEY", value: "a")
        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.isEmpty || review.executableCount == 0)
        #expect(try fixture.item(vault, "API_KEY").syncStatus == .synced)
        let states = try store.fetchJournal().map(\.state)
        #expect(states == [.reconciled])
    }

    @Test func anEditAfterAnInterruptedWriteStaysPending() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let id = try fixture.add(vault, "API_KEY", value: "a")
        remote.failNextWrite = .timeout
        _ = await fixture.syncAll()
        // The write landed; the user edits the value before the next Sync.
        remote.put("API_KEY", value: "a")
        try fixture.destinations.editItem(id, name: "API_KEY", kind: .secret, value: SecretBytes(utf8: "b"))

        let review = await fixture.sync.review(repositoryID: fixture.repo.id)

        // Reconciled with the value that was sent, so the edit is still a change to push.
        #expect(try DestinationStore(database: fixture.harness.database).fetchJournal().map(\.state) == [.reconciled])
        #expect(try fixture.item(vault, "API_KEY").syncStatus == .modified)
        #expect(review.executableCount == 1)
        let result = await fixture.sync.run(review, includeDeletions: false)
        #expect(result.outcomes.values.allSatisfy { $0 == .done })
        #expect(remote.value(of: "API_KEY") == "b")
    }

    @Test func supabaseDigestsAreStoredOnlyAsKeyedMarkers() async throws {
        let fixture = try await Fixture.make()
        let (functions, remote) = try fixture.supabase()
        let id = try fixture.add(functions, "STRIPE_SECRET_KEY", value: "sk_test_value")
        remote.put("OTHER_KEY", value: "other")
        _ = try await fixture.sync.importRemote(destinationID: functions)
        _ = await fixture.syncAll()

        let store = DestinationStore(database: fixture.harness.database)
        let digest = SHA256.hash(data: Data("sk_test_value".utf8)).map { String(format: "%02x", $0) }.joined()
        let records = try fixture.harness.database.read { tx in try store.fetchItemRecords(destinationID: functions, in: tx) }
        #expect(records.count == 2)
        for record in records {
            let marker = try #require(record.remoteVersion)
            #expect(marker.hasPrefix(DestinationFieldCipher.markerPrefix))
            #expect(!marker.contains(digest))
            #expect(record.preWriteVersion.map { $0.hasPrefix(DestinationFieldCipher.markerPrefix) } ?? true)
        }
        #expect(try store.fetchJournal().allSatisfy { $0.preWriteVersion.map { !$0.contains(digest) } ?? true })
        // Equal listings still compare equal: nothing changed since the sync.
        #expect(try await fixture.sync.refresh(destinationID: functions).findings.isEmpty)
        // A teammate's new value shows as a change.
        remote.put("STRIPE_SECRET_KEY", value: "sk_test_rotated")
        let findings = try await fixture.sync.refresh(destinationID: functions).findings
        #expect(findings.map(\.itemID) == [id])
    }

    @Test func dekRotationReKeysSupabaseMarkers() async throws {
        let fixture = try await Fixture.make()
        let (functions, _) = try fixture.supabase()
        let id = try fixture.add(functions, "STRIPE_SECRET_KEY", value: "sk_test_value")
        _ = await fixture.syncAll()
        let store = DestinationStore(database: fixture.harness.database)
        let before = try #require(try store.fetchItemRecord(id: id)?.remoteVersion)

        _ = try await fixture.harness.manager.rotateDEK(password: ConfigFixture.password)

        let after = try #require(try store.fetchItemRecord(id: id)?.remoteVersion)
        #expect(after != before)
        #expect(after.hasPrefix(DestinationFieldCipher.markerPrefix))
        #expect(try await fixture.sync.refresh(destinationID: functions).findings.isEmpty)
        try fixture.destinations.editItem(id, name: "STRIPE_SECRET_KEY", kind: .secret, value: SecretBytes(utf8: "sk_test_next"))
        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.executableCount == 1)
    }

    @Test func supabaseWritesAreConfirmedByTheirDigest() async throws {
        let fixture = try await Fixture.make()
        let (functions, remote) = try fixture.supabase()
        try fixture.add(functions, "STRIPE_SECRET_KEY", value: "sk_test_value")
        let (_, result) = await fixture.syncAll()
        #expect(result.outcomes.values.allSatisfy { $0 == .done })
        #expect(remote.value(of: "STRIPE_SECRET_KEY") == "sk_test_value")
        #expect(try fixture.item(functions, "STRIPE_SECRET_KEY").verifyState == .verified)
    }

    @Test func aMissingConnectionBlocksEveryChange() async throws {
        let fixture = try await Fixture.make()
        let (functions, _) = try fixture.supabase()
        try fixture.add(functions, "API_KEY", value: "a")
        let connection = try #require(try fixture.destinations.destination(functions)?.connectionID)
        try fixture.destinations.deleteConnection(connection)
        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.sections.first?.blocked.map(\.reason) == [.connectionMissing])
        #expect(review.executableCount == 0)
    }

    @Test func aListingFailureBlocksTheDestination() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        try fixture.add(vault, "API_KEY", value: "a")
        remote.failList = .azNotSignedIn
        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.sections.first?.blocked.map(\.reason) == [.listingFailed(.azNotSignedIn)])
    }

    // MARK: - Refresh, resolve and import

    @Test func refreshFindsAddsChangesAndDeletionsAndResolvesThem() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let changed = try fixture.add(vault, "CHANGED_KEY", value: "a")
        try fixture.add(vault, "GONE_KEY", value: "b")
        _ = await fixture.syncAll()
        remote.put("CHANGED_KEY", value: "teammate")
        remote.remove("GONE_KEY")
        remote.put("NEW_KEY", value: "new")
        remote.put("lower-case-key", value: "kept")
        let refresh = try await fixture.sync.refresh(destinationID: vault)
        let kinds = Dictionary(uniqueKeysWithValues: refresh.findings.map { ($0.name, $0.kind) })
        #expect(kinds == ["CHANGED_KEY": .remoteChanged, "GONE_KEY": .remoteDeleted, "NEW_KEY": .remoteAdded, "LOWER_CASE_KEY": .remoteAdded])

        try await fixture.sync.resolve(refresh.findings, choice: .useRemote, destinationID: vault)
        #expect(try fixture.reveal(changed) == "teammate")
        #expect(try fixture.destinations.items(destinationID: vault).map(\.name).sorted() == ["CHANGED_KEY", "LOWER_CASE_KEY", "NEW_KEY"])
        #expect(try fixture.reveal(try fixture.item(vault, "NEW_KEY").id) == "new")
        #expect(try fixture.destinations.pendingCounts().isEmpty)
        #expect(try await fixture.sync.refresh(destinationID: vault).findings.isEmpty)
    }

    @Test func resolvingAStaleFindingWritesNothing() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        remote.put("NEW_KEY", value: "new")
        let refresh = try await fixture.sync.refresh(destinationID: vault)
        remote.remove("NEW_KEY")
        await #expect(throws: DestinationSyncError.stale) {
            try await fixture.sync.resolve(refresh.findings, choice: .useRemote, destinationID: vault)
        }
        #expect(try fixture.destinations.items(destinationID: vault).isEmpty)
    }

    @Test func importBringsReadableValuesAndListsWriteOnlyOnes() async throws {
        let fixture = try await Fixture.make()
        let (functions, remote) = try fixture.supabase()
        remote.put("STRIPE_SECRET_KEY", value: "sk_test")
        remote.put("SUPABASE_URL", value: "reserved")
        let result = try await fixture.sync.importRemote(destinationID: functions)
        #expect(result.imported == ["STRIPE_SECRET_KEY"])
        #expect(result.withoutValue == ["STRIPE_SECRET_KEY"])
        #expect(result.unusable.map(\.remoteName) == ["SUPABASE_URL"])
        let item = try fixture.item(functions, "STRIPE_SECRET_KEY")
        #expect(item.valueState == .missing)
        #expect(item.isSynced)
        #expect(try fixture.destinations.pendingCounts().isEmpty)

        // Filling the value without "already matches" pushes it on the next Sync.
        try fixture.destinations.fillValue(item.id, value: SecretBytes(utf8: "sk_test_new"), alreadyMatchesRemote: false)
        let (_, run) = await fixture.syncAll()
        #expect(run.doneCount == 1)
        #expect(remote.value(of: "STRIPE_SECRET_KEY") == "sk_test_new")
    }

    @Test func aRemovedTombstoneTargetIsClearedByRefresh() async throws {
        let fixture = try await Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let id = try fixture.add(vault, "API_KEY", value: "a")
        _ = await fixture.syncAll()
        try fixture.destinations.deleteItems([id])
        remote.remove("API_KEY")
        let refresh = try await fixture.sync.refresh(destinationID: vault)
        #expect(refresh.findings.isEmpty)
        #expect(try fixture.destinations.items(destinationID: vault).isEmpty)
    }
}
