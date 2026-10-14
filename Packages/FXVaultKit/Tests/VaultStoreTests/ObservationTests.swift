import Foundation
import Testing
import VaultCore
@testable import VaultStore

/// ValueObservation-backed streams: current value first, then one value per committed change.
@Suite("Observation streams", .timeLimit(.minutes(1)))
struct ObservationTests {
    @Test func repositoriesStreamEmitsOnInsertAndDelete() async throws {
        let seeded = try SeededDatabase()
        var iterator = seeded.repos.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.id) == [seeded.repo.id])

        let other = Sample.repo(name: "fx-test-other", githubID: "R_other")
        try seeded.repos.insert(other)
        #expect(try await iterator.next()?.map(\.id) == [other.id, seeded.repo.id])

        try seeded.repos.delete(id: other.id)
        #expect(try await iterator.next()?.map(\.id) == [seeded.repo.id])
    }

    @Test func itemsStreamFollowsEditsInItsScopeOnly() async throws {
        let seeded = try SeededDatabase()
        let environment = Sample.environment(repositoryID: seeded.repo.id)
        try seeded.config.insertEnvironment(environment)
        var iterator = seeded.config.observeItems(repositoryID: seeded.repo.id, scope: .repository).makeAsyncIterator()
        #expect(try await iterator.next() == [])

        var item = Sample.item(repositoryID: seeded.repo.id)
        try seeded.config.insertItem(item)
        #expect(try await iterator.next()?.map(\.syncStatus) == [.added])

        // A change in another scope produces no new value (duplicates are skipped).
        try seeded.config.insertItem(Sample.item(repositoryID: seeded.repo.id, scope: .environment(environment.id)))
        item.syncedName = item.name
        item.syncedFingerprint = item.valueFingerprint
        try seeded.config.updateItem(item)
        #expect(try await iterator.next()?.map(\.syncStatus) == [.synced])
    }

    @Test func environmentsAndPendingInputsStreams() async throws {
        let seeded = try SeededDatabase()
        var environments = seeded.config.observeEnvironments(repositoryID: seeded.repo.id).makeAsyncIterator()
        var pending = seeded.config.observePendingInputs(repositoryID: seeded.repo.id).makeAsyncIterator()
        var allPending = seeded.config.observeAllPendingInputs().makeAsyncIterator()
        #expect(try await environments.next() == [])
        #expect(try await pending.next()??.environments.isEmpty == true)
        #expect(try await allPending.next()?.count == 1)

        let environment = Sample.environment(repositoryID: seeded.repo.id, policy: .custom([]))
        try seeded.config.insertEnvironment(environment)
        #expect(try await environments.next()?.map(\.id) == [environment.id])
        #expect(try await pending.next()??.environments.map(\.id) == [environment.id])
        #expect(try await allPending.next()?.first?.environments.count == 1)

        let pattern = BranchPatternModel(environmentID: environment.id, pattern: "main", type: .branch)
        try seeded.config.insertPattern(pattern)
        #expect(try await environments.next()?.first?.branchPolicy == .custom([pattern]))
        #expect(try await pending.next()??.environments.first?.branchPolicy == .custom([pattern]))

        try seeded.repos.delete(id: seeded.repo.id)
        #expect(try await environments.next() == [])
        let afterDelete = try await pending.next()
        #expect(afterDelete == .some(nil))
    }

    @Test func accountsRepoAndLatestRunStreams() async throws {
        let seeded = try SeededDatabase()
        var accounts = seeded.accounts.observeAll().makeAsyncIterator()
        var repo = seeded.repos.observe(id: seeded.repo.id).makeAsyncIterator()
        var latestRun = seeded.journal.observeLatestRun().makeAsyncIterator()
        #expect(try await accounts.next()?.map(\.login) == [Sample.login])
        #expect(try await repo.next()??.id == seeded.repo.id)
        #expect(try await latestRun.next() == [])

        try seeded.accounts.save(Sample.account("zz-second"))
        #expect(try await accounts.next()?.map(\.login) == [Sample.login, "zz-second"])

        var updated = seeded.repo
        updated.isEnvPlanGated = true
        try seeded.repos.update(updated)
        #expect(try await repo.next()??.isEnvPlanGated == true)

        let run = SyncRunID()
        try seeded.journal.appendInFlight(Sample.journal(runID: run, repositoryID: seeded.repo.id, startedAt: Sample.start))
        #expect(try await latestRun.next()?.map(\.runID) == [run])
    }

    @Test func cancellingTheConsumerStopsTheObservation() async throws {
        let seeded = try SeededDatabase()
        let stream = seeded.repos.observeAll()
        let consumer = Task {
            var count = 0
            for try await _ in stream {
                count += 1
            }
            return count
        }
        try seeded.repos.insert(Sample.repo(name: "fx-test-other", githubID: "R_other"))
        consumer.cancel()
        let received = try await consumer.value
        #expect(received >= 0)
        // The database keeps working after the observation ended.
        #expect(try seeded.repos.fetchAll().count == 2)
    }
}
