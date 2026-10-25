import Foundation
import GitHubKit
import os
import SyncEngine
import VaultCore
import VaultData
@testable import FXVault

/// A run the test drives by hand: it sends progress events and finishes with an outcome.
final class FakeSyncRun: SyncRunControlling {
    let progress: AsyncStream<SyncProgressEventModel>
    private let progressContinuation: AsyncStream<SyncProgressEventModel>.Continuation
    private let outcomes: AsyncStream<SyncRunOutcomeModel>
    private let outcomeContinuation: AsyncStream<SyncRunOutcomeModel>.Continuation
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init() {
        (progress, progressContinuation) = AsyncStream.makeStream()
        (outcomes, outcomeContinuation) = AsyncStream.makeStream()
    }

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func send(_ event: SyncProgressEventModel) {
        progressContinuation.yield(event)
    }

    /// Sends `.finished`, ends the progress stream and hands out `outcome`.
    func finish(_ outcome: SyncRunOutcomeModel) {
        progressContinuation.yield(.finished(outcome.result))
        progressContinuation.finish()
        outcomeContinuation.yield(outcome)
        outcomeContinuation.finish()
    }

    func outcome() async -> SyncRunOutcomeModel {
        for await outcome in outcomes {
            return outcome
        }
        return SyncRunOutcomeModel(
            result: SyncResultModel(runID: SyncRunID(), repositories: [], stopReason: .cancelled, warnings: []),
            clones: []
        )
    }
}

/// A scripted ``SyncServicing`` that records what the view model asked for.
final class FakeSyncService: SyncServicing {
    struct StartedRun: Equatable {
        let includeDeletions: Bool
        let cloneFolder: URL?
        /// The share files the From Files review included (v0.9.0).
        var includeHeld: Set<SharePackageID> = []
    }

    private struct State {
        var review: Result<SyncReviewModel, SyncRepositoryError>
        var previews: [RepoDeletionPreviewModel] = []
        var preflightCalls: [[RepoID]?] = []
        var startedRuns: [StartedRun] = []
        var clones: [RepoID] = []
        var cloneResult: Result<URL, RepoCreationError> = .failure(.gitUnavailable)
    }

    let run = FakeSyncRun()
    private let state: OSAllocatedUnfairLock<State>

    init(review: Result<SyncReviewModel, SyncRepositoryError>) {
        state = OSAllocatedUnfairLock(initialState: State(review: review))
    }

    var preflightCalls: [[RepoID]?] {
        state.withLock { $0.preflightCalls }
    }

    func setReview(_ review: Result<SyncReviewModel, SyncRepositoryError>) {
        state.withLock { $0.review = review }
    }

    var startedRuns: [StartedRun] {
        state.withLock { $0.startedRuns }
    }

    var clonedRepositories: [RepoID] {
        state.withLock { $0.clones }
    }

    func setPreviews(_ previews: [RepoDeletionPreviewModel]) {
        state.withLock { $0.previews = previews }
    }

    func setCloneResult(_ result: Result<URL, RepoCreationError>) {
        state.withLock { $0.cloneResult = result }
    }

    func preflight(repositoryIDs: [RepoID]?) async throws(SyncRepositoryError) -> SyncReviewModel {
        let review = state.withLock { state in
            state.preflightCalls.append(repositoryIDs)
            return state.review
        }
        return try review.get()
    }

    func deletionPreview(for review: SyncReviewModel) async -> [RepoDeletionPreviewModel] {
        state.withLock { $0.previews }
    }

    func startRun(
        _ review: SyncReviewModel,
        includeDeletions: Bool,
        includeHeld: Set<SharePackageID>,
        cloneFolder: URL?
    ) async throws(SyncRepositoryError) -> any SyncRunControlling {
        state.withLock {
            $0.startedRuns.append(StartedRun(
                includeDeletions: includeDeletions,
                cloneFolder: cloneFolder,
                includeHeld: includeHeld
            ))
        }
        return run
    }

    func clone(_ repositoryID: RepoID, into folder: URL) async throws(RepoCreationError) -> URL {
        let result = state.withLock { state in
            state.clones.append(repositoryID)
            return state.cloneResult
        }
        return try result.get()
    }
}

/// Synthetic sync data (lessons.md: no real identifiers).
enum SyncFixtures {
    static let repository = RepoModel(
        accountLogin: TestFixtures.account,
        githubID: "R_example",
        ownerLogin: TestFixtures.owner,
        ownerType: .organization,
        name: TestFixtures.repoName,
        visibility: .private,
        hasAdmin: true,
        hasPush: true,
        origin: .imported,
        importedAt: Date(timeIntervalSince1970: 0)
    )

    static let fullName = "\(TestFixtures.owner)/\(TestFixtures.repoName)"
    static let environmentID = EnvironmentID()
    static let usedWrites = 12

    static func set(
        _ kind: ConfigKind,
        _ name: String,
        environment: String? = nil,
        isNew: Bool = true,
        reason: ItemSetChangeModel.Reason = .added,
        itemID: ConfigItemID = ConfigItemID()
    ) -> ConfigChangeModel {
        ConfigChangeModel(repositoryID: repository.id, operation: .setItem(ItemSetChangeModel(
            itemID: itemID,
            environmentID: environment == nil ? nil : environmentID,
            environmentName: environment,
            kind: kind,
            name: name,
            isNew: isNew,
            reason: reason
        )))
    }

    static func deleteItem(_ kind: ConfigKind, _ name: String) -> ConfigChangeModel {
        ConfigChangeModel(repositoryID: repository.id, operation: .deleteItem(ItemDeleteChangeModel(
            itemID: ConfigItemID(),
            environmentID: nil,
            environmentName: nil,
            kind: kind,
            name: name,
            reason: .deleted
        )))
    }

    static func deleteEnvironment(_ name: String) -> ConfigChangeModel {
        ConfigChangeModel(repositoryID: repository.id, operation: .deleteEnvironment(EnvironmentDeleteChangeModel(
            environmentID: environmentID,
            name: name,
            githubID: 7,
            syncedPolicy: .all,
            impliedItems: []
        )))
    }

    static func createRepository(cloneAfter: Bool) -> ConfigChangeModel {
        ConfigChangeModel(repositoryID: repository.id, operation: .createRepository(RepositoryCreateChangeModel(
            ownerLogin: TestFixtures.owner,
            name: TestFixtures.repoName,
            visibility: .private,
            description: nil,
            spec: RepoCreateSpecModel(autoInit: true, cloneAfter: cloneAfter)
        )))
    }

    static func preflight(
        executable: [ConfigChangeModel],
        blocked: [SyncBlockedChangeModel] = [],
        repository: RepoModel = repository
    ) -> RepoPreflightModel {
        RepoPreflightModel(
            snapshot: RepoSnapshotModel(repository: repository, environments: [], items: []),
            changeSet: ChangeSetModel(repository: repository, changes: executable),
            executable: executable,
            blocked: blocked
        )
    }

    static func review(
        _ repositories: [RepoPreflightModel],
        credentialWarnings: [SyncCredentialWarningModel] = [],
        estimatedWriteCost: Int = 1
    ) -> SyncReviewModel {
        SyncReviewModel(
            preflight: SyncPreflightModel(
                runID: SyncRunID(),
                repositories: repositories,
                writeBudgets: [TestFixtures.account: WriteBudgetModel(used: usedWrites)],
                estimatedWriteCost: estimatedWriteCost
            ),
            credentialWarnings: credentialWarnings
        )
    }

    static func outcome(
        _ entries: [SyncChangeResultModel],
        stopReason: SyncStopReason? = nil,
        warnings: [SyncWarningModel] = [],
        clones: [RepoCloneOutcomeModel] = []
    ) -> SyncRunOutcomeModel {
        SyncRunOutcomeModel(
            result: SyncResultModel(
                runID: SyncRunID(),
                repositories: [RepoSyncResultModel(repositoryID: repository.id, fullName: fullName, entries: entries)],
                stopReason: stopReason,
                warnings: warnings
            ),
            clones: clones
        )
    }
}

/// Records the links the view model opens.
@MainActor
final class URLRecorder {
    var opened: [URL] = []
}

/// Counts calls of an injected closure.
@MainActor
final class Counter {
    var value = 0
}
